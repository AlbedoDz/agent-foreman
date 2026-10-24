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
        $r.Json.detail | Should -Match 'full permissions=False'
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
    It 'passes --auto only for permissions=full' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_x"}'; @{ Id = $PID } }
        $cfg.workers.opencode.permissions = 'full'
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
    It 'passes -Agent and puts -Prefix in front of the kickoff line' {
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_a"}'; @{ Id = $PID } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T10 -PromptFile $prompt -Workspace $ws -Agent plan -Prefix '/review' -Config $cfg } | Out-Null
        Should -Invoke Start-WorkerProcess -ParameterFilter {
            ($Arguments -join ' ') -match '--agent plan' -and $Arguments[-1] -like '/review Workspace: *'
        }
    }
    It '-Capabilities lists models from the CLI, static agents and skills from folders' {
        $skills = Join-Path $TestDrive 'oc-skills'
        New-Item -ItemType Directory -Force (Join-Path $skills 'tdd') | Out-Null
        Set-Content (Join-Path $skills 'tdd/SKILL.md') "---`nname: tdd`ndescription: Red then green.`n---`nbody"
        $cfg.workers.opencode.capabilities = @{ models = @{ cmd = @('opencode', 'models') }; agents = @('build', 'plan'); skills = @{ dirs = @($skills) } }
        Mock Invoke-CapabilityCommand { @('prov/a', 'prov/b') }
        $c = (Invoke-Run { Invoke-OpenCodeAdapter -Capabilities -Config $cfg }).Json.capabilities
        $c.models | Should -Be @('prov/a', 'prov/b')
        $c.agents | Should -Be @('build', 'plan')
        $c.skills[0].name | Should -Be 'tdd'
        $c.skills[0].description | Should -Be 'Red then green.'
    }
    It '-Cancel stops only the process tree it started, and is a no-op once finished' {
        Mock Stop-ProcessTree { }
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_c"}'; @{ Id = $PID } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T11 -PromptFile $prompt -Workspace $ws -Config $cfg } | Out-Null
        $r = (Invoke-Run { Invoke-OpenCodeAdapter -Cancel -SessionId ses_c -Config $cfg }).Json
        $r.cancelled | Should -BeTrue
        Should -Invoke Stop-ProcessTree -Times 1 -ParameterFilter { $ProcessId -eq $PID }
        Mock Start-WorkerProcess { Set-Content $StdOut '{"sessionID":"ses_d"}'; @{ Id = 999999 } }
        Invoke-Run { Invoke-OpenCodeAdapter -Dispatch -TaskId T12 -PromptFile $prompt -Workspace $ws -Config $cfg } | Out-Null
        (Invoke-Run { Invoke-OpenCodeAdapter -Cancel -SessionId ses_d -Config $cfg }).Json.cancelled | Should -BeFalse
        (Invoke-Run { Invoke-OpenCodeAdapter -Cancel -SessionId ses_unknown -Config $cfg }).Json.hint | Should -Match 'dispatched by this plugin'
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
        git -C $ws init -q 2>$null
        $script:cfg = @{ workers = @{ tool = @{
            dispatch = @('tool', 'exec', '--model', '{model}', '{message}')
            message = @('tool', 'resume', '{sessionId}', '--model', '{model}', '{messageText}')
            sessionIdPattern = 'session=(\w+)'; defaultModel = 'm1'
            errorPattern = 'NO_KEY[^\r\n]*'; errorHint = 'add the key in the app' } } }
        Mock Assert-Executable { }
    }
    AfterAll { Remove-Item Env:AG2O_HOME -ErrorAction SilentlyContinue }

    It 'expands placeholders and extracts the session id' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'booting... session=abc123'; @{ Id = $PID } }
        $r = Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G1 -PromptFile $prompt -Workspace $ws -WaitSeconds 6 -Config $cfg }
        $r.Json.sessionId | Should -Be 'abc123'
        $r.Json.worker | Should -Be 'tool'
        Should -Invoke Start-WorkerProcess -ParameterFilter { $FilePath -eq 'tool' -and $Arguments[2] -eq 'm1' -and $Arguments[3] -like 'Workspace: *' }
    }
    It '-Check passes a single argument intact (regression: splatting a string sent it char by char)' {
        $cfg.workers.tool.check = @('git', '--version')
        $r = Invoke-Run { Invoke-GenericAdapter -Worker tool -Check -Config $cfg }
        $r.Json.ok | Should -BeTrue
        $r.Json.version | Should -Match '^git version'
    }
    It 'splices {permissions} by mode and passes -Agent and -Prefix' {
        $cfg.workers.tool.dispatch = @('tool', 'run', '--agent', '{agent}', '--add-dir', '{promptDir}', '{permissions}', '{message}')
        $cfg.workers.tool.permissions = 'full'
        $cfg.workers.tool.permissionArgs = @{ default = @(); edits = @('--mode', 'edits'); full = @('--yolo', '--sandbox=off') }
        Mock Start-WorkerProcess { Set-Content $StdOut 'session=p1'; @{ Id = $PID } }
        Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G8 -PromptFile $prompt -Workspace $ws -Agent rev -Prefix '@helper' -WaitSeconds 6 -Config $cfg } | Out-Null
        Should -Invoke Start-WorkerProcess -ParameterFilter {
            $Arguments[0] -eq 'run' -and $Arguments[1] -eq '--agent' -and $Arguments[2] -eq 'rev' -and $Arguments[3] -eq '--add-dir' -and
            $Arguments[4] -eq $TestDrive -and $Arguments[5] -eq '--yolo' -and $Arguments[6] -eq '--sandbox=off' -and $Arguments[7] -like '@helper Workspace: *'
        }
    }
    It 'rejects an unknown permission mode' {
        $cfg.workers.tool.permissions = 'god'
        (Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G9 -PromptFile $prompt -Workspace $ws -Config $cfg }).Json.error | Should -Match 'default, edits or full'
    }
    It 'drops an empty optional value together with its flag' {
        Expand-CommandTemplate @('t', '--model', '{model}', '--x', '{message}') @{ model = ''; message = 'hi' } | Should -Be @('t', '--x', 'hi')
    }
    It 'expands %ENV% variables in the command' {
        $env:AG2O_TEST_DIR = 'C:\h'
        try { (Expand-CommandTemplate @('%AG2O_TEST_DIR%\bin\x.cmd', 'run') @{})[0] | Should -Be 'C:\h\bin\x.cmd' }
        finally { Remove-Item Env:AG2O_TEST_DIR }
    }
    It 'fails fast with the configured hint when errorPattern matches' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'session=s1'; Set-Content $StdErr 'fatal: NO_KEY for provider'; @{ Id = $PID } }
        $r = Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G4 -PromptFile $prompt -Workspace $ws -WaitSeconds 6 -Config $cfg }
        $r.Code | Should -Be 1
        $r.Json.error | Should -Match 'NO_KEY for provider'
        $r.Json.hint | Should -Be 'add the key in the app'
    }
    It 'reports a worker that exits before giving a session id' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'nothing'; Set-Content $StdErr 'boom'; @{ Id = 999999 } }
        $r = Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G2 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Json.error | Should -Match 'exited before reporting a session.*boom'
    }
    It 'falls back to a pid-based id when no sessionIdPattern is configured' {
        $cfg.workers.tool.Remove('sessionIdPattern'); $cfg.workers.tool.Remove('errorPattern')
        Mock Start-WorkerProcess { Set-Content $StdOut 'nothing'; @{ Id = 999999 } }
        (Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G5 -PromptFile $prompt -Workspace $ws -Config $cfg }).Json.sessionId | Should -Be 'pid:999999'
    }
    It '-Message resumes an idle session with the dispatch model and refuses while it runs' {
        Mock Start-WorkerProcess { Set-Content $StdOut 'session=g6'; @{ Id = 999999 } }
        Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G6 -PromptFile $prompt -Workspace $ws -Model 'm9' -WaitSeconds 6 -Config $cfg } | Out-Null
        $f = Join-Path $TestDrive 'g.md'; Set-Content $f 'continue'
        (Invoke-Run { Invoke-GenericAdapter -Worker tool -Message -SessionId g6 -MessageFile $f -Config $cfg }).Json.ok | Should -BeTrue
        Should -Invoke Start-WorkerProcess -ParameterFilter { $Arguments[0] -eq 'resume' -and $Arguments[1] -eq 'g6' -and $Arguments -contains 'm9' }
        Mock Start-WorkerProcess { Set-Content $StdOut 'session=g7'; @{ Id = $PID } }
        Invoke-Run { Invoke-GenericAdapter -Worker tool -Dispatch -TaskId G7 -PromptFile $prompt -Workspace $ws -WaitSeconds 6 -Config $cfg } | Out-Null
        (Invoke-Run { Invoke-GenericAdapter -Worker tool -Message -SessionId g7 -MessageFile $f -Config $cfg }).Json.error | Should -Match 'still running'
    }
    It 'explains a missing config entry' {
        $r = Invoke-Run { Invoke-GenericAdapter -Worker ghost -Dispatch -TaskId G3 -PromptFile $prompt -Workspace $ws -Config $cfg }
        $r.Json.error | Should -Match 'workers.ghost.dispatch'
        $r.Json.hint | Should -Match 'ADDING-A-HARNESS'
    }
}

Describe 'shipped harness presets (agy, dsh)' {
    BeforeAll {
        $script:tpl = Get-Content -Raw "$PSScriptRoot/../templates/orchestrator.config.json" | ConvertFrom-Json -AsHashtable
    }
    It 'agy: print mode, stream-json, model and accept-edits; conversation id from the init event' {
        $cmd = Expand-CommandTemplate $tpl.workers.agy.dispatch @{ message = 'GO'; model = 'gemini-x'; agent = ''; promptDir = 'C:\p'
            permissions = @($tpl.workers.agy.permissionArgs[$tpl.workers.agy.permissions]) }
        $cmd | Should -Be @('agy', '--print', 'GO', '--output-format', 'stream-json', '--model', 'gemini-x', '--add-dir', 'C:\p', '--mode', 'accept-edits')
        @($tpl.workers.agy.permissionArgs.full) | Should -Be @('--dangerously-skip-permissions')
        'jetski: no output produced — a tool required the "read_file" permission that headless mode cannot prompt for, so it was auto-denied.' |
            Should -Match $tpl.workers.agy.errorPattern
        $init = '{"event": "init", "conversation_id": "conv-abc", "init": {}}'
        [regex]::Match($init, $tpl.workers.agy.sessionIdPattern).Groups[1].Value | Should -Be 'conv-abc'
        '{"event": "result", "result": {"status": "SUCCESS"}}' | Should -Not -Match $tpl.workers.agy.errorPattern
        '{"event": "result", "result": {"status": "ERROR_QUOTA"}}' | Should -Match $tpl.workers.agy.errorPattern
        (Expand-CommandTemplate $tpl.workers.agy.message @{ messageText = 'm'; sessionId = 'c1'; model = '' }) -join ' ' |
            Should -Be 'agy --print m --conversation c1 --output-format stream-json'
    }
    It 'codex: exec --json in the worktree with sandbox level; thread id and turn.failed detection' {
        $c = $tpl.workers.codex
        $cmd = Expand-CommandTemplate $c.dispatch @{ message = 'GO'; model = ''; workspace = 'C:\wt'; promptDir = 'C:\p'
            permissions = @($c.permissionArgs[$c.permissions]) }
        $cmd[0] | Should -Match 'WindowsApps\\OpenAI\.Codex_\*\\app\\resources\\codex\.exe$'
        $cmd[1..($cmd.Count - 1)] -join ' ' | Should -Be 'exec --json --skip-git-repo-check -C C:\wt --add-dir C:\p -s workspace-write --approve-for-me GO'
        [regex]::Match('{"type":"thread.started","thread_id":"01a16f0f-3ae5"}', $c.sessionIdPattern).Groups[1].Value | Should -Be '01a16f0f-3ae5'
        '{"type":"turn.failed","error":{"message":"workspace routing discovery failed"}}' | Should -Match $c.errorPattern
        '{"type":"error","message":"Reconnecting... 1/5"}' | Should -Not -Match $c.errorPattern
        (Expand-CommandTemplate $c.message @{ messageText = 'm'; sessionId = 't1'; model = '' })[1..5] | Should -Be @('exec', 'resume', '--json', 't1', 'm')
    }
    It 'dsh: headless --json from the app install; session id and missing-credential detection' {
        $cmd = Expand-CommandTemplate $tpl.workers.dsh.dispatch @{ message = 'GO'; model = '' }
        $cmd[0] | Should -Be (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd')
        $cmd[1..3] | Should -Be @('headless', '--json', 'GO')
        [regex]::Match('{"type": "session", "sessionId": "session-a512", "cwd": "x"}', $tpl.workers.dsh.sessionIdPattern).Groups[1].Value | Should -Be 'session-a512'
        'dsh: MISSING_CREDENTIAL: llm-deepseek: no API key' | Should -Match $tpl.workers.dsh.errorPattern
        (Expand-CommandTemplate $tpl.workers.dsh.message @{ messageText = 'm'; sessionId = 's1' })[1..5] | Should -Be @('headless', '--json', '--session-id', 's1', 'm')
    }
}
