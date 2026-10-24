# Run one task end to end: [task-new] -> dispatch -> watch -> verify -> automatic fix rounds -> verdict.
# It NEVER merges: the builder is not the verifier, and the lead decides (task-cleanup -Merge).
# Long-running: start it in the background (Claude Code run_in_background, or the MCP tool task_run).
#
#   task-run.ps1 -Worker ag2 -TaskId T1 -PromptFile .claude\orchestrator\T1.prompt.md -Handoff docs/handoffs/HANDOFF_T1.md
#                [-Model m] [-Agent a] [-Prefix "/skill"] [-Title t]
#                [-Allowed 'src/*'] [-Forbidden 'x/*'] [-Locked 'tests/*'] [-Run "cmd1`ncmd2"] [-RunFile checks.txt]
#                [-FixRounds 2] [-TimeoutMin 120] [-StallMin 45] [-PollSeconds 60] [-SessionId <id>] [-Repo .]
#
# -SessionId: the task was already dispatched (e.g. by hand); skip the dispatch and start watching.
# Each automatic fix message lists the verifier's findings and the failing check output. The worker must commit
# the fix and a new HANDOFF as the last commit. When the rounds are used up, the verdict stays "refuted" and the lead
# takes over (fix it yourself or reroute).
# Output: one JSON line {ok, verdict: verified|refuted|no-handoff, rounds, sessionId, history[], evidence}.
# Exit 0 only when verified. The same JSON is also written to logs/run-<TaskId>.json (read it while it runs).
param(
    [string]$Worker = '',
    [string]$TaskId = '',
    [string]$PromptFile = '',
    [string]$Workspace = '',
    [string]$Handoff = '',
    [string]$Title = '',
    [string]$Model = '',
    [string]$Agent = '',
    [string]$Prefix = '',
    [string[]]$Allowed = @(),
    [string[]]$Forbidden = @(),
    [string[]]$Locked = @(),
    [string[]]$Run = @(),
    [string]$RunFile = '',
    [int]$FixRounds = -1,
    [int]$TimeoutMin = 120,
    [int]$StallMin = -1,
    [int]$PollSeconds = 60,
    [string]$SessionId = '',
    [string]$Repo = '.'
)
. "$PSScriptRoot/lib/Common.ps1"

function Invoke-JsonScript {
    <# Run one of our scripts as a child process; return @{ Json; Code }. Mocked in tests. #>
    param([string]$Script, [string[]]$Arguments)
    $line = pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $Script) @Arguments 2>$null | Select-Object -Last 1
    $code = $LASTEXITCODE
    $json = try { $line | ConvertFrom-Json -AsHashtable } catch { @{ ok = $false; error = "no JSON from $Script"; hint = [string]$line } }
    @{ Json = $json; Code = $code }
}

function Get-AdapterArgs {
    param($Config, [string]$Worker)
    $adapter = Get-ConfigValue $Config "workers.$Worker.adapter" $Worker
    $extra = if ($adapter -eq 'generic-cli') { @('-Worker', $Worker) } else { @() }
    @{ Script = "adapters/$adapter.ps1"; Extra = $extra }
}

function New-FixMessage {
    <# A specific, mechanical fix request built from the verifier's output. #>
    param([string]$TaskId, $Verify, [int]$Round, [int]$Max, [string]$Handoff)
    $lines = @("Tech Lead review of task $TaskId (automatic round $Round of $Max): REFUTED. Fix exactly these defects:")
    foreach ($f in @($Verify.findings)) { if ($f.severity -eq 'error') { $lines += "- [$($f.code)] $($f.detail)" } }
    foreach ($c in @($Verify.checks)) {
        if ($c.timedOut -or $c.exitCode -ne 0) {
            $lines += "- check '$($c.command)' $(if ($c.timedOut) { 'timed out' } else { "exited $($c.exitCode)" }). Last output:"
            $lines += @($c.tail | Select-Object -Last 8 | ForEach-Object { "    $_" })
        }
    }
    $lines += ''
    $lines += 'Keep every rule of the original prompt. Do not touch locked or forbidden files. Run the checks yourself.'
    $lines += "Commit the fix, then update $Handoff (DEVIATIONS must describe what changed) in a NEW last commit. Then stop."
    $lines -join "`n"
}

function Invoke-TaskRun {
    param([hashtable]$P)
    foreach ($k in 'Worker', 'TaskId', 'Handoff') { if (-not $P[$k]) { New-AdapterError "-$k is required." 'See the usage at the top of task-run.ps1.' } }
    if (-not $P.SessionId -and -not $P.PromptFile) { New-AdapterError '-PromptFile is required unless -SessionId is given.' 'Write the prompt first.' }
    $cfg = Read-OrchestratorConfig
    $fixMax = if ($P.FixRounds -ge 0) { $P.FixRounds } else { [int](Get-ConfigValue $cfg 'fixRoundsMax' 2) }
    $stall = if ($P.StallMin -ge 0) { $P.StallMin } else { [int](Get-ConfigValue $cfg 'stallMin' 45) }
    $ad = Get-AdapterArgs $cfg $P.Worker
    $branch = "task/$($P.TaskId)"
    $logDir = Get-LogDir
    $status = Join-Path $logDir "run-$($P.TaskId).json"
    $history = [System.Collections.Generic.List[object]]::new()
    $state = [ordered]@{ ok = $false; verdict = 'running'; taskId = $P.TaskId; worker = $P.Worker; sessionId = $P.SessionId; rounds = 0; history = $history }
    $save = { $state['updated'] = (Get-Date).ToString('o'); ConvertTo-ResultLine $state | Set-Content -Encoding utf8 -LiteralPath $status }

    # worktree
    $ws = if ($P.Workspace) { $P.Workspace } else { $null }
    if (-not $ws) {
        git -C $P.Repo rev-parse -q --verify "refs/heads/$branch" *> $null
        if ($LASTEXITCODE -ne 0) {
            $t = Invoke-JsonScript 'task-new.ps1' @('-Id', $P.TaskId, '-Repo', $P.Repo)
            if (-not $t.Json.ok) { New-AdapterError "task-new failed: $($t.Json.error)" $t.Json.hint }
            $ws = $t.Json.worktree
            $history.Add([ordered]@{ step = 'task-new'; worktree = $ws })
        } else { $ws = "../wt-$($P.TaskId)" }
    }

    # dispatch
    if (-not $P.SessionId) {
        $a = @($ad.Extra) + @('-Dispatch', '-TaskId', $P.TaskId, '-PromptFile', $P.PromptFile, '-Workspace', $ws)
        foreach ($k in 'Title', 'Model', 'Agent', 'Prefix') { if ($P[$k]) { $a += @("-$k", $P[$k]) } }
        $d = Invoke-JsonScript $ad.Script $a
        if (-not $d.Json.ok) { New-AdapterError "dispatch failed: $($d.Json.error)" $d.Json.hint }
        $state.sessionId = $d.Json.sessionId
        $history.Add([ordered]@{ step = 'dispatch'; sessionId = $d.Json.sessionId })
    }
    & $save

    $verifyArgs = @('-Repo', $P.Repo, '-Branch', $branch, '-Handoff', $P.Handoff)
    foreach ($k in 'Allowed', 'Forbidden', 'Locked') { if ($P[$k]) { $verifyArgs += @("-$k", ((@($P[$k]) | ForEach-Object { $_ -split ',' }) -join ',')) } }
    if ($P.Run) { $verifyArgs += @('-Run', ((@($P.Run) | ForEach-Object { $_ -split "`r?`n" }) -join "`n")) }
    if ($P.RunFile) { $verifyArgs += @('-RunFile', $P.RunFile) }

    $since = ''
    for ($round = 0; $round -le $fixMax; $round++) {
        $state.rounds = $round
        $w = Invoke-JsonScript 'watch-handoff.ps1' @('-Repo', $P.Repo, '-Branch', $branch, '-Handoff', $P.Handoff, '-Worker', $P.Worker,
            '-SessionId', [string]$state.sessionId, '-TimeoutMin', [string]$P.TimeoutMin, '-StallMin', [string]$stall,
            '-PollSeconds', [string]$P.PollSeconds, '-Since', $since)
        $history.Add([ordered]@{ step = 'watch'; round = $round; event = $w.Json.event; exit = $w.Code })
        if ($w.Code -ne 0) {
            $state.verdict = 'no-handoff'; $state['error'] = $w.Json.error; $state['hint'] = $w.Json.hint
            & $save; return $state
        }
        $v = Invoke-JsonScript 'verify-handoff.ps1' $verifyArgs
        $history.Add([ordered]@{ step = 'verify'; round = $round; verdict = $v.Json.verdict; findings = @($v.Json.findings | ForEach-Object { $_.code }) })
        $state['evidence'] = $v.Json.evidence
        if ($v.Json.verdict -eq 'verified') {
            $state.ok = $true; $state.verdict = 'verified'
            $state['next'] = "Read the diff, then merge: task-cleanup.ps1 -Id $($P.TaskId) -Merge"
            & $save; return $state
        }
        if ($round -eq $fixMax) { break }
        # automatic fix round
        $since = (git -C $P.Repo rev-parse $branch).Trim()
        $msgFile = Join-Path (Get-OrchestratorDir) "$($P.TaskId)-autofix$($round + 1).prompt.md"
        New-FixMessage $P.TaskId $v.Json ($round + 1) $fixMax $P.Handoff | Set-Content -Encoding utf8 -LiteralPath $msgFile
        $m = Invoke-JsonScript $ad.Script (@($ad.Extra) + @('-Message', '-SessionId', [string]$state.sessionId, '-MessageFile', $msgFile))
        $history.Add([ordered]@{ step = 'fix-message'; round = $round + 1; ok = $m.Json.ok; file = $msgFile })
        if (-not $m.Json.ok) { $state.verdict = 'refuted'; $state['error'] = "fix message failed: $($m.Json.error)"; $state['hint'] = $m.Json.hint; & $save; return $state }
        & $save
    }
    $state.verdict = 'refuted'
    $state['error'] = "Still refuted after $fixMax automatic fix round(s)."
    $state['hint'] = 'Take over: read the evidence, fix it yourself in the worktree, or reroute to another worker.'
    & $save
    $state
}

if ($MyInvocation.InvocationName -ne '.') {
    $p = @{}; foreach ($k in $PSBoundParameters.Keys) { $p[$k] = $PSBoundParameters[$k] }
    foreach ($k in 'Workspace', 'Title', 'Model', 'Agent', 'Prefix', 'RunFile', 'SessionId', 'PromptFile') { if (-not $p.ContainsKey($k)) { $p[$k] = '' } }
    foreach ($k in 'Allowed', 'Forbidden', 'Locked', 'Run') { if (-not $p.ContainsKey($k)) { $p[$k] = @() } }
    if (-not $p.ContainsKey('Repo')) { $p['Repo'] = '.' }
    if (-not $p.ContainsKey('FixRounds')) { $p['FixRounds'] = -1 }
    if (-not $p.ContainsKey('StallMin')) { $p['StallMin'] = -1 }
    if (-not $p.ContainsKey('TimeoutMin')) { $p['TimeoutMin'] = 120 }
    if (-not $p.ContainsKey('PollSeconds')) { $p['PollSeconds'] = 60 }
    Complete-Script -Body { Invoke-TaskRun -P $p }
}
