# Using each worker's own models, agents, skills and plugins

`-Capabilities` (every adapter) returns what a harness can use, from `workers.<w>.capabilities` in the config:

| Worker | models | agents | skills | plugins / MCP |
|---|---|---|---|---|
| `ag2` (desktop) | `flash_lite`, `flash`, `pro` (fixed by agentapi) | none (name skills in the prompt or use `-Prefix`) | `~/.gemini/antigravity/skills`, `builtin/skills`, shared `~/.gemini` skills and plugin skills | managed in the AG2 app |
| `opencode` | `opencode models` | `build`, `plan` (+ your config agents) | `~/.config/opencode/skills` | `opencode mcp list` |
| `agy` | `agy models` | `agy agents` | `~/.gemini/antigravity-cli/builtin/skills` + shared `~/.gemini` skills | `agy plugin list`, `agy mcp list` |
| `dsh` | profile default (set in the DeepSeek Harness app) | — | — | — |

Skill lists come from the folders on disk. Whether a harness loads a given folder depends on that harness and its
config: treat the list as "installed", and the harness as the judge of "enabled".

## Choosing per task

| Need | Do |
|---|---|
| A specific model | `-Model <id from the list>` (AG2: `flash_lite` / `flash` / `pro`; OpenCode: `provider/model`; agy: e.g. `gemini-3.8-flash-medium`) |
| A built-in agent/persona | `-Agent <name>` (OpenCode, agy) |
| A skill or slash command | `-Prefix "/<skill-name>"`. The kickoff line then starts with it, so the harness expands it before the task (verified with agy print mode). In the prompt, also say why the skill applies. |
| An `@agent` mention | `-Prefix "@<agent>"` where the harness supports mentions |
| MCP tools / plugins | name them in the TASK section ("use the codegraph MCP to list callers of X") |

## Permission levels (`workers.<w>.permissions`)

| Level | agy | OpenCode | Meaning |
|---|---|---|---|
| `default` | no flag | no flag | the harness's own rules; headless runs cannot answer prompts, so anything that asks is denied |
| `edits` | `--mode accept-edits` | (OpenCode default rules) | edits inside the worktree are allowed |
| `full` | `--dangerously-skip-permissions` | `--auto` | everything is allowed without asking |

`-Dispatch` also passes `--add-dir <prompt folder>` to agy, so the worker can read its prompt file outside the worktree.
Without it, agy auto-denied `read_file` in headless mode and "succeeded" without doing anything (seen live; the adapter now reports that as an error).

Seen live with agy at `edits`: shell commands (`git status`, `python -m unittest`) are auto-denied in headless mode,
so the worker reads and edits but cannot test or commit. A `.agents/settings.json` allow rule inside the workspace
was not honored. Either use agy's global allow rules (`command(<prefix>)`) or `full`.

`full` is for disposable worktrees only. Claude Code's auto mode classifies launching a `full` worker as creating an
unsafe agent and refuses it. That is expected. The user can approve such a run themselves (run it in their terminal, or
add their own allow rule), or keep `edits` and accept that the worker may stop at commands that need approval.
