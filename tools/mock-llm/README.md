# mock-llm

A scripted OpenAI-compatible chat model for tests. No keys, no network, no cost. Python 3 standard library only
(the macOS `/usr/bin/python3` works).

```bash
/usr/bin/python3 tools/mock-llm/mock_llm.py --port 47811 --script tools/mock-llm/test-script.json --log /tmp/mock.jsonl
```

- `GET /v1/models`, `POST /v1/chat/completions` (streaming SSE and plain JSON, text, reasoning and tool calls).
- `--port 0` picks a free port; `--port-file FILE` writes the chosen port once it is listening.
- `--log FILE` appends every request body as one JSON line (handy to see what OpenCode sends).
- The script file is reloaded when it changes.

## Script format

```json
{
  "default": {"text": "Mock reply.", "title": "Mock session"},
  "rules": [
    {"match": ["hello"], "text": "Hello from the mock model."},
    {"match": ["run the echo"], "tool": {"name": "shell", "arguments": {"command": "echo hi"}}, "then": "It printed hi."},
    {"match": ["think first"], "reasoning": "Let me think.", "text": "Done thinking."},
    {"match": ["several steps"], "steps": [
      {"tool": {"name": "read", "arguments": {"path": "README.md"}}},
      {"tool": {"name": "shell", "arguments": {"command": "ls"}}},
      {"text": "Read and listed."}
    ]},
    {"match": ["go slow"], "text": "A long reply.", "chunks": 40, "delay": 0.5}
  ]
}
```

A rule matches when one of its `match` words appears (case-insensitive) in the newest user message. OpenCode sends
synthetic messages and subagent reports (`<subagent ...>`) as user messages too. Step N of a rule plays when N
assistant messages already follow that user message, so a tool call is followed by the next step once the tool result
comes back. Requests without tools (OpenCode's title generator) always get `default.title`.

OpenCode 2.3 tool names: `shell` (not `bash`), `subagent` (args `agent`, `description`, `prompt`), `edit`
(`path`, `oldString`, `newString`), `write` (`path`, `content`), `read` (`path`), `glob`, `grep`, `webfetch`,
`websearch`, `question`, `skill`, `execute`.

## Registering it with OpenCode

Put an `opencode.json` in the project folder (see `opencode.json.example`, replace `PORT`). OpenCode reads
`opencode.json(c)` from the session's folder and every parent folder, so nothing global changes. The model is
then `mock/mock-1`. The example also turns on `experimental.schedules`, which the schedule API needs.

The live tests (`scripts/test-live.sh`) start the mock on a free port and write this config into a temporary folder.
