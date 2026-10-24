# Check a worker's HANDOFF against git reality. Never trust a HANDOFF on its own word.
#
#   verify-handoff.ps1 -Branch task/T1 -Handoff docs/handoffs/HANDOFF_T1.md [-Base main]
#                      [-Allowed 'src/foo/*','tests/test_foo.py'] [-Forbidden 'tests/locked_*'] [-Repo .]
#                      [-Locked 'tests/*'] [-Run 'python -m unittest tests.test_foo','ruff check src']
#
# Verification contract: -Run commands come from the PLAN (never from the HANDOFF). They run in the task's worktree
# (or a temporary detached checkout of the branch) with a timeout, and their exit codes decide. If a -Locked file
# was modified, the run is refuted: a worker must not edit the checks that judge it.
# verdict: verified (no error and every -Run passed) | refuted (any error) | unverified (no error, nothing run).
# Evidence (findings + command tails) is written to .claude/orchestrator/logs/verify-<branch>.json.
#
# Detects (each one has really happened with AI workers):
#   sha-not-found / sha-not-on-branch   commit SHAs in the HANDOFF that do not exist or are not on the branch
#   files-claimed-not-changed           FILES CHANGED lists a file the diff does not touch
#   files-changed-not-listed            the diff touches a file FILES CHANGED does not list
#   out-of-scope / forbidden-file       files outside -Allowed, or matching -Forbidden
#   deviations-none-but-scope-violated  "DEVIATIONS: none" while the scope was violated
#   handoff-not-in-last-commit          HANDOFF must be committed in the branch's last commit
#   uncommitted-changes                 the task worktree still has uncommitted work (e.g. a script never committed)
#   locked-file-modified                a -Locked file (e.g. a locked test) differs from the base
#   check-failed / check-timeout        a -Run command exited non-zero or ran past -RunTimeoutSec
#   no-sha / no-status / no-files-list  report fields missing (warnings)
# It cannot check numeric claims ("met", "pass"): those stay in manualChecks for the reviewer.
# Exit 0 when there is no error-level finding.
param(
    [string]$Branch = '',
    [string]$Handoff = '',
    [string]$Base = '',
    [string[]]$Allowed = @(),
    [string[]]$Forbidden = @(),
    [string[]]$Locked = @(),
    [string[]]$Run = @(),
    [int]$RunTimeoutSec = 600,
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

function Invoke-Check {
    <# Run one check command in a folder with a timeout (a pwsh child, so any shell syntax works). #>
    param([string]$Command, [string]$Dir, [int]$TimeoutSec)
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Join-ProcessArguments @('-NoProfile', '-NonInteractive', '-Command', $Command)) `
            -WorkingDirectory $Dir -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
        if ($timedOut) { $p.Kill($true) }
        $tail = @(@(Get-Content -LiteralPath $out) + @(Get-Content -LiteralPath $err) | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 15)
        [ordered]@{ command = $Command; exitCode = $(if ($timedOut) { $null } else { $p.ExitCode }); timedOut = $timedOut
            seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); tail = $tail }
    } finally { Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue }
}

function Find-BranchWorktree {
    param([string]$Repo, [string]$Branch)
    $wt = $null
    foreach ($line in (git -C $Repo worktree list --porcelain)) {
        if ($line -like 'worktree *') { $wt = $line.Substring(9) }
        elseif ($line -eq "branch refs/heads/$Branch") { return $wt }
    }
    $null
}

function Test-Handoff {
    param([string]$Repo, [string]$Branch, [string]$Handoff, [string]$Base, [string[]]$Allowed, [string[]]$Forbidden,
        [string[]]$Locked = @(), [string[]]$Run = @(), [int]$RunTimeoutSec = 600)
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

    $wt = Find-BranchWorktree $Repo $Branch
    if ($wt) {
        $dirty = @(git -C $wt status --porcelain)
        if ($dirty) { Add-Finding 'error' 'uncommitted-changes' "$($dirty.Count) uncommitted change(s) in $wt (work that was never committed)." }
    }

    foreach ($f in $changed) {
        if ($Locked -and (Test-GlobAny $f $Locked)) { Add-Finding 'error' 'locked-file-modified' "$f is locked (a check that judges the task) but was changed." }
    }

    # verification contract: run the plan's checks against the committed branch
    $runs = @()
    if ($Run) {
        $tmp = $null
        $dir = $wt
        if (-not $dir) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ag2o-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            git -C $Repo worktree add --detach $tmp $Branch *> $null
            $dir = $tmp
        }
        try {
            foreach ($c in $Run) {
                $r = Invoke-Check -Command $c -Dir $dir -TimeoutSec $RunTimeoutSec
                $runs += $r
                if ($r.timedOut) { Add-Finding 'error' 'check-timeout' "'$c' ran longer than $RunTimeoutSec s." }
                elseif ($r.exitCode -ne 0) { Add-Finding 'error' 'check-failed' "'$c' exited $($r.exitCode)." }
            }
        } finally {
            if ($tmp) { git -C $Repo worktree remove --force $tmp *> $null }
        }
    }

    $errors = @($findings | Where-Object { $_.severity -eq 'error' })
    $verdict = if ($errors.Count) { 'refuted' } elseif ($Run) { 'verified' } else { 'unverified' }
    $result = [ordered]@{
        ok = ($errors.Count -eq 0); verdict = $verdict; branch = $Branch; base = $Base; status = $status; changedFiles = $changed
        findings = @($findings); checks = @($runs)
        manualChecks = @(
            $(if ($Run) { 'Compare the check results above with the numbers the HANDOFF claims.' } else { 'No -Run checks: run the task tests, the full suite and the linter yourself; do not copy numbers from the HANDOFF.' })
            'Check every "met"/"pass"/"done" claim against the raw numbers in the report.'
            $(if ($Locked) { 'Locked files were checked against the base.' } else { 'Pass -Locked <globs> so edited locked tests refute the run.' })
            'Read the full diff (git diff <base>...<branch>) for scope creep and hidden behaviour changes.'
        )
    }
    $evidence = Join-Path (Get-LogDir) ('verify-' + ($Branch -replace '[\\/:]', '_') + '.json')
    ConvertTo-ResultLine $result | Set-Content -Encoding utf8 -LiteralPath $evidence
    $result['evidence'] = $evidence
    $result
}

if ($MyInvocation.InvocationName -ne '.') {
    Complete-Script -Body { Test-Handoff -Repo $Repo -Branch $Branch -Handoff $Handoff -Base $Base -Allowed $Allowed -Forbidden $Forbidden `
            -Locked $Locked -Run $Run -RunTimeoutSec $RunTimeoutSec }
}
