# Anatomy of a task prompt

Template: `.claude\orchestrator\templates\TASK.prompt.template.md`. Each section has a job:

1. **Role line**: "You are the IMPLEMENTER for task X. An external Tech Lead reviews your work against git."
   Workers report more honestly when they know the report will be checked.
2. **WORKSPACE**: the absolute worktree path. The adapter's kickoff message repeats it.
3. **READ FIRST**: `AGENTS.md` plus the exact spec or plan section (path and heading), not "the docs".
4. **TASK**: numbered steps with concrete names (files, functions, CLI flags) and the expected behaviour.
5. **ALLOWED / FORBIDDEN files**: the same globs you will pass to `verify-handoff.ps1`.
6. **LOCKED TESTS**: paste them in full. The worker copies them byte for byte; you diff them at review.
7. **COMMANDS**: task tests, full suite, lint. Their output tails go into the HANDOFF.
8. **DONE WHEN**: measurable criteria only ("p95 < 50 ms on T1", not "fast").
9. **HARD RULES**: scope, no new dependencies, timeouts on every command, red-then-green, commit on the task branch with
   the HANDOFF last, honest "met" / "DEVIATIONS", stop after the HANDOFF.
10. **HANDOFF format**: STATUS, COMMIT, FILES CHANGED, RED/GREEN evidence, DONE-WHEN check, DEVIATIONS, OPEN QUESTIONS.

Fix prompts (`<id>-fix<n>.prompt.md`): the same workspace and rules, only the defects found at review
(`file:line → expected`), plus "update the HANDOFF in a new last commit".

Nudge messages (stall): short and specific. Say what you saw in the transcript tail, what to do next,
and "commit what you have and write the HANDOFF if blocked". Do not restate the whole task.
