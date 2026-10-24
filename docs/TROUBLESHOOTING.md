# Troubleshooting

Every script prints `{"ok":false,"error":...,"hint":...}` on failure. Start with the hint.

## AG2

| Symptom | Cause / fix |
|---|---|
| `Antigravity 2 is not running` | Open the AG2 desktop app and wait for the agent hub. The older "Antigravity IDE" is a different product; its `chat` CLI exited 0 but did not run tasks in our tests. |
| `not listening on any 127.0.0.1 port` | The hub is still starting, or it crashed. Restart AG2. |
| `AG2 needs a project id` / `project_id is required` | Open your repository folder as a project in AG2 and start any conversation. Run `ag2.ps1 -FindProjectId` (lists recent sessions), then `ag2.ps1 -FindProjectId -SessionId <id>`, and put the value in `workers.ag2.projectId`. |
| `failed on every port ... Unauthenticated` | The token changed (AG2 restarted between calls). Retry. |
| Task dispatched, nothing happens | In the AG2 window, the agent may be waiting for you to approve a command. `-Status` cannot see that (`state` is only inferred from transcript writes). |
| Watcher reports `stall` | Run `ag2.ps1 -Status -SessionId <id> -Tail 30`, then send a short nudge with `-Message`. In one real case a spike stalled for about 1.5 h because its own measuring script hung. Prompts must demand timeouts. |

### api-changed

`AG2 agentapi signature changed; refusing to run.` means `agentapi --help` no longer contains the three command
signatures this adapter was written against (see `docs/HOW-IT-WORKS.md`). The adapter stops instead of guessing.

1. Meanwhile, keep working by hand: paste the kickoff line into AG2 yourself.
   `Workspace: <worktree>. Read the file '<prompt>' and follow its instructions exactly. It contains your rules, your single task and the HANDOFF format.`
   Worktrees, HANDOFFs, watcher and review all still work.
2. Look at the new help: `& "$env:USERPROFILE\.gemini\antigravity\bin\agentapi.bat" --help`
3. If only new commands were added, the adapter keeps working. If an existing signature changed, update
   `$KnownAgentApiSignature` and the call sites in `scripts/adapters/ag2.ps1`, then the mocks in
   `tests/Ag2Adapter.Tests.ps1`, and open a PR.

Other internals that may change without notice: the env variable names, the `--subclient_type hub` and `--csrf_token`
flags, and the `brain/<id>/.system_generated/logs/transcript.jsonl` layout.

## OpenCode

| Symptom | Fix |
|---|---|
| `provider.auth ... requires a credential` | The default model's provider has no key. Run `opencode auth login`, or pass `-Model provider/model` for a provider in `opencode auth list`, or set `workers.opencode.defaultModel`. |
| `opencode exited before starting a session` | Run `opencode run --format json "hello"` in the worktree by hand to see the error. |
| Worker exits without a HANDOFF (watcher exit 4) | Usually a refused permission. See SECURITY.md about `autoApprove`, then check `logs/<task>.opencode.jsonl`. |

## Git / worktrees

| Symptom | Fix |
|---|---|
| `Worktree path already exists` | A previous run was not cleaned up. Use `task-cleanup.ps1 -Id <id> -Merge` or `-Discard`. |
| `has uncommitted changes` on cleanup | On purpose: nothing is ever force-deleted. Commit or remove the changes yourself. |
| Merge failed | The merge was aborted and nothing changed. Rebase the task branch, or send a fix prompt. |

## Claude Code permissions

If dispatch keeps asking for approval, or auto mode blocks it: the command must match an allow rule **exactly**.
That means `pwsh -NoProfile -File .claude\orchestrator\bin\...` run from the project root, with no `&&` chains. Re-run the installer and
check `.claude/settings.local.json`. See SECURITY.md.
