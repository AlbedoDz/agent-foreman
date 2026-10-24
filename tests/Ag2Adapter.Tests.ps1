BeforeAll {
    . "$PSScriptRoot/../scripts/adapters/ag2.ps1"
    $script:fakeToken = 'tok' + ('9f' * 12)
    $script:exe = Join-Path $TestDrive 'language_server.exe'
    Set-Content $exe 'fake'
    $script:helpOk = @"
Usage: agentapi <command> [args]

Available Commands:
  get-conversation-metadata <conversation_id>
  new-conversation [--model=<flash_lite|flash|pro>] [--title=<title>] [--profile=<profile>] <prompt>
  send-message [--title=<title>] <recipient_id> <content>
"@
    $script:hub = [pscustomobject]@{
        ProcessId = 4242; ExecutablePath = $exe
        CommandLine = "`"$exe`" --subclient_type hub --csrf" + "_token $fakeToken --other x"
    }
    function Invoke-Run([hashtable]$P) {
        $cfg = if ($P.ContainsKey('Config')) { $P.Config } else { @{} }
        $P.Remove('Config')
        $r = Invoke-Guarded -Worker 'ag2' -Body { Invoke-Ag2Adapter @P -Config $cfg }
        $r.Line | Should -Not -Match $fakeToken
        [pscustomobject]@{ Json = ($r.Line | ConvertFrom-Json); Code = $r.ExitCode; Line = $r.Line }
    }
}

Describe 'ag2.ps1' {
BeforeEach {
    $env:AG2O_HOME = Join-Path $TestDrive 'orch'
    Remove-Item Env:ANTIGRAVITY_PROJECT_ID, Env:ANTIGRAVITY_CSRF_TOKEN -ErrorAction SilentlyContinue
    Mock Get-CimInstance { $hub }
    Mock Get-NetTCPConnection {
        @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 61989 },
          [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 61990 })
    }
    # 61989 behaves like the gRPC preface port seen in practice; 61990 is the agent API.
    Mock Invoke-AgentApi {
        if ($Arguments[0] -eq '--help') { return @{ Out = $helpOk; Code = 0 } }
        if ($env:ANTIGRAVITY_LS_ADDRESS -like '*:61989') { return @{ Out = 'error reading server preface: EOF'; Code = 1 } }
        switch ($Arguments[0]) {
            'get-conversation-metadata' {
                if ($Arguments[1] -like '00000000*') { return @{ Out = '{"error":"conversation not found"}'; Code = 1 } }
                return @{ Out = ('{"response":{"projectId":"proj-1","gitOriginUrl":"https://user' + ':pw@github.com/o/r.git","branch":"task/T1"}}'); Code = 0 }
            }
            'new-conversation' { return @{ Out = '{"response":{"newConversation":{"conversationId":"conv-123"}}}'; Code = 0 } }
            'send-message' { return @{ Out = '{"response":{"sendMessage":{}}}'; Code = 0 } }
        }
    }
}

AfterAll { Remove-Item Env:AG2O_HOME, Env:ANTIGRAVITY_LS_ADDRESS, Env:ANTIGRAVITY_CSRF_TOKEN, Env:ANTIGRAVITY_PROJECT_ID -ErrorAction SilentlyContinue }

Describe 'process discovery' {
    It 'reports AG2 not running with a fix hint' {
        Mock Get-CimInstance { }
        $r = Invoke-Run @{ Check = $true }
        $r.Code | Should -Be 1
        $r.Json.ok | Should -BeFalse
        $r.Json.hint | Should -Match 'Open the Antigravity 2'
    }
    It 'ignores language_server processes that are not the hub' {
        Mock Get-CimInstance { [pscustomobject]@{ ProcessId = 1; ExecutablePath = $exe; CommandLine = 'language_server.exe --subclient_type ide' } }
        (Invoke-Run @{ Check = $true }).Json.error | Should -Match 'not running'
    }
    It 'puts the token only in the environment, never in the output' {
        $r = Invoke-Run @{ Check = $true }
        $r.Code | Should -Be 0
        $env:ANTIGRAVITY_CSRF_TOKEN | Should -Be $fakeToken
    }
}

Describe '-Check' {
    It 'skips the preface port and reports the API port' {
        $r = Invoke-Run @{ Check = $true }
        $r.Json.worker | Should -Be 'ag2'
        $r.Json.detail | Should -Match '61990'
        $r.Json.detail | Should -Match 'no projectId'
    }
    It 'refuses to run when agentapi --help changed' {
        Mock Invoke-AgentApi { @{ Out = "Usage: agentapi`n  new-conversation [--model=<a|b>] <prompt>"; Code = 0 } } -ParameterFilter { $Arguments[0] -eq '--help' }
        $r = Invoke-Run @{ Check = $true }
        $r.Code | Should -Be 1
        $r.Json.error | Should -Match 'signature changed'
        $r.Json.hint | Should -Match 'TROUBLESHOOTING'
    }
    It 'tolerates new extra commands' {
        Mock Invoke-AgentApi { @{ Out = $helpOk + "`n  list-conversations"; Code = 0 } } -ParameterFilter { $Arguments[0] -eq '--help' }
        (Invoke-Run @{ Check = $true }).Code | Should -Be 0
    }
}

Describe '-Dispatch' {
    BeforeEach {
        $script:prompt = Join-Path $TestDrive 'T1.prompt.md'; Set-Content $prompt 'do it'
        $script:ws = Join-Path $TestDrive 'wt-T1'; New-Item -ItemType Directory -Force $ws | Out-Null
    }
    It 'requires a project id and says how to find it' {
        $r = Invoke-Run @{ Dispatch = $true; TaskId = 'T1'; PromptFile = $prompt; Workspace = $ws }
        $r.Code | Should -Be 1
        $r.Json.hint | Should -Match 'FindProjectId'
    }
    It 'creates a conversation and returns the contract fields' {
        $r = Invoke-Run @{ Dispatch = $true; TaskId = 'T1'; PromptFile = $prompt; Workspace = $ws; Config = @{ workers = @{ ag2 = @{ projectId = 'proj-1' } } } }
        $r.Code | Should -Be 0
        $r.Json.worker | Should -Be 'ag2'
        $r.Json.taskId | Should -Be 'T1'
        $r.Json.sessionId | Should -Be 'conv-123'
        $r.Json.logPath | Should -Match 'conv-123.*transcript\.jsonl$'
        Should -Invoke Invoke-AgentApi -ParameterFilter {
            $Arguments[0] -eq 'new-conversation' -and $Arguments[1] -eq '--model=flash' -and $Arguments[3] -like "Workspace: $ws*"
        }
        Get-Content (Join-Path $env:AG2O_HOME 'logs/dispatch.jsonl') -Raw | Should -Match '"taskId":"T1"'
        $env:ANTIGRAVITY_PROJECT_ID | Should -Be 'proj-1'
    }
    It 'rejects models outside flash_lite|flash|pro' {
        $r = Invoke-Run @{ Dispatch = $true; TaskId = 'T1'; PromptFile = $prompt; Workspace = $ws; Model = 'ultra'; ProjectId = 'p' }
        $r.Json.error | Should -Match 'Unsupported AG2 model'
    }
    It 'turns project_id errors into the project-id hint' {
        Mock Invoke-AgentApi { @{ Out = '{"error":"project_id is required when providing project_env_config"}'; Code = 1 } } -ParameterFilter { $Arguments[0] -eq 'new-conversation' }
        $r = Invoke-Run @{ Dispatch = $true; TaskId = 'T1'; PromptFile = $prompt; Workspace = $ws; ProjectId = 'wrong' }
        $r.Json.hint | Should -Match 'workers.ag2.projectId'
    }
}

Describe '-Status' {
    BeforeEach {
        $script:brain = Join-Path $TestDrive 'brain'
        $script:t = Join-Path $brain 'conv-123/.system_generated/logs/transcript.jsonl'
        New-Item -ItemType File -Force $t | Out-Null
        Set-Content $t @('{"step":1}', '{"step":2}')
        $script:cfg = @{ workers = @{ ag2 = @{ brainDir = $brain } } }
    }
    It 'infers running from a fresh transcript and strips url fields from metadata' {
        $r = Invoke-Run @{ Status = $true; SessionId = 'conv-123'; Config = $cfg; Tail = 1 }
        $r.Json.state | Should -Be 'running'
        $r.Json.stateSource | Should -Match 'inferred'
        $r.Json.metadata.response.branch | Should -Be 'task/T1'
        $r.Line | Should -Not -Match 'gitOriginUrl'
        $r.Line | Should -Not -Match 'user:pw'
        @($r.Json.tail).Count | Should -Be 1
    }
    It 'infers idle from an old transcript' {
        (Get-Item $t).LastWriteTime = (Get-Date).AddHours(-2)
        (Invoke-Run @{ Status = $true; SessionId = 'conv-123'; Config = $cfg }).Json.state | Should -Be 'idle'
    }
    It 'reports unknown when no transcript exists' {
        (Invoke-Run @{ Status = $true; SessionId = 'nope'; Config = $cfg }).Json.state | Should -Be 'unknown'
    }
}

Describe '-Capabilities, -Prefix, -Agent' {
    It 'lists the fixed agentapi models without contacting AG2' {
        Mock Get-CimInstance { throw 'must not be called' }
        $r = Invoke-Run @{ Capabilities = $true }
        $r.Json.capabilities.models | Should -Be @('flash_lite', 'flash', 'pro')
    }
    It 'puts -Prefix in front of the kickoff message' {
        $p = Join-Path $TestDrive 'P.prompt.md'; Set-Content $p 'x'
        $w = Join-Path $TestDrive 'wt-P'; New-Item -ItemType Directory -Force $w | Out-Null
        (Invoke-Run @{ Dispatch = $true; TaskId = 'P'; PromptFile = $p; Workspace = $w; ProjectId = 'p'; Prefix = '/tdd' }).Code | Should -Be 0
        Should -Invoke Invoke-AgentApi -ParameterFilter { $Arguments[0] -eq 'new-conversation' -and $Arguments[3] -like '/tdd Workspace: *' }
    }
    It '-Cancel explains that AG2 conversations are stopped in the app' {
        (Invoke-Run @{ Cancel = $true; SessionId = 'conv-123' }).Json.hint | Should -Match 'Antigravity 2 window'
    }
    It 'refuses -Agent with a pointer to the agy worker' {
        (Invoke-Run @{ Check = $true; Agent = 'x' }).Json.hint | Should -Match 'agy'
    }
}

Describe '-Message and -FindProjectId' {
    It 'sends the file content to the conversation' {
        $f = Join-Path $TestDrive 'nudge.md'; Set-Content $f 'please continue'
        (Invoke-Run @{ Message = $true; SessionId = 'conv-123'; MessageFile = $f }).Json.ok | Should -BeTrue
        Should -Invoke Invoke-AgentApi -ParameterFilter { $Arguments[0] -eq 'send-message' -and $Arguments[1] -eq 'conv-123' -and $Arguments[2] -match 'please continue' }
    }
    It 'extracts only the projectId from metadata' {
        $r = Invoke-Run @{ FindProjectId = $true; SessionId = 'conv-123' }
        $r.Json.projectId | Should -Be 'proj-1'
        $r.Line | Should -Not -Match 'github.com'
    }
}
}
