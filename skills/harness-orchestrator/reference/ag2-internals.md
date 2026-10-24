# How the AG2 adapter talks to Antigravity 2 (and why it can break)

Antigravity 2 ships a CLI, `%USERPROFILE%\.gemini\antigravity\bin\agentapi.bat`. It wraps `language_server.exe agentapi`.
Its `--help` (verified 2026-10) lists exactly:
```
get-conversation-metadata <conversation_id>
new-conversation [--model=<flash_lite|flash|pro>] [--title=<title>] [--profile=<profile>] <prompt>
send-message [--title=<title>] <recipient_id> <content>
```
It needs three environment variables:
- `ANTIGRAVITY_LS_ADDRESS`: `127.0.0.1:<port>` of the running hub (ports are dynamic; one of them answers with
  "error reading server preface", so each port is tried in turn).
- `ANTIGRAVITY_CSRF_TOKEN`: taken from the command line of the hub process
  (`language_server.exe --subclient_type hub ... --csrf_token <value>`), owned by the same Windows user.
- `ANTIGRAVITY_PROJECT_ID`: the AG2 project bound to the repository folder (`workers.ag2.projectId`).

Limits (all observed):
- `new-conversation` returns only the conversationId. AG2 never reports completion; the HANDOFF commit is the only signal.
- `get-conversation-metadata` has no running/idle field, and it includes `gitOriginUrl`, which can contain a token.
  The adapter drops every `*url*`/`*token*` key.
- Running/idle is inferred from `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl` mtime.
- None of this is a public, documented API. An AG2 update can change the variables, the flags or the help text.
  The adapter then refuses to run (`signature changed`). Fall back to pasting the prompt by hand.
- Claude Code's auto mode may block scripts that read another process's credentials. The installer adds one allow rule
  per script path. Do not replace them with wildcards.
