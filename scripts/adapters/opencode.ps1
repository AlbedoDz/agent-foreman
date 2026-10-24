# OpenCode CLI adapter (verified with opencode v2.0.x).
#
#   opencode.ps1 -Check
#   opencode.ps1 -Dispatch -TaskId T1 -PromptFile .claude\orchestrator\T1.prompt.md -Workspace ..\wt-T1 [-Title t] [-Model provider/model]
#   opencode.ps1 -Status   -SessionId ses_...
#   opencode.ps1 -Message  -SessionId ses_... -MessageFile nudge.md
#
# `opencode run --format json` prints one JSON event per line, each with "sessionID". It has no --dir flag, so the
# process is started with the worktree as working directory. It runs in the background; stdout goes to
# logs/<TaskId>.opencode.jsonl. Permission prompts cannot be answered headless: set workers.opencode.autoApprove=true
# in the config to pass --auto (read docs/SECURITY.md first).
param(
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

function Resolve-OpenCodeCommand {
    param($Config)
    $cmd = Get-ConfigValue $Config 'workers.opencode.command' ''
    if ($cmd) { return $cmd }
    foreach ($n in 'opencode.cmd', 'opencode.exe', 'opencode') {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    New-AdapterError 'opencode is not on PATH.' 'Install it (npm i -g opencode-ai) or set workers.opencode.command in orchestrator.config.json.'
}

function Invoke-OpenCodeCli {
    <# Synchronous call (--version, session list). Mocked in tests. #>
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = '')
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try { $out = & $Exe @Arguments 2>$null | Out-String; $code = $LASTEXITCODE }
    finally { if ($WorkingDirectory) { Pop-Location } }
    @{ Out = $out; Code = $code }
}

function Find-OpenCodeSession {
    <# Look a session up by title (dispatch) or id (status) in `opencode session list --format json` of the workspace.
       Needed because the first JSON event only appears after the model's first reply, which can take minutes. #>
    param($Config, [string]$Workspace, [string]$Title = '', [string]$Id = '', [datetime]$Since = [datetime]::MinValue)
    $exe = Resolve-OpenCodeCommand $Config
    $r = Invoke-OpenCodeCli -Exe $exe -Arguments @('session', 'list', '--format', 'json', '-n', '20') -WorkingDirectory $Workspace
    if ($r.Code -ne 0 -or -not $r.Out.Trim()) { return $null }
    try { $list = @($r.Out | ConvertFrom-Json -AsHashtable -ErrorAction Stop) } catch { return $null }
    $sinceMs = if ($Since -gt [datetime]::MinValue) { ([DateTimeOffset]$Since.ToUniversalTime()).ToUnixTimeMilliseconds() - 5000 } else { 0 }
    $list | Where-Object {
        ($Id -and $_['id'] -eq $Id) -or (-not $Id -and $_['title'] -eq $Title -and [int64]$_['created'] -ge $sinceMs)
    } | Sort-Object { [int64]$_['created'] } -Descending | Select-Object -First 1
}

function Wait-OpenCodeSession {
    <# Wait until the log shows a sessionID (started) or an error event / process exit (failed). #>
    param([string]$Log, [string]$ErrLog, [int]$ProcessId, [int]$Seconds,
        $Config = @{}, [string]$Workspace = '', [string]$Title = '', [datetime]$Since = [datetime]::MinValue)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $events = @()
        if (Test-Path -LiteralPath $Log) {
            $events = @(Get-Content -LiteralPath $Log -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_ | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null } } | Where-Object { $_ })
        }
        $err = $events | Where-Object { $_['type'] -eq 'error' } | Select-Object -First 1
        if ($err) {
            $kind = Get-ConfigValue $err 'error.type' 'error'
            $msg = Get-ConfigValue $err 'error.message' 'unknown error'
            $hint = if ($kind -match 'auth') { 'The model provider has no credential: run `opencode auth login`, or pass -Model provider/model for a provider listed by `opencode auth list`.' }
                    else { 'Read the log for details: ' + $Log }
            New-AdapterError "opencode failed: $kind - $msg" $hint
        }
        $sid = $events | Where-Object { $_['sessionID'] } | Select-Object -First 1
        if ($sid) { return $sid['sessionID'] }
        if (-not (Test-ProcessAlive $ProcessId)) {
            $tail = if (Test-Path -LiteralPath $ErrLog) { (Get-Content -LiteralPath $ErrLog -Tail 5) -join ' | ' } else { '' }
            New-AdapterError "opencode exited before starting a session. $tail" "Run it by hand in the worktree to see the error: opencode run --format json `"hello`""
        }
        Start-Sleep -Milliseconds 500
    }
    if ($Title) {
        $found = Find-OpenCodeSession -Config $Config -Workspace $Workspace -Title $Title -Since $Since
        if ($found) { return $found['id'] }
    }
    "pid:$ProcessId"
}

function Test-OpenCodeFull {
    <# permissions=full (or the older autoApprove=true) -> --auto #>
    param($Config)
    (Get-PermissionMode $Config 'opencode') -eq 'full' -or [bool](Get-ConfigValue $Config 'workers.opencode.autoApprove' $false)
}

function Start-OpenCodeRun {
    param($Config, [string]$Workspace, [string]$Key, [string[]]$RunArgs, [int]$WaitSeconds, [string]$Title = '')
    $started = Get-Date
    $exe = Resolve-OpenCodeCommand $Config
    $args_ = @('run', '--format', 'json')
    if (Test-OpenCodeFull $Config) { $args_ += '--auto' }
    $args_ += $RunArgs
    $log = Join-Path (Get-LogDir) "$Key.opencode.jsonl"
    $err = Join-Path (Get-LogDir) "$Key.opencode.err.log"
    $p = Start-WorkerProcess -FilePath $exe -Arguments $args_ -WorkingDirectory $Workspace -StdOut $log -StdErr $err
    $sid = Wait-OpenCodeSession -Log $log -ErrLog $err -ProcessId $p.Id -Seconds $WaitSeconds `
        -Config $Config -Workspace $Workspace -Title $Title -Since $started
    @{ SessionId = $sid; Pid = $p.Id; Log = $log }
}

function Invoke-OpenCodeAdapter {
    param(
        [switch]$Check, [switch]$Dispatch, [switch]$Status, [switch]$Message, [switch]$Capabilities, [switch]$Cancel,
        [string]$Agent = '', [string]$Prefix = '',
        [string]$TaskId = '', [string]$PromptFile = '', [string]$Workspace = '.', [string]$Title = '',
        [string]$Model = '', [string]$SessionId = '', [string]$MessageFile = '', [int]$WaitSeconds = 60,
        $Config = $null
    )
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }

    if ($Capabilities) {
        return [ordered]@{ ok = $true; worker = 'opencode'; permissions = $(if (Test-OpenCodeFull $Config) { 'full' } else { Get-PermissionMode $Config 'opencode' })
            capabilities = (Get-WorkerCapabilities $Config 'opencode') }
    }

    if ($Check) {
        $exe = Resolve-OpenCodeCommand $Config
        $r = Invoke-OpenCodeCli -Exe $exe -Arguments @('--version')
        if ($r.Code -ne 0) { New-AdapterError "opencode --version failed: $($r.Out.Trim())" 'Reinstall opencode.' }
        $auto = Test-OpenCodeFull $Config
        $detail = "opencode found at $exe; full permissions=$auto"
        if (-not $auto) { $detail += ' (headless runs cannot answer permission prompts; see docs/SECURITY.md)' }
        return [ordered]@{ ok = $true; worker = 'opencode'; version = $r.Out.Trim(); detail = $detail }
    }

    if ($Dispatch) {
        $in = Resolve-DispatchInputs $TaskId $PromptFile $Workspace
        if (-not $Model) { $Model = Get-ConfigValue $Config 'workers.opencode.defaultModel' '' }
        if (-not $Title) { $Title = $TaskId }
        if (-not $Agent) { $Agent = Get-ConfigValue $Config 'workers.opencode.defaultAgent' '' }
        $runArgs = @('--title', $Title)
        if ($Model) { $runArgs += @('-m', $Model) }
        if ($Agent) { $runArgs += @('--agent', $Agent) }
        $runArgs += (Add-MessagePrefix $Prefix (Get-TaskMessage $in.Workspace $in.Prompt))
        $r = Start-OpenCodeRun -Config $Config -Workspace $in.Workspace -Key $TaskId -RunArgs $runArgs -WaitSeconds $WaitSeconds -Title $Title
        Save-TaskState $TaskId ([ordered]@{ worker = 'opencode'; taskId = $TaskId; sessionId = $r.SessionId; pid = $r.Pid; logPath = $r.Log; workspace = $in.Workspace; model = $Model; agent = $Agent }) | Out-Null
        Add-DispatchLog ([ordered]@{ worker = 'opencode'; action = 'dispatch'; taskId = $TaskId; sessionId = $r.SessionId; model = $Model; workspace = $in.Workspace })
        return [ordered]@{ ok = $true; worker = 'opencode'; taskId = $TaskId; sessionId = $r.SessionId; logPath = $r.Log }
    }

    if ($Cancel) {
        if (-not $SessionId) { New-AdapterError '-Cancel needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        return Stop-TaskProcess -Worker 'opencode' -SessionId $SessionId
    }

    if ($Status) {
        if (-not $SessionId) { New-AdapterError '-Status needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        $st = Get-ProcessTaskStatus -Worker 'opencode' -SessionId $SessionId
        # The session's own `updated` time is a better activity signal than the stdout log (the model may think for minutes).
        $s = Find-TaskState $SessionId
        if ($s -and $SessionId -like 'ses_*') {
            $info = Find-OpenCodeSession -Config $Config -Workspace $s.workspace -Id $SessionId
            if ($info -and $info['updated']) {
                $upd = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$info['updated']).LocalDateTime
                if (-not $st.lastActivity -or $upd -gt [datetime]$st.lastActivity) { $st.lastActivity = $upd.ToString('o') }
            }
        }
        return $st
    }

    if ($Message) {
        if (-not $SessionId -or -not $MessageFile) { New-AdapterError '-Message needs -SessionId and -MessageFile.' 'Write the nudge to a file first.' }
        if ($SessionId -like 'pid:*') { New-AdapterError 'This dispatch never reported a session id.' 'Dispatch again instead of messaging.' }
        $body = Read-TextFile $MessageFile 'Message file'
        $s = Find-TaskState $SessionId
        $ws = if ($s) { $s.workspace } else { (Get-Location).Path }
        Assert-TaskWorkspace $ws
        $key = if ($s) { "$($s.taskId).msg-$((Get-Date).ToString('HHmmss'))" } else { "msg-$((Get-Date).ToString('yyyyMMdd-HHmmss'))" }
        if ($s -and (Test-ProcessAlive ([int]$s.pid))) {
            New-AdapterError "Session $SessionId is still running (pid $($s.pid)); a second run on it would race." 'Wait until -Status says idle, or stop that process, then send the message.'
        }
        if (-not $Model) { $Model = if ($s -and $s['model']) { $s['model'] } else { Get-ConfigValue $Config 'workers.opencode.defaultModel' '' } }
        if (-not $Agent -and $s -and $s['agent']) { $Agent = $s['agent'] }
        $msgArgs = @('--session', $SessionId)
        if ($Model) { $msgArgs += @('-m', $Model) }
        if ($Agent) { $msgArgs += @('--agent', $Agent) }
        $r = Start-OpenCodeRun -Config $Config -Workspace $ws -Key $key -RunArgs ($msgArgs + (Add-MessagePrefix $Prefix $body)) -WaitSeconds $WaitSeconds
        if ($s) {
            $s.pid = $r.Pid; $s.logPath = $r.Log; $p = $s.statePath; $s.Remove('statePath')
            $s | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $p
        }
        Add-DispatchLog ([ordered]@{ worker = 'opencode'; action = 'message'; sessionId = $SessionId; file = $MessageFile })
        return [ordered]@{ ok = $true }
    }

    New-AdapterError 'No mode given.' 'Use one of -Check, -Capabilities, -Dispatch, -Status, -Message, -Cancel.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $bound = $PSBoundParameters
    Complete-Script -Worker 'opencode' -Body { Invoke-OpenCodeAdapter @bound }
}
