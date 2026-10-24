# How it works

## The loop

```
Claude Code (Tech Lead)                                        Workers
  plan waves → PLAN.md
  task-new.ps1        → ../wt-<id> on task/<id>
  write <id>.prompt.md
  adapters/<w>.ps1 -Dispatch ───────────────────────────────▶  AG2 conversation / opencode run / your CLI
  watch-handoff.ps1 (background) ◀── polls git for ──────────  edits, tests, commits on task/<id>,
                                       HANDOFF_<id>.md          HANDOFF_<id>.md in the last commit
  verify-handoff.ps1 + read diff + re-run tests
  GO  → task-cleanup.ps1 -Merge
  FIX → -Message / new prompt (max 2 rounds) → watch again
```

Workers never report back over an API. The **only** completion signal is a commit that contains the HANDOFF file.
That makes every worker interchangeable: anything that can edit files and run `git commit` in a folder can be a worker.

## Why Claude Code can drive Antigravity 2

Antigravity 2 (the desktop app, not the older Antigravity IDE) runs an agent hub process:
`language_server.exe --subclient_type hub ... --csrf_token <token>`. It listens on dynamic 127.0.0.1 ports.

AG2 also installs a small CLI, `%USERPROFILE%\.gemini\antigravity\bin\agentapi.bat`, which runs
`language_server.exe agentapi <command>`. Its help text lists three commands:

```
get-conversation-metadata <conversation_id>
new-conversation [--model=<flash_lite|flash|pro>] [--title=<title>] [--profile=<profile>] <prompt>
send-message [--title=<title>] <recipient_id> <content>
```

`agentapi` reads three environment variables. Their names were found in the binary and confirmed by its error messages:

| Variable | Value | Error when missing |
|---|---|---|
| `ANTIGRAVITY_LS_ADDRESS` | `127.0.0.1:<port>` of the hub | `ANTIGRAVITY_LS_ADDRESS is not set` |
| `ANTIGRAVITY_CSRF_TOKEN` | the hub's `--csrf_token` argument | `missing CSRF token` (Unauthenticated) |
| `ANTIGRAVITY_PROJECT_ID` | the AG2 project bound to your repo folder | `project_id is required when providing project_env_config` |

`adapters/ag2.ps1` finds the hub process and copies the token into its **own** environment. It then tries each loopback
port (in practice one port is the agent API and another answers `error reading server preface`) and calls
`agentapi`. `new-conversation` returns a `conversationId`. The prompt itself is never sent inline: the kickoff
message tells the agent which workspace to use and which prompt file to read.

What AG2 does **not** give you, and how the plugin works around it:
- No completion callback, and no answer text: watch git for the HANDOFF commit.
- No running/idle state: infer it from the modification time of
  `~/.gemini/antigravity/brain/<conversationId>/.system_generated/logs/transcript.jsonl`.
  This is an inference, not an API. AG2 may also be waiting for the user to approve a command.
- The real model name behind `flash` / `pro` is not exposed (only internal placeholder codes). It is unverified.

## OpenCode

`opencode run --format json` prints one JSON event per line, and each event carries `sessionID`. Errors arrive as
`{"type":"error","error":{"type":"provider.auth",...}}`. There is no `--dir` flag, so the adapter starts the process
with the worktree as working directory, in the background, with stdout going to `logs/<task>.opencode.jsonl`.
`--session <id>` continues a session. Permission prompts cannot be answered headless; see SECURITY.md about `--auto`.

## Isolation

Each task gets `git worktree add ../wt-<id> -b task/<id>`. Parallel workers therefore never share a working tree or a
branch. Sharing them was the main source of conflicts before this design: spikes had to run one after another.
Two tasks in the same wave must still not edit the same files. The plan enforces this; git cannot.

## What was verified, and how

See CHANGELOG.md. The Pester suite mocks processes and `agentapi` and uses real temporary git repos. The smoke test ran
the full loop against a real AG2 on Windows 11.
