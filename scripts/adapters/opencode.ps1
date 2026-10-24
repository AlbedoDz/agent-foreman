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
    [string]$TaskId = '',
    [string]$PromptFile = '',
    [string]$Workspace = '.',
    [string]$Title = '',
    [string]$Model = '',
    [string]$SessionId = '',
    [string]$MessageFile = '',
    [int]$WaitSeconds = 45
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
    <# Synchronous call, used only for --version. Mocked in tests. #>
    param([string]$Exe, [string[]]$Arguments)
    $out = & $Exe @Arguments 2>&1 | Out-String
    @{ Out = $out; Code = $LASTEXITCODE }
}

function Wait-OpenCodeSession {
    <# Wait until the log shows a sessionID (started) or an error event / process exit (failed). #>
    param([string]$Log, [string]$ErrLog, [int]$ProcessId, [int]$Seconds)
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
    "pid:$ProcessId"
}

function Start-OpenCodeRun {
    param($Config, [string]$Workspace, [string]$Key, [string[]]$RunArgs, [int]$WaitSeconds)
    $exe = Resolve-OpenCodeCommand $Config
    $args_ = @('run', '--format', 'json')
    if (Get-ConfigValue $Config 'workers.opencode.autoApprove' $false) { $args_ += '--auto' }
    $args_ += $RunArgs
    $log = Join-Path (Get-LogDir) "$Key.opencode.jsonl"
    $err = Join-Path (Get-LogDir) "$Key.opencode.err.log"
    $p = Start-WorkerProcess -FilePath $exe -Arguments $args_ -WorkingDirectory $Workspace -StdOut $log -StdErr $err
    $sid = Wait-OpenCodeSession -Log $log -ErrLog $err -ProcessId $p.Id -Seconds $WaitSeconds
    @{ SessionId = $sid; Pid = $p.Id; Log = $log }
}

function Invoke-OpenCodeAdapter {
    param(
        [switch]$Check, [switch]$Dispatch, [switch]$Status, [switch]$Message,
        [string]$TaskId = '', [string]$PromptFile = '', [string]$Workspace = '.', [string]$Title = '',
        [string]$Model = '', [string]$SessionId = '', [string]$MessageFile = '', [int]$WaitSeconds = 45,
        $Config = $null
    )
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }

    if ($Check) {
        $exe = Resolve-OpenCodeCommand $Config
        $r = Invoke-OpenCodeCli -Exe $exe -Arguments @('--version')
        if ($r.Code -ne 0) { New-AdapterError "opencode --version failed: $($r.Out.Trim())" 'Reinstall opencode.' }
        $auto = [bool](Get-ConfigValue $Config 'workers.opencode.autoApprove' $false)
        $detail = "opencode found at $exe; autoApprove=$auto"
        if (-not $auto) { $detail += ' (headless runs cannot answer permission prompts; see docs/SECURITY.md)' }
        return [ordered]@{ ok = $true; worker = 'opencode'; version = $r.Out.Trim(); detail = $detail }
    }

    if ($Dispatch) {
        $in = Resolve-DispatchInputs $TaskId $PromptFile $Workspace
        if (-not $Model) { $Model = Get-ConfigValue $Config 'workers.opencode.defaultModel' '' }
        if (-not $Title) { $Title = $TaskId }
        $runArgs = @('--title', $Title)
        if ($Model) { $runArgs += @('-m', $Model) }
        $runArgs += (Get-TaskMessage $in.Workspace $in.Prompt)
        $r = Start-OpenCodeRun -Config $Config -Workspace $in.Workspace -Key $TaskId -RunArgs $runArgs -WaitSeconds $WaitSeconds
        Save-TaskState $TaskId ([ordered]@{ worker = 'opencode'; taskId = $TaskId; sessionId = $r.SessionId; pid = $r.Pid; logPath = $r.Log; workspace = $in.Workspace }) | Out-Null
        Add-DispatchLog ([ordered]@{ worker = 'opencode'; action = 'dispatch'; taskId = $TaskId; sessionId = $r.SessionId; model = $Model; workspace = $in.Workspace })
        return [ordered]@{ ok = $true; worker = 'opencode'; taskId = $TaskId; sessionId = $r.SessionId; logPath = $r.Log }
    }

    if ($Status) {
        if (-not $SessionId) { New-AdapterError '-Status needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        return Get-ProcessTaskStatus -Worker 'opencode' -SessionId $SessionId
    }

    if ($Message) {
        if (-not $SessionId -or -not $MessageFile) { New-AdapterError '-Message needs -SessionId and -MessageFile.' 'Write the nudge to a file first.' }
        if ($SessionId -like 'pid:*') { New-AdapterError 'This dispatch never reported a session id.' 'Dispatch again instead of messaging.' }
        $body = Read-TextFile $MessageFile 'Message file'
        $s = Find-TaskState $SessionId
        $ws = if ($s) { $s.workspace } else { (Get-Location).Path }
        $key = if ($s) { "$($s.taskId).msg-$((Get-Date).ToString('HHmmss'))" } else { "msg-$((Get-Date).ToString('yyyyMMdd-HHmmss'))" }
        $r = Start-OpenCodeRun -Config $Config -Workspace $ws -Key $key -RunArgs @('--session', $SessionId, $body) -WaitSeconds $WaitSeconds
        if ($s) {
            $s.pid = $r.Pid; $s.logPath = $r.Log; $p = $s.statePath; $s.Remove('statePath')
            $s | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $p
        }
        Add-DispatchLog ([ordered]@{ worker = 'opencode'; action = 'message'; sessionId = $SessionId; file = $MessageFile })
        return [ordered]@{ ok = $true }
    }

    New-AdapterError 'No mode given.' 'Use one of -Check, -Dispatch, -Status, -Message.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $bound = $PSBoundParameters
    Complete-Script -Worker 'opencode' -Body { Invoke-OpenCodeAdapter @bound }
}
