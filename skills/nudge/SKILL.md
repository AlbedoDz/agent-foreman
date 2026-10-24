---
description: Send a follow-up message to a running worker session (unstick a stalled task or relay a fix).
argument-hint: "<taskId> [what to tell the worker]"
disable-model-invocation: true
---

Nudge task `$0`. Arguments: `$ARGUMENTS`.

1. Find the worker and sessionId for `$0` in `.claude\orchestrator\logs\dispatch.jsonl`.
2. Look at what it is doing: `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\<worker>.ps1 -Status -SessionId <sid> -Tail 30`. `-Tail` works for AG2 only; for other workers, read the end of `logPath`.
3. Write `.claude\orchestrator\$0-nudge.prompt.md` in 3 to 8 lines: what you observed, the concrete next step,
   "if blocked: commit what you have and write the HANDOFF with STATUS: BLOCKED", plus any text the user gave after the task id.
4. Send it: `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\<worker>.ps1 -Message -SessionId <sid> -MessageFile .claude\orchestrator\$0-nudge.prompt.md`
5. If the background watcher for `$0` has exited, restart it.
