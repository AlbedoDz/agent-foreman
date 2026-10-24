# Routing workers

These defaults come from `routing` in `orchestrator.config.json`. The user's config always wins.

| Kind of work | Default | Why |
|---|---|---|
| UI, styling, wiring screens | `ag2:flash` | AG2 has a browser and screenshots, and flash is fast enough |
| Read-heavy exploration, inventories | `ag2:flash` | large context, cheap |
| Writing tests against a given interface | `ag2:flash` | mechanical |
| Hard spike, measurement, unclear design | `ag2:pro` | needs reasoning and long autonomous runs |
| Scoped logic or refactor in a few files | `opencode` | tight loop, any provider/model |
| Interface contracts shared by tasks | Claude | they gate parallel work, so write them before the wave |
| Review, merge, conflict resolution | Claude | never delegated |

Rules of thumb:
- Do not run parallel tasks that touch the same files. Serialize them or merge the tasks.
- A task a worker failed twice goes to a stronger model, another worker, or you.
- Measurement and benchmark tasks: demand raw output in the HANDOFF and the committed harness script.
- Keep tasks small enough for one HANDOFF (about one day of human work at most).
