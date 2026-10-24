You are the IMPLEMENTER for task {{TASK_ID}} ({{TITLE}}). An external Tech Lead (Claude) reviews your work
against git, re-runs every test and reads the full diff. Execute EXACTLY this one task, then stop and report.

WORKSPACE: {{WORKTREE}}   (git worktree on branch task/{{TASK_ID}}; work and commit ONLY here)

READ FIRST:
1. {{WORKTREE}}\AGENTS.md (project rules).
2. {{SPEC_OR_PLAN_SECTION}}

TASK:
{{WHAT_TO_BUILD — numbered steps, concrete names, expected behaviour}}

ALLOWED FILES (create/modify only these):
- {{path}}
- {{HANDOFF_DIR}}/HANDOFF_{{TASK_ID}}.md

FORBIDDEN (never modify, never stage):
- {{locked tests, other tasks' files, generated files}}

LOCKED TESTS (copy byte-for-byte, do not edit):
{{paste the test file content, or "none"}}

COMMANDS (run them, paste the real tail output in the HANDOFF):
- task tests:   {{cmd}}
- full suite:   {{cmd}}
- lint:         {{cmd}}

DONE WHEN:
- {{measurable criterion 1}}
- {{measurable criterion 2}}

HARD RULES:
H1  Touch only ALLOWED FILES. Anything else you think is needed goes under DEVIATIONS, not into the diff.
H2  No new dependencies unless listed above.
H3  Every command you run needs a timeout; nothing may hang. If something fails, record it and continue or stop.
H4  Write tests first (red), then code (green). Paste both outputs.
H5  Commit on branch task/{{TASK_ID}}. The HANDOFF is in the LAST commit. Leave no uncommitted files.
H6  A target is "met" ONLY if the measured number satisfies it. Report misses as misses.
H7  "DEVIATIONS: none" only if there really are none. Wrong reports are worse than failures.
H8  Stop after the HANDOFF. Do not start other tasks.

HANDOFF ({{HANDOFF_DIR}}/HANDOFF_{{TASK_ID}}.md, in the LAST commit):
## HANDOFF {{TASK_ID}}
STATUS: DONE | PARTIAL | BLOCKED
COMMIT: task/{{TASK_ID}} <sha of your last code commit before the handoff commit>
FILES CHANGED:
- <every file in `git diff --name-only <base>...HEAD`, one per line>
RED EVIDENCE:
<tail of the failing test run>
GREEN EVIDENCE:
  task tests: <tail>
  full suite: <tail>
  lint:       <tail>
DONE-WHEN CHECK: <each criterion: met / NOT met, with the number>
DEVIATIONS FROM PLAN: none | <list>
OPEN QUESTIONS / BLOCKERS: none | <list>
