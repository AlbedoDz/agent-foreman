BeforeAll {
    $script:install = Resolve-Path "$PSScriptRoot/../scripts/install.ps1"
    function Invoke-Install([string]$Proj, [string[]]$Extra = @()) {
        $line = pwsh -NoProfile -File $install -Project $Proj -SkipCheck @Extra | Select-Object -Last 1
        [pscustomobject]@{ Json = ($line | ConvertFrom-Json); Code = $LASTEXITCODE }
    }
    function Get-TreeHash([string]$Dir) {
        Get-ChildItem -Recurse -File -Force $Dir | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Dir.Length))=$((Get-FileHash $_.FullName).Hash)" }
    }
}

Describe 'install.ps1' {
    BeforeEach {
        $script:proj = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory $proj | Out-Null
        git -C $proj init -q -b main
        New-Item -ItemType Directory (Join-Path $proj '.claude') | Out-Null
        # pre-existing user settings that must survive the merge
        '{ "permissions": { "allow": ["Bash(git status:*)"], "deny": ["Bash(rm:*)"] }, "env": { "X": "1" } }' |
            Set-Content (Join-Path $proj '.claude/settings.local.json')
        "node_modules/" | Set-Content (Join-Path $proj '.gitignore')
    }

    It 'installs scripts, templates, config, allow rules and gitignore entries' {
        $r = Invoke-Install $proj
        $r.Code | Should -Be 0
        foreach ($f in 'bin/adapters/ag2.ps1', 'bin/adapters/opencode.ps1', 'bin/lib/Common.ps1', 'bin/task-new.ps1', 'bin/verify-handoff.ps1',
                       'templates/TASK.prompt.template.md', 'orchestrator.config.json', 'PLAN.md') {
            Test-Path (Join-Path $proj ".claude/orchestrator/$f") | Should -BeTrue -Because $f
        }
        $s = Get-Content -Raw (Join-Path $proj '.claude/settings.local.json') | ConvertFrom-Json
        $s.permissions.allow | Should -Contain 'Bash(git status:*)'
        $s.permissions.deny | Should -Contain 'Bash(rm:*)'
        $s.env.X | Should -Be '1'
        $s.permissions.allow | Should -Contain 'PowerShell(pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1:*)'
        $s.permissions.allow | Should -Contain 'PowerShell(pwsh -NoProfile -File .claude\orchestrator\bin\verify-handoff.ps1:*)'
        ($s.permissions.allow | Where-Object { $_ -match '\*\)$' -and $_ -notmatch '\.ps1:\*\)$' -and $_ -notlike 'Bash(git status*' }) | Should -BeNullOrEmpty
        $gi = Get-Content (Join-Path $proj '.gitignore')
        $gi | Should -Contain 'node_modules/'
        $gi | Should -Contain '.claude/orchestrator/*.prompt.md'
        $gi | Should -Contain '.claude/orchestrator/logs/'
        $r.Json.todo -join ' ' | Should -Match 'FindProjectId'
    }

    It 'is idempotent: a second run changes nothing' {
        Invoke-Install $proj | Out-Null
        $before = Get-TreeHash $proj
        $r = Invoke-Install $proj
        $r.Code | Should -Be 0
        @($r.Json.actions).Count | Should -Be 0
        Get-TreeHash $proj | Should -Be $before
        @((Get-Content -Raw (Join-Path $proj '.claude/settings.local.json') | ConvertFrom-Json).permissions.allow |
            Where-Object { $_ -like '*ag2.ps1*' }).Count | Should -Be 1
    }

    It 'never overwrites an edited config or PLAN.md, but refreshes scripts' {
        Invoke-Install $proj | Out-Null
        Set-Content (Join-Path $proj '.claude/orchestrator/PLAN.md') 'my plan'
        $cfg = Join-Path $proj '.claude/orchestrator/orchestrator.config.json'
        (Get-Content -Raw $cfg) -replace '"projectId": ""', '"projectId": "abc"' | Set-Content $cfg
        Set-Content (Join-Path $proj '.claude/orchestrator/bin/task-new.ps1') 'stale'
        $r = Invoke-Install $proj
        Get-Content (Join-Path $proj '.claude/orchestrator/PLAN.md') | Should -Be 'my plan'
        Get-Content -Raw $cfg | Should -Match '"projectId": "abc"'
        Get-Content -Raw (Join-Path $proj '.claude/orchestrator/bin/task-new.ps1') | Should -Not -Be "stale`r`n"
        $r.Json.actions -join ' ' | Should -Match 'updated .*task-new.ps1'
        $r.Json.todo -join ' ' | Should -Not -Match 'FindProjectId'
    }

    It '-WhatIf lists actions but writes nothing' {
        $before = Get-TreeHash $proj
        $r = Invoke-Install $proj @('-WhatIf')
        $r.Code | Should -Be 0
        $r.Json.dryRun | Should -BeTrue
        @($r.Json.actions).Count | Should -BeGreaterThan 5
        Get-TreeHash $proj | Should -Be $before
    }

    It 'honours -Workers and refuses unknown workers' {
        $r = Invoke-Install $proj @('-Workers', 'opencode')
        $s = Get-Content -Raw (Join-Path $proj '.claude/settings.local.json') | ConvertFrom-Json
        ($s.permissions.allow -join ' ') | Should -Not -Match 'ag2\.ps1'
        (Get-Content -Raw (Join-Path $proj '.claude/orchestrator/orchestrator.config.json') | ConvertFrom-Json).workers.ag2.enabled | Should -BeFalse
        (Invoke-Install $proj @('-Workers', 'nope')).Json.error | Should -Match 'Unknown worker'
    }

    It 'warns when a git remote embeds credentials' {
        git -C $proj remote add origin ('https://someone' + ':' + 'sekret123@example.com/o/r.git')
        $r = Invoke-Install $proj
        ($r.Json.warnings -join ' ') | Should -Match 'credentials'
        $r.Json | ConvertTo-Json -Depth 5 | Should -Not -Match 'sekret123'
    }

    It 'refuses to touch an invalid settings file' {
        'not json {' | Set-Content (Join-Path $proj '.claude/settings.local.json')
        $r = Invoke-Install $proj
        $r.Code | Should -Be 1
        Get-Content (Join-Path $proj '.claude/settings.local.json') | Should -Be 'not json {'
    }
}
