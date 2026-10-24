---
description: Run one task hands-off - worktree, dispatch, watch, verify, automatic fix rounds - and report the verdict. Never merges.
argument-hint: "<taskId> <worker[:model]> [/skill-or-@agent prefix]"
disable-model-invocation: true
---

Run task `$0` on worker `$1` end to end. Arguments: `$ARGUMENTS`.

1. Take the task from `.claude\orchestrator\PLAN.md`: allowed, forbidden and locked globs, the check commands, and the
   handoff path (`<handoffDir>/HANDOFF_$0.md`). Make sure `.claude\orchestrator\$0.prompt.md` exists (write it from the template if not).
2. Split `$1` into worker and model at the first `:`. Optional third argument = `-Prefix`.
3. Start it in the background (Claude Code: `run_in_background`):
   `pwsh -NoProfile -File .claude\orchestrator\bin\task-run.ps1 -Worker <worker> -TaskId $0 -PromptFile .claude\orchestrator\$0.prompt.md -Handoff <handoff> -Allowed "<globs>" -Forbidden "<globs>" -Locked "<globs>" -Run "<cmd1>`n<cmd2>" [-Model <model>] [-Prefix <prefix>]`
4. When it exits, read its JSON:
   - `verified`: read `git diff <base>...task/$0` yourself, then ask the user before `task-cleanup.ps1 -Id $0 -Merge`
     (unless they already said to merge verified tasks);
   - `refuted`: the automatic fix rounds were used up. Read the evidence file, then fix it yourself in `..\wt-$0` or reroute;
   - `no-handoff`: stall, timeout or worker exit. Check `-Status`, nudge, or `-Cancel` and redo.
