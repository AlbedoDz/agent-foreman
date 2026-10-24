# Check a worker's HANDOFF against git reality. Never trust a HANDOFF on its own word.
#
#   verify-handoff.ps1 -Branch task/T1 -Handoff docs/handoffs/HANDOFF_T1.md [-Base main]
#                      [-Allowed 'src/foo/*','tests/test_foo.py'] [-Forbidden 'tests/locked_*'] [-Repo .]
#
# Detects (each one has really happened with AI workers):
#   sha-not-found / sha-not-on-branch   commit SHAs in the HANDOFF that do not exist or are not on the branch
#   files-claimed-not-changed           FILES CHANGED lists a file the diff does not touch
#   files-changed-not-listed            the diff touches a file FILES CHANGED does not list
#   out-of-scope / forbidden-file       files outside -Allowed, or matching -Forbidden
#   deviations-none-but-scope-violated  "DEVIATIONS: none" while the scope was violated
#   handoff-not-in-last-commit          HANDOFF must be committed in the branch's last commit
#   uncommitted-changes                 the task worktree still has uncommitted work (e.g. a script never committed)
#   no-sha / no-status / no-files-list  report fields missing (warnings)
# It cannot check numeric claims ("met", "pass"): those stay in manualChecks for the reviewer.
# Exit 0 when there is no error-level finding.
param(
    [string]$Branch = '',
    [string]$Handoff = '',
    [string]$Base = '',
    [string[]]$Allowed = @(),
    [string[]]$Forbidden = @(),
    [string]$Repo = '.'
)
. "$PSScriptRoot/lib/Common.ps1"

function Get-HandoffSection {
    <# Lines of a "HEADER:" block (bullets until the next UPPERCASE header). #>
    param([string[]]$Lines, [string]$Header)
    $out = @(); $in = $false
    foreach ($l in $Lines) {
        if ($l -match "^\s*$Header[^:]*:\s*(.*)$") { $in = $true; if ($Matches[1].Trim()) { $out += $Matches[1].Trim() }; continue }
        if ($in -and $l -match '^\s*[A-Z][A-Z0-9 /_-]{2,}:') { break }
        if ($in -and $l.Trim()) { $out += $l.Trim() }
    }
    $out
}

function Test-GlobAny {
    param([string]$Path, [string[]]$Globs)
    foreach ($g in $Globs) { if ($Path -like ($g -replace '\\', '/')) { return $true } }
    $false
}

function Test-Handoff {
    param([string]$Repo, [string]$Branch, [string]$Handoff, [string]$Base, [string[]]$Allowed, [string[]]$Forbidden)
    if (-not $Branch -or -not $Handoff) { New-AdapterError '-Branch and -Handoff are required.' 'e.g. -Branch task/T1 -Handoff docs/handoffs/HANDOFF_T1.md' }
    $Handoff = $Handoff -replace '\\', '/'
    git -C $Repo rev-parse -q --verify "refs/heads/$Branch" *> $null
    if ($LASTEXITCODE -ne 0) { New-AdapterError "Branch $Branch does not exist." 'Did the worker commit on the task branch?' }
    if (-not $Base) { $Base = (git -C $Repo merge-base HEAD $Branch).Trim() }
    $text = git -C $Repo show "${Branch}:$Handoff" 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $text.Trim()) {
        New-AdapterError "HANDOFF $Handoff is not committed on $Branch." 'The task is not finished, or the worker wrote it elsewhere/forgot to commit it.'
    }
    $lines = $text -split "`r?`n"
    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding($sev, $code, $detail) { $findings.Add([ordered]@{ severity = $sev; code = $code; detail = $detail }) }

    $changed = @(git -C $Repo diff --name-only "$Base...$Branch" | Where-Object { $_ })

    $status = ($lines | Where-Object { $_ -match '^\s*STATUS:\s*(\S+)' } | Select-Object -First 1)
    $status = if ($status -and $status -match '^\s*STATUS:\s*(\S+)') { $Matches[1] } else { $null }
    if (-not $status) { Add-Finding 'warn' 'no-status' 'No STATUS: line.' }

    $shas = @($lines | Where-Object { $_ -match '(?i)COMMIT' } | ForEach-Object { [regex]::Matches($_, '\b[0-9a-f]{7,40}\b') } | ForEach-Object { $_.Value } | Select-Object -Unique)
    if (-not $shas) { Add-Finding 'warn' 'no-sha' 'No commit SHA in the HANDOFF; cannot cross-check it.' }
    foreach ($sha in $shas) {
        git -C $Repo cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { Add-Finding 'error' 'sha-not-found' "HANDOFF cites $sha, which does not exist."; continue }
        git -C $Repo merge-base --is-ancestor $sha $Branch 2>$null
        if ($LASTEXITCODE -ne 0) { Add-Finding 'error' 'sha-not-on-branch' "HANDOFF cites $sha, which is not on $Branch." }
    }

    $listed = @(Get-HandoffSection $lines 'FILES CHANGED' | ForEach-Object { ($_ -replace '^[-*]\s*', '' -replace '\s+\(.*\)$', '' -replace '`', '').Trim() -replace '\\', '/' } |
        Where-Object { $_ -and $_ -notmatch '^(none|n/a)$' })
    if (-not $listed) { Add-Finding 'warn' 'no-files-list' 'No FILES CHANGED list.' }
    else {
        foreach ($f in $listed) { if ($f -notin $changed) { Add-Finding 'error' 'files-claimed-not-changed' "$f is listed but not in the diff." } }
        foreach ($f in $changed) { if ($f -notin $listed) { Add-Finding 'error' 'files-changed-not-listed' "$f changed but is not listed." } }
    }

    $scopeViolated = $false
    foreach ($f in $changed) {
        if ($f -eq $Handoff) { continue }
        if ($Forbidden -and (Test-GlobAny $f $Forbidden)) { Add-Finding 'error' 'forbidden-file' "$f matches a forbidden pattern."; $scopeViolated = $true }
        elseif ($Allowed -and -not (Test-GlobAny $f $Allowed)) { Add-Finding 'error' 'out-of-scope' "$f is outside the allowed files."; $scopeViolated = $true }
    }
    $dev = (Get-HandoffSection $lines 'DEVIATIONS') -join ' '
    if ($dev -match '^(?i)\s*none\b' -and ($scopeViolated -or ($findings | Where-Object { $_.code -eq 'files-changed-not-listed' }))) {
        Add-Finding 'error' 'deviations-none-but-scope-violated' 'DEVIATIONS says none, but the diff shows otherwise.'
    }

    $last = @(git -C $Repo diff-tree --no-commit-id --name-only -r --root $Branch)
    if ($Handoff -notin $last) { Add-Finding 'error' 'handoff-not-in-last-commit' 'The HANDOFF must be committed in the last commit of the branch.' }

    foreach ($line in (git -C $Repo worktree list --porcelain)) {
        if ($line -like 'worktree *') { $wt = $line.Substring(9) }
        elseif ($line -eq "branch refs/heads/$Branch") {
            $dirty = @(git -C $wt status --porcelain)
            if ($dirty) { Add-Finding 'error' 'uncommitted-changes' "$($dirty.Count) uncommitted change(s) in $wt (work that was never committed)." }
        }
    }

    $errors = @($findings | Where-Object { $_.severity -eq 'error' })
    [ordered]@{
        ok = ($errors.Count -eq 0); branch = $Branch; base = $Base; status = $status; changedFiles = $changed
        findings = @($findings)
        manualChecks = @(
            'Re-run the task tests, the full suite and the linter yourself; do not copy numbers from the HANDOFF.'
            'Check every "met"/"pass"/"done" claim against the raw numbers in the report.'
            'Byte-compare locked test files against the plan (git diff <base> -- <locked files> must be empty).'
            'Read the full diff (git diff <base>...<branch>) for scope creep and hidden behaviour changes.'
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Complete-Script -Body { Test-Handoff -Repo $Repo -Branch $Branch -Handoff $Handoff -Base $Base -Allowed $Allowed -Forbidden $Forbidden }
}
