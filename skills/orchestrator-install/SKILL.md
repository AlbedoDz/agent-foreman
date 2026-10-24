---
description: Install or update agent-foreman in the current project (scripts, templates, config, minimal allow rules, gitignore).
argument-hint: "[ag2,opencode]"
disable-model-invocation: true
---

Install agent-foreman into the current project.

1. Do a dry run first, from the project root:
   `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/install.ps1" -Project . -Workers <workers> -WhatIf`
   `<workers>` is `$ARGUMENTS`, or `ag2,opencode` when no argument is given.
2. Show the user the planned actions, especially the allow rules added to `.claude/settings.local.json`, and ask them to confirm.
3. Run the same command without `-WhatIf`.
4. Report the `actions`, the `warnings` (for example, a git remote with embedded credentials: tell the user to rotate that token), the `checks` per worker, and the `todo` list.
5. Point the user to `${CLAUDE_PLUGIN_ROOT}/docs/SECURITY.md`, which explains what the AG2 adapter does with the AG2 CSRF token.
