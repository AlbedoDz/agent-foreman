# Adding a harness

Any coding agent with a headless CLI can be a worker. It must be able to: start from a prompt, work in a given folder,
and run `git commit`. The protocol is the same for every worker: a prompt file, a worktree, and a HANDOFF in the last commit.

## Shipped presets

The template config already contains two `generic-cli` workers (disabled by default). To turn them on, set `"enabled": true`
in your `orchestrator.config.json` (copy them from `.claude/orchestrator/templates/orchestrator.config.json` if your
config is older), then re-run the installer with `-Workers ag2,opencode,agy,dsh`.

| Worker | Harness | Headless call | Session id | Resume |
|---|---|---|---|---|
| `agy` | Antigravity CLI (`agy`, separate from the AG2 desktop hub) | `agy --print <msg> --output-format stream-json --model <m> --mode accept-edits` | `conversation_id` of the first (`init`) event | `--conversation <id>` |
| `dsh` | DeepSeek Harness (`dsh.cmd` inside the app install) | `dsh headless --json <msg>` | `sessionId` of the first (`session`) event | `--session-id <id>` |

- `agy`: list models with `agy models`. `--mode accept-edits` lets the worker edit files without prompting.
- `dsh`: the headless profile needs a model credential. Add your DeepSeek API key in the DeepSeek Harness app
  (Models page), or set `DEEPSEEK_API_KEY` in the environment Claude Code runs in. Never put a key in the config.
  Without a key, `-Dispatch` fails within seconds with `MISSING_CREDENTIAL` and this hint.

## Option 1: config only (generic-cli adapter)

Add an entry under `workers` in `.claude/orchestrator/orchestrator.config.json`:

```json
"mytool": {
  "adapter": "generic-cli",
  "enabled": true,
  "defaultModel": "some-model",
  "check":    ["mytool", "--version"],
  "dispatch": ["mytool", "exec", "--model", "{model}", "{message}"],
  "message":  ["mytool", "exec", "--resume", "{sessionId}", "--model", "{model}", "{messageText}"],
  "sessionIdPattern": "\"session_id\"\\s*:\\s*\"([^\"]+)\"",
  "errorPattern": "AUTH_ERROR[^\\r\\n]*",
  "errorHint": "Sign in to mytool first: mytool login"
}
```

- Commands are **argument arrays**, so no shell quoting is involved. The first element is the executable.
- Placeholders: `{taskId} {prompt} {workspace} {title} {model} {message} {sessionId} {messageFile} {messageText}`.
  `{message}` is the standard kickoff line (`Workspace: ... Read the file '...' and follow its instructions exactly ...`).
- `%ENV%` variables are expanded, e.g. `%LOCALAPPDATA%\Programs\Tool\tool.cmd` for a CLI that is not on PATH.
- An element whose placeholders all expand to an empty value is dropped, together with the flag right before it. So
  `"--model", "{model}"` disappears when no model is set.
- The process starts in the background with the worktree as working directory. stdout goes to `logs/<task>.mytool.log`.
- `sessionIdPattern`: a regex with one group, matched against stdout for up to `-WaitSeconds` (default 60). Without it,
  the session id is `pid:<n>`. If the process exits before a match appears, the dispatch fails with the stderr tail.
- `errorPattern` (optional): a regex checked against stdout and stderr while waiting. A match fails the call at once
  with `errorHint`.
- Status = whether the process is still alive. `-Message` reuses the dispatch model, and refuses while the session's
  process is still running.

Then re-run the installer with `-Workers ag2,mytool` so the allow rule for `generic-cli.ps1` is added, and check the
worker with `generic-cli.ps1 -Worker mytool -Check`.

## Option 2: a dedicated adapter

Copy `scripts/adapters/opencode.ps1` (process-based) or `ag2.ps1` (API-based) and keep the contract in
`skills/harness-orchestrator/reference/adapter-contract.md`:

- same switches: `-Check`, `-Dispatch -TaskId -PromptFile -Workspace -Title -Model`, `-Status -SessionId`, `-Message -SessionId -MessageFile`;
- dot-source `../lib/Common.ps1`; build the result as an ordered hashtable; end with
  `Complete-Script -Worker '<name>' -Body { ... }`, so stdout is one redacted JSON line and the exit code matches `ok`;
- errors: `New-AdapterError '<what failed>' '<concrete fix>'`;
- wrap every external call in one small function (like `Invoke-AgentApi`) so the Pester tests can mock it;
- `$MyInvocation.InvocationName -ne '.'` guard, so tests can dot-source the script;
- tests in `tests/<Name>Adapter.Tests.ps1`: no real harness needed.

Add the adapter name to `$known` in `scripts/install.ps1` and a row to the routing table in the skill.
