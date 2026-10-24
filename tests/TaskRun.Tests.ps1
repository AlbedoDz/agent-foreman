BeforeAll {
    . "$PSScriptRoot/../scripts/task-run.ps1"
    $script:runRepo = Join-Path $TestDrive 'run/repo'
    New-Item -ItemType Directory -Force $runRepo | Out-Null
    git -C $runRepo init -q -b main; git -C $runRepo config user.email t@example.invalid; git -C $runRepo config user.name t
    git -C $runRepo commit -q --allow-empty -m init
    git -C $runRepo branch task/R1
    $env:AG2O_HOME = Join-Path $TestDrive 'orch'
    function New-P([hashtable]$Over = @{}) {
        $p = @{ Worker = 'opencode'; TaskId = 'R1'; PromptFile = 'p.md'; Workspace = '../wt-R1'; Handoff = 'H.md'; Title = ''; Model = 'm1'
            Agent = ''; Prefix = '/tdd'; Allowed = @('src/*'); Forbidden = @(); Locked = @('tests/*'); Run = @('python -m unittest'); RunFile = ''
            FixRounds = 2; TimeoutMin = 5; StallMin = 5; PollSeconds = 1; SessionId = ''; Repo = $runRepo }
        foreach ($k in $Over.Keys) { $p[$k] = $Over[$k] }
        $p
    }
    $script:refuted = @{ ok = $false; verdict = 'refuted'; evidence = 'e.json'
        findings = @(@{ severity = 'error'; code = 'check-failed'; detail = "'python -m unittest' exited 1." })
        checks = @(@{ command = 'python -m unittest'; exitCode = 1; timedOut = $false; tail = @('FAIL: test_x', 'AssertionError: 2 != 3') }) }
    $script:verified = @{ ok = $true; verdict = 'verified'; evidence = 'e.json'; findings = @(); checks = @() }
}
AfterAll { Remove-Item Env:AG2O_HOME -ErrorAction SilentlyContinue }

Describe 'task-run.ps1 (dispatch -> watch -> verify -> auto-fix)' {
    BeforeEach { $script:calls = [System.Collections.Generic.List[object]]::new() }

    It 'dispatches with model/prefix, watches, verifies and stops at verified without merging' {
        Mock Invoke-JsonScript {
            $calls.Add(@{ Script = $Script; Args = $Arguments })
            switch -Wildcard ($Script) {
                'adapters/*' { @{ Json = @{ ok = $true; sessionId = 'S1' }; Code = 0 } }
                'watch-handoff.ps1' { @{ Json = @{ ok = $true; event = 'handoff' }; Code = 0 } }
                'verify-handoff.ps1' { @{ Json = $verified; Code = 0 } }
            }
        }
        $r = Invoke-TaskRun -P (New-P)
        $r.verdict | Should -Be 'verified'
        $r.sessionId | Should -Be 'S1'
        $r.next | Should -Match 'task-cleanup.*-Merge'
        $d = $calls | Where-Object { $_.Script -like 'adapters/*' } | Select-Object -First 1
        $d.Args -join ' ' | Should -Match '-Model m1.*-Prefix /tdd'
        $v = $calls | Where-Object { $_.Script -eq 'verify-handoff.ps1' } | Select-Object -First 1
        $v.Args -join ' ' | Should -Match '-Allowed src/\* -Locked tests/\* -Run python -m unittest'
        @($calls | Where-Object { $_.Script -eq 'task-cleanup.ps1' }).Count | Should -Be 0
        (Get-Content -Raw (Join-Path $env:AG2O_HOME 'logs/run-R1.json') | ConvertFrom-Json).verdict | Should -Be 'verified'
    }

    It 'sends a specific fix message when refuted, then waits for a NEW handoff and verifies again' {
        $script:verifyCount = 0
        Mock Invoke-JsonScript {
            $calls.Add(@{ Script = $Script; Args = $Arguments })
            switch -Wildcard ($Script) {
                'adapters/*' { @{ Json = @{ ok = $true; sessionId = 'S2' }; Code = 0 } }
                'watch-handoff.ps1' { @{ Json = @{ ok = $true; event = 'handoff' }; Code = 0 } }
                'verify-handoff.ps1' { $script:verifyCount++; if ($script:verifyCount -eq 1) { @{ Json = $refuted; Code = 1 } } else { @{ Json = $verified; Code = 0 } } }
            }
        }
        $r = Invoke-TaskRun -P (New-P)
        $r.verdict | Should -Be 'verified'
        $r.rounds | Should -Be 1
        $msg = $calls | Where-Object { $_.Args -contains '-Message' }
        @($msg).Count | Should -Be 1
        $file = $msg.Args[[array]::IndexOf($msg.Args, '-MessageFile') + 1]
        $text = Get-Content -Raw $file
        $text | Should -Match '\[check-failed\]'
        $text | Should -Match 'AssertionError: 2 != 3'
        $text | Should -Match 'NEW last commit'
        $w2 = @($calls | Where-Object { $_.Script -eq 'watch-handoff.ps1' })[1]
        $w2.Args[[array]::IndexOf($w2.Args, '-Since') + 1] | Should -Match '^[0-9a-f]{40}$'
    }

    It 'gives up after the fix rounds with a take-over hint' {
        Mock Invoke-JsonScript {
            $calls.Add(@{ Script = $Script; Args = $Arguments })
            switch -Wildcard ($Script) {
                'adapters/*' { @{ Json = @{ ok = $true; sessionId = 'S3' }; Code = 0 } }
                'watch-handoff.ps1' { @{ Json = @{ ok = $true; event = 'handoff' }; Code = 0 } }
                'verify-handoff.ps1' { @{ Json = $refuted; Code = 1 } }
            }
        }
        $r = Invoke-TaskRun -P (New-P @{ FixRounds = 2 })
        $r.verdict | Should -Be 'refuted'
        $r.hint | Should -Match 'Take over'
        @($calls | Where-Object { $_.Args -contains '-Message' }).Count | Should -Be 2
        @($calls | Where-Object { $_.Script -eq 'verify-handoff.ps1' }).Count | Should -Be 3
    }

    It 'stops with no-handoff when the watcher reports a stall, and skips dispatch for a given session' {
        Mock Invoke-JsonScript {
            $calls.Add(@{ Script = $Script; Args = $Arguments })
            if ($Script -eq 'watch-handoff.ps1') { return @{ Json = @{ ok = $false; event = 'stall'; error = 'quiet'; hint = 'nudge' }; Code = 2 } }
            @{ Json = @{ ok = $true }; Code = 0 }
        }
        $r = Invoke-TaskRun -P (New-P @{ SessionId = 'given' })
        $r.verdict | Should -Be 'no-handoff'
        $r.hint | Should -Be 'nudge'
        @($calls | Where-Object { $_.Args -contains '-Dispatch' }).Count | Should -Be 0
    }
}
