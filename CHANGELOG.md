# Changelog

## 0.1.0 (unreleased)

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
