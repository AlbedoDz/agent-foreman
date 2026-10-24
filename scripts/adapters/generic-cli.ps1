# Generic adapter for any coding harness with a headless CLI. TEMPLATE: not yet tested against a real harness.
#
#   generic-cli.ps1 -Worker <name> -Check | -Dispatch ... | -Status -SessionId x | -Message -SessionId x -MessageFile f
#
# Commands come from orchestrator.config.json -> workers.<name>, as argument ARRAYS (no shell quoting involved):
#   "mytool": {
#     "adapter": "generic-cli",
#     "check":    ["mytool", "--version"],
#     "dispatch": ["mytool", "exec", "--model", "{model}", "{message}"],
#     "message":  ["mytool", "exec", "--resume", "{sessionId}", "{messageText}"],
#     "sessionIdPattern": "\"session_id\"\\s*:\\s*\"([^\"]+)\""
#   }
# Placeholders: {taskId} {prompt} {workspace} {title} {model} {message} (the standard kickoff line)
#               {sessionId} {messageFile} {messageText}
# The process runs in the background with the worktree as working directory; stdout -> logs/<TaskId>.<worker>.log.
# sessionId = first match of sessionIdPattern in stdout within -WaitSeconds, else "pid:<n>".
param(
    [string]$Worker = '',
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
    [int]$WaitSeconds = 20
)
. "$PSScriptRoot/../lib/Common.ps1"

function Expand-CommandTemplate {
    param([string[]]$Template, [hashtable]$Values)
    @($Template | ForEach-Object {
        $a = $_
        foreach ($k in $Values.Keys) { $a = $a.Replace("{$k}", [string]$Values[$k]) }
        $a
    })
}

function Get-WorkerSpec {
    param($Config, [string]$Worker, [string]$Key)
    if (-not $Worker) { New-AdapterError '-Worker is required.' 'Name the worker as configured under workers.<name> in orchestrator.config.json.' }
    $t = Get-ConfigValue $Config "workers.$Worker.$Key" $null
    if (-not $t) { New-AdapterError "workers.$Worker.$Key is not configured." 'See docs/ADDING-A-HARNESS.md for the config shape.' }
    @($t)
}

function Start-GenericRun {
    param($Config, [string]$Worker, [string[]]$Cmd, [string]$Workspace, [string]$Key, [int]$WaitSeconds)
    $log = Join-Path (Get-LogDir) "$Key.$Worker.log"
    $err = Join-Path (Get-LogDir) "$Key.$Worker.err.log"
    $rest = if ($Cmd.Count -gt 1) { $Cmd[1..($Cmd.Count - 1)] } else { @() }
    $p = Start-WorkerProcess -FilePath $Cmd[0] -Arguments $rest -WorkingDirectory $Workspace -StdOut $log -StdErr $err
    $pattern = Get-ConfigValue $Config "workers.$Worker.sessionIdPattern" ''
    $sid = "pid:$($p.Id)"
    if ($pattern) {
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $deadline) {
            $text = if (Test-Path -LiteralPath $log) { Get-Content -Raw -LiteralPath $log } else { '' }
            $m = [regex]::Match([string]$text, $pattern)
            if ($m.Success) { $sid = $m.Groups[1].Value; break }
            if (-not (Test-ProcessAlive $p.Id)) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    @{ SessionId = $sid; Pid = $p.Id; Log = $log }
}

function Invoke-GenericAdapter {
    param(
        [string]$Worker = '', [switch]$Check, [switch]$Dispatch, [switch]$Status, [switch]$Message,
        [string]$TaskId = '', [string]$PromptFile = '', [string]$Workspace = '.', [string]$Title = '',
        [string]$Model = '', [string]$SessionId = '', [string]$MessageFile = '', [int]$WaitSeconds = 20,
        $Config = $null
    )
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }

    if ($Check) {
        $cmd = Get-WorkerSpec $Config $Worker 'check'
        $rest = if ($cmd.Count -gt 1) { $cmd[1..($cmd.Count - 1)] } else { @() }
        if (-not (Get-Command $cmd[0] -ErrorAction SilentlyContinue)) { New-AdapterError "$($cmd[0]) not found." "Install it or fix workers.$Worker.check." }
        $out = & $cmd[0] @rest 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { New-AdapterError "check command failed: $($out.Trim())" "Run it by hand: $($cmd -join ' ')" }
        return [ordered]@{ ok = $true; worker = $Worker; version = $out.Trim(); detail = 'check command succeeded' }
    }

    if ($Dispatch) {
        $in = Resolve-DispatchInputs $TaskId $PromptFile $Workspace
        if (-not $Model) { $Model = Get-ConfigValue $Config "workers.$Worker.defaultModel" '' }
        if (-not $Title) { $Title = $TaskId }
        $vals = @{ taskId = $TaskId; prompt = $in.Prompt; workspace = $in.Workspace; title = $Title; model = $Model
            message = (Get-TaskMessage $in.Workspace $in.Prompt) }
        $cmd = Expand-CommandTemplate (Get-WorkerSpec $Config $Worker 'dispatch') $vals
        $r = Start-GenericRun $Config $Worker $cmd $in.Workspace $TaskId $WaitSeconds
        Save-TaskState $TaskId ([ordered]@{ worker = $Worker; taskId = $TaskId; sessionId = $r.SessionId; pid = $r.Pid; logPath = $r.Log; workspace = $in.Workspace }) | Out-Null
        Add-DispatchLog ([ordered]@{ worker = $Worker; action = 'dispatch'; taskId = $TaskId; sessionId = $r.SessionId; workspace = $in.Workspace })
        return [ordered]@{ ok = $true; worker = $Worker; taskId = $TaskId; sessionId = $r.SessionId; logPath = $r.Log }
    }

    if ($Status) {
        if (-not $SessionId) { New-AdapterError '-Status needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        return Get-ProcessTaskStatus -Worker $Worker -SessionId $SessionId
    }

    if ($Message) {
        if (-not $SessionId -or -not $MessageFile) { New-AdapterError '-Message needs -SessionId and -MessageFile.' 'Write the nudge to a file first.' }
        $body = Read-TextFile $MessageFile 'Message file'
        $s = Find-TaskState $SessionId
        $ws = if ($s) { $s.workspace } else { (Get-Location).Path }
        Assert-TaskWorkspace $ws
        $vals = @{ sessionId = $SessionId; messageFile = (Resolve-Path $MessageFile).Path; messageText = $body; workspace = $ws; model = $Model }
        $cmd = Expand-CommandTemplate (Get-WorkerSpec $Config $Worker 'message') $vals
        $key = if ($s) { "$($s.taskId).msg-$((Get-Date).ToString('HHmmss'))" } else { "msg-$((Get-Date).ToString('yyyyMMdd-HHmmss'))" }
        Start-GenericRun $Config $Worker $cmd $ws $key 0 | Out-Null
        Add-DispatchLog ([ordered]@{ worker = $Worker; action = 'message'; sessionId = $SessionId; file = $MessageFile })
        return [ordered]@{ ok = $true }
    }

    New-AdapterError 'No mode given.' 'Use one of -Check, -Dispatch, -Status, -Message.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $bound = $PSBoundParameters
    Complete-Script -Worker $Worker -Body { Invoke-GenericAdapter @bound }
}
