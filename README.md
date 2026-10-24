# agent-foreman: Claude Code multi-agent orchestrator for Antigravity 2, OpenCode, OpenAI Codex and DeepSeek Harness

**Use Claude Code (Opus 5.5) as the Tech Lead over other AI coding agents on Windows.** Claude plans the work in waves
and gives each task its own git worktree. It dispatches the tasks to the **Google Antigravity 2 desktop app**, the
**Antigravity CLI (`agy`)**, **OpenCode**, the **OpenAI Codex CLI** that ships with the **ChatGPT / Codex desktop app**,
**DeepSeek Harness**, or any other headless coding CLI. For each task it picks that tool's own models, agents, skills
and plugins. It waits for each worker's HANDOFF commit, **verifies the work against git and re-runs the checks itself**,
then merges it or sends a precise fix request.

**Claude Code is the default lead.** You can also make another harness and model the lead, for example **Antigravity 2
directing OpenCode workers**, or OpenCode, the Antigravity CLI or Codex leading the team.

[Tiếng Việt](README.vi.md)

> Status: early (0.4.0). The Antigravity 2 desktop integration uses the `agentapi` CLI bundled with Antigravity 2, plus
> internal details that may change in any Antigravity 2 update. The adapter detects such changes and refuses to guess.
> Read [docs/SECURITY.md](docs/SECURITY.md) first.

## Supported coding agents (harnesses)

| Harness | How it is driven | Use it as worker | Use it as lead |
|---|---|---|---|
| **Claude Code** (Opus 5.5 / Sonnet 5.5) | this plugin's skills | — | **default** |
| **Google Antigravity 2** desktop app | `agentapi` of the Antigravity 2 hub (loopback API) | yes (`flash_lite`, `flash`, `pro`) | yes (skill + scripts) |
| **Antigravity CLI** (`agy`, Gemini and Claude models) | `agy --print --output-format stream-json` | yes | yes (skill; MCP via global config) |
| **OpenCode** CLI / OpenCode desktop | `opencode run --format json` | yes | yes (skill + MCP in `opencode.json`) |
| **OpenAI Codex CLI** / **ChatGPT & Codex desktop app** | `codex exec --json` (CLI bundled in the desktop app) | yes | yes (skill; `codex mcp add`) |
| **DeepSeek Harness** (`dsh`) | `dsh headless --json` | yes (needs a DeepSeek API key) | — |
| Any headless coding CLI | `generic-cli` adapter, configured as argument arrays | yes | — |

The **Antigravity IDE** (the older editor) is not a worker: its `chat` CLI does not run agent tasks.

## Requirements

- Windows 10/11, PowerShell 7 (`pwsh`), git, Python 3 (for the MCP server)
- Claude Code (tested with Opus 5.5; the skills also work with Sonnet 5.5)
- At least one worker from the table above
- For running the tests: Pester 5+ (`Install-Module Pester -Scope CurrentUser`)

## Install

```powershell
claude plugin marketplace add AlbedoDz/agent-foreman
claude plugin install agent-foreman@agent-foreman
```

Then, inside Claude Code in your project:

```
/agent-foreman:orchestrator-install ag2,opencode,agy,codex
```

This runs `scripts/install.ps1`, with a `-WhatIf` preview first. In your project it:
- creates `.claude/orchestrator/` (scripts, templates, `orchestrator.config.json`, `PLAN.md`);
- adds **one allow rule per script** to `.claude/settings.local.json`;
- git-ignores logs, prompts and local config;
- warns if your git remote embeds a token;
- checks each worker.

For the Antigravity 2 desktop app, set the project id once. Open the repository folder as a project in Antigravity 2,
start any conversation, then run:

```powershell
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId -SessionId <id from the list>
```

Put the value into `workers.ag2.projectId`, then run `/agent-foreman:ag2-check`.

## Use

Ask Claude for multi-part work ("split this feature across agents"), and the `harness-orchestrator` skill takes over.
You can also drive it step by step:

| Command | What it does |
|---|---|
| `/agent-foreman:ag2-check` | check every worker (Antigravity 2, OpenCode, Antigravity CLI, Codex, DeepSeek Harness) |
| `/agent-foreman:wave 1` | dispatch every ready task of wave 1 (max 3 in parallel) |
| `/agent-foreman:dispatch T1 ag2:flash` | one task: worktree, prompt, dispatch, background watcher |
| `/agent-foreman:run T1 opencode` | hands-off: dispatch → watch → verify → automatic fix rounds → verdict (never merges) |
| `/agent-foreman:status` | worker state, token usage, HANDOFF yes/no per task |
| `/agent-foreman:nudge T1` | read the transcript tail, send a specific nudge |
| `/agent-foreman:review T1` | verification contract + diff review → GO (merge) / FIX |
| `/agent-foreman:delegate-lead ag2:pro "goal"` | hand the lead role for one goal to another harness and model |

Per task, Claude chooses the model (`-Model`), the agent (`-Agent`) and a skill or command of the worker
(`-Prefix "/test-driven-development"`), based on what `-Capabilities` reports for that harness.

## Choosing the lead

- **Default:** Claude Code leads through this plugin.
- **Switch for one goal:** `/agent-foreman:delegate-lead <harness[:model]> "<goal>"`. Claude writes a lead prompt and
  hands it to that harness at the project root, waits for its `LEAD_REPORT`, then checks the work.
- **Any harness can lead permanently:** `install.ps1 -Lead opencode,agy,ag2,codex` installs the harness-neutral
  `agent-foreman-lead` skill in `.agents/skills/`. OpenCode, the Antigravity CLI and Antigravity 2 read project skills
  from that folder. For OpenCode the installer also registers the **agent-foreman MCP server** in `opencode.json`. The
  server is `.claude/orchestrator/bin/mcp/agent_foreman_mcp.py`, Python standard library only, with 13 tools: workers,
  capabilities, tasks, dispatch, status, messages, cancel, verification, `task_run` and cleanup. The Antigravity CLI,
  Antigravity 2 and Codex load MCP servers from global config, so for them the installer prints the command instead
  of editing global files.

The workflow (Plan → Route → Isolate → Dispatch → Watch → Review gate → Merge/Fix → Fallback) is in
[skills/harness-orchestrator/SKILL.md](skills/harness-orchestrator/SKILL.md).

## How it works

[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) explains:
- how the adapter finds the Antigravity 2 hub process and passes its loopback address and CSRF token to `agentapi`, only through the environment of the script's own process;
- why the only completion signal is a git commit containing the HANDOFF;
- how the verification contract decides: checks taken from the plan, locked tests, and evidence files.

All scripts share one contract: one JSON line on stdout, and on failure an exit code ≠ 0 with `{ok:false, error, hint}`.
Details: [adapter contract](skills/harness-orchestrator/reference/adapter-contract.md). To add a new worker, see
[docs/ADDING-A-HARNESS.md](docs/ADDING-A-HARNESS.md). For problems, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What is verified

See [CHANGELOG.md](CHANGELOG.md). It covers the Pester tests (mocked processes and Antigravity 2 API, real temporary git
repos) and real end-to-end runs: Antigravity 2 and OpenCode workers in parallel, OpenCode leading an Antigravity 2
worker, and capability discovery for all harnesses. Anything marked **unverified** there has not been run against the real tool.

## Development

```powershell
Invoke-Pester tests
pwsh -NoProfile -File scripts/secret-scan.ps1          # also -Staged (pre-commit) and -History
claude plugin validate .
```

## License

MIT
