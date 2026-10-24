BeforeAll {
    . "$PSScriptRoot/../scripts/adapters/opencode.ps1"
    . "$PSScriptRoot/../scripts/adapters/generic-cli.ps1"
    function Invoke-Run([scriptblock]$Body) {
        $r = Invoke-Guarded -Body $Body
        [pscustomobject]@{ Json = ($r.Line | ConvertFrom-Json); Code = $r.ExitCode; Line = $r.Line }
    }
}

Describe 'Join-ProcessArguments' {
    It 'quotes arguments with spaces and escapes quotes' {
        Join-ProcessArguments @('run', 'a b', 'say "hi"', '') | Should -Be 'run "a b" "say \"hi\"" ""'
    }
    It 'doubles trailing backslashes inside quotes' {
        Join-ProcessArguments @('C:\dir with space\') | Should -Be '"C:\dir with space\\"'
    }
}

Describe 'opencode.ps1' {
    BeforeEach {
        $env:AG2O_HOME = Join-Path $TestDrive 'orch'
        $script:prompt = Join-Path $TestDrive 'T1.prompt.md'; Set-Content $prompt 'x'
        $script:ws = Join-Path $TestDrive 'wt-T1'; New-Item -ItemType Directory -Force $ws | Out-Null
        git -C $ws init -q 2>$null
        $script:cfg = @{ workers = @{ opencode = @{ command = 'opencode.cmd'; defaultModel = 'prov/model' } } }
        Mock Invoke-OpenCodeCli { @{ Out = '[]'; Code = 0 } } -ParameterFilter { $Arguments[0] -eq 'session' }
    }
    AfterAll { Remove-Item Env:AG2O_HOME -ErrorAction SilentlyContinue }

    It '-Check reports the version and warns about permissions' {
        Mock Invoke-OpenCodeCli { @{ Out = "2.0.32`n"; Code = 0 } }
        $r = Invoke-Run { Invoke-OpenCodeAdapter -Check -Config $cfg }
        $r.Json.worker | Should -Be 'opencode'
        $r.Json.version | Should -Be '2.0.32'
        $r.Json.detail | Should -Match 'autoApprove=False'
    }
    It '-Dispatch starts opencode in the worktree and returns the sessionID from the first event' {
        Mock Start-WorkerProcess {
            Set-Content $StdOut '{"type":"step_start","timestamp":1,"sessionID":"ses_abc","part":{}}'
            @{ Id = $PID }
        }
        $r = Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T1 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Code | Should -Be 0
        $r.Json.sessionId | Should -Be 'ses_abc'
        $r.Json.logPath | Should -Match 'T1\.opencode\.jsonl$'
        Should -Invoke Start-WorkerProcess -ParameterFilter {
            $WorkingDirectory -eq $ws -and $Arguments[0] -eq 'run' -and ($Arguments -contains 'prov/model') -and
            ($Arguments -notcontains '--auto') -and ($Arguments[-1] -like "Workspace: $ws*")
        }
        (Invoke-Run { Invoke-OpenCodeAdapter -Status -SessionId ses_abc }).Json.state | Should -Be 'running'
    }
    It 'passes --auto only when autoApprove is set' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_x"}'; @{ Id = $PID } }
        $cfg.workers.opencode.autoApprove = $true
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T2 -PromptFile $prompt -Workspace $ws -Config $cfg } | Out-Null
        Should -Invoke Start-WorkerProcess -ParameterFilter { $Arguments -contains '--auto' }
    }
    It 'turns a provider auth error event into a credential hint' {
        Mock Start-WorkerProcess {
            Set-Content $StdOut '{"type":"error","sessionID":"ses_e","error":{"type":"provider.auth","message":"requires a credential"}}'
            @{ Id = 999999 }
        }
        $r = Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T3 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Code | Should -Be 1
        $r.Json.error | Should -Match 'provider.auth'
        $r.Json.hint | Should -Match 'opencode auth'
    }
    It '-Status is idle once the process has exited, unknown for a foreign session' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_dead"}'; @{ Id = 999999 } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T4 -PromptFile $prompt -Workspace $ws -Config $cfg } | Out-Null
        (Invoke-Run { Invoke-OpenCodeAdapter -Status -SessionId ses_dead }).Json.state | Should -Be 'idle'
        (Invoke-Run { Invoke-OpenCodeAdapter -Status -SessionId ses_other }).Json.state | Should -Be 'unknown'
    }
    It '-Message continues an idle session in the same worktree with the dispatch model' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_m"}'; @{ Id = 999999 } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T5 -PromptFile $prompt -Workspace $ws -Model 'x/fast' -Config $cfg } | Out-Null
        $f = Join-Path $TestDrive 'n.md'; Set-Content $f 'keep going'
        (Invoke-Run { Invoke-OpenCodeAdapter -Message -SessionId ses_m -MessageFile $f -Config $cfg }).Json.ok | Should -BeTrue
        Should -Invoke Start-WorkerProcess -ParameterFilter {
            $Arguments -contains '--session' -and $Arguments -contains 'ses_m' -and $Arguments -contains 'x/fast' -and $WorkingDirectory -eq $ws
        }
    }
    It '-Message refuses when the task worktree is gone' {
        $gone = Join-Path $TestDrive 'wt-gone'; New-Item -ItemType Directory $gone | Out-Null
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_gone"}'; @{ Id = 999999 } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T9 -PromptFile $prompt -Workspace $gone -Config $cfg } | Out-Null
        $f = Join-Path $TestDrive 'n3.md'; Set-Content $f 'x'
        (Invoke-Run { Invoke-OpenCodeAdapter -Message -SessionId ses_gone -MessageFile $f -Config $cfg }).Json.error | Should -Match 'gone or not a git worktree'
    }
    It '-Message refuses while the session is still running' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_busy"}'; @{ Id = $PID } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T7 -PromptFile $prompt -Workspace $ws -Config $cfg } | Out-Null
        $f = Join-Path $TestDrive 'n2.md'; Set-Content $f 'x'
        (Invoke-Run { Invoke-OpenCodeAdapter -Message -SessionId ses_busy -MessageFile $f -Config $cfg }).Json.error | Should -Match 'still running'
    }
    It 'finds the session by title when the model is slow to emit the first event' {
        Mock Start-WorkerProcess { Set-Content $StdOut ''; @{ Id = $PID } }
        Mock Invoke-OpenCodeCli {
            $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            @{ Out = "[{`"id`":`"ses_slow`",`"title`":`"T8`",`"created`":$now,`"updated`":$now},{`"id`":`"ses_old`",`"title`":`"T8`",`"created`":1,`"updated`":1}]"; Code = 0 }
        } -ParameterFilter { $Arguments[0] -eq 'session' }
        $r = Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T8 -PromptFile $prompt -Workspace $ws -WaitSeconds 1 -Config $cfg }
        $r.Json.sessionId | Should -Be 'ses_slow'
        $st = (Invoke-Run { Invoke-OpenCodeAdapter -Status -SessionId ses_slow -Config $cfg }).Json
        $st.state | Should -Be 'running'
        ([datetime]$st.lastActivity) | Should -BeGreaterThan (Get-Date).AddMinutes(-1)
    }
    It 'fails cleanly with a hint when the prompt is missing' {
        $r = Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T6 -PromptFile 'nope.md' -Workspace $ws -Config $cfg }
        $r.Json.ok | Should -BeFalse
        $r.Json.hint | Should -Match 'TASK.prompt.md'
    }
}

Describe 'generic-cli.ps1' {
    BeforeEach {
        $env:AG2O_HOME = Join-Path $TestDrive 'orch-g'
        $script:prompt = Join-Path $TestDrive 'G1.prompt.md'; Set-Content $prompt 'x'
        $script:ws = Join-Path $TestDrive 'wt-G1'; New-Item -ItemType Directory -Force $ws | Out-Null
        $script:cfg = @{ workers = @{ tool = @{
            dispatch = @('tool', 'exec', '--model', '{model}', '{message}')
            message = @('tool', 'resume', '{sessionId}', '{messageText}')
            sessionIdPattern = 'session=(\w+)'; defaultModel = 'm1' } } }
    }
    AfterAll { Remove-Item Env:AG2O_HOME -ErrorAction SilentlyContinue }

    It 'expands placeholders and extracts the session id' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'booting... session=abc123'; @{ Id = $PID } }
        $r = Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G1 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Json.sessionId | Should -Be 'abc123'
        $r.Json.worker | Should -Be 'tool'
        Should -Invoke Start-WorkerProcess -ParameterFilter { $FilePath -eq 'tool' -and $Arguments[2] -eq 'm1' -and $Arguments[3] -like 'Workspace: *' }
    }
    It 'falls back to a pid-based id when no session id appears' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'nothing'; @{ Id = 999999 } }
        (Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G2 -PromptFile $prompt -Workspace $ws -Config $cfg }).Json.sessionId | Should -Be 'pid:999999'
    }
    It 'explains a missing config entry' {
        $r = Invoke-Run { Invoke-GenericAdapter -Worker ghost -Dispatch -TaskId G3 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Json.error | Should -Match 'workers.ghost.dispatch'
        $r.Json.hint | Should -Match 'ADDING-A-HARNESS'
    }
}
