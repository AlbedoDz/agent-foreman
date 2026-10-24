BeforeAll {
    $script:scripts = Resolve-Path "$PSScriptRoot/../scripts"
    function Invoke-Script([string]$Name, [string[]]$ArgList) {
        $line = pwsh -NoProfile -File (Join-Path $scripts $Name) @ArgList -Repo (Get-Location).Path | Select-Object -Last 1
        $code = $LASTEXITCODE
        if (-not $line) { throw "$Name printed nothing (exit $code)" }
        [pscustomobject]@{ Json = ($line | ConvertFrom-Json); Code = $code }
    }
    function New-TestRepo([string]$Name) {
        $r = Join-Path $TestDrive $Name
        if (-not $r.StartsWith([string]$TestDrive)) { throw 'test repo must live under TestDrive' }
        New-Item -ItemType Directory -Force $r | Out-Null
        git -C $r init -q -b main
        git -C $r config user.email t@example.invalid; git -C $r config user.name t
        Set-Content (Join-Path $r 'README.md') 'hi'
        git -C $r add -A; git -C $r commit -q -m init
        $r
    }
    function Write-Handoff([string]$Wt, [string]$Sha, [string[]]$Files, [string]$Deviations = 'none') {
        New-Item -ItemType Directory -Force (Join-Path $Wt 'handoffs') | Out-Null
        $body = @('## HANDOFF T1', 'STATUS: DONE', "COMMIT: task/T1 $Sha", 'FILES CHANGED:') + ($Files | ForEach-Object { "- $_" }) +
            @("DEVIATIONS FROM PLAN: $Deviations", 'OPEN QUESTIONS / BLOCKERS: none')
        Set-Content (Join-Path $Wt 'handoffs/HANDOFF_T1.md') $body
        git -C $Wt add -A; git -C $Wt commit -q -m 'handoff'
    }
    $env:AG2O_HOME = Join-Path $TestDrive 'orch'
}
AfterAll { Remove-Item Env:AG2O_HOME -ErrorAction SilentlyContinue }

Describe 'task-new / verify-handoff / task-cleanup' {
    BeforeEach {
        # each repo gets its own parent folder, because worktrees are created next to it (../wt-<id>)
        $script:testRepo = New-TestRepo ([guid]::NewGuid().ToString('N').Substring(0, 6) + '/repo')
        Push-Location $testRepo
        $script:t = Invoke-Script 'task-new.ps1' @('-Id', 'T1')
        $script:taskWt = $t.Json.worktree
    }
    AfterEach { Pop-Location }

    It 'creates ../wt-<id> on task/<id>' {
        $t.Code | Should -Be 0
        $t.Json.branch | Should -Be 'task/T1'
        $taskWt | Should -Be ([IO.Path]::GetFullPath((Join-Path $testRepo '../wt-T1')))
        (git -C $taskWt branch --show-current) | Should -Be 'task/T1'
    }
    It 'refuses to create the same task twice and rejects bad ids' {
        (Invoke-Script 'task-new.ps1' @('-Id', 'T1')).Json.hint | Should -Match 'task-cleanup'
        (Invoke-Script 'task-new.ps1' @('-Id', 'a b')).Json.error | Should -Match 'Invalid'
    }
    It 'passes an honest HANDOFF' {
        New-Item -ItemType Directory (Join-Path $taskWt 'src') | Out-Null
        Set-Content (Join-Path $taskWt 'src/a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        $sha = (git -C $taskWt rev-parse --short HEAD)
        Write-Handoff $taskWt $sha @('src/a.txt', 'handoffs/HANDOFF_T1.md')
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Allowed', 'src/*')
        $v.Code | Should -Be 0
        $v.Json.ok | Should -BeTrue
        $v.Json.status | Should -Be 'DONE'
        @($v.Json.findings).Count | Should -Be 0
    }
    It 'detects a SHA that does not exist' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt 'deadbeef1' @('a.txt', 'handoffs/HANDOFF_T1.md')
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')
        $v.Code | Should -Be 1
        $v.Json.findings.code | Should -Contain 'sha-not-found'
    }
    It 'detects a SHA from another branch' {
        Set-Content (Join-Path $testRepo 'm.txt') 'm'; git -C $testRepo add -A; git -C $testRepo commit -q -m main-only
        $foreign = (git -C $testRepo rev-parse --short HEAD)
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt $foreign @('a.txt', 'handoffs/HANDOFF_T1.md')
        (Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')).Json.findings.code | Should -Contain 'sha-not-on-branch'
    }
    It 'catches out-of-scope files, unlisted files and a false "DEVIATIONS: none"' {
        New-Item -ItemType Directory (Join-Path $taskWt 'src') | Out-Null
        Set-Content (Join-Path $taskWt 'src/a.txt') 'a'; Set-Content (Join-Path $taskWt 'other.txt') 'x'
        git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('src/a.txt', 'src/ghost.txt', 'handoffs/HANDOFF_T1.md')
        $codes = (Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Allowed', 'src/*', '-Forbidden', 'README.md')).Json.findings.code
        $codes | Should -Contain 'out-of-scope'
        $codes | Should -Contain 'files-changed-not-listed'
        $codes | Should -Contain 'files-claimed-not-changed'
        $codes | Should -Contain 'deviations-none-but-scope-violated'
    }
    It 'flags uncommitted work and a HANDOFF that is not the last commit' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'b.txt', 'handoffs/HANDOFF_T1.md')
        Set-Content (Join-Path $taskWt 'b.txt') 'b'; git -C $taskWt add -A; git -C $taskWt commit -q -m late
        Set-Content (Join-Path $taskWt 'measure.py') 'never committed'
        $codes = (Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')).Json.findings.code
        $codes | Should -Contain 'handoff-not-in-last-commit'
        $codes | Should -Contain 'uncommitted-changes'
    }
    It 'verification contract: verified when the plan checks pass in the worktree' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'handoffs/HANDOFF_T1.md')
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Run', 'if (Test-Path a.txt) { exit 0 } else { exit 9 }')
        $v.Code | Should -Be 0
        $v.Json.verdict | Should -Be 'verified'
        $v.Json.checks[0].exitCode | Should -Be 0
        Test-Path $v.Json.evidence | Should -BeTrue
    }
    It 'verification contract: refuted by a failing check, and by an edited locked file' {
        Set-Content (Join-Path $taskWt 'README.md') 'tampered'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('README.md', 'handoffs/HANDOFF_T1.md')
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Locked', 'README.md', '-Run', 'Write-Output boom; exit 4')
        $v.Code | Should -Be 1
        $v.Json.verdict | Should -Be 'refuted'
        $v.Json.findings.code | Should -Contain 'locked-file-modified'
        $v.Json.findings.code | Should -Contain 'check-failed'
        $v.Json.checks[0].tail | Should -Contain 'boom'
    }
    It 'verification contract: runs in a temporary checkout when the worktree is gone' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'handoffs/HANDOFF_T1.md')
        git -C $testRepo worktree remove $taskWt
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Run', 'if (Test-Path a.txt) { exit 0 } else { exit 9 }')
        $v.Json.verdict | Should -Be 'verified'
        @(git -C $testRepo worktree list).Count | Should -Be 1
    }
    It 'checks run on the merge preview by default (base moved after branching), on the branch with -OnBranchOnly' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'handoffs/HANDOFF_T1.md')
        Set-Content (Join-Path $testRepo 'm.txt') 'merged meanwhile'; git -C $testRepo add m.txt; git -C $testRepo commit -q -m sibling
        $check = 'if ((Test-Path m.txt) -and (Test-Path a.txt)) { exit 0 } else { exit 5 }'
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Run', $check)
        $v.Json.verdict | Should -Be 'verified'
        $v.Json.checkedOn | Should -Match 'merge preview'
        $b = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Run', $check, '-OnBranchOnly')
        $b.Json.verdict | Should -Be 'refuted'
        @(git -C $testRepo worktree list).Count | Should -Be 2
    }
    It 'reports a merge conflict with the current HEAD' {
        Set-Content (Join-Path $taskWt 'README.md') 'branch version'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('README.md', 'handoffs/HANDOFF_T1.md')
        Set-Content (Join-Path $testRepo 'README.md') 'main version'; git -C $testRepo add README.md; git -C $testRepo commit -q -m main-edit
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md', '-Run', 'exit 0')
        $v.Json.findings.code | Should -Contain 'merge-conflict'
        $v.Json.verdict | Should -Be 'refuted'
    }
    It 'ignores tool caches (warn) in verify and cleanup, but not real leftovers' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'handoffs/HANDOFF_T1.md')
        New-Item -ItemType File -Force (Join-Path $taskWt 'pkg/__pycache__/m.cpython-312.pyc') | Out-Null
        $v = Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')
        $v.Json.ok | Should -BeTrue
        $v.Json.findings.code | Should -Contain 'cache-files'
        (Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1', '-Merge')).Json.ok | Should -BeTrue
    }
    It 'unverified when no checks are given' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        Write-Handoff $taskWt (git -C $taskWt rev-parse --short HEAD) @('a.txt', 'handoffs/HANDOFF_T1.md')
        (Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')).Json.verdict | Should -Be 'unverified'
    }
    It 'reports a missing HANDOFF as not finished' {
        (Invoke-Script 'verify-handoff.ps1' @('-Branch', 'task/T1', '-Handoff', 'handoffs/HANDOFF_T1.md')).Json.hint | Should -Match 'not finished'
    }
    It 'refuses to clean a dirty worktree, then merges and cleans up' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'
        $c = Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1', '-Merge')
        $c.Code | Should -Be 1
        Test-Path $taskWt | Should -BeTrue
        git -C $taskWt add -A; git -C $taskWt commit -q -m work
        $c = Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1', '-Merge')
        $c.Code | Should -Be 0
        $c.Json.mergeCommit | Should -Not -BeNullOrEmpty
        Test-Path $taskWt | Should -BeFalse
        Test-Path (Join-Path $testRepo 'a.txt') | Should -BeTrue
        (git -C $testRepo branch --list 'task/T1') | Should -BeNullOrEmpty
    }
    It 'merges and reports a leftover empty folder when another program holds the worktree open' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        # a process whose working directory is the worktree locks the folder on Windows (like a worker app does)
        $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -WorkingDirectory $taskWt -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 800
            $c = Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1', '-Merge')
            $c.Code | Should -Be 0
            $c.Json.mergeCommit | Should -Not -BeNullOrEmpty
            $c.Json.leftoverEmptyFolder | Should -Not -BeNullOrEmpty
            (git -C $testRepo worktree list --porcelain) -join ' ' | Should -Not -Match 'wt-T1'
            (git -C $testRepo branch --list 'task/T1') | Should -BeNullOrEmpty
        } finally { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'will not delete an unmerged branch without -Discard' {
        Set-Content (Join-Path $taskWt 'a.txt') 'a'; git -C $taskWt add -A; git -C $taskWt commit -q -m work
        (Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1')).Json.hint | Should -Match 'Discard'
        (Invoke-Script 'task-cleanup.ps1' @('-Id', 'T1', '-Discard')).Code | Should -Be 0
    }
}

Describe 'watch-handoff' {
    BeforeAll {
        . (Join-Path $scripts 'watch-handoff.ps1')
        $script:testRepo = New-TestRepo 'watch'
        git -C $testRepo branch task/W1
    }
    It 'times out with exit 3 when nothing arrives' {
        Push-Location $testRepo
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Script 'watch-handoff.ps1' @('-Branch', 'task/W1', '-Handoff', 'H.md', '-TimeoutMin', '0', '-PollSeconds', '1')
            $r.Code | Should -Be 3
            $r.Json.event | Should -Be 'timeout'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        } finally { Pop-Location }
    }
    It 'exits 0 as soon as the HANDOFF is committed on the branch' {
        git -C $testRepo checkout -q task/W1
        Set-Content (Join-Path $testRepo 'H.md') 'STATUS: DONE'; git -C $testRepo add -A; git -C $testRepo commit -q -m handoff
        git -C $testRepo checkout -q main
        Push-Location $testRepo
        try {
            $r = Invoke-Script 'watch-handoff.ps1' @('-Branch', 'task/W1', '-Handoff', 'H.md')
            $r.Code | Should -Be 0
            $r.Json.commit | Should -Match '^[0-9a-f]{40}$'
        } finally { Pop-Location }
    }
    It 'reports a stall when the worker has been silent longer than StallMin' {
        Mock Get-WorkerStatus { [pscustomobject]@{ ok = $true; state = 'idle'; lastActivity = (Get-Date).AddHours(-3).ToString('o') } }
        $clock = @{ t = Get-Date }
        $r = Watch-Handoff -Repo $testRepo -Branch 'task/none' -Handoff 'H.md' -Worker 'ag2' -SessionId 's' -TimeoutMin 600 -StallMin 45 -PollSeconds 60 `
            -SleepFn { param($s) $clock.t = $clock.t.AddSeconds($s) }.GetNewClosure() -ClockFn { $clock.t }.GetNewClosure()
        $r.Code | Should -Be 2
        $r.Result.event | Should -Be 'stall'
    }
    It 'reports a process worker that exited without a HANDOFF' {
        Mock Get-WorkerStatus { [pscustomobject]@{ ok = $true; state = 'idle'; lastActivity = (Get-Date).ToString('o') } }
        $clock = @{ t = Get-Date }
        $r = Watch-Handoff -Repo $testRepo -Branch 'task/none' -Handoff 'H.md' -Worker 'opencode' -SessionId 's' -TimeoutMin 600 -StallMin 45 -PollSeconds 60 `
            -SleepFn { param($s) $clock.t = $clock.t.AddSeconds($s) }.GetNewClosure() -ClockFn { $clock.t }.GetNewClosure()
        $r.Code | Should -Be 4
    }
}
