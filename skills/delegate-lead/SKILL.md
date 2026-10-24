---
description: Hand the Tech Lead role for one goal to another harness and model (e.g. Antigravity 2 desktop leading OpenCode workers, or OpenCode / Antigravity CLI / Codex leading). Claude Code stays the default lead and reviews the result.
argument-hint: "<lead harness[:model]> <goal>   e.g.  ag2:pro \"add CSV export\""
disable-model-invocation: true
---

Delegate the lead for one goal. Lead harness: `$0`. Goal: everything after the first argument in `$ARGUMENTS`.
Claude Code (you) stays the default lead: you set this up, then review what the delegated lead merged.

1. Split `$0` at the first `:` into harness and model. Allowed leads: `ag2` (Antigravity 2 desktop), `agy` (Antigravity CLI),
   `opencode`, `codex` (OpenAI Codex CLI from the ChatGPT/Codex desktop app). Ask the user if it is anything else.
2. Make sure the lead has the protocol:
   `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/install.ps1" -Project . -Lead <harness> -SkipCheck`
   (this creates `.agents/skills/agent-foreman-lead`; for OpenCode it also registers the MCP server; for Codex/agy/AG2 it prints the
   global MCP command for the user. Without MCP the lead uses the scripts through its shell).
3. Pick a lead id `LEAD<n>`. Write `.claude\orchestrator\LEAD<n>.prompt.md` from `.claude\orchestrator\templates\LEAD.prompt.template.md`:
   PROJECT_ROOT = this folder, GOAL = the goal, WORKERS = enabled workers except the lead itself, MAX_PARALLEL and FIX_ROUNDS
   from the config.
4. Dispatch it to the lead harness with the **project root** as workspace (not a worktree):
   `pwsh -NoProfile -File .claude\orchestrator\bin\adapters\<adapter>.ps1 [-Worker <name>] -Dispatch -TaskId LEAD<n> -PromptFile .claude\orchestrator\LEAD<n>.prompt.md -Workspace . -Title "LEAD<n> <goal>" [-Model <model>]`
5. Watch for `docs/handoffs/LEAD_REPORT_LEAD<n>.md` on the current branch (`watch-handoff.ps1 -Branch <current branch> -Handoff ...`
   in the background; long timeout).
6. When the report arrives: check each task it claims, using its evidence files and `git log` (`verify-handoff` evidence,
   merge commits), and run the full test suite yourself. Report to the user what the delegated lead did and anything you disagree with.
Note: an Antigravity 2 desktop lead may need the user to approve shell commands in the Antigravity 2 window.
