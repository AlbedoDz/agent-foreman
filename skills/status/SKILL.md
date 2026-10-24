---
description: Show the state of dispatched orchestration tasks (worker state, last activity, HANDOFF committed or not).
argument-hint: "[taskId]"
disable-model-invocation: true
---

Show the status of orchestration tasks. Optional task id: `$ARGUMENTS`.

1. Read `.claude\orchestrator\logs\dispatch.jsonl` (one JSON object per line) to map each taskId to its worker and sessionId. Without an argument, use every task in `.claude\orchestrator\PLAN.md` that is dispatched but not yet merged.
2. For each task:
   - `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\<worker>.ps1 -Status -SessionId <sessionId>` (generic CLI workers: `generic-cli.ps1 -Worker <worker>`)
   - HANDOFF committed? `git log task/<id> --oneline -1 -- <handoffDir>/HANDOFF_<id>.md`
3. Print a table: task | worker | state | last activity | HANDOFF yes/no.
   For AG2, say that `state` is inferred from the transcript's modification time.
4. Suggest the next step: review if the HANDOFF is in, nudge if the task has been quiet longer than `stallMin`.
