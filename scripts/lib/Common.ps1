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
    # EscapeNonAscii: pure-ASCII line, so console code pages cannot corrupt it between processes
    Protect-Secret ($Result | ConvertTo-Json -Compress -Depth 8 -EscapeHandling EscapeNonAscii)
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
    $r = Resolve-Path (Join-Path $ScriptRoot '../..') -ErrorAction SilentlyContinue
    if ($r) { $r.Path } else { (Get-Location).Path }
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

function Join-ProcessArguments {
    <# Quote an argument array for a Windows command line (CRT rules). #>
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -ne '' -and $_ -notmatch '[\s"]') { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

function Start-WorkerProcess {
    <# Start a headless harness in the background, stdout/stderr to files. Mocked in tests. #>
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [string]$StdOut, [string]$StdErr)
    $p = Start-Process -FilePath $FilePath -ArgumentList (Join-ProcessArguments $Arguments) -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -WindowStyle Hidden -PassThru
    @{ Id = $p.Id }
}

function Save-TaskState {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$State)
    $path = Join-Path (Get-LogDir) "$Key.state.json"
    $State | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $path
    $path
}

function Find-TaskState {
    <# Find the state file written at dispatch time for a session id. #>
    param([Parameter(Mandatory)][string]$SessionId)
    foreach ($f in Get-ChildItem -LiteralPath (Get-LogDir) -Filter '*.state.json' -ErrorAction SilentlyContinue) {
        $s = Get-Content -Raw $f.FullName | ConvertFrom-Json -AsHashtable
        if ($s.sessionId -eq $SessionId) { $s['statePath'] = $f.FullName; return $s }
    }
    $null
}

function Get-ProcessTaskStatus {
    <# running = the harness process is still alive; idle = it exited. lastActivity = stdout log mtime. #>
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][string]$SessionId)
    $s = Find-TaskState $SessionId
    if (-not $s) { return [ordered]@{ ok = $true; worker = $Worker; sessionId = $SessionId; state = 'unknown'; lastActivity = $null; stateSource = 'no state file for this session' } }
    $last = if (Test-Path -LiteralPath $s.logPath) { (Get-Item -LiteralPath $s.logPath).LastWriteTime.ToString('o') } else { $null }
    $state = if (Test-ProcessAlive ([int]$s.pid)) { 'running' } else { 'idle' }
    [ordered]@{ ok = $true; worker = $Worker; sessionId = $SessionId; state = $state; lastActivity = $last; logPath = $s.logPath
        stateSource = 'harness process alive (running) or exited (idle)' }
}

function Get-TaskMessage {
    <# The one-line kickoff message every worker receives (wording verified with AG2). #>
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$PromptPath)
    "Workspace: $Workspace. Read the file '$PromptPath' and follow its instructions exactly. " +
        'It contains your rules, your single task and the HANDOFF format.'
}

function Resolve-DispatchInputs {
    <# Validate -TaskId/-PromptFile/-Workspace and return absolute paths. #>
    param([string]$TaskId, [string]$PromptFile, [string]$Workspace)
    if (-not $TaskId -or -not $PromptFile) { New-AdapterError '-Dispatch needs -TaskId and -PromptFile.' 'See skills/harness-orchestrator/reference/adapter-contract.md.' }
    $p = Resolve-Path -LiteralPath $PromptFile -ErrorAction SilentlyContinue
    if (-not $p) { New-AdapterError "Prompt file not found: $PromptFile" 'Write the task prompt first (templates/TASK.prompt.md).' }
    $w = Resolve-Path -LiteralPath $Workspace -ErrorAction SilentlyContinue
    if (-not $w) { New-AdapterError "Workspace not found: $Workspace" 'Create the worktree first: task-new.ps1 -Id <task>.' }
    @{ Prompt = $p.Path; Workspace = $w.Path }
}

function Assert-TaskId {
    param([string]$Id)
    if ($Id -notmatch '^[A-Za-z0-9._-]+$') { New-AdapterError "Invalid or missing task id '$Id'." 'Use -Id with letters, digits, dot, dash or underscore (e.g. -Id T1).' }
}

function Assert-TaskWorkspace {
    <# Messages must go to a live task worktree, never to a removed (empty) folder. #>
    param([string]$Workspace)
    git -C $Workspace rev-parse --is-inside-work-tree *> $null
    if (-not $Workspace -or -not (Test-Path -LiteralPath $Workspace) -or $LASTEXITCODE -ne 0) {
        New-AdapterError "The task workspace '$Workspace' is gone or not a git worktree (task already cleaned up?)." 'Messages only make sense for live tasks. Start a new task (task-new + -Dispatch) instead.'
    }
}

function Expand-UserPath {
    <# %ENV% variables and a leading ~ #>
    param([string]$Path)
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if ($p -match '^~[\\/]') { $p = Join-Path $env:USERPROFILE $p.Substring(2) }
    $p
}

function Get-SkillsFromDirs {
    <# Skills = sub-folders holding a SKILL.md; name/description come from its frontmatter. Dirs may contain wildcards. #>
    param([string[]]$Dirs)
    $seen = @{}
    foreach ($d in $Dirs) {
        foreach ($root in @(Resolve-Path -Path (Expand-UserPath $d) -ErrorAction SilentlyContinue)) {
            foreach ($f in Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue) {
                $md = Join-Path $f.FullName 'SKILL.md'
                if (-not (Test-Path -LiteralPath $md)) { continue }
                $head = (Get-Content -LiteralPath $md -TotalCount 15 -ErrorAction SilentlyContinue) -join "`n"
                $name = if ($head -match '(?m)^name:\s*["'']?([^"''\r\n]+)') { $Matches[1].Trim() } else { $f.Name }
                if ($seen.ContainsKey($name)) { continue }
                $seen[$name] = $true
                $desc = if ($head -match '(?m)^description:\s*["'']?([^\r\n]+)') { $Matches[1].Trim(' ', '"', "'") } else { '' }
                if ($desc.Length -gt 140) { $desc = $desc.Substring(0, 140) + '...' }
                [ordered]@{ name = $name; description = $desc; source = $root.Path }
            }
        }
    }
}

function Resolve-Executable {
    <# A file Start-Process can launch: an existing path, or the .exe/.cmd/.bat on PATH (npm also installs an
       extension-less sh shim and a .ps1 next to the .cmd, which Start-Process cannot run). #>
    param([string]$Name)
    if (Test-Path -LiteralPath $Name -PathType Leaf) { return (Resolve-Path -LiteralPath $Name).Path }
    $c = Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.exe', '.cmd', '.bat', '.com' } | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

function Invoke-CapabilityCommand {
    <# Run a listing command (e.g. `agy models`) with a timeout; return its non-empty output lines. Mocked in tests. #>
    param([string[]]$Command, [int]$TimeoutSec = 90)
    $exe = Resolve-Executable (Expand-UserPath $Command[0])
    if (-not $exe) { return @("(not available: $($Command[0]) not found)") }
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $exe -ArgumentList (Join-ProcessArguments @($Command | Select-Object -Skip 1)) `
            -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill($true); return @("(timed out after $TimeoutSec s)") }
        @(Get-Content -LiteralPath $out | Where-Object { $_.Trim() } | ForEach-Object { $_.TrimEnd() } | Select-Object -First 300)
    } finally { Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue }
}

function Get-WorkerCapabilities {
    <# What a worker can use: models, agents, skills, plugins, MCP servers... from workers.<w>.capabilities:
         "<category>": { "cmd": ["agy","models"], "skip": 1, "pattern": "^(\\S+)" }   listing command, optional header skip
         "skills":     { "dirs": ["~/.gemini/antigravity/skills", "~/.gemini/config/plugins/*/skills"] }
         "<category>": ["static", "values"]                                              fixed list #>
    param($Config, [string]$Worker, $Static = @{})
    $caps = [ordered]@{}
    foreach ($k in $Static.Keys) { $caps[$k] = $Static[$k] }
    $spec = Get-ConfigValue $Config "workers.$Worker.capabilities" @{}
    foreach ($cat in $spec.Keys) {
        $s = $spec[$cat]
        if ($s -is [System.Collections.IList]) { $caps[$cat] = @($s); continue }
        if ($s.Contains('dirs')) { $caps[$cat] = @(Get-SkillsFromDirs @($s['dirs'])); continue }
        if ($s.Contains('cmd')) {
            try { $lines = @(Invoke-CapabilityCommand @($s['cmd'])) }
            catch { $caps[$cat] = @("(error: $($_.Exception.Message))"); continue }
            $skip = [int](Get-ConfigValue $s 'skip' 0)
            if ($skip -gt 0) { $lines = @($lines | Select-Object -Skip $skip) }
            $pat = Get-ConfigValue $s 'pattern' ''
            if ($pat) { $lines = @($lines | ForEach-Object { $m = [regex]::Match($_, $pat); if ($m.Success) { $m.Groups[1].Value } }) }
            $caps[$cat] = $lines
        }
    }
    $caps
}

function Get-PermissionMode {
    <# default | edits | full. `full` lets the worker act without asking: only for worktrees you can throw away. #>
    param($Config, [string]$Worker)
    $m = [string](Get-ConfigValue $Config "workers.$Worker.permissions" 'default')
    if ($m -notin 'default', 'edits', 'full') { New-AdapterError "workers.$Worker.permissions must be default, edits or full (got '$m')." 'Fix orchestrator.config.json.' }
    $m
}

function Add-MessagePrefix {
    <# Put a slash command / @agent / skill hint in front of the kickoff line, e.g. "/tdd" or "@reviewer". #>
    param([string]$Prefix, [string]$Text)
    if ($Prefix) { "$($Prefix.Trim()) $Text" } else { $Text }
}

function Stop-TaskProcess {
    <# Cancel a running process-based task: kill the process tree this plugin started for the session (pid from the
       state file). Never touches processes it did not start. #>
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][string]$SessionId)
    $s = Find-TaskState $SessionId
    if (-not $s) { New-AdapterError "No state file for session $SessionId." 'Only tasks dispatched by this plugin can be cancelled.' }
    $pid_ = [int]$s.pid
    if (-not (Test-ProcessAlive $pid_)) { return [ordered]@{ ok = $true; worker = $Worker; sessionId = $SessionId; cancelled = $false; detail = 'already finished' } }
    Stop-ProcessTree $pid_
    [ordered]@{ ok = $true; worker = $Worker; sessionId = $SessionId; cancelled = $true; pid = $pid_
        detail = 'process tree stopped; the worktree is left as it is for review or task-cleanup -Discard' }
}

function Stop-ProcessTree {
    <# Mocked in tests. #>
    param([int]$ProcessId)
    taskkill /T /F /PID $ProcessId *> $null
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path, [string]$What = 'file')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        New-AdapterError "$What not found: $Path" "Check the path; it is resolved from the current directory."
    }
    Get-Content -Raw -Encoding utf8 -LiteralPath $Path
}
