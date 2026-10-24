# Finish a task: optionally merge task/<Id> into the current branch of the main worktree, then remove the worktree
# and the branch. Refuses when the task worktree has uncommitted changes (nothing is ever force-deleted).
#   task-cleanup.ps1 -Id T1 -Merge        # review passed: merge --no-ff, remove worktree, delete branch
#   task-cleanup.ps1 -Id T1 -Discard      # abandon: remove worktree, delete the unmerged branch
param(
    [string]$Id = '',
    [string]$Repo = '.',
    [switch]$Merge,
    [switch]$Discard
)
. "$PSScriptRoot/lib/Common.ps1"

function Find-TaskWorktree {
    param([string]$Top, [string]$Branch)
    $cur = $null
    foreach ($line in (git -C $Top worktree list --porcelain)) {
        if ($line -like 'worktree *') { $cur = $line.Substring(9) }
        elseif ($line -eq "branch refs/heads/$Branch") { return $cur }
    }
    $null
}

function Remove-TaskWorktree {
    param([string]$Id, [string]$Repo, [switch]$Merge, [switch]$Discard)
    Assert-TaskId $Id
    if ($Merge -and $Discard) { New-AdapterError 'Use -Merge or -Discard, not both.' '' }
    $top = git -C $Repo rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Not a git repository: $Repo" 'Run from the project root.' }
    $branch = "task/$Id"
    git -C $top rev-parse -q --verify "refs/heads/$branch" *> $null
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Branch $branch does not exist." 'Nothing to clean up.' }
    $wt = Find-TaskWorktree $top $branch
    if ($wt -and (git -C $wt status --porcelain)) {
        New-AdapterError "Worktree $wt has uncommitted changes." 'Review them: commit them on the task branch, or ask the worker to. Nothing was deleted.'
    }
    $merged = $null
    if ($Merge) {
        if (git -C $top status --porcelain --untracked-files=no) { New-AdapterError 'The main worktree has uncommitted changes; refusing to merge.' 'Commit or stash them first.' }
        $out = git -C $top merge --no-ff --no-edit $branch -m "merge $branch" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            git -C $top merge --abort *> $null
            New-AdapterError "Merge of $branch failed (aborted, nothing changed): $($out.Trim())" 'Resolve by rebasing the task branch on the target, or send a fix prompt.'
        }
        $merged = (git -C $top rev-parse HEAD).Trim()
    }
    $leftover = $null
    if ($wt) {
        $out = git -C $top worktree remove $wt 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            # Typical on Windows: a harness (e.g. OpenCode's background service) still holds the folder open. git has
            # already deleted the files; if nothing but empty folders is left, unregister it and report the leftover.
            $files = @(Get-ChildItem -LiteralPath $wt -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($files.Count -gt 0) {
                $done = if ($merged) { "Merge done ($merged), but " } else { '' }
                New-AdapterError "${done}git worktree remove failed: $($out.Trim())" 'A program still holds that folder (a worker app or editor). Close it, then run task-cleanup again.'
            }
            git -C $top worktree prune *> $null
            $leftover = $wt
        }
    }
    $flag = if ($Discard) { '-D' } else { '-d' }
    $out = git -C $top branch $flag $branch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Could not delete $branch (not merged?): $($out.Trim())" 'Use -Merge to merge it, or -Discard to drop it on purpose.' }
    $r = [ordered]@{ ok = $true; taskId = $Id; branch = $branch; worktreeRemoved = [bool]$wt; mergeCommit = $merged; discarded = [bool]$Discard }
    if ($leftover) { $r['leftoverEmptyFolder'] = $leftover; $r['note'] = 'An empty folder is still held open by another program; delete it once that program releases it.' }
    $r
}

if ($MyInvocation.InvocationName -ne '.') {
    Complete-Script -Body { Remove-TaskWorktree -Id $Id -Repo $Repo -Merge:$Merge -Discard:$Discard }
}
