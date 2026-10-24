## Orchestration rules (agent-foreman)

- For multi-task work, act as Tech Lead with the `agent-foreman:harness-orchestrator` skill: plan in waves
  (`.claude/orchestrator/PLAN.md`), one worktree per task, dispatch, watch, review, merge.
- Scripts live in `.claude/orchestrator/bin/`. Always call them exactly as
  `pwsh -NoProfile -File .claude\orchestrator\bin\<script>.ps1 ...` so the allow rules in `.claude/settings.local.json` match.
- Never trust a HANDOFF: run `verify-handoff.ps1`, read the diff, re-run tests and lint yourself.
- Max 2 fix rounds per task, then do it yourself or switch worker.
- Never print or paste raw AG2 metadata, tokens or remote URLs. Adapters already redact; keep it that way.
- If AG2 is down or its API changed: print the prompt for the user to paste into AG2 by hand; same protocol.
