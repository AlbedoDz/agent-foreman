---
description: Dispatch every ready task of a wave from PLAN.md in parallel (up to maxParallel), each in its own worktree.
argument-hint: "<wave number>"
disable-model-invocation: true
---

Run wave `$ARGUMENTS` of `.claude\orchestrator\PLAN.md`. Follow the ag2-orchestrator:harness-orchestrator skill.

1. List the tasks of the wave. A task is ready only if every `depends_on` task is merged. If two tasks of the wave have overlapping allowed files, stop and tell the user.
2. Check each needed worker once (`adapters\<worker>.ps1 -Check`).
3. Dispatch the ready tasks the way `/ag2-orchestrator:dispatch` does (worktree, prompt, dispatch, background watcher), with at most `maxParallel` running at a time. When a watcher exits, review that task (`/ag2-orchestrator:review`), then fill the free slot.
4. When the whole wave is merged, run the full test suite on the base branch and report the status table before starting the next wave.
