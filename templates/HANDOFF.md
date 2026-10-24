## HANDOFF <TASK_ID>
STATUS: DONE | PARTIAL | BLOCKED
COMMIT: task/<TASK_ID> <sha of the last code commit before this handoff commit>
FILES CHANGED:
- path/one
- path/two
- docs/handoffs/HANDOFF_<TASK_ID>.md
RED EVIDENCE:
```
<tail of the failing test run, before the implementation>
```
GREEN EVIDENCE:
  task tests: <tail, e.g. "9 passed in 1.2s">
  full suite: <tail>
  lint:       <tail>
DONE-WHEN CHECK:
- <criterion>: met | NOT met (<measured number>)
DEVIATIONS FROM PLAN: none | <what and why>
OPEN QUESTIONS / BLOCKERS: none | <list>
