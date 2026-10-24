---
description: Check that the orchestration workers (Antigravity 2, OpenCode, configured CLIs) are reachable and configured.
argument-hint: "[worker]"
disable-model-invocation: true
---

Check the orchestration workers for this project.

1. If `.claude\orchestrator\bin` does not exist, stop and tell the user to run `/ag2-orchestrator:orchestrator-install`.
2. Read `.claude\orchestrator\orchestrator.config.json` and list the enabled workers. If an argument is given, check only that worker: `$ARGUMENTS`.
3. For each worker, run from the project root (exact form, one call per worker):
   - AG2: `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -Check`
   - OpenCode: `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\opencode.ps1 -Check`
   - generic CLI `<name>`: `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\generic-cli.ps1 -Worker <name> -Check`
4. Report one line per worker: OK/FAIL, `detail` or `error`, and the `hint` when it failed.
   If AG2 has no `projectId`, explain `ag2.ps1 -FindProjectId`: open the folder as an AG2 project, start any conversation, run it, and put the id in the config.

Never print anything the scripts did not print. Do not read AG2 process command lines or `~/.gemini` files yourself.
