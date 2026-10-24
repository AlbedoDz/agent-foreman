# PLAN: <feature>

Goal: <one sentence>. Base branch: `main`. Handoffs: `docs/handoffs/`.
Interface contracts written by the Tech Lead before wave 1: <files / signatures, or "none">.

## Wave 1 (no dependencies; run in parallel, max `maxParallel`)

| id | title | worker | depends_on | allowed files | forbidden | test command | done when |
|----|-------|--------|------------|---------------|-----------|--------------|-----------|
| T1 | <title> | ag2:flash | - | `src/a/*`, `tests/test_a.py` | `tests/locked_*` | `pytest tests/test_a.py` | <measurable> |
| T2 | <title> | opencode | - | `src/b.py` | - | `pytest tests/test_b.py` | <measurable> |

## Wave 2 (starts when every task it depends on is merged)

| id | title | worker | depends_on | allowed files | forbidden | test command | done when |
|----|-------|--------|------------|---------------|-----------|--------------|-----------|
| T3 | <title> | ag2:pro | T1, T2 | `src/c/*` | `src/a/*` | `pytest` | <measurable> |

## Status log

| id | dispatched | session | handoff | review | merged |
|----|------------|---------|---------|--------|--------|
| T1 | | | | | |
