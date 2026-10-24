BeforeAll {
    $script:root = (Resolve-Path "$PSScriptRoot/..").Path
    $script:proj = Join-Path $TestDrive 'mcp-proj/repo'
    New-Item -ItemType Directory -Force $proj | Out-Null
    git -C $proj init -q -b main
    git -C $proj config user.email t@example.invalid; git -C $proj config user.name t
    New-Item -ItemType Directory -Force (Join-Path $proj 'tests') | Out-Null
    Set-Content (Join-Path $proj 'tests/locked.txt') 'locked'
    git -C $proj add -A; git -C $proj commit -q -m init
    pwsh -NoProfile -File (Join-Path $root 'scripts/install.ps1') -Project $proj -Workers 'ag2,opencode' -Lead 'opencode' -SkipCheck | Out-Null
    git -C $proj add .gitignore; git -C $proj commit -q -m ignore

    function Invoke-Mcp([object[]]$Requests) {
        <# Send JSON-RPC requests to a fresh server over stdio; return the replies keyed by id. #>
        $psi = [Diagnostics.ProcessStartInfo]::new('python')
        foreach ($a in '-I', (Join-Path $proj '.claude/orchestrator/bin/mcp/agent_foreman_mcp.py')) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $proj
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [Diagnostics.Process]::Start($psi)
        foreach ($r in $Requests) { $p.StandardInput.WriteLine(($r | ConvertTo-Json -Compress -Depth 10)) }
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(600000)) { $p.Kill($true) }
        $byId = @{}
        foreach ($line in ($out -split "`r?`n" | Where-Object { $_ })) { $m = $line | ConvertFrom-Json; $byId[[string]$m.id] = $m }
        $byId
    }
    function Get-ToolJson($Reply) { $Reply.result.content[0].text | ConvertFrom-Json }
    $script:n = 0
    function New-Call([string]$Tool, [hashtable]$ToolArgs) {
        $script:n++
        @{ jsonrpc = '2.0'; id = $script:n; method = 'tools/call'; params = @{ name = $Tool; arguments = $ToolArgs } }
    }
}

Describe 'agent-foreman MCP server (any harness as lead)' {
    It 'answers initialize and lists the control tools' {
        $r = Invoke-Mcp @(
            @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 't'; version = '1' } } },
            @{ jsonrpc = '2.0'; method = 'notifications/initialized' },
            @{ jsonrpc = '2.0'; id = 2; method = 'tools/list' },
            @{ jsonrpc = '2.0'; id = 3; method = 'nope' })
        $r['1'].result.serverInfo.name | Should -Be 'agent-foreman'
        $r['1'].result.protocolVersion | Should -Be '2025-06-18'
        $names = $r['2'].result.tools.name
        foreach ($t in 'workers_list', 'worker_check', 'worker_capabilities', 'task_new', 'dispatch', 'task_status', 'handoff_check', 'task_message', 'task_cancel', 'verify_handoff', 'task_cleanup') {
            $names | Should -Contain $t
        }
        $r['3'].error.code | Should -Be -32601
        $r.Count | Should -Be 3
    }

    It 'drives a whole task through the real scripts: new, handoff check, verify (lists), cleanup' {
        $r = Invoke-Mcp @(
            (New-Call 'workers_list' @{}),
            (New-Call 'task_new' @{ task_id = 'M1' }),
            (New-Call 'handoff_check' @{ task_id = 'M1'; handoff = 'H_M1.md' }))
        (Get-ToolJson $r['1']).workers.name | Should -Contain 'ag2'
        $t = Get-ToolJson $r['2']
        $t.ok | Should -BeTrue
        (Get-ToolJson $r['3']).committed | Should -BeFalse

        # the "worker" does its job in the worktree
        $wt = $t.worktree
        New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
        Set-Content (Join-Path $wt 'src/a.txt') 'a'; git -C $wt add -A; git -C $wt commit -q -m work
        $sha = git -C $wt rev-parse --short HEAD
        Set-Content (Join-Path $wt 'H_M1.md') @('STATUS: DONE', "COMMIT: task/M1 $sha", 'FILES CHANGED:', '- src/a.txt', '- H_M1.md', 'DEVIATIONS FROM PLAN: none')
        git -C $wt add -A; git -C $wt commit -q -m handoff

        $r = Invoke-Mcp @(
            (New-Call 'handoff_check' @{ task_id = 'M1'; handoff = 'H_M1.md' }),
            (New-Call 'verify_handoff' @{ task_id = 'M1'; handoff = 'H_M1.md'; allowed = @('src/*', 'docs/*'); locked = @('tests/*', 'README.md')
                run = @('if (Test-Path src/a.txt) { exit 0 } else { exit 7 }', 'Write-Output "second, check"; exit 0') }),
            (New-Call 'task_cleanup' @{ task_id = 'M1'; mode = 'merge' }))
        (Get-ToolJson $r['4']).committed | Should -BeTrue
        $v = Get-ToolJson $r['5']
        $v.verdict | Should -Be 'verified'
        @($v.checks).Count | Should -Be 2
        $v.checks[1].tail | Should -Contain 'second, check'
        $r['5'].result.isError | Should -BeFalse
        (Get-ToolJson $r['6']).mergeCommit | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $proj 'src/a.txt') | Should -BeTrue
    }

    It 'reports tool errors as isError with a hint, without crashing' {
        $r = Invoke-Mcp @((New-Call 'worker_check' @{ worker = 'ghost' }), (New-Call 'task_new' @{ task_id = 'bad id' }), (New-Call 'workers_list' @{}))
        $r['7'].result.isError | Should -BeTrue
        (Get-ToolJson $r['7']).error | Should -Match 'unknown worker'
        $r['8'].result.isError | Should -BeTrue
        (Get-ToolJson $r['9']).ok | Should -BeTrue
    }
}

Describe 'install.ps1 -Lead' {
    It 'installs the lead skill for OpenCode/agy/AG2 and registers MCP in opencode.json, idempotently' {
        Test-Path (Join-Path $proj '.agents/skills/agent-foreman-lead/SKILL.md') | Should -BeTrue
        Test-Path (Join-Path $proj '.agents/skills/agent-foreman-lead/reference/review-checklist.md') | Should -BeTrue
        $oc = Get-Content -Raw (Join-Path $proj 'opencode.json') | ConvertFrom-Json
        $oc.mcp.'agent-foreman'.type | Should -Be 'local'
        $oc.mcp.'agent-foreman'.command[1] | Should -Be '.claude/orchestrator/bin/mcp/agent_foreman_mcp.py'
        $again = pwsh -NoProfile -File (Join-Path $root 'scripts/install.ps1') -Project $proj -Workers 'ag2,opencode' -Lead 'opencode' -SkipCheck | Select-Object -Last 1 | ConvertFrom-Json
        @($again.actions).Count | Should -Be 0
    }
    It 'keeps other opencode.json keys, prints the global snippet for agy, refuses unknown leads' {
        $p2 = Join-Path $TestDrive 'lead2'; New-Item -ItemType Directory -Force $p2 | Out-Null; git -C $p2 init -q
        '{ "model": "x/y", "mcp": { "other": { "type": "local", "command": ["a"] } } }' | Set-Content (Join-Path $p2 'opencode.json')
        $r = pwsh -NoProfile -File (Join-Path $root 'scripts/install.ps1') -Project $p2 -Lead 'opencode,agy' -SkipCheck | Select-Object -Last 1 | ConvertFrom-Json
        $oc = Get-Content -Raw (Join-Path $p2 'opencode.json') | ConvertFrom-Json
        $oc.model | Should -Be 'x/y'
        $oc.mcp.other.command | Should -Be @('a')
        $oc.mcp.'agent-foreman'.enabled | Should -BeTrue
        ($r.todo -join ' ') | Should -Match 'mcp_config.json'
        (pwsh -NoProfile -File (Join-Path $root 'scripts/install.ps1') -Project $p2 -Lead 'cursor' -SkipCheck | Select-Object -Last 1 | ConvertFrom-Json).error | Should -Match 'Unknown lead'
    }
}
