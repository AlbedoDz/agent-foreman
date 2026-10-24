# Generic adapter for any coding harness with a headless CLI.
# Ready-made entries in templates/orchestrator.config.json: `agy` (Antigravity CLI) and `dsh` (DeepSeek Harness).
#
#   generic-cli.ps1 -Worker <name> -Check | -Dispatch ... | -Status -SessionId x | -Message -SessionId x -MessageFile f
#
# Commands come from orchestrator.config.json -> workers.<name>, as argument ARRAYS (no shell quoting involved):
#   "mytool": {
#     "adapter": "generic-cli",
#     "check":    ["mytool", "--version"],
#     "dispatch": ["mytool", "exec", "--model", "{model}", "{message}"],
#     "message":  ["mytool", "exec", "--resume", "{sessionId}", "--model", "{model}", "{messageText}"],
#     "sessionIdPattern": "\"session_id\"\\s*:\\s*\"([^\"]+)\"",
#     "errorPattern": "MISSING_CREDENTIAL[^\\r\\n]*",
#     "errorHint": "what the user should do when errorPattern matches"
#   }
# Placeholders: {taskId} {prompt} {promptDir} {workspace} {title} {model} {agent} {message} (the kickoff line,
#               with -Prefix in front) {sessionId} {messageFile} {messageText} {permissions}
# {permissions} expands to the argument list in workers.<name>.permissionArgs.<mode>, where mode is
# workers.<name>.permissions (default | edits | full).
# -Capabilities lists what the harness offers (models, agents, skills, plugins, MCP), from workers.<name>.capabilities.
# %ENV% variables are expanded (e.g. %LOCALAPPDATA%\Programs\...). An element whose placeholders all expand to ''
# is dropped, together with the flag right before it (so "--model", "{model}" disappears when no model is set).
# The process runs in the background with the worktree as working directory; stdout -> logs/<TaskId>.<worker>.log.
# sessionId = first match of sessionIdPattern in stdout within -WaitSeconds, else "pid:<n>".
# errorPattern is checked on stdout+stderr during that wait: a match fails the call with errorHint.
param(
    [string]$Worker = '',
    [switch]$Check,
    [switch]$Dispatch,
    [switch]$Status,
    [switch]$Message,
    [switch]$Capabilities,
    [switch]$Cancel,
    [string]$TaskId = '',
    [string]$PromptFile = '',
    [string]$Workspace = '.',
    [string]$Title = '',
    [string]$Model = '',
    [string]$SessionId = '',
    [string]$MessageFile = '',
    [string]$Agent = '',
    [string]$Prefix = '',
    [int]$WaitSeconds = 60
)
. "$PSScriptRoot/../lib/Common.ps1"

function Expand-CommandTemplate {
    param([string[]]$Template, [hashtable]$Values)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Template) {
        # a placeholder standing alone whose value is a list (e.g. {permissions}) is spliced in as several arguments
        if ($t -match '^\{([A-Za-z]+)\}$' -and $Values.ContainsKey($Matches[1]) -and $Values[$Matches[1]] -is [System.Collections.IList]) {
            foreach ($v in $Values[$Matches[1]]) { $out.Add([string]$v) }
            continue
        }
        $a = [Environment]::ExpandEnvironmentVariables($t)
        $hasPlaceholder = $a -match '\{[A-Za-z]+\}'
        foreach ($k in $Values.Keys) { $a = $a.Replace("{$k}", [string]$Values[$k]) }
        # a known placeholder that was not supplied counts as empty
        $a = [regex]::Replace($a, '\{(taskId|prompt|promptDir|workspace|title|model|agent|message|sessionId|messageFile|messageText|permissions)\}', '')
        if ($hasPlaceholder -and $a -eq '') {
            # optional value missing: drop it and the flag that introduced it
            if ($out.Count -gt 0 -and $out[$out.Count - 1].StartsWith('-')) { $out.RemoveAt($out.Count - 1) }
            continue
        }
        $out.Add($a)
    }
    @($out)
}

function Get-WorkerSpec {
    param($Config, [string]$Worker, [string]$Key)
    if (-not $Worker) { New-AdapterError '-Worker is required.' 'Name the worker as configured under workers.<name> in orchestrator.config.json.' }
    $t = Get-ConfigValue $Config "workers.$Worker.$Key" $null
    if (-not $t) { New-AdapterError "workers.$Worker.$Key is not configured." 'See docs/ADDING-A-HARNESS.md for the config shape.' }
    @($t)
}

function Assert-Executable {
    <# Returns the launchable path (.exe/.cmd), or fails with a fix hint. #>
    param([string]$Exe, [string]$Worker)
    $resolved = Resolve-Executable $Exe
    if (-not $resolved) {
        New-AdapterError "$Exe not found." "Install the harness, or fix the command paths under workers.$Worker in orchestrator.config.json."
    }
    $resolved
}

function Start-GenericRun {
    param($Config, [string]$Worker, [string[]]$Cmd, [string]$Workspace, [string]$Key, [int]$WaitSeconds)
    $exe = Assert-Executable $Cmd[0] $Worker
    if (-not $exe) { $exe = $Cmd[0] }
    $log = Join-Path (Get-LogDir) "$Key.$Worker.log"
    $err = Join-Path (Get-LogDir) "$Key.$Worker.err.log"
    $rest = @($Cmd | Select-Object -Skip 1)
    $p = Start-WorkerProcess -FilePath $exe -Arguments $rest -WorkingDirectory $Workspace -StdOut $log -StdErr $err
    $pattern = Get-ConfigValue $Config "workers.$Worker.sessionIdPattern" ''
    $errPattern = Get-ConfigValue $Config "workers.$Worker.errorPattern" ''
    $sid = "pid:$($p.Id)"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $foundAt = $null
    while ($pattern -or $errPattern) {
        $text = if (Test-Path -LiteralPath $log) { [string](Get-Content -Raw -LiteralPath $log) } else { '' }
        $etext = if (Test-Path -LiteralPath $err) { [string](Get-Content -Raw -LiteralPath $err) } else { '' }
        if ($errPattern) {
            $e = [regex]::Match("$text`n$etext", $errPattern)
            if ($e.Success) {
                New-AdapterError "$Worker reported an error: $($e.Value.Trim())" (Get-ConfigValue $Config "workers.$Worker.errorHint" "Read $err and $log.")
            }
        }
        if ($pattern -and $sid -like 'pid:*') {
            $m = [regex]::Match($text, $pattern)
            if ($m.Success) { $sid = $m.Groups[1].Value; $foundAt = Get-Date }
        }
        # session known: stop at once, or after a 5 s grace period that catches early errors (e.g. missing API key)
        if ($foundAt -and (-not $errPattern -or ((Get-Date) - $foundAt).TotalSeconds -ge 5)) { break }
        if (-not $pattern -and ((Get-Date) - $deadline.AddSeconds(-$WaitSeconds)).TotalSeconds -ge 5) { break }
        if (-not (Test-ProcessAlive $p.Id)) {
            if ($sid -like 'pid:*' -and $pattern) {
                $tail = (($etext -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
                New-AdapterError "$Worker exited before reporting a session. $tail" "Run the dispatch command by hand in the worktree to see the error (log: $log)."
            }
            break
        }
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 500
    }
    @{ SessionId = $sid; Pid = $p.Id; Log = $log }
}

function Get-PermissionArgs {
    param($Config, [string]$Worker)
    $mode = Get-PermissionMode $Config $Worker
    @(Get-ConfigValue $Config "workers.$Worker.permissionArgs.$mode" @())
}

function Invoke-GenericAdapter {
    param(
        [string]$Worker = '', [switch]$Check, [switch]$Dispatch, [switch]$Status, [switch]$Message, [switch]$Capabilities, [switch]$Cancel,
        [string]$TaskId = '', [string]$PromptFile = '', [string]$Workspace = '.', [string]$Title = '',
        [string]$Model = '', [string]$SessionId = '', [string]$MessageFile = '', [string]$Agent = '', [string]$Prefix = '',
        [int]$WaitSeconds = 60, $Config = $null
    )
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }

    if ($Capabilities) {
        if (-not $Worker) { New-AdapterError '-Worker is required.' 'Name the worker as configured under workers.<name>.' }
        return [ordered]@{ ok = $true; worker = $Worker; permissions = (Get-PermissionMode $Config $Worker)
            capabilities = (Get-WorkerCapabilities $Config $Worker) }
    }

    if ($Check) {
        $cmd = Expand-CommandTemplate (Get-WorkerSpec $Config $Worker 'check') @{}
        Assert-Executable $cmd[0] $Worker
        # @(): a single argument must stay an array, or splatting would pass it character by character
        $rest = @($cmd | Select-Object -Skip 1)
        $out = & $cmd[0] @rest 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { New-AdapterError "check command failed: $($out.Trim())" "Run it by hand: $($cmd -join ' ')" }
        return [ordered]@{ ok = $true; worker = $Worker; version = $out.Trim(); detail = 'check command succeeded' }
    }

    if ($Dispatch) {
        $in = Resolve-DispatchInputs $TaskId $PromptFile $Workspace
        if (-not $Model) { $Model = Get-ConfigValue $Config "workers.$Worker.defaultModel" '' }
        if (-not $Title) { $Title = $TaskId }
        if (-not $Agent) { $Agent = Get-ConfigValue $Config "workers.$Worker.defaultAgent" '' }
        $vals = @{ taskId = $TaskId; prompt = $in.Prompt; promptDir = (Split-Path -Parent $in.Prompt); workspace = $in.Workspace
            title = $Title; model = $Model; agent = $Agent; permissions = (Get-PermissionArgs $Config $Worker)
            message = (Add-MessagePrefix $Prefix (Get-TaskMessage $in.Workspace $in.Prompt)) }
        $cmd = Expand-CommandTemplate (Get-WorkerSpec $Config $Worker 'dispatch') $vals
        $r = Start-GenericRun $Config $Worker $cmd $in.Workspace $TaskId $WaitSeconds
        Save-TaskState $TaskId ([ordered]@{ worker = $Worker; taskId = $TaskId; sessionId = $r.SessionId; pid = $r.Pid; logPath = $r.Log
            workspace = $in.Workspace; model = $Model; agent = $Agent; promptDir = $vals.promptDir }) | Out-Null
        Add-DispatchLog ([ordered]@{ worker = $Worker; action = 'dispatch'; taskId = $TaskId; sessionId = $r.SessionId; model = $Model; agent = $Agent; prefix = $Prefix; workspace = $in.Workspace })
        return [ordered]@{ ok = $true; worker = $Worker; taskId = $TaskId; sessionId = $r.SessionId; logPath = $r.Log }
    }

    if ($Cancel) {
        if (-not $SessionId) { New-AdapterError '-Cancel needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        return Stop-TaskProcess -Worker $Worker -SessionId $SessionId
    }

    if ($Status) {
        if (-not $SessionId) { New-AdapterError '-Status needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        return Get-ProcessTaskStatus -Worker $Worker -SessionId $SessionId
    }

    if ($Message) {
        if (-not $SessionId -or -not $MessageFile) { New-AdapterError '-Message needs -SessionId and -MessageFile.' 'Write the nudge to a file first.' }
        if ($SessionId -like 'pid:*') { New-AdapterError 'This dispatch never reported a session id.' 'Dispatch again instead of messaging.' }
        $body = Read-TextFile $MessageFile 'Message file'
        $s = Find-TaskState $SessionId
        $ws = if ($s) { $s.workspace } else { (Get-Location).Path }
        Assert-TaskWorkspace $ws
        if ($s -and (Test-ProcessAlive ([int]$s.pid))) {
            New-AdapterError "Session $SessionId is still running (pid $($s.pid)); a second run on it would race." 'Wait until -Status says idle, or stop that process, then send the message.'
        }
        if (-not $Model) { $Model = if ($s -and $s['model']) { $s['model'] } else { Get-ConfigValue $Config "workers.$Worker.defaultModel" '' } }
        if (-not $Agent -and $s -and $s['agent']) { $Agent = $s['agent'] }
        $mf = (Resolve-Path $MessageFile).Path
        $vals = @{ sessionId = $SessionId; messageFile = $mf; messageText = (Add-MessagePrefix $Prefix $body); workspace = $ws; model = $Model
            agent = $Agent; permissions = (Get-PermissionArgs $Config $Worker)
            promptDir = $(if ($s -and $s['promptDir']) { $s['promptDir'] } else { Split-Path -Parent $mf }) }
        $cmd = Expand-CommandTemplate (Get-WorkerSpec $Config $Worker 'message') $vals
        $key = if ($s) { "$($s.taskId).msg-$((Get-Date).ToString('HHmmss'))" } else { "msg-$((Get-Date).ToString('yyyyMMdd-HHmmss'))" }
        $r = Start-GenericRun $Config $Worker $cmd $ws $key ([Math]::Min($WaitSeconds, 20))
        if ($s) {
            $s.pid = $r.Pid; $s.logPath = $r.Log; $p = $s.statePath; $s.Remove('statePath')
            $s | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $p
        }
        Add-DispatchLog ([ordered]@{ worker = $Worker; action = 'message'; sessionId = $SessionId; file = $MessageFile })
        return [ordered]@{ ok = $true }
    }

    New-AdapterError 'No mode given.' 'Use one of -Check, -Capabilities, -Dispatch, -Status, -Message, -Cancel.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $bound = $PSBoundParameters
    Complete-Script -Worker $Worker -Body { Invoke-GenericAdapter @bound }
}
