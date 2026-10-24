# agent-foreman

**Use Claude Code as Tech Lead over other coding agents on Windows.** Claude plans the work in waves and gives each
task its own git worktree. It dispatches the tasks to **Antigravity 2** (desktop), **OpenCode**, the **Antigravity CLI** (`agy`), **DeepSeek Harness** (`dsh`), or any headless CLI harness, choosing each harness's own models, agents, skills and plugins per task (`-Capabilities`, `-Model`, `-Agent`, `-Prefix "/skill"`). It waits
for each worker's HANDOFF commit, **verifies the report against git and re-runs the tests itself**, then merges or sends a fix.

[Tiếng Việt](README.vi.md)

> Status: early (0.3.0). The AG2 integration uses Antigravity 2's bundled `agentapi` CLI and internal details that
> may change in any AG2 update. The adapter detects this and refuses to guess. Read [docs/SECURITY.md](docs/SECURITY.md) first.

## Requirements

- Windows 10/11, PowerShell 7 (`pwsh`), git
- Claude Code (tested with Opus 5.5; the skill is written to work with Sonnet 5.5 too)
- At least one worker: Antigravity 2 desktop, and/or [OpenCode](https://opencode.ai) with a configured provider
- For running the tests: Pester 5+ (`Install-Module Pester -Scope CurrentUser`)

## Install

```powershell
claude plugin marketplace add AlbedoDz/agent-foreman
claude plugin install agent-foreman@agent-foreman
```

Then, inside Claude Code in your project:

```
/agent-foreman:orchestrator-install ag2,opencode
```

This runs `scripts/install.ps1` (with a `-WhatIf` preview first). In your project it creates `.claude/orchestrator/`
(scripts, templates, `orchestrator.config.json`, `PLAN.md`). It also adds **one allow rule per script** to `.claude/settings.local.json`,
git-ignores logs, prompts and local config, warns if your git remote embeds a token, and checks each worker.

For AG2, set the project id once: open the repo folder as a project in Antigravity 2, start any conversation, then:

```powershell
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId -SessionId <id from the list>
```

Put the value into `workers.ag2.projectId`, then run `/agent-foreman:ag2-check`.

## Use

Ask Claude for multi-part work ("split this feature across agents"), and the `harness-orchestrator` skill takes over. You can also drive it step by step:

| Command | What it does |
|---|---|
| `/agent-foreman:ag2-check` | check workers |
| `/agent-foreman:wave 1` | dispatch every ready task of wave 1 (max 3 in parallel) |
| `/agent-foreman:dispatch T1 ag2:flash` | one task: worktree, prompt, dispatch, background watcher |
| `/agent-foreman:status` | worker state + HANDOFF yes/no per task |
| `/agent-foreman:nudge T1` | read the transcript tail, send a specific nudge |
| `/agent-foreman:review T1` | verify HANDOFF vs git, read the diff, re-run tests → GO (merge) / FIX |
| `/agent-foreman:run T1 opencode` | hands-off: dispatch → watch → verify → automatic fix rounds → verdict (never merges) |

## Any harness can lead

The lead does not have to be Claude Code. `install.ps1 -Lead opencode,agy,ag2` puts the `agent-foreman-lead` skill in
`.agents/skills/`, where OpenCode, the Antigravity CLI and AG2 read project skills. For OpenCode it also registers the
**agent-foreman MCP server** (`.claude/orchestrator/bin/mcp/agent_foreman_mcp.py`, Python standard library only) in
`opencode.json`. Its tools are `workers_list`, `worker_capabilities`, `task_new`, `dispatch`, `task_status`,
`handoff_check`, `task_message`, `task_cancel`, `verify_handoff`, `task_run`, `task_run_result` and `task_cleanup`.
Verified live: OpenCode as lead created a worktree and dispatched a task to AG2 through these tools; the work was
then verified and merged. agy and AG2 read MCP servers only from global config; the installer prints the snippet
instead of editing it.

The workflow (Plan → Route → Isolate → Dispatch → Watch → Review gate → Merge/Fix → Fallback) is in
[skills/harness-orchestrator/SKILL.md](skills/harness-orchestrator/SKILL.md).

## How it works

[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) explains in short how the adapter finds the AG2 hub process and passes its loopback address and CSRF token
to `agentapi` through the environment of the script's own process. It also explains why the only completion signal is a git commit containing the HANDOFF,
and why `running/idle` for AG2 is an inference from transcript file times.

All scripts share one contract: one JSON line on stdout, exit code ≠ 0 with `{ok:false, error, hint}` on failure.
Details: [adapter contract](skills/harness-orchestrator/reference/adapter-contract.md). New worker:
[docs/ADDING-A-HARNESS.md](docs/ADDING-A-HARNESS.md). Problems: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What is verified

See [CHANGELOG.md](CHANGELOG.md): Pester tests (mocked AG2/processes, real temporary git repos) and a real end-to-end smoke
test. Anything marked **unverified** there has not been run against the real tool.

## Development

```powershell
Invoke-Pester tests
pwsh -NoProfile -File scripts/secret-scan.ps1          # also -Staged (pre-commit) and -History
claude plugin validate .
```

## License

MIT
