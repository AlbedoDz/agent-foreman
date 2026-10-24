---
description: Dispatch one orchestration task to a worker in its own git worktree, then start the HANDOFF watcher.
argument-hint: "<taskId> <ag2[:flash_lite|flash|pro] | opencode[:provider/model] | cli-worker> [title]"
disable-model-invocation: true
---

Dispatch task `$0` to worker `$1`. Full arguments: `$ARGUMENTS`.
Follow the ag2-orchestrator:harness-orchestrator skill, sections 3 to 5.

1. Find task `$0` in `.claude\orchestrator\PLAN.md` (allowed/forbidden files, test command, done-when). If it is missing, ask the user for these before continuing.
2. If `..\wt-$0` does not exist yet: `pwsh -NoProfile -File .claude\orchestrator\bin\task-new.ps1 -Id $0`.
3. If `.claude\orchestrator\$0.prompt.md` does not exist, write it from `.claude\orchestrator\templates\TASK.prompt.template.md`. Fill in every `{{...}}`, with WORKSPACE = the worktree path. Show it to the user if anything was guessed.
4. Split `$1` at the first `:` into worker and model, then run:
   `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\<worker>.ps1 -Dispatch -TaskId $0 -PromptFile .claude\orchestrator\$0.prompt.md -Workspace ..\wt-$0 -Title "<title>" [-Model <model>]`
   For a generic CLI worker, use `generic-cli.ps1 -Worker <worker>`.
5. On `ok:false`, show `error` and `hint`. If AG2 is down or its API changed, use the manual paste fallback (skill section 8).
6. Record the sessionId in PLAN.md's status log. Start the watcher in the background:
   `pwsh -NoProfile -File .claude\orchestrator\bin\watch-handoff.ps1 -Repo . -Branch task/$0 -Handoff <handoffDir>/HANDOFF_$0.md -Worker <worker> -SessionId <sessionId> -StallMin <stallMin>`
