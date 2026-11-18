#!/usr/bin/env python3
"""Scripted OpenAI-compatible chat model for Ensemble tests.

Standard library only (works with the macOS /usr/bin/python3, 3.9+).

Serves:
  GET  /v1/models
  POST /v1/chat/completions   (streaming SSE and plain JSON, text and tool calls)
  GET  /health

Replies come from a script file (JSON). Example:

  {
    "default": {"text": "Mock reply."},
    "rules": [
      {"match": ["hello"], "text": "Hello from the mock model."},
      {"match": ["run the echo"],
       "steps": [
         {"tool": {"name": "bash", "arguments": {"command": "echo hi", "description": "Print hi"}}},
         {"text": "The command printed hi."}
       ]},
      {"match": ["think first"], "reasoning": "Let me think.", "text": "Thought about it."}
    ]
  }

A rule matches when any of its `match` keywords (case-insensitive substrings) appear in the
newest user message. `steps` play in order: step N is used when N assistant messages already
follow that user message (so a tool call step is followed by the next step once the tool result
comes back). Shorthand: `text`, `tool`, `then` (text after the tool) and `reasoning` on the rule.
Each step may set `delay` (seconds between streamed chunks) and `chunks` (how many pieces the
text is split into). Requests without tools (title generation and similar) always get text.

Every request is appended to the `--log` file as one JSON line when given.
"""

import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-1"


class Script(object):
    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.data = {"default": {"text": "Mock reply."}, "rules": []}
        self.lock = threading.Lock()
        self.reload()

    def reload(self):
        if not self.path:
            return
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            return
        if mtime == self.mtime:
            return
        with open(self.path, "r", encoding="utf-8") as f:
            self.data = json.load(f)
        self.mtime = mtime

    def rules(self):
        with self.lock:
            self.reload()
            return list(self.data.get("rules", [])), dict(self.data.get("default", {"text": "Mock reply."}))


def message_text(message):
    content = message.get("content")
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    parts = []
    for part in content:
        if isinstance(part, dict):
            if part.get("type") == "text":
                parts.append(part.get("text", ""))
        elif isinstance(part, str):
            parts.append(part)
    return "\n".join(parts)


def rule_steps(rule):
    if "steps" in rule:
        return list(rule["steps"])
    steps = []
    if "tool" in rule:
        first = {"tool": rule["tool"]}
        if "reasoning" in rule:
            first["reasoning"] = rule["reasoning"]
        if "delay" in rule:
            first["delay"] = rule["delay"]
        steps.append(first)
        steps.append({"text": rule.get("then", "Done.")})
    else:
        step = {"text": rule.get("text", "")}
        for key in ("reasoning", "delay", "chunks"):
            if key in rule:
                step[key] = rule[key]
        steps.append(step)
    return steps


def choose_step(script, body):
    messages = body.get("messages", [])
    has_tools = bool(body.get("tools"))
    last_user_index = None
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") == "user":
            last_user_index = i
            break
    user_text = message_text(messages[last_user_index]) if last_user_index is not None else ""
    assistant_after = 0
    if last_user_index is not None:
        assistant_after = sum(1 for m in messages[last_user_index + 1:] if m.get("role") == "assistant")

    rules, default = script.rules()
    lowered = user_text.lower()
    chosen = None
    for rule in rules:
        keywords = rule.get("match", [])
        if isinstance(keywords, str):
            keywords = [keywords]
        if any(k.lower() in lowered for k in keywords):
            chosen = rule
            break

    if not has_tools:
        # Title generation and other helper calls: answer with plain text.
        if chosen is not None and chosen.get("title"):
            return {"text": chosen["title"]}
        return {"text": default.get("title", "Mock session")}

    if chosen is None:
        steps = rule_steps(default)
    else:
        steps = rule_steps(chosen)
    if not steps:
        return {"text": ""}
    index = min(assistant_after, len(steps) - 1)
    if assistant_after >= len(steps):
        # Past the end of the script: finish with the last text step or a short default.
        last = steps[-1]
        if "tool" in last:
            return {"text": default.get("text", "Done.")}
        return last
    return steps[index]


def split_text(text, chunks):
    if not text:
        return []
    chunks = max(1, int(chunks))
    size = max(1, (len(text) + chunks - 1) // chunks)
    return [text[i:i + size] for i in range(0, len(text), size)]


def usage_for(body, completion_text):
    prompt_chars = len(json.dumps(body.get("messages", [])))
    prompt_tokens = max(1, prompt_chars // 4)
    completion_tokens = max(1, len(completion_text) // 4)
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MockLLM/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            sys.stderr.write("mock-llm: " + (fmt % args) + "\n")

    def _send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/health", ""):
            self._send_json(200, {"ok": True})
        elif path.endswith("/models"):
            self._send_json(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "created": 0, "owned_by": "mock"}]})
        else:
            self._send_json(404, {"error": {"message": "not found: " + self.path}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            self._send_json(400, {"error": {"message": "bad json"}})
            return
        self.server.record(self.path, body)
        path = self.path.split("?")[0].rstrip("/")
        if not path.endswith("/chat/completions"):
            self._send_json(404, {"error": {"message": "unsupported path: " + self.path}})
            return
        step = choose_step(self.server.script, body)
        if body.get("stream"):
            self._stream(body, step)
        else:
            self._complete(body, step)

    def _complete(self, body, step):
        completion_id = "chatcmpl-" + uuid.uuid4().hex[:12]
        message = {"role": "assistant", "content": None}
        finish = "stop"
        text = ""
        if "tool" in step:
            tool = step["tool"]
            message["tool_calls"] = [{
                "id": "call_" + uuid.uuid4().hex[:12],
                "type": "function",
                "function": {"name": tool["name"], "arguments": json.dumps(tool.get("arguments", {}))},
            }]
            finish = "tool_calls"
        else:
            text = step.get("text", "")
            message["content"] = text
        if step.get("reasoning"):
            message["reasoning_content"] = step["reasoning"]
        self._send_json(200, {
            "id": completion_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": body.get("model", MODEL_ID),
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": usage_for(body, text),
        })

    def _write_event(self, payload):
        data = "data: " + json.dumps(payload) + "\n\n"
        self.wfile.write(data.encode("utf-8"))
        self.wfile.flush()

    def _stream(self, body, step):
        completion_id = "chatcmpl-" + uuid.uuid4().hex[:12]
        created = int(time.time())
        model = body.get("model", MODEL_ID)
        delay = float(step.get("delay", 0.02))

        def chunk(delta, finish=None, usage=None):
            payload = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            if usage is not None:
                payload["usage"] = usage
            return payload

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self._write_event(chunk({"role": "assistant", "content": ""}))
            if step.get("reasoning"):
                for piece in split_text(step["reasoning"], 3):
                    time.sleep(delay)
                    self._write_event(chunk({"reasoning_content": piece}))
            text = ""
            if "tool" in step:
                tool = step["tool"]
                call_id = "call_" + uuid.uuid4().hex[:12]
                args = json.dumps(tool.get("arguments", {}))
                self._write_event(chunk({"tool_calls": [{
                    "index": 0, "id": call_id, "type": "function",
                    "function": {"name": tool["name"], "arguments": ""}}]}))
                for piece in split_text(args, 3):
                    time.sleep(delay)
                    self._write_event(chunk({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}))
                finish = "tool_calls"
            else:
                text = step.get("text", "")
                for piece in split_text(text, step.get("chunks", 4)):
                    time.sleep(delay)
                    self._write_event(chunk({"content": piece}))
                finish = "stop"
            self._write_event(chunk({}, finish=finish))
            self._write_event({
                "id": completion_id, "object": "chat.completion.chunk", "created": created, "model": model,
                "choices": [], "usage": usage_for(body, text)})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The client stopped reading (interrupt). Nothing else to do.
            pass


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, script, log_path, verbose):
        ThreadingHTTPServer.__init__(self, address, Handler)
        self.script = script
        self.log_path = log_path
        self.verbose = verbose
        self.log_lock = threading.Lock()

    def record(self, path, body):
        if not self.log_path:
            return
        with self.log_lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({"time": time.time(), "path": path, "body": body}) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Scripted OpenAI-compatible mock model")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port")
    parser.add_argument("--script", help="JSON script file (reloaded when it changes)")
    parser.add_argument("--port-file", help="write the chosen port to this file once listening")
    parser.add_argument("--log", help="append every request body to this file (JSON lines)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = MockServer((args.host, args.port), Script(args.script), args.log, args.verbose)
    port = server.server_address[1]
    if args.port_file:
        tmp = args.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(port))
        os.rename(tmp, args.port_file)
    sys.stderr.write("mock-llm listening on http://%s:%d/v1\n" % (args.host, port))
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
