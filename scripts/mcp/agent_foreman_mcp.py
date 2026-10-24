"""agent-foreman MCP server: lets ANY MCP-capable harness (OpenCode, Antigravity, Claude Code, ...) act as the lead
and drive workers in other harnesses through the same PowerShell scripts the Claude Code plugin uses.

Standard library only. Transport: MCP stdio (newline-delimited JSON-RPC 2.0).
Each tool runs one script from .claude/orchestrator/bin and returns its one-line JSON result unchanged
(already redacted by the scripts). Never put tokens or secrets in tool arguments.

Run from the project root:   python .claude/orchestrator/bin/mcp/agent_foreman_mcp.py
Environment: AG2O_PROJECT (project root, default: cwd), AG2O_PWSH (default: pwsh).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

SERVER_NAME = "agent-foreman"
SERVER_VERSION = "0.3.0"
BIN = Path(__file__).resolve().parent.parent  # .claude/orchestrator/bin
PROJECT = Path(os.environ.get("AG2O_PROJECT") or os.getcwd()).resolve()
PWSH = os.environ.get("AG2O_PWSH", "pwsh")
ORCH = PROJECT / ".claude" / "orchestrator"


def _str(desc: str) -> dict[str, Any]:
    return {"type": "string", "description": desc}


def _arr(desc: str) -> dict[str, Any]:
    return {"type": "array", "items": {"type": "string"}, "description": desc}


def _schema(props: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {"type": "object", "properties": props, "required": required, "additionalProperties": False}


WORKER = _str("Worker name from orchestrator.config.json, e.g. ag2, opencode, agy, dsh")
TOOLS: list[dict[str, Any]] = [
    {"name": "workers_list", "description": "List configured workers (name, adapter, enabled, default model, permission level).",
     "inputSchema": _schema({}, [])},
    {"name": "worker_check", "description": "Check that a worker harness is installed and reachable.",
     "inputSchema": _schema({"worker": WORKER}, ["worker"])},
    {"name": "worker_capabilities", "description": "List a worker's models, agents, skills, plugins and MCP servers, to pick -model/-agent/-prefix per task.",
     "inputSchema": _schema({"worker": WORKER}, ["worker"])},
    {"name": "task_new", "description": "Create an isolated git worktree ../wt-<task_id> on branch task/<task_id>.",
     "inputSchema": _schema({"task_id": _str("Task id: letters, digits, . _ -"), "base": _str("Base revision (default HEAD)")}, ["task_id"])},
    {"name": "dispatch", "description": "Start a task on a worker. The prompt file must already exist (write it from templates/TASK.prompt.template.md).",
     "inputSchema": _schema({
         "worker": WORKER, "task_id": _str("Task id"), "prompt_file": _str("Prompt file, relative to the project root"),
         "workspace": _str("Worktree path (default ../wt-<task_id>)"), "title": _str("Session title"),
         "model": _str("Model id from worker_capabilities"), "agent": _str("Agent name (OpenCode/agy)"),
         "prefix": _str("Text put before the kickoff line, e.g. '/test-driven-development' or '@reviewer'")},
         ["worker", "task_id", "prompt_file"])},
    {"name": "task_status", "description": "State of a dispatched session: running | idle | unknown, last activity (AG2: inferred from transcript time).",
     "inputSchema": _schema({"worker": WORKER, "session_id": _str("sessionId from dispatch"),
                             "tail": {"type": "integer", "description": "AG2 only: last N transcript lines"}}, ["worker", "session_id"])},
    {"name": "handoff_check", "description": "Has the worker committed its HANDOFF on task/<task_id> yet? Quick, non-blocking; poll it.",
     "inputSchema": _schema({"task_id": _str("Task id"), "handoff": _str("HANDOFF path in the repo, e.g. docs/handoffs/HANDOFF_T1.md")}, ["task_id", "handoff"])},
    {"name": "task_message", "description": "Send a follow-up message (nudge or fix request) to a worker session.",
     "inputSchema": _schema({"worker": WORKER, "session_id": _str("sessionId"), "task_id": _str("Task id (names the message file)"),
                             "text": _str("Message text"), "prefix": _str("Optional /skill or @agent prefix")},
                            ["worker", "session_id", "task_id", "text"])},
    {"name": "task_cancel", "description": "Stop a running process-based task (OpenCode, agy, dsh, ...). AG2 desktop tasks are stopped in the app.",
     "inputSchema": _schema({"worker": WORKER, "session_id": _str("sessionId")}, ["worker", "session_id"])},
    {"name": "verify_handoff", "description": "Review gate: check the HANDOFF against git and run the plan's checks (verification contract). Never trust a HANDOFF without it.",
     "inputSchema": _schema({"task_id": _str("Task id"), "handoff": _str("HANDOFF path"), "base": _str("Base revision (default merge-base)"),
                             "allowed": _arr("Globs the task may change"), "forbidden": _arr("Globs it must not change"),
                             "locked": _arr("Globs of checks that must stay byte-identical (locked tests)"),
                             "run": _arr("Check commands from the PLAN, run in the worktree; exit codes decide")},
                            ["task_id", "handoff"])},
    {"name": "task_cleanup", "description": "Finish a task: mode 'merge' (merge --no-ff into the current branch) or 'discard'; removes the worktree and branch. Refuses dirty worktrees.",
     "inputSchema": _schema({"task_id": _str("Task id"), "mode": {"type": "string", "enum": ["merge", "discard"]}}, ["task_id", "mode"])},
]


def _config() -> dict[str, Any]:
    p = ORCH / "orchestrator.config.json"
    return json.loads(p.read_text(encoding="utf-8-sig")) if p.exists() else {}


def _adapter(worker: str) -> tuple[Path, list[str]]:
    w = _config().get("workers", {}).get(worker)
    if w is None:
        raise ValueError(f"unknown worker '{worker}' (see workers_list)")
    name = w.get("adapter", worker)
    extra = ["-Worker", worker] if name == "generic-cli" else []
    return BIN / "adapters" / f"{name}.ps1", extra


def _run(script: Path, args: list[str], timeout: int = 900) -> dict[str, Any]:
    """Run one script; its last stdout line is the JSON result."""
    cmd = [PWSH, "-NoProfile", "-NonInteractive", "-File", str(script), *args]
    try:
        p = subprocess.run(cmd, cwd=PROJECT, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"{script.name} timed out after {timeout}s", "hint": "Check the worker by hand."}
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    if not lines:
        return {"ok": False, "error": f"{script.name} printed nothing (exit {p.returncode})", "hint": p.stderr[-400:]}
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError:
        return {"ok": False, "error": f"{script.name} printed non-JSON output", "hint": lines[-1][:400]}


def _opt(args: list[str], flag: str, value: Any) -> None:
    """Add `flag value` when a value was given."""
    if value not in (None, ""):
        args.extend([flag, str(value)])


def call_tool(name: str, a: dict[str, Any]) -> dict[str, Any]:
    if name == "workers_list":
        ws = _config().get("workers", {})
        return {"ok": True, "workers": [
            {"name": k, "adapter": v.get("adapter", k), "enabled": v.get("enabled", False),
             "defaultModel": v.get("defaultModel", ""), "permissions": v.get("permissions", "default")}
            for k, v in ws.items()]}
    if name in ("worker_check", "worker_capabilities"):
        script, extra = _adapter(a["worker"])
        return _run(script, [*extra, "-Check" if name == "worker_check" else "-Capabilities"], timeout=300)
    if name == "task_new":
        args = ["-Id", a["task_id"]]
        _opt(args, "-Base", a.get("base"))
        return _run(BIN / "task-new.ps1", args)
    if name == "dispatch":
        script, extra = _adapter(a["worker"])
        args = [*extra, "-Dispatch", "-TaskId", a["task_id"], "-PromptFile", a["prompt_file"],
                "-Workspace", a.get("workspace") or f"../wt-{a['task_id']}"]
        for key, flag in (("title", "-Title"), ("model", "-Model"), ("agent", "-Agent"), ("prefix", "-Prefix")):
            _opt(args, flag, a.get(key))
        return _run(script, args, timeout=300)
    if name == "task_status":
        script, extra = _adapter(a["worker"])
        args = [*extra, "-Status", "-SessionId", a["session_id"]]
        if a.get("tail") and a["worker"] == "ag2":
            args += ["-Tail", str(int(a["tail"]))]
        return _run(script, args, timeout=120)
    if name == "handoff_check":
        p = subprocess.run(["git", "-C", str(PROJECT), "log", f"task/{a['task_id']}", "--format=%H", "-1", "--", a["handoff"]],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL)
        sha = p.stdout.strip()
        return {"ok": True, "taskId": a["task_id"], "committed": bool(sha), "commit": sha or None}
    if name == "task_message":
        script, extra = _adapter(a["worker"])
        ORCH.mkdir(parents=True, exist_ok=True)
        f = ORCH / f"{a['task_id']}-msg.prompt.md"
        f.write_text(a["text"], encoding="utf-8")
        args = [*extra, "-Message", "-SessionId", a["session_id"], "-MessageFile", str(f)]
        _opt(args, "-Prefix", a.get("prefix"))
        return _run(script, args, timeout=300)
    if name == "task_cancel":
        script, extra = _adapter(a["worker"])
        return _run(script, [*extra, "-Cancel", "-SessionId", a["session_id"]], timeout=120)
    if name == "verify_handoff":
        args = ["-Repo", ".", "-Branch", f"task/{a['task_id']}", "-Handoff", a["handoff"]]
        _opt(args, "-Base", a.get("base"))
        # pwsh -File passes one value per parameter: globs comma-joined, commands newline-joined
        for key, flag in (("allowed", "-Allowed"), ("forbidden", "-Forbidden"), ("locked", "-Locked")):
            if a.get(key):
                args += [flag, ",".join(a[key])]
        if a.get("run"):
            args += ["-Run", "\n".join(a["run"])]
        return _run(BIN / "verify-handoff.ps1", args, timeout=1800)
    if name == "task_cleanup":
        flag = {"merge": "-Merge", "discard": "-Discard"}[a["mode"]]
        return _run(BIN / "task-cleanup.ps1", ["-Id", a["task_id"], flag])
    raise ValueError(f"unknown tool '{name}'")


def handle(msg: dict[str, Any]) -> dict[str, Any] | None:
    mid, method = msg.get("id"), msg.get("method", "")
    if mid is None:  # notification (e.g. notifications/initialized): no reply
        return None
    try:
        if method == "initialize":
            ver = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            result: dict[str, Any] = {"protocolVersion": ver, "capabilities": {"tools": {}},
                                      "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = msg.get("params") or {}
            try:
                out = call_tool(params.get("name", ""), params.get("arguments") or {})
            except (KeyError, ValueError) as exc:
                out = {"ok": False, "error": str(exc), "hint": "Check the tool arguments (tools/list has the schema)."}
            result = {"content": [{"type": "text", "text": json.dumps(out, ensure_ascii=True)}],
                      "isError": not out.get("ok", False)}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}
        return {"jsonrpc": "2.0", "id": mid, "result": result}
    except Exception as exc:  # never crash the server on one bad call
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(exc)}}


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        reply = handle(msg)
        if reply is not None:
            sys.stdout.write(json.dumps(reply, ensure_ascii=True) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
