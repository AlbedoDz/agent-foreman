# Wait until a HANDOFF file is committed on a task branch, or report a stall / timeout / worker exit.
# Meant to run in the background (Claude Code: run_in_background) so its exit wakes the Tech Lead.
#
#   watch-handoff.ps1 -Branch task/T1 -Handoff docs/handoffs/HANDOFF_T1.md [-Worker ag2 -SessionId <id>]
#                     [-Repo .] [-TimeoutMin 180] [-StallMin 45] [-PollSeconds 60] [-Since <sha>]
#
# -Since: only a HANDOFF committed AFTER that commit counts (used after a fix round, when an old HANDOFF exists).
#
# Exit codes: 0 handoff committed | 2 stall (no worker activity for StallMin) | 3 timeout | 4 worker exited without
# a handoff | 1 usage error. Prints one JSON line.
param(
    [string]$Branch = '',
    [string]$Handoff = '',
    [string]$Repo = '.',
    [string]$Worker = '',
    [string]$SessionId = '',
    [int]$TimeoutMin = 180,
    [int]$StallMin = 45,
    [int]$PollSeconds = 60,
    [string]$Since = ''
)
. "$PSScriptRoot/lib/Common.ps1"

function Test-HandoffCommitted {
    param([string]$Repo, [string]$Branch, [string]$Handoff, [string]$Since = '')
    git -C $Repo rev-parse -q --verify "refs/heads/$Branch" *> $null
    if ($LASTEXITCODE -ne 0) { return $null }
    $range = if ($Since) { "$Since..$Branch" } else { $Branch }
    $log = git -C $Repo log $range --format=%H -- $Handoff 2>$null
    if ($log) { return @($log)[0] }
    $null
}

function Get-WorkerStatus {
    <# Ask the worker's adapter for -Status. Returns the parsed JSON or $null. #>
    param([string]$Worker, [string]$SessionId)
    $cfg = Read-OrchestratorConfig
    $adapter = Get-ConfigValue $cfg "workers.$Worker.adapter" $Worker
    $script = Join-Path $PSScriptRoot "adapters/$adapter.ps1"
    if (-not (Test-Path $script)) { return $null }
    $extra = if ($adapter -eq 'generic-cli') { @('-Worker', $Worker) } else { @() }
    $line = pwsh -NoProfile -File $script -Status -SessionId $SessionId @extra 2>$null | Select-Object -Last 1
    try { $line | ConvertFrom-Json } catch { $null }
}

function Watch-Handoff {
    param([string]$Repo, [string]$Branch, [string]$Handoff, [string]$Worker, [string]$SessionId,
        [int]$TimeoutMin, [int]$StallMin, [int]$PollSeconds, [scriptblock]$SleepFn = { param($s) Start-Sleep -Seconds $s },
        [scriptblock]$ClockFn = { Get-Date }, [string]$Since = '')
    $ErrorActionPreference = 'Stop'
    $start = & $ClockFn
    while ($true) {
        $now = & $ClockFn
        $el = [int]($now - $start).TotalSeconds
        $sha = Test-HandoffCommitted $Repo $Branch $Handoff $Since
        if ($sha) {
            return @{ Code = 0; Result = [ordered]@{ ok = $true; event = 'handoff'; branch = $Branch; commit = $sha; elapsedSec = $el } }
        }
        if ($Worker -and $SessionId) {
            $st = Get-WorkerStatus $Worker $SessionId
            if ($st -and $st.ok) {
                if ($st.state -eq 'idle' -and $Worker -ne 'ag2' -and $el -gt $PollSeconds) {
                    return @{ Code = 4; Result = [ordered]@{ ok = $false; event = 'worker-exited'; branch = $Branch; elapsedSec = $el
                        error = 'The worker process exited without committing the HANDOFF.'; hint = 'Read the worker log, then send a fix prompt or redo the task.' } }
                }
                $last = if ($st.lastActivity) { [datetime]$st.lastActivity } else { $start }
                if ($el -gt $StallMin * 60 -and ($now - $last).TotalMinutes -gt $StallMin) {
                    return @{ Code = 2; Result = [ordered]@{ ok = $false; event = 'stall'; branch = $Branch; elapsedSec = $el; lastActivity = $st.lastActivity
                        error = "No worker activity for $StallMin min."; hint = 'Read the transcript tail (adapter -Status -Tail 30) and send a nudge (-Message).' } }
                }
            }
        }
        if ($el -gt $TimeoutMin * 60) {
            return @{ Code = 3; Result = [ordered]@{ ok = $false; event = 'timeout'; branch = $Branch; elapsedSec = $el
                error = "No HANDOFF after $TimeoutMin min."; hint = 'Check the worker status; nudge, redo, or take the task over.' } }
        }
        & $SleepFn $PollSeconds
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Branch -or -not $Handoff) {
        [Console]::Out.WriteLine((ConvertTo-ResultLine ([ordered]@{ ok = $false; error = '-Branch and -Handoff are required.'; hint = 'e.g. -Branch task/T1 -Handoff docs/handoffs/HANDOFF_T1.md' })))
        exit 1
    }
    $r = Watch-Handoff -Repo $Repo -Branch $Branch -Handoff $Handoff -Worker $Worker -SessionId $SessionId `
        -TimeoutMin $TimeoutMin -StallMin $StallMin -PollSeconds $PollSeconds -Since $Since
    [Console]::Out.WriteLine((ConvertTo-ResultLine $r.Result))
    exit $r.Code
}
