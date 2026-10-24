---
name: harness-orchestrator
description: Act as Tech Lead and drive external coding agents (Antigravity 2 desktop, OpenCode CLI, any headless CLI harness) on Windows. Plan work in waves, isolate each task in its own git worktree, dispatch, watch for HANDOFF commits, verify every report against git, then merge or send fixes.
when_to_use: The user asks to orchestrate, delegate, split work across agents, dispatch a task to Antigravity/AG2/OpenCode, run a wave, or review a worker's HANDOFF. Requires `.claude/orchestrator/` (install with /agent-foreman:orchestrator-install).
---

# Harness orchestrator: Claude as Tech Lead

You plan, route, review and merge. Workers write code. You never take a worker's report on its word.

All scripts print ONE line of JSON (`ok`, plus `error`/`hint` on failure) and live in `.claude\orchestrator\bin\`.
Call them EXACTLY like this from the project root (the allow rules match this form only):
`pwsh -NoProfile -File .claude\orchestrator\bin\<script>.ps1 <args>`.
If `.claude\orchestrator\bin` is missing, run `/agent-foreman:orchestrator-install` first.
Config: `.claude\orchestrator\orchestrator.config.json` (`maxParallel`, `routing`, `workers`, `stallMin`, `fixRoundsMax`, `handoffDir`).

## 1. Plan
1. Read the request, the spec and `AGENTS.md`. Write the interface contracts that several tasks share yourself, first.
2. Split the work into tasks. Each task has: id, title, worker, `depends_on`, allowed files, forbidden files,
   test command, measurable "done when". Two tasks in the same wave may NOT touch the same file.
3. Group the tasks into waves (a wave = tasks whose dependencies are all merged). Write `.claude\orchestrator\PLAN.md`
   (template: `.claude\orchestrator\templates\PLAN.md`). Show the plan to the user before dispatching wave 1.

## 2. Route
Default routing (the user's `routing` config wins; details in [reference/routing.md](reference/routing.md)):

| Work | Worker |
|---|---|
| UI, read-heavy exploration, test writing | `ag2` model `flash` |
| Hard spike, unclear design, measurement work | `ag2` model `pro` |
| Scoped logic, refactor inside a few files | `opencode` |
| Second opinion / parallel attempt with another model family | `agy` (Antigravity CLI, `--model` from `agy models`) |
| Cheap bulk work | `dsh` (DeepSeek Harness, needs its API key) |
| Interface contracts, review, merge, final fixes | you (Claude) |

AG2 desktop models are only `flash_lite`, `flash` or `pro`. `agy` and `dsh` are `generic-cli` workers: call
`adapters\generic-cli.ps1 -Worker agy|dsh ...` with the same switches.

**Use each harness fully.** Once per session, before routing, run `adapters\<worker>.ps1 -Capabilities` for every
enabled worker (for generic workers, `generic-cli.ps1 -Worker <name> -Capabilities`). It lists the worker's models,
agents, skills (name + description), plugins and MCP servers. Then, for each task:
- pick the **model** that fits the task from that list (`-Model`): a strong model for design work, a fast one for mechanical work;
- pick an **agent** if the harness has a fitting one (`-Agent`: OpenCode `build`/`plan`, agy agents). The AG2 desktop has none;
- invoke a **skill or command** the worker already has, by name: `-Prefix "/<skill>"` puts it in front of the kickoff
  line (for example `/test-driven-development`). `@<agent>` mentions work the same way where the harness supports them.
  Also name skills, plugins and MCP tools in the prompt's TASK section ("use your codegraph MCP to find callers");
- set the **permission level** per worker in config (`workers.<w>.permissions`): `edits` lets it edit its worktree,
  `full` lets it run anything without asking. Claude Code's auto mode may refuse to launch a `full` worker. If it does,
  tell the user, and let the user decide (see the plugin's docs/SECURITY.md). Never work around that refusal.
Details: [reference/worker-capabilities.md](reference/worker-capabilities.md).

## 3. Isolate
For each task: `task-new.ps1 -Id <id>` creates `..\wt-<id>` on branch `task/<id>` from HEAD.
Write the prompt to `.claude\orchestrator\<id>.prompt.md` from `templates\TASK.prompt.template.md`
(anatomy: [reference/prompt-anatomy.md](reference/prompt-anatomy.md)). The prompt's `WORKSPACE:` is the worktree path,
the HANDOFF path is `<handoffDir>/HANDOFF_<id>.md` inside the worktree, and locked tests are pasted in full.

## 4. Dispatch
Only tasks of the current wave, at most `maxParallel` (default 3) at a time:
`adapters\<worker>.ps1 -Dispatch -TaskId <id> -PromptFile .claude\orchestrator\<id>.prompt.md -Workspace ..\wt-<id> -Title "<id> <title>" [-Model <m>] [-Agent <a>] [-Prefix "/<skill>"]`
Record `sessionId` in PLAN.md's status log. On `ok:false`, follow `hint`. Contract: [reference/adapter-contract.md](reference/adapter-contract.md).

**Hands-off mode:** `task-run.ps1` does sections 3 to 6 for one task: worktree, dispatch, watch, verify, then up to
`fixRoundsMax` automatic fix messages built from the verifier's findings and failing check output. It never merges.
Start it in the background:
`task-run.ps1 -Worker <w> -TaskId <id> -PromptFile .claude\orchestrator\<id>.prompt.md -Handoff <handoffDir>/HANDOFF_<id>.md -Allowed <globs> -Locked <globs> -Run "<cmd1>`n<cmd2>" [-Model ..] [-Agent ..] [-Prefix ..]`.
When it exits: verdict `verified` → read the diff and merge; `refuted` after the rounds → take over or reroute;
`no-handoff` → stall, timeout or worker exit (see section 5). Progress is in `logs\run-<id>.json`.
`-Cancel -SessionId <sid>` stops a process worker (OpenCode, agy, dsh). AG2 conversations are stopped in the app.

## 5. Watch
Start one background watcher per task (Claude Code: run it with `run_in_background`; its exit notifies you):
`watch-handoff.ps1 -Repo . -Branch task/<id> -Handoff <handoffDir>/HANDOFF_<id>.md -Worker <worker> -SessionId <sid> -StallMin 45`
Exit 0 = HANDOFF committed, then review. Exit 2 = stall: run `adapters\<worker>.ps1 -Status -SessionId <sid> -Tail 30`,
read the tail, write a short specific nudge file and send it with `-Message -SessionId <sid> -MessageFile <file>`,
then watch again. Exit 3 = timeout. Exit 4 = the worker process exited without a HANDOFF. For both 3 and 4: read the log and decide whether to redo, fix or take over.
AG2 `state` is inferred from the transcript's modification time, not reported by AG2. Treat it as a hint.

## 6. Review gate (never skip)
1. Verification contract: `verify-handoff.ps1 -Repo . -Branch task/<id> -Handoff <handoffDir>/HANDOFF_<id>.md -Allowed <globs> -Forbidden <globs> -Locked <globs> -Run "<cmd1>`n<cmd2>"`.
   Globs are comma-separated in one argument; commands go one per line (or `-RunFile`). The commands come from
   your PLAN, never from the HANDOFF. Only `verdict: verified` can pass. An edited locked file or a failing check
   refutes the task, whatever the HANDOFF says. Pick checks that this task alone can pass: tests of tasks that are
   not merged yet fail for reasons that are not the worker's fault.
2. Read the full diff yourself: `git diff <base>...task/<id>`.
3. Compare every number in the HANDOFF with the check output in `checks` (and the evidence file).
4. Usage: `-Status` reports `usage` (tokens; cost when the harness reports it). Note heavy runs in PLAN.md.
5. Walk the checklist in [reference/review-checklist.md](reference/review-checklist.md). Failures already seen in practice:
   - `DEVIATIONS: none` while the worker hit a real problem (a missing library API).
   - The commit SHA in the HANDOFF does not match `git log`.
   - Wrong tool/library versions reported.
   - A measurement script was used but never committed.
   - Every target was marked "met" although the HANDOFF's own numbers missed several.
6. Verdict: GO or FIX (list each defect with file, line and expected behaviour).
7. Optional **cross-harness review** for risky tasks: `task-new -Id <id>-review -Base task/<id>`, then dispatch
   `templates\REVIEW.prompt.template.md` to a worker from a **different model family** than the implementer.
   It writes only `REVIEW_<id>.md`. Read it next to your own review; disagreements are where bugs hide.
8. Optional **race** for critical or uncertain tasks: the same prompt to two workers (`<id>a`, `<id>b`, separate
   worktrees). Keep the first `verified` one, `-Cancel` the other and `task-cleanup -Discard` it.

## 7. Merge or fix
- GO: `task-cleanup.ps1 -Id <id> -Merge` (merges with --no-ff, removes the worktree, deletes the branch). Update PLAN.md.
  When the wave is merged, run the full suite on the base branch, then start the next wave.
- FIX: write `<id>-fix<n>.prompt.md` with only the concrete defects and the same rules, then send it with `-Message`
  (same session) or `-Dispatch` on the same worktree. At most `fixRoundsMax` (default 2) rounds. After that, fix it
  yourself in the worktree or reroute it to another worker. Never merge a failing gate.
- Abandon: `task-cleanup.ps1 -Id <id> -Discard`.

## 8. Fallback (AG2 not running, or `signature changed`)
Do not guess at the API. Print the prompt path and the one-line kickoff text for the user to paste into AG2 by hand:
`Workspace: <worktree>. Read the file '<prompt path>' and follow its instructions exactly. It contains your rules, your single task and the HANDOFF format.`
Everything else stays the same: worktree, HANDOFF, watcher, review gate. See the plugin's `docs/TROUBLESHOOTING.md`.

## Security rules
- Never print, paste or store tokens, raw AG2 metadata or git remote URLs. Adapters redact. Do not bypass them by
  reading AG2 process command lines or `~/.gemini` files yourself.
- Never widen the allow rules; one exact script path per rule. Details: [reference/ag2-internals.md](reference/ag2-internals.md).
