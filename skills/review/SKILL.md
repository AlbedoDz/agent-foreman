---
description: Review a worker's HANDOFF against git (verify script, diff, re-run tests) and give a GO/FIX verdict; merge on GO.
argument-hint: "<taskId>"
disable-model-invocation: true
---

Review task `$0`. Follow the ag2-orchestrator:harness-orchestrator skill, sections 6 and 7, and its reference/review-checklist.md.

1. Take the allowed and forbidden globs and the test commands from `.claude\orchestrator\PLAN.md`.
2. `pwsh -NoProfile -File .claude\orchestrator\bin\verify-handoff.ps1 -Repo . -Branch task/$0 -Handoff <handoffDir>/HANDOFF_$0.md -Allowed <globs> -Forbidden <globs>`
3. Read `git diff <base>...task/$0` in full. Re-run the task tests, the full suite and the linter yourself, inside `..\wt-$0`.
4. Check every claim in the HANDOFF against your own results and the checklist.
5. Verdict: `REVIEW $0: GO`, or `REVIEW $0: FIX` with `[file:line] defect -> expected` for each defect.
6. On GO, ask the user before merging, unless they already said to merge on GO. Then run `pwsh -NoProfile -File .claude\orchestrator\bin\task-cleanup.ps1 -Id $0 -Merge` and update PLAN.md.
   On FIX, write `.claude\orchestrator\$0-fix<n>.prompt.md` and send it (at most `fixRoundsMax` rounds; after that, fix it yourself or reroute).
