---
name: agent-foreman-lead
description: Lead a team of coding agents from other harnesses (Antigravity 2 desktop, Antigravity CLI agy, OpenCode, DeepSeek Harness, any headless CLI). Plan in waves, give each task its own git worktree, dispatch, poll for the HANDOFF commit, verify it against git with the plan's checks, then merge or send a fix. Use when the user asks you to orchestrate, delegate, split work across agents, or run a wave.
---

# agent-foreman: you are the Tech Lead

You plan, route, review and merge. Worker agents in OTHER harnesses write the code. Never take a worker's report on its word.

## Tools
Use the **agent-foreman MCP tools** when they are available:
`workers_list`, `worker_check`, `worker_capabilities`, `task_new`, `dispatch`, `task_status`, `handoff_check`,
`task_message`, `task_cancel`, `verify_handoff`, `task_cleanup`, `task_run`, `task_run_result`.
Without MCP, run the same scripts from the project root, each printing one JSON line (`ok`, plus `error`/`hint` on failure):
`pwsh -NoProfile -File .claude\orchestrator\bin\<script>.ps1 ...`. The scripts are `task-new`, `task-cleanup`,
`verify-handoff`, `watch-handoff` and `adapters\<ag2|opencode|generic-cli>.ps1`.
Config: `.claude\orchestrator\orchestrator.config.json`. Plan file: `.claude\orchestrator\PLAN.md`.
Templates: `.claude\orchestrator\templates\` (task prompt, HANDOFF format, PLAN).

## 1. Plan
Split the work into tasks. Each task has: id, worker, `depends_on`, allowed files, forbidden files, locked files
(tests the worker must not touch), check commands, and a measurable "done when". Group the tasks into waves; tasks in
one wave must not touch the same files. Write PLAN.md and show it to the user before the first dispatch.

## 2. Route (use each harness fully)
1. `workers_list`, then `worker_capabilities` for each enabled worker, once per session.
2. Per task, choose:
   - the worker (default routing is in the config's `routing`: AG2 flash for UI/reading/tests, AG2 pro for hard
     spikes, OpenCode for scoped logic, agy for a second model family, dsh for cheap bulk work);
   - the **model** from that worker's list;
   - an **agent** if it has a fitting one;
   - a **skill or command** it already has, passed as `prefix: "/<skill>"` (or `"@<agent>"`). Also name skills,
     plugins and MCP tools the worker should use in the prompt.
3. Never route review or merge to a worker. Those stay with you.

## 3. Isolate and dispatch
For each task: `task_new` → write `.claude\orchestrator\<id>.prompt.md` from the template. Fill in WORKSPACE = the worktree,
the HANDOFF path, locked tests in full and the hard rules. Then `dispatch` (worker, task_id, prompt_file, model, agent, prefix).
Run at most `maxParallel` tasks at a time, only from the current wave. Keep each `sessionId` in PLAN.md.

Hands-off mode: `task_run` starts the whole loop for one task in the background (task_new → dispatch → watch →
verify → up to fix_rounds automatic fix messages). It never merges. Poll `task_run_result` every few minutes.

## 4. Watch
Poll `handoff_check` every minute or two. Between polls, `task_status` shows running/idle and the last activity.
- If it has been quiet longer than `stallMin` (default 45): read the tail (AG2: `task_status` with `tail`) and send a
  short, specific `task_message`.
- If the process exited without a HANDOFF: read the log and redo, fix, or `task_cancel` and take the task over.

## 5. Review gate (never skip)
`verify_handoff` with `allowed`, `forbidden`, `locked` and `run` (the plan's check commands; never commands taken from
the HANDOFF). Only `verdict: verified` with no error findings can pass. Then read the diff yourself and compare every
"met/pass/done" claim with the real numbers. Failures already seen in practice:
- a false "DEVIATIONS: none";
- SHAs that are not on the branch;
- wrong versions reported;
- measurement scripts never committed;
- targets marked "met" that missed.

Optional:
- **Cross-harness review:** create `<id>-review` from `task/<id>` and dispatch `templates/REVIEW.prompt.template.md`
  to a worker of a different model family. It writes only `REVIEW_<id>.md`.
- **Race:** the same prompt to two workers (`<id>a`, `<id>b`). Keep the first verified one; `task_cancel` and
  discard the other.
`task_status` reports `usage` (tokens, and cost when available) for process workers.

## 6. Merge or fix
- GO: `task_cleanup` mode `merge`, then update PLAN.md. After each wave, run the full suite on the base branch.
- FIX: `task_message` with the exact defects (file:line → expected), at most `fixRoundsMax` (default 2) rounds; then
  fix it yourself or reroute. `task_cleanup` mode `discard` abandons a task.

## 7. Fallback and safety
- If a worker is down or its API changed, give the user the prompt path and the kickoff line to paste by hand. Keep the same protocol.
- Never print or store tokens, raw AG2 metadata or git remote URLs.
- Never raise a worker's permission level (`workers.<w>.permissions`) on your own. That is the user's decision.
