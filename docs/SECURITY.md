# Security

Read this before installing. This plugin makes Claude Code start autonomous coding agents on your machine. One of its
scripts also reads a credential that belongs to another program.

## What the AG2 adapter does with credentials

`adapters/ag2.ps1` reads the command line of the running Antigravity 2 hub process
(`language_server.exe --subclient_type hub`). That process belongs to **your own Windows user**. The script extracts its
`--csrf_token` value. This token lets any local program that holds it drive your AG2 agents through the loopback API.

What the script does with it:
- puts it in the `ANTIGRAVITY_CSRF_TOKEN` environment variable of **its own process only**, then calls `agentapi`;
- never writes it to disk, never logs it, never prints it, never sends it anywhere but 127.0.0.1;
- passes every line of output through `Protect-Secret`, which redacts the literal token value, `--csrf_token X`,
  `ghp_…`, `gho_…`, `github_pat_…`, URLs carrying credentials (`user:pass@` or `token@` after the scheme), and the
  `gitOriginUrl` field.

Other secrets this design can expose, and the countermeasures:
- **`gitOriginUrl` in AG2 metadata.** AG2 returns your `origin` URL. If that URL embeds a GitHub token, the token leaks
  into any output that shows the metadata. `-Status` drops every metadata key containing `url`, `token`, `secret` or
  `credential`. `install.ps1` warns when `git remote -v` contains credentials. Fix it properly: use a credential helper
  and revoke the embedded token.
- **Transcript tails** (`-Status -Tail N`) are redacted too. Still, treat them as private.
- **Prompts and logs** stay local: `*.prompt.md`, `logs/`, the local config and `settings.local.json` are git-ignored
  by the installer.

## Why Claude Code's auto mode blocks this, and the minimal allow rules

Reading another process's credentials and launching autonomous agents are exactly what a safety classifier should
stop. In practice, auto mode blocked the first attempts. One block was labelled "Credential Exploration" (calling
`agentapi` with a token taken from a process). Another was labelled "Create Unsafe Agents" (writing the dispatch script).

A plugin cannot ship permission rules (Claude Code only honours `agent` and `subagentStatusLine` from plugin settings).
`install.ps1` therefore adds rules to **your project's** `.claude/settings.local.json`. That file is local and
git-ignored, so its allow rules apply without a folder-trust step. The installer adds one rule per script, with the exact
relative path and no broad wildcard:

```json
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\adapters\\ag2.ps1:*)",
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\adapters\\opencode.ps1:*)",
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\task-new.ps1:*)",
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\task-cleanup.ps1:*)",
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\watch-handoff.ps1:*)",
"PowerShell(pwsh -NoProfile -File .claude\\orchestrator\\bin\\verify-handoff.ps1:*)"
```

`:*` allows any arguments after that exact script path. Do **not** replace these rules with `PowerShell(pwsh *)` or
`PowerShell(*)`. Those would let any script run unprompted. Claude Code checks each part of a compound command
(`a && b`) separately, so these rules do not cover chained commands. Deny rules always win over allow rules.

The scripts sit inside your project (`.claude/orchestrator/bin/`). Anyone who can write to that folder can change what
an allowed rule runs. Review changes to it like any other code, and re-run the installer to restore the plugin's
version.

## Autonomous workers

- **AG2** agents run commands on your machine with AG2's own approval settings. This plugin does not change them.
- **OpenCode** run headless cannot answer permission prompts. `workers.opencode.autoApprove: true` adds `--auto`
  ("auto-approve permissions that are not explicitly denied"). Only enable it with an OpenCode permission config
  that denies what you never want (pushes, deletes outside the worktree, network tools), and only on repositories you
  can afford to reset.
- Workers are told never to push. The scripts never push or force anything, and they refuse to delete dirty worktrees.

## Before publishing a fork

Run `pwsh -NoProfile -File scripts/secret-scan.ps1` (tracked files) and `-History`. Put your own user name,
project ids and private repo names in a git-ignored `.secret-denylist` (one per line) or in `AG2O_DENYLIST`. Install the
pre-commit hook: `.git/hooks/pre-commit` → `exec pwsh -NoProfile -File scripts/secret-scan.ps1 -Staged`.
`gitleaks` is used as well when it is on PATH.
