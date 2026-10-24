# Shared helpers for every adapter and helper script. Dot-source it:  . "$PSScriptRoot/../lib/Common.ps1"
#
# Output contract: every script prints exactly ONE line of JSON on stdout and exits 0 on success, 1 on failure.
# Everything printed goes through Protect-Secret first.

Set-StrictMode -Version 3.0

function Protect-Secret {
    <# Redact credentials from any text before it is printed or written to a log. #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    foreach ($name in 'ANTIGRAVITY_CSRF_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN') {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v -and $v.Length -ge 6) { $t = $t.Replace($v, '***') }
    }
    $t = $t -replace '(--csrf_token[ =]+)[^\s"'']+', '$1***'
    $t = $t -replace '(?i)(CSRF_TOKEN["'']?\s*[=:]\s*["'']?)[^\s"'',}]+', '$1***'
    $t = $t -replace '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}', '$1_***'
    $t = $t -replace '\bgithub_pat_[A-Za-z0-9_]{20,}', 'github_pat_***'
    $t = $t -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s:@"'']+:[^/\s@"'']+@', '$1***@'
    $t = $t -replace '(?i)([a-z][a-z0-9+.-]*://)[A-Za-z0-9_\-]{20,}@', '$1***@'
    $t = $t -replace '("gitOriginUrl"\s*:\s*)"[^"]*"', '$1"[redacted]"'
    return $t
}

function New-AdapterError {
    <# Throw an error that carries a concrete fix hint for the user. #>
    param([Parameter(Mandatory)][string]$Message, [string]$Hint = '')
    $ex = [System.InvalidOperationException]::new($Message)
    $ex.Data['hint'] = $Hint
    throw $ex
}

function ConvertTo-ResultLine {
    <# One-line, redacted JSON. #>
    param([Parameter(Mandatory)]$Result)
    Protect-Secret ($Result | ConvertTo-Json -Compress -Depth 8)
}

function Invoke-Guarded {
    <# Run a script block and turn its result (or its error) into @{ Line; ExitCode }. Testable without exiting. #>
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Worker = '')
    try {
        $r = & $Body
        if ($r -isnot [System.Collections.IDictionary]) { $r = [ordered]@{ ok = $true; result = $r } }
        if (-not $r.Contains('ok')) { $r['ok'] = $true }
    } catch {
        $ex = $_.Exception
        $hint = if ($ex.Data.Contains('hint')) { [string]$ex.Data['hint'] } else { '' }
        $r = [ordered]@{ ok = $false; error = $ex.Message; hint = $hint }
        if ($Worker) { $r['worker'] = $Worker }
    }
    @{ Line = (ConvertTo-ResultLine $r); ExitCode = $(if ($r['ok']) { 0 } else { 1 }) }
}

function Complete-Script {
    <# Entry point for `pwsh -File`: print the JSON line and exit with the matching code. #>
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Worker = '')
    $out = Invoke-Guarded -Body $Body -Worker $Worker
    [Console]::Out.WriteLine($out.Line)
    exit $out.ExitCode
}

function Get-OrchestratorDir {
    <# The project's .claude/orchestrator directory. Scripts are installed in <it>/bin/... #>
    param([string]$ScriptRoot = $PSScriptRoot)
    if ($env:AG2O_HOME) { return $env:AG2O_HOME }
    $fromCwd = Join-Path (Get-Location).Path '.claude/orchestrator'
    if (Test-Path (Join-Path $fromCwd 'orchestrator.config.json')) { return $fromCwd }
    # installed layout: .claude/orchestrator/bin/{lib,adapters}/x.ps1
    return (Resolve-Path (Join-Path $ScriptRoot '../..') -ErrorAction SilentlyContinue).Path
}

function Read-OrchestratorConfig {
    param([string]$Path = '')
    if (-not $Path) {
        $Path = if ($env:AG2O_CONFIG) { $env:AG2O_CONFIG } else { Join-Path (Get-OrchestratorDir) 'orchestrator.config.json' }
    }
    if (-not $Path -or -not (Test-Path $Path)) { return @{} }
    Get-Content -Raw -Encoding utf8 $Path | ConvertFrom-Json -AsHashtable
}

function Get-ConfigValue {
    <# Dotted lookup with a default, e.g. Get-ConfigValue $cfg 'workers.ag2.projectId' '' #>
    param($Config, [string]$Key, $Default = $null)
    $node = $Config
    foreach ($part in $Key -split '\.') {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { return $Default }
    }
    if ($null -eq $node -or ($node -is [string] -and $node -eq '')) { return $Default }
    $node
}

function Get-LogDir {
    $dir = Join-Path (Get-OrchestratorDir) 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    (Resolve-Path $dir).Path
}

function Add-DispatchLog {
    <# Append one redacted JSON line to logs/dispatch.jsonl. #>
    param([Parameter(Mandatory)]$Entry)
    $e = [ordered]@{ at = (Get-Date).ToString('o') }
    foreach ($k in $Entry.Keys) { $e[$k] = $Entry[$k] }
    Add-Content -Encoding utf8 -Path (Join-Path (Get-LogDir) 'dispatch.jsonl') -Value (ConvertTo-ResultLine $e)
}

function Get-LoopbackPorts {
    <# Listening 127.0.0.1 ports of a process, ascending. #>
    param([Parameter(Mandatory)][int]$ProcessId)
    @(Get-NetTCPConnection -OwningProcess $ProcessId -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' } |
        Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path, [string]$What = 'file')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        New-AdapterError "$What not found: $Path" "Check the path; it is resolved from the current directory."
    }
    Get-Content -Raw -Encoding utf8 -LiteralPath $Path
}
