# Adapter contract

Every adapter (`bin\adapters\ag2.ps1`, `opencode.ps1`, `generic-cli.ps1 -Worker <name>`) takes the same switches and
prints exactly one line of JSON on stdout. Exit code 0 means `ok:true`; any other exit code comes with
`{"ok":false,"error":"...","hint":"<concrete fix>"}`. All output passes through `Protect-Secret` (tokens,
`ghp_…`, `github_pat_…`, `user:pass@` URLs and `gitOriginUrl` are redacted).

| Call | Output |
|---|---|
| `-Check` | `{ok, worker, version?, detail}` |
| `-Dispatch -TaskId <id> -PromptFile <f> -Workspace <wt> [-Title <t>] [-Model <m>]` | `{ok, worker, taskId, sessionId, logPath}` |
| `-Status -SessionId <sid>` | `{ok, worker, sessionId, state: running\|idle\|unknown, lastActivity, stateSource, ...}` |
| `-Message -SessionId <sid> -MessageFile <f>` | `{ok}` |

Worker specifics:
- **ag2**: `-Model flash_lite|flash|pro` (default `workers.ag2.defaultModel`). `sessionId` = AG2 conversationId.
  `logPath` = the conversation transcript. `-Status` infers `state` from the transcript's modification time
  (`running` = written within `idleAfterMin`, default 5). This is an inference, NOT an AG2 API. `-Status -Tail N` adds the last N
  transcript lines, cut to 400 characters each. Extra mode: `-FindProjectId [-SessionId <id>]`.
- **opencode**: `-Model provider/model`. Runs `opencode run --format json` in the background with the worktree as its working
  directory. `sessionId` = the `sessionID` field of the first JSON event. `state` = `running` while the process is alive.
- **generic-cli**: commands from `workers.<name>.{check,dispatch,message}`, written as argument arrays with placeholders.
  `sessionId` = first match of `sessionIdPattern`, otherwise `pid:<n>`. See the plugin's `docs/ADDING-A-HARNESS.md`.

Every dispatch and message is appended (redacted) to `.claude\orchestrator\logs\dispatch.jsonl`.
Process-based workers also write `logs\<taskId>.state.json` (pid, sessionId, log path).

Helper scripts (same JSON convention):
- `task-new.ps1 -Id <id> [-Base <rev>]` → `{ok, taskId, branch, worktree, base}`
- `task-cleanup.ps1 -Id <id> [-Merge | -Discard]` → refuses when the worktree is dirty or the merge fails (the merge is aborted).
- `watch-handoff.ps1 ...` exits with 0 handoff, 2 stall, 3 timeout, 4 worker exited.
- `verify-handoff.ps1 ...` → `{ok, findings:[{severity, code, detail}], changedFiles, manualChecks}`
