# Antigravity 2 (desktop) adapter: drives AG2 through the `agentapi` CLI that ships with it.
#
#   ag2.ps1 -Check
#   ag2.ps1 -Dispatch -TaskId T1 -PromptFile .claude\orchestrator\T1.prompt.md -Workspace ..\wt-T1 [-Title t] [-Model flash]
#   ag2.ps1 -Status   -SessionId <conversationId> [-Tail 20]
#   ag2.ps1 -Message  -SessionId <conversationId> -MessageFile nudge.md
#   ag2.ps1 -FindProjectId [-SessionId <conversationId of a chat you started in the AG2 project>]
#
# How it works (see docs/HOW-IT-WORKS.md): the running AG2 hub (`language_server.exe --subclient_type hub`) is
# found from its process; its CSRF token is copied ONLY into this process's environment
# (ANTIGRAVITY_CSRF_TOKEN), never printed, logged or written to disk; each 127.0.0.1 port it listens on is tried.
# Every line printed is one JSON object passed through Protect-Secret.
param(
    [switch]$Check,
    [switch]$Dispatch,
    [switch]$Status,
    [switch]$Message,
    [switch]$FindProjectId,
    [string]$TaskId = '',
    [string]$PromptFile = '',
    [string]$Workspace = '.',
    [string]$Title = '',
    [ValidateSet('flash_lite', 'flash', 'pro')][string]$Model,
    [string]$SessionId = '',
    [string]$MessageFile = '',
    [string]$ProjectId = '',
    [int]$Tail = 0
)
. "$PSScriptRoot/../lib/Common.ps1"

# `agentapi --help` command lines this adapter was written against (verified 2026-10).
# If any of them is missing or reworded, refuse to run.
$script:KnownAgentApiSignature = @(
    'get-conversation-metadata <conversation_id>'
    'new-conversation [--model=<flash_lite|flash|pro>] [--title=<title>] [--profile=<profile>] <prompt>'
    'send-message [--title=<title>] <recipient_id> <content>'
)
$script:TransportError = 'Unauthenticated|Unavailable|connection error|server preface|connection refused|ANTIGRAVITY_\w+ is not set'
$script:ApiChangedHint = 'AG2 changed its agent API. Do not guess: see docs/TROUBLESHOOTING.md#api-changed, and dispatch by pasting the prompt into AG2 by hand meanwhile.'

function Get-Ag2Home { Join-Path $env:USERPROFILE '.gemini/antigravity' }

function Get-Ag2HubProcess {
    $p = Get-CimInstance Win32_Process -Filter "Name='language_server.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '--subclient_type[ =]+hub' } | Select-Object -First 1
    if (-not $p) {
        New-AdapterError 'Antigravity 2 is not running (no language_server.exe with --subclient_type hub).' `
            'Open the Antigravity 2 desktop app, wait until the agent hub is ready, then retry. Fallback: paste the prompt into AG2 by hand.'
    }
    $p
}

function Resolve-LanguageServerExe {
    <# Prefer the running process's own path; fall back to the path written inside agentapi.bat. #>
    param($Process)
    if ($Process.ExecutablePath -and (Test-Path -LiteralPath $Process.ExecutablePath)) { return $Process.ExecutablePath }
    $bat = Join-Path (Get-Ag2Home) 'bin/agentapi.bat'
    if (Test-Path -LiteralPath $bat) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $bat), '"([^"]+language_server\.exe)"')
        if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) { return $m.Groups[1].Value }
    }
    New-AdapterError 'Could not locate language_server.exe.' "Expected the AG2 process path or $bat. Reinstall/update Antigravity 2."
}

function Invoke-AgentApi {
    <# The only place the AG2 binary is executed. Mocked in tests. #>
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Arguments)
    $out = & $Exe agentapi @Arguments 2>&1 | Out-String
    @{ Out = $out; Code = $LASTEXITCODE }
}

function ConvertTo-SignatureLines {
    param([string]$HelpText)
    @($HelpText -split "`r?`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } |
        Where-Object { $_ -match '^(get-|new-|send-|[a-z]+-[a-z-]+ )' })
}

function Assert-Ag2Compatible {
    param([Parameter(Mandatory)][string]$Exe)
    $help = (Invoke-AgentApi -Exe $Exe -Arguments @('--help')).Out
    $got = ConvertTo-SignatureLines $help
    # A known command missing or with a changed signature = incompatible. New extra commands are tolerated.
    $missing = @($script:KnownAgentApiSignature | Where-Object { $_ -notin $got })
    if ($missing) { New-AdapterError 'AG2 agentapi signature changed; refusing to run.' $script:ApiChangedHint }
}

function Connect-Ag2 {
    <# Locate the hub, put the token in this process's env only, return exe + candidate ports (no token). #>
    $proc = Get-Ag2HubProcess
    $exe = Resolve-LanguageServerExe $proc
    $m = [regex]::Match([string]$proc.CommandLine, '--csrf_token[ =]+(\S+)')
    if (-not $m.Success) {
        New-AdapterError 'The AG2 hub process has no --csrf_token argument.' $script:ApiChangedHint
    }
    $env:ANTIGRAVITY_CSRF_TOKEN = $m.Groups[1].Value
    $ports = @(Get-LoopbackPorts -ProcessId $proc.ProcessId)
    if (-not $ports) {
        New-AdapterError 'The AG2 hub is not listening on any 127.0.0.1 port.' 'Restart Antigravity 2 and retry.'
    }
    Assert-Ag2Compatible -Exe $exe
    @{ Exe = $exe; Ports = $ports }
}

function Invoke-OnPorts {
    <# Try each loopback port until one answers without a transport/auth error. #>
    param($Conn, [string[]]$Arguments, [switch]$AllowApiError)
    $last = ''
    foreach ($port in $Conn.Ports) {
        $env:ANTIGRAVITY_LS_ADDRESS = "127.0.0.1:$port"
        $r = Invoke-AgentApi -Exe $Conn.Exe -Arguments $Arguments
        if ($r.Out -match $script:TransportError) { $last = "port ${port}: $($r.Out.Trim())"; continue }
        if (-not $AllowApiError -and ($r.Code -ne 0 -or $r.Out -match '"error"')) { $last = "port ${port}: $($r.Out.Trim())"; continue }
        return @{ Out = $r.Out; Port = $port }
    }
    if ($last -match 'project_id is required') {
        New-AdapterError 'AG2 needs a project id.' 'Set workers.ag2.projectId in .claude/orchestrator/orchestrator.config.json (find it with: ag2.ps1 -FindProjectId).'
    }
    New-AdapterError "AG2 agent API call failed on every port. Last: $last" 'Is Antigravity 2 fully started? Run ag2.ps1 -Check. If it keeps failing see docs/TROUBLESHOOTING.md.'
}

function Get-TranscriptPath {
    param([string]$Id, $Config)
    $brain = Get-ConfigValue $Config 'workers.ag2.brainDir' (Join-Path (Get-Ag2Home) 'brain')
    Join-Path $brain "$Id/.system_generated/logs/transcript.jsonl"
}

function Remove-UrlFields {
    <# Drop any key that may carry credentials (gitOriginUrl & co.) from parsed metadata, recursively. #>
    param($Node)
    if ($Node -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($k in @($Node.Keys)) {
            if ($k -match '(?i)url|token|secret|credential') { continue }
            $clean[$k] = Remove-UrlFields $Node[$k]
        }
        return $clean
    }
    if ($Node -is [System.Collections.IList] -and $Node -isnot [string]) { return @($Node | ForEach-Object { Remove-UrlFields $_ }) }
    $Node
}

function Resolve-ProjectId {
    param([string]$Explicit, $Config)
    if ($Explicit) { return $Explicit }
    $fromCfg = Get-ConfigValue $Config 'workers.ag2.projectId' ''
    if ($fromCfg) { return $fromCfg }
    ''
}

function Invoke-Ag2Adapter {
    param(
        [switch]$Check, [switch]$Dispatch, [switch]$Status, [switch]$Message, [switch]$FindProjectId,
        [string]$TaskId = '', [string]$PromptFile = '', [string]$Workspace = '.', [string]$Title = '',
        [string]$Model = '', [string]$SessionId = '', [string]$MessageFile = '', [string]$ProjectId = '', [int]$Tail = 0,
        $Config = $null
    )
    if ($null -eq $Config) { $Config = Read-OrchestratorConfig }
    $pid_ = Resolve-ProjectId $ProjectId $Config
    if ($pid_) { $env:ANTIGRAVITY_PROJECT_ID = $pid_ }

    if ($Check) {
        $conn = Connect-Ag2
        $r = Invoke-OnPorts $conn @('get-conversation-metadata', '00000000-0000-0000-0000-000000000000') -AllowApiError
        $detail = "agent API reachable on 127.0.0.1:$($r.Port)"
        if (-not $pid_) { $detail += '; WARNING no projectId configured (needed for -Dispatch, see -FindProjectId)' }
        return [ordered]@{ ok = $true; worker = 'ag2'; version = 'agentapi-v1-signature'; detail = $detail }
    }

    if ($FindProjectId) {
        if (-not $SessionId) {
            $brain = Get-ConfigValue $Config 'workers.ag2.brainDir' (Join-Path (Get-Ag2Home) 'brain')
            $recent = @(Get-ChildItem -Directory -LiteralPath $brain -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
                ForEach-Object { [ordered]@{ sessionId = $_.Name; lastActivity = $_.LastWriteTime.ToString('o') } })
            return [ordered]@{ ok = $true; worker = 'ag2'; recentSessions = $recent
                hint = 'In AG2, open (or create) the project for this repository folder and start any conversation. Then run: ag2.ps1 -FindProjectId -SessionId <that conversation id> (the most recent one above is usually it).' }
        }
        $conn = Connect-Ag2
        $r = Invoke-OnPorts $conn @('get-conversation-metadata', $SessionId)
        $m = [regex]::Match($r.Out, '"projectId"\s*:\s*"([^"]+)"')
        if (-not $m.Success) { New-AdapterError 'No projectId in that conversation''s metadata.' 'Use a conversation started inside an AG2 project (not a scratch chat).' }
        return [ordered]@{ ok = $true; worker = 'ag2'; projectId = $m.Groups[1].Value
            hint = 'Put it in .claude/orchestrator/orchestrator.config.json as workers.ag2.projectId (never commit that file to a public repo).' }
    }

    if ($Status) {
        if (-not $SessionId) { New-AdapterError '-Status needs -SessionId.' 'Pass the sessionId returned by -Dispatch.' }
        $meta = $null
        try {
            $conn = Connect-Ag2
            $r = Invoke-OnPorts $conn @('get-conversation-metadata', $SessionId)
            $json = $r.Out.Substring([Math]::Max(0, $r.Out.IndexOf('{')))
            $meta = Remove-UrlFields ($json | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
        } catch { $meta = $null }
        $t = Get-TranscriptPath $SessionId $Config
        $idleAfter = [int](Get-ConfigValue $Config 'workers.ag2.idleAfterMin' 5)
        $state = 'unknown'; $last = $null
        if (Test-Path -LiteralPath $t) {
            $lw = (Get-Item -LiteralPath $t).LastWriteTime
            $last = $lw.ToString('o')
            $state = if (((Get-Date) - $lw).TotalMinutes -lt $idleAfter) { 'running' } else { 'idle' }
        }
        $res = [ordered]@{ ok = $true; worker = 'ag2'; sessionId = $SessionId; state = $state; lastActivity = $last
            stateSource = "inferred-from-transcript-mtime (running = written in the last $idleAfter min); not an AG2 API" }
        if ($meta) { $res['metadata'] = $meta }
        if ($Tail -gt 0 -and (Test-Path -LiteralPath $t)) {
            $res['tail'] = @(Get-Content -LiteralPath $t -Tail $Tail | ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } })
        }
        return $res
    }

    if ($Message) {
        if (-not $SessionId -or -not $MessageFile) { New-AdapterError '-Message needs -SessionId and -MessageFile.' 'Write the nudge to a file first.' }
        $body = Read-TextFile $MessageFile 'Message file'
        $conn = Connect-Ag2
        Invoke-OnPorts $conn @('send-message', $SessionId, $body) | Out-Null
        Add-DispatchLog ([ordered]@{ worker = 'ag2'; action = 'message'; sessionId = $SessionId; file = $MessageFile })
        return [ordered]@{ ok = $true }
    }

    if ($Dispatch) {
        $in = Resolve-DispatchInputs $TaskId $PromptFile $Workspace
        if (-not $pid_) { New-AdapterError 'AG2 needs a project id.' 'Set workers.ag2.projectId in .claude/orchestrator/orchestrator.config.json (find it with: ag2.ps1 -FindProjectId).' }
        if (-not $Model) { $Model = Get-ConfigValue $Config 'workers.ag2.defaultModel' 'flash' }
        if ($Model -notin 'flash_lite', 'flash', 'pro') { New-AdapterError "Unsupported AG2 model '$Model'." 'Use flash_lite, flash or pro.' }
        $ws = $in.Workspace
        if (-not $Title) { $Title = $TaskId }
        $text = Get-TaskMessage $ws $in.Prompt
        $conn = Connect-Ag2
        $r = Invoke-OnPorts $conn @('new-conversation', "--model=$Model", "--title=$Title", $text)
        $m = [regex]::Match($r.Out, '"conversationId"\s*:\s*"([^"]+)"')
        if (-not $m.Success) { New-AdapterError 'AG2 accepted the call but returned no conversationId.' $script:ApiChangedHint }
        $sid = $m.Groups[1].Value
        $log = Get-TranscriptPath $sid $Config
        Add-DispatchLog ([ordered]@{ worker = 'ag2'; action = 'dispatch'; taskId = $TaskId; sessionId = $sid; model = $Model; workspace = $ws })
        return [ordered]@{ ok = $true; worker = 'ag2'; taskId = $TaskId; sessionId = $sid; logPath = $log }
    }

    New-AdapterError 'No mode given.' 'Use one of -Check, -Dispatch, -Status, -Message, -FindProjectId.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $bound = $PSBoundParameters
    Complete-Script -Worker 'ag2' -Body { Invoke-Ag2Adapter @bound }
}
