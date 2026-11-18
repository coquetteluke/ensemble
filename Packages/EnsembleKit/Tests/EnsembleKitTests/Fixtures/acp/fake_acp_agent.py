#!/usr/bin/env python3
"""A scripted ACP (Agent Client Protocol v1) agent for Ensemble's tests. Python 3 standard library only.

It speaks JSON-RPC 2.0 over stdio, one message per line, and behaves like the real agents Ensemble was tested with
(agy acp 1.5.10, opencode acp 2.3.0): config options for model, thought_level and mode, permission requests with
diffs, cancellation, session/load replay, usage and title updates.

Prompt words pick the behaviour (case-insensitive, first match):
  fail    -> the prompt request fails with a JSON-RPC error
  slow    -> streams "tick " every 0.1 s until cancelled (stopReason cancelled), at most 100 ticks
  mystery -> execute tool call whose arguments name no command (only a title), asks permission
  outside -> edit tool call on a file outside the session folder, asks permission
  edit    -> edit tool call on notes.txt with a diff, asks permission, completes, fails or is cancelled
  write   -> new-file tool call (diff without oldText), asks permission
  shell   -> execute tool call `echo hi`; asks permission unless the mode is turbo or auto, or --bypass was given
             ("env" in the prompt adds an environment variable to the call's arguments)
  think   -> a thought chunk, then text
  plan    -> a plan update, then text
  other   -> "Echo: <prompt>" in two chunks

Environment:
  FAKE_ACP_LOG           append every message the client sends, plus prompt start/end events, as JSON lines
  FAKE_ACP_STATE         JSON file with session histories (so session/load works across processes)
  FAKE_ACP_INITIAL_MODE  the mode new and loaded sessions start in (default "default"; "turbo" mimics a user preset
                         that runs commands without asking)
  FAKE_ACP_NO_ALWAYS     "1": offer only allow_once and reject_once (like Antigravity)
  FAKE_ACP_SIGNED_OUT    "1": session/new fails with -32000 (auth required)
  FAKE_ACP_IGNORE_MODE   "1": accept mode changes but keep reporting the initial mode
  FAKE_ACP_NO_MODES      "1": report no modes at all (sessions keep the initial mode)
"""
import json, os, sys, threading, time

LOCK = threading.Lock()
LOG = os.environ.get("FAKE_ACP_LOG")
STATE = os.environ.get("FAKE_ACP_STATE")
INITIAL_MODE = os.environ.get("FAKE_ACP_INITIAL_MODE", "default")
NO_ALWAYS = os.environ.get("FAKE_ACP_NO_ALWAYS") == "1"
SIGNED_OUT = os.environ.get("FAKE_ACP_SIGNED_OUT") == "1"
IGNORE_MODE = os.environ.get("FAKE_ACP_IGNORE_MODE") == "1"
NO_MODES = os.environ.get("FAKE_ACP_NO_MODES") == "1"
BYPASS = "--bypass" in sys.argv[1:]

MODES = [("default", "Default"), ("accept-edits", "Accept edits"), ("auto", "Auto"), ("turbo", "Turbo")]
MODELS = [("fake-fast", "Fake Fast"), ("fake-smart", "Fake Smart")]
LEVELS = [("low", "Low"), ("medium", "Medium"), ("high", "High")]

sessions = {}      # id -> {"cwd", "mode", "model", "level", "history": [...], "prompts": int, "cancel": Event}
pending = {}       # outgoing request id -> {"event": Event, "result": ...}
active = [0]
next_out = [0]


def log(entry):
    if not LOG:
        return
    with LOCK:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")


def send(message):
    message["jsonrpc"] = "2.0"
    with LOCK:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def load_state():
    if STATE and os.path.exists(STATE):
        try:
            with open(STATE) as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_state():
    if not STATE:
        return
    with LOCK:
        data = {sid: {"cwd": s["cwd"], "history": s["history"], "prompts": s["prompts"]} for sid, s in sessions.items()}
        old = {}
        if os.path.exists(STATE):
            try:
                with open(STATE) as f:
                    old = json.load(f)
            except Exception:
                old = {}
        old.update(data)
        with open(STATE, "w") as f:
            json.dump(old, f)


def config_options(s):
    mode = INITIAL_MODE if IGNORE_MODE else s["mode"]
    options = [
        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": s["model"],
         "options": [{"value": v, "name": n} for v, n in MODELS]},
        {"id": "thought_level", "name": "Thinking Level", "category": "thought_level", "type": "select", "currentValue": s["level"],
         "options": [{"value": v, "name": n} for v, n in LEVELS]},
        {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": mode,
         "options": [{"value": v, "name": n} for v, n in MODES]},
    ]
    return [o for o in options if not (NO_MODES and o["id"] == "mode")]


def update(sid, body):
    send({"method": "session/update", "params": {"sessionId": sid, "update": body}})


def new_session(cwd, sid=None, history=None, prompts=0):
    if sid is None:
        sid = "fake-%d-%d" % (os.getpid(), len(sessions) + 1)
    sessions[sid] = {"cwd": cwd, "mode": INITIAL_MODE, "model": "fake-fast", "level": "medium", "history": history or [],
                     "prompts": prompts, "cancel": threading.Event()}
    return sid


def setup_result(sid, include_id=True):
    s = sessions[sid]
    result = {"configOptions": config_options(s)}
    if not NO_MODES:
        result["modes"] = {"currentModeId": INITIAL_MODE if IGNORE_MODE else s["mode"], "availableModes": [{"id": v, "name": n} for v, n in MODES]}
    if include_id:
        result["sessionId"] = sid
    return result


def commands_later(sid):
    def run():
        time.sleep(0.05)
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "compact", "description": "Compact the conversation"},
            {"name": "review", "description": "Review changes", "input": {"hint": "<target>"}}]})
    threading.Thread(target=run, daemon=True).start()


def ask_permission(sid, tool_call, cancel):
    next_out[0] += 1
    rid = "perm-%d" % next_out[0]
    options = [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]
    if not NO_ALWAYS:
        options.append({"optionId": "always", "name": "Always allow", "kind": "allow_always"})
    options.append({"optionId": "deny", "name": "Deny", "kind": "reject_once"})
    entry = {"event": threading.Event(), "result": None}
    pending[rid] = entry
    send({"id": rid, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": tool_call, "options": options}})
    while not entry["event"].wait(0.05):
        pass
    outcome = (entry["result"] or {}).get("outcome", {})
    log({"event": "permission_answer", "session": sid, "outcome": outcome})
    if outcome.get("outcome") != "selected":
        return "cancelled"
    return {"allow": "allow", "always": "allow", "deny": "deny"}.get(outcome.get("optionId"), "deny")


def run_prompt(rid, sid, text):
    s = sessions[sid]
    s["cancel"].clear()
    with LOCK:
        active[0] += 1
        now = active[0]
    log({"event": "prompt_start", "session": sid, "active": now, "text": text})
    s["history"].append({"role": "user", "text": text})
    s["prompts"] += 1
    if s["prompts"] == 1:
        update(sid, {"sessionUpdate": "session_info_update", "title": "Fake: " + text[:30]})
    lower = text.lower()
    stop = "end_turn"
    reply = ""
    try:
        if "fail" in lower:
            send({"id": rid, "error": {"code": -32603, "message": "fake failure"}})
            return
        if "slow" in lower:
            for _ in range(100):
                if s["cancel"].is_set():
                    stop = "cancelled"
                    break
                update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "tick "}})
                reply += "tick "
                time.sleep(0.1)
        elif "mystery" in lower or "outside" in lower:
            tid = "call_%d" % s["prompts"]
            if "mystery" in lower:
                call = {"toolCallId": tid, "name": "helper", "title": "echo hi", "kind": "execute", "status": "pending", "rawInput": {}}
            else:
                path = os.path.join(os.path.dirname(s["cwd"].rstrip("/")), "outside.txt")
                call = {"toolCallId": tid, "name": "edit_file", "title": "File outside.txt", "kind": "edit", "status": "pending",
                        "locations": [{"path": path}], "rawInput": {"path": path},
                        "content": [{"type": "diff", "path": path, "oldText": "a\n", "newText": "b\n"}]}
            update(sid, dict(call, sessionUpdate="tool_call"))
            answer = "allow" if BYPASS else ask_permission(sid, call, s["cancel"])
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed" if answer == "allow" else "failed"})
            stop = "cancelled" if answer == "cancelled" else "end_turn"
            reply = "Done." if answer == "allow" else ""
        elif "edit" in lower or "write" in lower:
            new_file = "write" in lower
            path = os.path.join(s["cwd"], "hello.txt" if new_file else "notes.txt")
            tid = "call_%d" % s["prompts"]
            diff = {"type": "diff", "path": path, "newText": "hello\n"} if new_file else \
                {"type": "diff", "path": path, "oldText": "alpha\n", "newText": "beta\n"}
            raw = {"path": path, "content": "hello\n"} if new_file else {"path": path, "oldText": "alpha", "newText": "beta"}
            call = {"toolCallId": tid, "name": "write_file" if new_file else "edit_file", "title": "File " + os.path.basename(path),
                    "kind": "edit", "status": "pending", "locations": [{"path": path}], "rawInput": raw}
            update(sid, dict(call, sessionUpdate="tool_call"))
            if s["mode"] in ("accept-edits", "auto", "turbo") or BYPASS:
                answer = "allow"
            else:
                answer = ask_permission(sid, dict(call, content=[diff]), s["cancel"])
            if answer == "allow":
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed", "content": [diff], "rawOutput": {}})
                s["history"].append({"role": "tool", "call": dict(call, status="completed", content=[diff])})
                reply = "Edited the file."
            else:
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "failed"})
                s["history"].append({"role": "tool", "call": dict(call, status="failed")})
                if answer == "cancelled":
                    stop = "cancelled"
                else:
                    reply = "The edit was rejected."
        elif "shell" in lower:
            tid = "call_%d" % s["prompts"]
            call = {"toolCallId": tid, "name": "run_command", "title": "echo hi", "kind": "execute", "status": "pending",
                    "rawInput": {"CommandLine": "echo hi", "toolSummary": "Say hi"}}
            if "env" in lower:
                call["rawInput"]["env"] = {"GREETING": "hello"}
            update(sid, dict(call, sessionUpdate="tool_call"))
            effective = INITIAL_MODE if IGNORE_MODE else s["mode"]
            if effective in ("turbo", "auto") or BYPASS:
                answer = "allow"
            else:
                answer = ask_permission(sid, call, s["cancel"])
            log({"event": "shell", "session": sid, "asked": not (effective in ("turbo", "auto") or BYPASS), "answer": answer})
            if answer == "allow":
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed",
                             "content": [{"type": "content", "content": {"type": "text", "text": "hi\n"}}], "rawOutput": {"output": "hi\n", "exit_code": 0}})
                reply = "It printed hi."
            else:
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "failed"})
                stop = "cancelled" if answer == "cancelled" else "end_turn"
                reply = "" if answer == "cancelled" else "The command was rejected."
        elif "think" in lower:
            update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Thinking about it."}})
            reply = "Thought about it."
        elif "plan" in lower:
            update(sid, {"sessionUpdate": "plan", "entries": [
                {"content": "Read the notes", "priority": "high", "status": "completed"},
                {"content": "Write the summary", "priority": "medium", "status": "in_progress"},
                {"content": "Review", "priority": "low", "status": "pending"}]})
            reply = "Planned."
        else:
            reply = "Echo: " + text
        if reply and stop != "cancelled":
            half = len(reply) // 2
            for part in (reply[:half], reply[half:]):
                if part:
                    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": part}})
        if reply:
            s["history"].append({"role": "agent", "text": reply})
        update(sid, {"sessionUpdate": "usage_update", "used": 100 * s["prompts"], "size": 1000})
        save_state()
        result = {"stopReason": stop}
        if stop != "cancelled":
            result["usage"] = {"inputTokens": 10, "outputTokens": 5, "thoughtTokens": 1, "cachedReadTokens": 2, "cachedWriteTokens": 0, "totalTokens": 18}
        send({"id": rid, "result": result})
    finally:
        with LOCK:
            active[0] -= 1
        log({"event": "prompt_end", "session": sid, "stop": stop})


def replay(sid):
    for entry in sessions[sid]["history"]:
        if entry["role"] == "user":
            update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": entry["text"]}})
        elif entry["role"] == "agent":
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": entry["text"]}})
        elif entry["role"] == "tool":
            update(sid, dict(entry["call"], sessionUpdate="tool_call"))


def handle(msg):
    method = msg.get("method")
    rid = msg.get("id")
    params = msg.get("params") or {}
    if method is None:
        entry = pending.pop(rid, None)
        if entry is not None:
            entry["result"] = msg.get("result")
            entry["event"].set()
        return
    if method == "initialize":
        send({"id": rid, "result": {"protocolVersion": 1, "agentInfo": {"name": "Fake ACP Agent", "version": "0.1"},
                                    "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True},
                                                          "sessionCapabilities": {"close": {}, "list": {}}},
                                    "authMethods": [{"id": "fake-login", "name": "Log in"}]}})
    elif method == "session/new":
        if SIGNED_OUT:
            send({"id": rid, "error": {"code": -32000, "message": "Authentication required"}})
            return
        sid = new_session(params.get("cwd", "/"))
        send({"id": rid, "result": setup_result(sid)})
        commands_later(sid)
    elif method == "session/load":
        sid = params.get("sessionId")
        saved = load_state().get(sid)
        if sid in sessions:
            sessions[sid]["mode"] = INITIAL_MODE
        elif saved:
            new_session(params.get("cwd", saved["cwd"]), sid=sid, history=saved["history"], prompts=saved["prompts"])
        else:
            send({"id": rid, "error": {"code": -32002, "message": "Session not found"}})
            return
        replay(sid)
        send({"id": rid, "result": setup_result(sid, include_id=False)})
        commands_later(sid)
    elif method == "session/set_config_option":
        s = sessions.get(params.get("sessionId"))
        key, value = params.get("configId"), params.get("value")
        allowed = {"model": [v for v, _ in MODELS], "thought_level": [v for v, _ in LEVELS], "mode": [v for v, _ in MODES]}
        if s is None or key not in allowed or value not in allowed[key]:
            send({"id": rid, "error": {"code": -32602, "message": "Invalid config option"}})
            return
        s[{"model": "model", "thought_level": "level", "mode": "mode"}[key]] = value
        send({"id": rid, "result": {"configOptions": config_options(s)}})
        if key == "mode":
            update(params["sessionId"], {"sessionUpdate": "current_mode_update", "currentModeId": INITIAL_MODE if IGNORE_MODE else value})
    elif method == "session/set_mode":
        s = sessions.get(params.get("sessionId"))
        if s is None:
            send({"id": rid, "error": {"code": -32602, "message": "Unknown session"}})
            return
        s["mode"] = params.get("modeId")
        send({"id": rid, "result": {}})
    elif method == "session/prompt":
        sid = params.get("sessionId")
        if sid not in sessions:
            send({"id": rid, "error": {"code": -32002, "message": "Session not found"}})
            return
        text = "\n".join(b.get("text", "") for b in params.get("prompt", []) if b.get("type") == "text")
        threading.Thread(target=run_prompt, args=(rid, sid, text), daemon=True).start()
    elif method == "session/cancel":
        s = sessions.get(params.get("sessionId"))
        if s:
            s["cancel"].set()
    elif method == "session/close":
        send({"id": rid, "result": {}})
    elif rid is not None:
        send({"id": rid, "error": {"code": -32601, "message": "Method not found: %s" % method}})


def main():
    log({"event": "start", "argv": sys.argv[1:], "pid": os.getpid(), "env": sorted(os.environ.keys())})
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        log({"received": msg})
        handle(msg)


if __name__ == "__main__":
    main()
