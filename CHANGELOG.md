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
- `secret-scan.ps1` + pre-commit hook. Pester suite (67 tests).

### Verified (2026-10-24, Windows 11, pwsh 7.6, Pester 6.2, AG2 desktop, OpenCode 2.0.x)
- Pester: all tests green (adapters with mocked processes/`agentapi`, real temporary git repos for worktree/verify/cleanup/install).
- `ag2.ps1 -Check` against a running AG2: API found on the second loopback port. The signature gate passed on the real `--help`.
- `opencode run --format json` event format: every event carries `sessionID`, errors are `type: "error"`. A provider without
  a credential fails with `provider.auth`, and the adapter maps that to a hint.
- `install.ps1` into a fresh temporary git project: dry run, real run, `-Check` OK for AG2 and OpenCode.

### Not verified yet
- End-to-end dispatch → HANDOFF → verify → merge on a real worker with this packaged version (see the next entry when done).
- `generic-cli.ps1` against any real third-party harness (only unit-tested with mocks).
- Installing from GitHub with `claude plugin marketplace add <owner>/ag2-orchestrator` (only the local manifests were validated).
- The real model names behind AG2's `flash` / `pro`.
