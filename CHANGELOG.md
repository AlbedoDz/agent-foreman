# Changelog

## 0.2.0 (unreleased)

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
