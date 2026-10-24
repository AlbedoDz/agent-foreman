# Adding a harness

Any coding agent with a headless CLI can be a worker. It must be able to: start from a prompt, work in a given folder,
and run `git commit`. The protocol is the same for every worker: a prompt file, a worktree, and a HANDOFF in the last commit.

## Option 1: config only (generic-cli adapter)

Add an entry under `workers` in `.claude/orchestrator/orchestrator.config.json`:

```json
"mytool": {
  "adapter": "generic-cli",
  "enabled": true,
  "defaultModel": "some-model",
  "check":    ["mytool", "--version"],
  "dispatch": ["mytool", "exec", "--model", "{model}", "{message}"],
  "message":  ["mytool", "exec", "--resume", "{sessionId}", "{messageText}"],
  "sessionIdPattern": "\"session_id\"\\s*:\\s*\"([^\"]+)\""
}
```

- Commands are **argument arrays**, so no shell quoting is involved. The first element is the executable.
- Placeholders: `{taskId} {prompt} {workspace} {title} {model} {message} {sessionId} {messageFile} {messageText}`.
  `{message}` is the standard kickoff line (`Workspace: ... Read the file '...' and follow its instructions exactly ...`).
- The process starts in the background with the worktree as working directory. stdout goes to `logs/<task>.mytool.log`.
- `sessionIdPattern`: a regex with one group, matched against stdout for up to 20 s. Without it, the session id is `pid:<n>`.
- Status = whether the process is still alive.

Then re-run the installer with `-Workers ag2,mytool` so the allow rule for `generic-cli.ps1` is added, and check the
worker with `generic-cli.ps1 -Worker mytool -Check`.

The generic adapter is unit-tested with mocks only. It has **not** been tried against a real third-party harness yet.

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
