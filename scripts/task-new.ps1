# Create an isolated git worktree + branch for one task:  ../wt-<Id>  on  task/<Id>
#   task-new.ps1 -Id T1 [-Repo .] [-Base HEAD]
param(
    [string]$Id = '',
    [string]$Repo = '.',
    [string]$Base = 'HEAD'
)
. "$PSScriptRoot/lib/Common.ps1"

function Get-WorktreePath {
    param([string]$RepoRoot, [string]$Id, $Config)
    $root = Get-ConfigValue $Config 'worktreeRoot' (Split-Path -Parent $RepoRoot)
    if (-not [IO.Path]::IsPathRooted($root)) { $root = Join-Path $RepoRoot $root }
    [IO.Path]::GetFullPath((Join-Path $root "wt-$Id"))
}

function New-TaskWorktree {
    param([string]$Id, [string]$Repo, [string]$Base, $Config = $null)
    Assert-TaskId $Id
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }
    $top = git -C $Repo rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Not a git repository: $Repo" 'Run from the project root.' }
    $top = [IO.Path]::GetFullPath($top)
    $branch = "task/$Id"
    $wt = Get-WorktreePath $top $Id $Config
    if (Test-Path -LiteralPath $wt) { New-AdapterError "Worktree path already exists: $wt" "Finish or clean the previous run first: task-cleanup.ps1 -Id $Id" }
    git -C $top rev-parse -q --verify "refs/heads/$branch" *> $null
    if ($LASTEXITCODE -eq 0) { New-AdapterError "Branch $branch already exists." "Pick a new task id, or clean up: task-cleanup.ps1 -Id $Id" }
    $baseSha = (git -C $top rev-parse --verify "$Base^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Unknown base revision: $Base" 'Pass -Base <branch or sha>.' }
    $out = git -C $top worktree add -b $branch $wt $baseSha 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { New-AdapterError "git worktree add failed: $($out.Trim())" 'Check git status of the main worktree.' }
    [ordered]@{ ok = $true; taskId = $Id; branch = $branch; worktree = $wt; base = $baseSha.Trim() }
}

if ($MyInvocation.InvocationName -ne '.') {
    Complete-Script -Body { New-TaskWorktree -Id $Id -Repo $Repo -Base $Base }
}
