# Install ag2-orchestrator into a project. Idempotent; supports -WhatIf (changes nothing, lists what it would do).
#
#   pwsh -NoProfile -File <plugin>/scripts/install.ps1 -Project <path> [-Workers ag2,opencode] [-SkipCheck] [-WhatIf]
#
# What it does in <project>:
#   .claude/orchestrator/bin/            scripts (lib, adapters, task-new/cleanup, watch-handoff, verify-handoff)  [refreshed]
#   .claude/orchestrator/templates/      TASK prompt, HANDOFF, PLAN, AGENTS, CLAUDE snippet                        [refreshed]
#   .claude/orchestrator/orchestrator.config.json, PLAN.md                                                         [only if missing]
#   .claude/settings.local.json          minimal PowerShell allow rules, merged (existing content kept)
#   .gitignore                           logs, *.prompt.md, local config, settings.local.json
# Then warns about credentials in `git remote -v`, runs -Check for each worker, and prints the remaining TODOs.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Project = '',
    [string[]]$Workers = @('ag2', 'opencode'),
    [switch]$SkipCheck
)
. "$PSScriptRoot/lib/Common.ps1"

$script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:BinScripts = @('task-new.ps1', 'task-cleanup.ps1', 'watch-handoff.ps1', 'verify-handoff.ps1')
$script:IgnoreLines = @('.claude/orchestrator/logs/', '.claude/orchestrator/*.prompt.md', '.claude/orchestrator/orchestrator.config.json', '.claude/settings.local.json')

function Get-AllowRules {
    <# One exact-path rule per script: no broad wildcard. Matches how the skills invoke them. #>
    param([string[]]$Workers, $Config)
    $rules = @()
    foreach ($w in $Workers) {
        $adapter = Get-ConfigValue $Config "workers.$w.adapter" $w
        $rules += "PowerShell(pwsh -NoProfile -File .claude\orchestrator\bin\adapters\${adapter}.ps1:*)"
    }
    foreach ($s in $script:BinScripts) { $rules += "PowerShell(pwsh -NoProfile -File .claude\orchestrator\bin\${s}:*)" }
    @($rules | Select-Object -Unique)
}

function Sync-File {
    <# Copy if missing or different (or only if missing with -OnlyIfMissing). Returns the action taken. #>
    param([string]$Source, [string]$Dest, [switch]$OnlyIfMissing, [bool]$DryRun)
    $exists = Test-Path -LiteralPath $Dest
    if ($exists -and $OnlyIfMissing) { return "kept $Dest" }
    if ($exists -and (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Dest).Hash) { return $null }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $Dest) -WhatIf:$false | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Dest -Force -WhatIf:$false
    }
    $(if ($exists) { "updated $Dest" } else { "created $Dest" })
}

function Merge-AllowRules {
    param([string]$SettingsPath, [string[]]$Rules, [bool]$DryRun)
    $s = if (Test-Path -LiteralPath $SettingsPath) {
        $raw = Get-Content -Raw -LiteralPath $SettingsPath
        if ($raw.Trim()) {
            try { $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
            catch { New-AdapterError "$SettingsPath is not valid JSON; refusing to touch it." 'Fix or remove it, then re-run install.' }
        } else { [ordered]@{} }
    } else { [ordered]@{} }
    if (-not $s.Contains('permissions')) { $s['permissions'] = [ordered]@{} }
    if (-not $s['permissions'].Contains('allow')) { $s['permissions']['allow'] = @() }
    $allow = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $s['permissions']['allow']) { $allow.Add([string]$r) }
    $added = @($Rules | Where-Object { $_ -notin $allow })
    if (-not $added) { return @() }
    foreach ($r in $added) { $allow.Add($r) }
    $s['permissions']['allow'] = $allow.ToArray()
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $SettingsPath) -WhatIf:$false | Out-Null
        $s | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 -LiteralPath $SettingsPath -WhatIf:$false
    }
    @($added | ForEach-Object { "allow rule added: $_" })
}

function Add-GitIgnoreLines {
    param([string]$Path, [string[]]$Lines, [bool]$DryRun)
    $have = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() }) } else { @() }
    $missing = @($Lines | Where-Object { $_ -notin $have })
    if (-not $missing) { return @() }
    if (-not $DryRun) {
        $prefix = if ($have -and (Get-Content -Raw -LiteralPath $Path) -notmatch "`n$") { "`n" } else { '' }
        Add-Content -Encoding utf8 -LiteralPath $Path -Value ($prefix + "# ag2-orchestrator`n" + ($missing -join "`n")) -WhatIf:$false
    }
    @($missing | ForEach-Object { ".gitignore += $_" })
}

function Test-RemoteCredentials {
    param([string]$Project)
    $remotes = git -C $Project remote -v 2>$null | Out-String
    if ($remotes -match '://[^/\s@]+@' ) {
        return 'A git remote URL contains credentials (user:token@ or token@). Agents and AG2 metadata can leak it: switch to a credential helper (git remote set-url origin https://github.com/<owner>/<repo>.git) and revoke the token.'
    }
    $null
}

function Install-Orchestrator {
    param([string]$Project, [string[]]$Workers, [switch]$SkipCheck, [bool]$DryRun)
    if (-not $Project) { New-AdapterError '-Project is required.' 'e.g. install.ps1 -Project .' }
    $proj = Resolve-Path -LiteralPath $Project -ErrorAction SilentlyContinue
    if (-not $proj) { New-AdapterError "Project folder not found: $Project" 'Pass an existing folder.' }
    $proj = $proj.Path
    $Workers = @($Workers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $known = 'ag2', 'opencode', 'generic-cli'
    $orch = Join-Path $proj '.claude/orchestrator'
    $actions = [System.Collections.Generic.List[string]]::new()
    $todo = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    git -C $proj rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { $warnings.Add('Project is not a git repository; worktrees and HANDOFF checks need git (git init).') }

    # scripts
    foreach ($f in Get-ChildItem -Recurse -File (Join-Path $PluginRoot 'scripts/lib'), (Join-Path $PluginRoot 'scripts/adapters')) {
        $rel = $f.FullName.Substring((Join-Path $PluginRoot 'scripts').Length + 1)
        $a = Sync-File $f.FullName (Join-Path $orch "bin/$rel") -DryRun $DryRun; if ($a) { $actions.Add($a) }
    }
    foreach ($s in $script:BinScripts) {
        $a = Sync-File (Join-Path $PluginRoot "scripts/$s") (Join-Path $orch "bin/$s") -DryRun $DryRun; if ($a) { $actions.Add($a) }
    }
    # templates (reference copies) + working files created once
    foreach ($f in Get-ChildItem -File (Join-Path $PluginRoot 'templates')) {
        $a = Sync-File $f.FullName (Join-Path $orch "templates/$($f.Name)") -DryRun $DryRun; if ($a) { $actions.Add($a) }
    }
    $cfgPath = Join-Path $orch 'orchestrator.config.json'
    $cfgIsNew = -not (Test-Path -LiteralPath $cfgPath)
    if ($cfgIsNew) {
        $cfg = Get-Content -Raw (Join-Path $PluginRoot 'templates/orchestrator.config.json') | ConvertFrom-Json -AsHashtable
        foreach ($w in @($cfg.workers.Keys)) { $cfg.workers[$w].enabled = ($w -in $Workers) }
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force $orch -WhatIf:$false | Out-Null
            $cfg | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 -LiteralPath $cfgPath -WhatIf:$false
        }
        $actions.Add("created $cfgPath")
    }
    $cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -Raw $cfgPath | ConvertFrom-Json -AsHashtable } else { @{} }
    $a = Sync-File (Join-Path $PluginRoot 'templates/PLAN.md') (Join-Path $orch 'PLAN.md') -OnlyIfMissing -DryRun $DryRun
    if ($a -and $a -notlike 'kept*') { $actions.Add($a) }

    foreach ($w in $Workers) {
        $adapter = Get-ConfigValue $cfg "workers.$w.adapter" $w
        if ($adapter -notin $known) { New-AdapterError "Unknown worker '$w'." "Known: ag2, opencode, or a generic-cli worker defined in $cfgPath." }
    }
    foreach ($a in (Merge-AllowRules (Join-Path $proj '.claude/settings.local.json') (Get-AllowRules $Workers $cfg) $DryRun)) { $actions.Add($a) }
    foreach ($a in (Add-GitIgnoreLines (Join-Path $proj '.gitignore') $script:IgnoreLines $DryRun)) { $actions.Add($a) }

    $cred = Test-RemoteCredentials $proj
    if ($cred) { $warnings.Add($cred) }

    $checks = [ordered]@{}
    if (-not $SkipCheck -and -not $DryRun) {
        foreach ($w in $Workers) {
            $adapter = Get-ConfigValue $cfg "workers.$w.adapter" $w
            $extra = if ($adapter -eq 'generic-cli') { @('-Worker', $w) } else { @() }
            Push-Location $proj
            try { $line = pwsh -NoProfile -File (Join-Path $orch "bin/adapters/$adapter.ps1") -Check @extra 2>$null | Select-Object -Last 1 }
            finally { Pop-Location }
            try { $checks[$w] = $line | ConvertFrom-Json } catch { $checks[$w] = [ordered]@{ ok = $false; error = "no JSON from -Check: $line" } }
            if (-not $checks[$w].ok) { $todo.Add("Fix worker '$w': $($checks[$w].error) -> $($checks[$w].hint)") }
        }
    }
    if ('ag2' -in $Workers -and -not (Get-ConfigValue $cfg 'workers.ag2.projectId' '')) {
        $todo.Add('AG2 project id: open this folder as a project in Antigravity 2, start any conversation, then run: pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId  (and set workers.ag2.projectId).')
    }
    if ('opencode' -in $Workers -and -not (Get-ConfigValue $cfg 'workers.opencode.autoApprove' $false)) {
        $todo.Add('OpenCode runs headless and cannot answer permission prompts. Read docs/SECURITY.md, then decide on workers.opencode.autoApprove.')
    }
    if (-not (Test-Path (Join-Path $proj 'AGENTS.md'))) { $todo.Add('Add an AGENTS.md for workers (sample: .claude/orchestrator/templates/AGENTS.md).') }
    $todo.Add('Optionally paste .claude/orchestrator/templates/CLAUDE.orchestration.md into your CLAUDE.md.')

    [ordered]@{ ok = $true; project = $proj; dryRun = $DryRun; workers = $Workers; actions = @($actions); warnings = @($warnings); checks = $checks; todo = @($todo) }
}

if ($MyInvocation.InvocationName -ne '.') {
    Complete-Script -Body { Install-Orchestrator -Project $Project -Workers $Workers -SkipCheck:$SkipCheck -DryRun ([bool]$WhatIfPreference) }
}
