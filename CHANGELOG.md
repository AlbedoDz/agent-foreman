# Changelog

## 0.4.0 (unreleased)

Claude Code (Opus 5.5) stays the default lead; the lead can be handed to another harness and model per goal.
Adds OpenAI Codex / the ChatGPT & Codex desktop app.

### Added
- **`/agent-foreman:delegate-lead <harness[:model]> "<goal>"`** (verified with Antigravity 2 as lead, see below) and `templates/LEAD.prompt.template.md`. Claude hands
  one goal to another lead: Antigravity 2 desktop, Antigravity CLI, OpenCode or Codex. That lead runs at the project
  root, coordinates workers in the other harnesses, and commits `LEAD_REPORT_<id>.md`. Claude then checks the work.
  The `lead` block in the config documents the default.
- **`codex` worker preset.** It drives the OpenAI Codex CLI 0.163 bundled with the ChatGPT/Codex desktop app
  (Microsoft Store, `OpenAI.Codex`): `codex exec --json -C <worktree> --add-dir <prompts> -s workspace-write
  --approve-for-me`. It resumes with `exec resume`, takes `thread_id` from `thread.started`, and detects `turn.failed`.
  Capabilities: `codex debug models`, `codex mcp list`, `codex plugin list`, `~/.codex/skills`.
- `install.ps1 -Lead codex` prints the `codex mcp add agent-foreman -- python ...` command. It does not edit the
  global Codex config.
- `Resolve-Executable` accepts wildcards for versioned install folders (newest match).
- Usage parsing for Codex `turn.completed` events.
- README and descriptions rewritten with the full product names (Google Antigravity 2 desktop, Antigravity CLI,
  Antigravity IDE, OpenAI Codex, ChatGPT desktop, OpenCode, DeepSeek Harness) and a harness support table.

- **Merge-preview verification:** `verify-handoff -Run` checks now run on a temporary merge of the current HEAD with
  the task branch, i.e. on what a merge would produce. A conflict becomes a `merge-conflict` finding;
  `-OnBranchOnly` keeps the old behaviour. Check commands run with `PYTHONDONTWRITEBYTECODE=1`.
- Tool caches (`__pycache__`, `*.pyc`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`) no longer count as uncommitted work.
  verify reports a `cache-files` warning, and `task-cleanup` drops them with the worktree. Real leftovers still block both.

### Verified live (2026-10-25)
- **Antigravity 2 desktop as lead (model `pro`) directing an OpenCode worker**, via `delegate-lead`:
  - Antigravity 2 dispatched G1 to OpenCode (glm-5.3-flash). OpenCode implemented `snake_case` and committed its HANDOFF.
  - Antigravity 2 ran the verification contract and got `refuted`, so it **did not merge**.
  - It found the cause itself: the branch predated a sibling task's merge.
  - It committed an honest `LEAD_REPORT` with usage (41,773 tokens) and next steps.
  - Claude, as the default lead, re-verified on the new merge preview (`verified`, 12/12 tests) and merged. `main` passes the full suite.
- Codex worker: `-Check` OK (codex-cli 0.163.0-alpha.11); `-Capabilities` lists 1 model (`gpt-6-astra`), 5 MCP servers
  and 29 enabled plugins. The JSON event format was confirmed from a real run (`thread.started` … `turn.failed`).
- **Not verified:** a Codex task end to end. On this machine `codex exec` failed with "workspace routing discovery
  failed", although TCP to chatgpt.com worked. Check `codex doctor` and your ChatGPT workspace. The Antigravity CLI
  and Codex reading project skills from `.agents/skills` is also unverified.

## 0.3.0

Any harness can lead, and the most useful ideas from other orchestrators are built in (see docs/HOW-IT-WORKS.md for the sources).

### Added
- **Multi-lead.** `scripts/mcp/agent_foreman_mcp.py` is a standard-library MCP server over the same scripts, with 13 tools:
  workers, capabilities, task_new, dispatch, status, handoff_check, message, cancel, verify, task_run, task_run_result, cleanup.
  `install.ps1 -Lead opencode,agy,ag2` installs the harness-neutral `agent-foreman-lead` skill in `.agents/skills/`,
  and registers the MCP server in `opencode.json`. For agy/AG2 it prints the global `mcp_config.json` snippet
  instead of editing global files.
- **Verification contract** in `verify-handoff`. `-Run` executes the PLAN's check commands in the worktree (or a
  temporary checkout) with a timeout; `-Locked` refutes the run when a locked file was edited. Each run gets a
  verdict (`verified` / `refuted` / `unverified`) and an evidence file.
- **`task-run.ps1`, `/agent-foreman:run` and the MCP `task_run` tool.** One task runs hands-off: dispatch → watch →
  verify → up to `fixRoundsMax` automatic fix messages, built from the findings and the failing check output.
  `watch-handoff -Since` waits for a NEW HANDOFF after each fix. It never merges.
- **`-Cancel`** for process workers (OpenCode, agy, dsh). It kills only the process tree this plugin started.
- **Usage** (tokens, plus cost when the harness reports it) in `-Status` for OpenCode and agy logs.
- **Cross-harness review** template (`templates/REVIEW.prompt.template.md`) and **race** guidance in both skills.

### Fixed
- `pwsh -File` passes only ONE value per `[string[]]` parameter. So multi-value `-Allowed/-Forbidden/-Locked` silently
  used only the first value. Globs are now comma-separated in one argument; commands go one per line, or in `-RunFile`.

### Verified live (2026-10-25)
- **OpenCode as lead** (glm-5.3-flash, headless) loaded `agent-foreman-lead` from `.agents/skills`. Through MCP it
  called `workers_list` → `task_new L1` → `dispatch` to **AG2** (flash). AG2 committed the HANDOFF after about 2 minutes.
  The verification contract (`-Locked tests/*`, `-Run` with the task's tests) returned `verified`; the task was then merged.
- On the same task, a full-suite check correctly **refuted** the run because a different, unmerged task's test was
  still failing. Lesson, now in the skills: choose checks that this task alone can pass.
- Usage read from real logs: agy G1 33,212 tokens; OpenCode O1 32,869 tokens over 9 steps.

## 0.2.0

More harnesses, and Claude can now use each harness's own models, agents, skills and plugins.

### Added
- Ready-made `generic-cli` workers in the config template:
  - `agy`: Antigravity CLI. `--print --output-format stream-json`, `--conversation` to resume, `--add-dir` for the prompt folder.
  - `dsh`: DeepSeek Harness. `dsh headless --json`, `--session-id` to resume.
- `-Capabilities` on every adapter. It lists models, agents, skills (name + description from `SKILL.md`), plugins and MCP
  servers, driven by `workers.<w>.capabilities` (listing commands, skill folders, or fixed lists).
- `-Agent <name>` (OpenCode `--agent`, agy `--agent`) and `-Prefix "/<skill>" | "@<agent>"`. The prefix goes in front of the
  kickoff line, so the harness expands its own skill or command first.
- Permission levels `workers.<w>.permissions`: `default`, `edits` or `full`. For agy they map to `--mode accept-edits` and
  `--dangerously-skip-permissions`; for OpenCode, `full` means `--auto`.
- `generic-cli`:
  - `%ENV%` expansion in commands;
  - an empty optional value is dropped together with its flag;
  - list-valued placeholders such as `{permissions}` are spliced in as separate arguments;
  - `errorPattern` / `errorHint` fail a dispatch at once on a known error;
  - `-Message` reuses the dispatch model and agent, and refuses while the session's process is still running.
- The harness-orchestrator skill has a "Use each harness fully" step, with details in `reference/worker-capabilities.md`.

### Fixed
- `generic-cli -Check` with a single argument (`agy --version`) passed it character by character (string splatting).
- Listing commands now launch the `.exe` or `.cmd` of an npm CLI, not its extension-less shell shim.
- The JSON output line escapes non-ASCII characters, so console code pages cannot corrupt it between processes.

### Verified live (2026-10-24)
- `-Check` OK for all four workers: AG2 (it had moved to a new loopback port and was found again), OpenCode 2.1.4, agy 1.4.7, dsh 0.2.1.
- `-Capabilities`: AG2 3 models and skills; OpenCode 300 models, 2 agents, 10 skills, MCP; agy 13 models, 4 plugins, 4 MCP
  servers, skills; dsh profile model.
- agy with `-Prefix "/test-driven-development"`: the worker first loaded that skill's `SKILL.md`, then read the prompt
  through `--add-dir`, then the test file.
- dsh without an API key: `-Dispatch` failed within seconds with `MISSING_CREDENTIAL` and the fix hint.

### Known limits (verified)
- agy headless with `edits` cannot run shell commands (`git`, `python`): they are auto-denied, so the worker stops before
  committing. A `.agents/settings.json` allow rule inside the workspace was **not** honored. Options are agy's global
  allow rules (`command(<prefix>)` in `~/.gemini/antigravity-cli/settings.json`; their format was not verified) or
  `permissions: full`.
- Claude Code's auto mode refuses to launch a `full` (skip-permissions) worker ("Create Unsafe Agents"). That run has
  to be approved by the user.
- dsh needs a DeepSeek API key for its headless profile before it can do work.

## 0.1.0

First packaging of a Claude Code to Antigravity 2 orchestration workflow that was used in a real project
(about 15 tasks dispatched to AG2 by script, plus several pasted by hand).

### Added
- Plugin + single-plugin marketplace manifest (`claude plugin validate` passes for both).
- `harness-orchestrator` skill (Plan, Route, Isolate, Dispatch, Watch, Review gate, Merge/Fix, Fallback) with reference docs.
- User-invoked skills: `ag2-check`, `dispatch`, `status`, `nudge`, `review`, `wave`, `orchestrator-install`.
  These are skills rather than `commands/`, because the current Claude Code docs call `commands/` the legacy format.
- Adapters with one JSON contract: `ag2.ps1` (generalised from the original dispatch script: process discovery,
  loopback port probing, `agentapi --help` signature gate, `-FindProjectId`, inferred status), `opencode.ps1`, `generic-cli.ps1`.
- `task-new` / `task-cleanup` (worktree per task), `watch-handoff` (handoff / stall / timeout / worker-exit),
  `verify-handoff` (SHA, file list, scope, false "DEVIATIONS: none", HANDOFF-last-commit, uncommitted work).
- `install.ps1`: idempotent, `-WhatIf`, merges minimal allow rules, gitignore entries, warns about credentials in remotes, runs `-Check`.
- `secret-scan.ps1` + pre-commit hook. Pester suite (71 tests).

### Verified (2026-10-24, Windows 11, pwsh 7.6, Pester 6.2, AG2 desktop, OpenCode 2.0.x)
- Pester: all tests green (adapters with mocked processes/`agentapi`, real temporary git repos for worktree/verify/cleanup/install).
- `ag2.ps1 -Check` against a running AG2: API found on the second loopback port. The signature gate passed on the real `--help`.
- `opencode run --format json` event format: every event carries `sessionID`, errors are `type: "error"`. A provider without
  a credential fails with `provider.auth`, and the adapter maps that to a hint.
- `install.ps1` into a fresh temporary git project: dry run, real run, `-Check` OK for AG2 and OpenCode.

### Verified live: two workers in parallel (2026-10-24)
Test project: a small Python package with two locked `unittest` files and one wave of two independent tasks.
Each task ran in its own worktree, using the packaged scripts installed by `install.ps1`.
- **AG2 (`flash`)**: `-Dispatch` → conversation created. `-Status` → `running` (inferred). The watcher saw the HANDOFF after
  about 40 s. `verify-handoff` found nothing. A Tech Lead re-run passed 4/4. Merged with `task-cleanup -Merge`. `-Message` was
  delivered, and the agent answered in the same conversation.
- **OpenCode (desktop app running; the CLI uses its background service `opencode serve --service`)**: `-Dispatch` without `--auto`
  worked. The worker edited, tested and committed on its own with the default OpenCode permissions. The HANDOFF arrived after
  about 3 min. `verify-handoff` found nothing. Re-run passed 5/5. Merged. `-Message` continued the same session (reply received).
- After both merges, the full suite on `main` passed 9/9.
- The AG2 project id does not have to belong to the task's folder: a project bound to another folder worked, because the
  kickoff message names the workspace. The conversation then appears under that other project in the AG2 UI.
- Sessions that the adapter starts through the OpenCode CLI appear in the OpenCode **desktop** app (checked by the user
  in the desktop window), so you can follow or take over a worker's session there.

### Fixed by the live test
- OpenCode prints its first JSON event only after the model's first reply, which can take minutes, so `sessionId`
  fell back to `pid:<n>`. The adapter now looks the session up by title (`opencode session list --format json`).
  `-Status` uses the session's `updated` time. `-Message` reuses the dispatch model and refuses while a run on that
  session is still active.
- One provider stalled on its second request and never recovered (no permission prompt, no error). Recovery that worked:
  stop the run, dispatch again with another model. Documented in TROUBLESHOOTING.
- `task-cleanup -Merge` reported `ok:false` after a successful merge when OpenCode's background service still held the
  worktree folder open. It now unregisters the worktree, reports `leftoverEmptyFolder`, and still deletes the merged branch.
- `-Message` refuses to start a worker in a task worktree that was already removed.

### Not verified yet
- `generic-cli.ps1` against any real third-party harness (only unit-tested with mocks).
- Installing from GitHub with `claude plugin marketplace add AlbedoDz/agent-foreman` (only the local manifests were validated).
- The real model names behind AG2's `flash` / `pro`.
