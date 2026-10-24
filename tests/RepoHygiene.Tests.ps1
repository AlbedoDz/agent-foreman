BeforeAll { $script:root = (Resolve-Path "$PSScriptRoot/..").Path }

Describe 'repository hygiene' {
    It 'passes the secret scan' {
        $out = pwsh -NoProfile -File (Join-Path $root 'scripts/secret-scan.ps1') -Repo $root
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }
    It 'catches a planted token (the scanner works)' {
        $d = Join-Path $TestDrive 'leak'; New-Item -ItemType Directory $d | Out-Null
        git -C $d init -q
        Set-Content (Join-Path $d 'x.txt') ('token=ghp_' + ('Z9' * 18))
        pwsh -NoProfile -File (Join-Path $root 'scripts/secret-scan.ps1') -Repo $d | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
    It 'has matching plugin and marketplace names' {
        $p = Get-Content -Raw (Join-Path $root '.claude-plugin/plugin.json') | ConvertFrom-Json
        $m = Get-Content -Raw (Join-Path $root '.claude-plugin/marketplace.json') | ConvertFrom-Json
        $m.plugins[0].name | Should -Be $p.name
        $m.plugins[0].source | Should -Be '.'
    }
    It 'every skill has frontmatter with a description' {
        foreach ($f in Get-ChildItem -Recurse (Join-Path $root 'skills') -Filter SKILL.md) {
            $text = Get-Content -Raw $f.FullName
            $text | Should -Match '^---\r?\n(.|\r|\n)*?description: .+(.|\r|\n)*?\r?\n---' -Because $f.FullName
            (Get-Content $f.FullName).Count | Should -BeLessThan 500
        }
    }
    It 'skills only call installed scripts with the allow-rule form' {
        foreach ($f in Get-ChildItem -Recurse (Join-Path $root 'skills') -Filter *.md) {
            foreach ($m in [regex]::Matches((Get-Content -Raw $f.FullName), 'pwsh -NoProfile -File (\S+)')) {
                $m.Groups[1].Value | Should -Match '^(\.claude\\orchestrator\\bin\\|"\$\{CLAUDE_PLUGIN_ROOT\}/scripts/install\.ps1")' -Because $f.Name
            }
        }
    }
    It 'every adapter guards its entry point so tests can dot-source it' {
        foreach ($f in Get-ChildItem (Join-Path $root 'scripts') -Recurse -Filter *.ps1 | Where-Object { $_.Name -notin 'Common.ps1', 'secret-scan.ps1' }) {
            Get-Content -Raw $f.FullName | Should -Match "InvocationName -ne '\.'" -Because $f.Name
        }
    }
}
