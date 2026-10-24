BeforeAll {
    . "$PSScriptRoot/../scripts/lib/Common.ps1"
    # Fake secrets are assembled at runtime so the repository never contains a token-shaped literal.
    $script:ghp = 'ghp_' + ('a1' * 18)
    $script:pat = 'github_pat_' + ('B2_' * 10)
    $script:userinfo = 'bob' + ':' + 'hunter2'
    $script:csrfArg = '--csrf' + '_token abcdef123456'
}

Describe 'Protect-Secret' {
    It 'redacts GitHub tokens' {
        $out = Protect-Secret "token $ghp and $pat end"
        $out | Should -Not -Match 'a1a1a1'
        $out | Should -Not -Match 'B2_B2_'
        $out | Should -Match 'ghp_\*\*\*'
        $out | Should -Match 'github_pat_\*\*\*'
    }
    It 'redacts user:pass@ and token@ URLs' {
        Protect-Secret "https://$userinfo@github.com/x/y.git" | Should -Be 'https://***@github.com/x/y.git'
        Protect-Secret "https://$('z' * 30)@github.com/x" | Should -Be 'https://***@github.com/x'
    }
    It 'redacts the csrf flag value and env assignments' {
        Protect-Secret "language_server.exe $csrfArg --x" | Should -Be ('language_server.exe --csrf' + '_token *** --x')
        Protect-Secret 'ANTIGRAVITY_CSRF_TOKEN=abcdef123456' | Should -Be 'ANTIGRAVITY_CSRF_TOKEN=***'
    }
    It 'redacts the literal value of the CSRF env var wherever it appears' {
        $env:ANTIGRAVITY_CSRF_TOKEN = 'live-secret-value-123'
        try { Protect-Secret 'echo live-secret-value-123 here' | Should -Be 'echo *** here' }
        finally { Remove-Item Env:ANTIGRAVITY_CSRF_TOKEN }
    }
    It 'blanks gitOriginUrl in JSON' {
        Protect-Secret '{"gitOriginUrl":"https://example.com/a.git","b":1}' | Should -Be '{"gitOriginUrl":"[redacted]","b":1}'
    }
    It 'leaves ordinary text alone' {
        Protect-Secret 'Workspace: C:\work\repo. Read the file' | Should -Be 'Workspace: C:\work\repo. Read the file'
    }
}

Describe 'Invoke-Guarded (JSON output contract)' {
    It 'emits one line of JSON with ok=true and exit 0' {
        $r = Invoke-Guarded { [ordered]@{ worker = 'x'; detail = 'fine' } }
        $r.ExitCode | Should -Be 0
        $r.Line | Should -Not -Match "`n"
        ($r.Line | ConvertFrom-Json).ok | Should -BeTrue
    }
    It 'turns an error with a hint into ok=false, error, hint and exit 1' {
        $r = Invoke-Guarded { New-AdapterError 'boom' 'do this' } -Worker 'w'
        $r.ExitCode | Should -Be 1
        $j = $r.Line | ConvertFrom-Json
        $j.ok | Should -BeFalse
        $j.error | Should -Be 'boom'
        $j.hint | Should -Be 'do this'
        $j.worker | Should -Be 'w'
    }
    It 'redacts secrets inside the result' {
        $r = Invoke-Guarded { [ordered]@{ detail = "remote https://$userinfo$ghp@github.com" } }
        $r.Line | Should -Not -Match 'a1a1a1'
    }
    It 'emits pure ASCII even for non-ASCII content' {
        $r = Invoke-Guarded { [ordered]@{ detail = "Tiếng Việt — ok" } }
        $r.Line | Should -Match '^[\x20-\x7e]+$'
        ($r.Line | ConvertFrom-Json).detail | Should -Be "Tiếng Việt — ok"
    }
    It 'respects an explicit ok=false from the body' {
        (Invoke-Guarded { [ordered]@{ ok = $false; error = 'e'; hint = 'h' } }).ExitCode | Should -Be 1
    }
}

Describe 'Get-LoopbackPorts' {
    It 'keeps only 127.0.0.1 listeners, sorted and unique' {
        Mock Get-NetTCPConnection {
            @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 61990 },
                [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5000 },
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 61989 },
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 61990 }
            )
        }
        Get-LoopbackPorts -ProcessId 42 | Should -Be @(61989, 61990)
    }
    It 'returns an empty array when nothing listens' {
        Mock Get-NetTCPConnection { }
        @(Get-LoopbackPorts -ProcessId 42).Count | Should -Be 0
    }
}

Describe 'Get-ConfigValue' {
    It 'reads dotted keys with defaults' {
        $cfg = @{ workers = @{ ag2 = @{ projectId = 'p'; empty = '' } } }
        Get-ConfigValue $cfg 'workers.ag2.projectId' | Should -Be 'p'
        Get-ConfigValue $cfg 'workers.ag2.empty' 'd' | Should -Be 'd'
        Get-ConfigValue $cfg 'workers.none.x' 7 | Should -Be 7
    }
}
