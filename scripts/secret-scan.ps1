# Scan files (or staged changes, or git history) for secrets and machine-specific identifiers.
#
#   pwsh -NoProfile -File scripts/secret-scan.ps1            # tracked + untracked (not ignored) files
#   pwsh -NoProfile -File scripts/secret-scan.ps1 -Staged    # what is about to be committed (pre-commit hook)
#   pwsh -NoProfile -File scripts/secret-scan.ps1 -History   # every commit (git log -p)
#
# Extra literal strings to forbid (your user name, project ids, private repo names...) come from the env var
# AG2O_DENYLIST (separated by ';') and from a git-ignored file `.secret-denylist` (one per line). They are never
# printed: a hit is reported as "denylist entry #n".
# Uses gitleaks as well when it is on PATH. Exit 0 = clean, 1 = findings.
[CmdletBinding()]
param(
    [string]$Repo = (Join-Path $PSScriptRoot '..'),
    [switch]$Staged,
    [switch]$History
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path $Repo).Path

$patterns = [ordered]@{
    'github-token'     = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}'
    'github-pat'       = '\bgithub_pat_[A-Za-z0-9_]{20,}'
    'url-credentials'  = '[a-z][a-z0-9+.-]*://[^/\s:@''"]+:[^/\s@''"]+@'
    'csrf-token'       = '--csrf_token[ =]+(?![<${])[^\s''"]{8,}'
    'uuid'             = '\b(?!([0-9a-f])\1{7}-)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    'windows-userpath' = '(?i)\b[a-z]:[\\/]+Users[\\/]+(?!<|%|\$|you\b|me\b|USERNAME\b|Public\b|Default\b)[A-Za-z0-9._-]+'
    'posix-userpath'   = '(?i)/(c|d|e)/Users/(?!<|you\b|me\b)[A-Za-z0-9._-]+'
}

$deny = @()
if ($env:AG2O_DENYLIST) { $deny += $env:AG2O_DENYLIST -split ';' }
$denyFile = Join-Path $Repo '.secret-denylist'
if (Test-Path $denyFile) { $deny += Get-Content $denyFile }
$deny = @($deny | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Find-Secrets([string]$Label, [string[]]$Lines) {
    $hits = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        foreach ($name in $patterns.Keys) {
            if ($line -match $patterns[$name]) { $hits += "${Label}:$($i + 1): $name" }
        }
        for ($d = 0; $d -lt $deny.Count; $d++) {
            if ($line.IndexOf($deny[$d], [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hits += "${Label}:$($i + 1): denylist entry #$($d + 1)"
            }
        }
    }
    $hits
}

$findings = @()
Push-Location $Repo
try {
    if ($Staged) {
        $findings += Find-Secrets 'staged' @(git diff --cached -U0 --no-color | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' })
    } elseif ($History) {
        $findings += Find-Secrets 'history' @(git log -p --all --no-color)
    } else {
        foreach ($f in (git ls-files -co --exclude-standard)) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            $findings += Find-Secrets $f @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
        }
    }
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        $mode = if ($Staged) { @('protect', '--staged') } else { @('detect') }
        & gitleaks @mode --no-banner --redact | Out-Null
        if ($LASTEXITCODE -ne 0) { $findings += 'gitleaks reported findings (run gitleaks yourself for details)' }
    }
} finally { Pop-Location }

if ($findings) {
    Write-Output "SECRET SCAN FAILED ($($findings.Count) finding(s)):"
    $findings | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output 'secret scan: clean'
exit 0
