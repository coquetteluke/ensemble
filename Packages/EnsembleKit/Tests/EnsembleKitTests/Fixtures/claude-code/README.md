# Claude Code fixtures

Recorded on 2026-11-18 from the real `claude` CLI 2.1.319 on the cheapest model (`--model haiku`), in a throwaway
folder, with the flags the engine uses:

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages \
  --permission-mode default --permission-prompt-tool stdio --thinking-display summarized [--forward-subagent-text]
```

| File | What it is |
|---|---|
| `stream-plain.jsonl` | Two turns in one process: "Reply with exactly: hello there", then "bye". |
| `stream-thinking.jsonl` | A reply with summarized thinking (`thinking_delta`), then the text "391". |
| `stream-edit-allowed.jsonl` | Read, then Edit with a `can_use_tool` control request answered allow (diff in `tool_use_result.structuredPatch`). |
| `stream-edit-rejected.jsonl` | The same Edit answered deny. |
| `stream-subagent.jsonl` | An Agent tool call; the subagent's messages carry `parent_tool_use_id` (`--forward-subagent-text`), plus `task_started` / `task_notification`. |
| `stream-interrupt.jsonl` | A long reply stopped with an `interrupt` control request, then a new turn in the same process. |
| `control-permission-prompts.jsonl` | Three `can_use_tool` requests (2026-11-18, haiku, `--setting-sources ""`): `touch made.txt` (blocked path inside the project), `mkdir d1 && touch d1/x` (one rule suggestion per subcommand, new `words *` form), and a Read outside the project (`decision_reason_type: workingDir`, rule `//dir/**`). Paths are `/private/tmp/ensemble-claude/...`. |
| `control-context-usage.json` | The answer to a `get_context_usage` control request (what `/context` shows). |
| `transcript-*.jsonl` | The CLI's own transcript files for the edit, subagent and interrupt sessions (conversation lines only). |
| `transcript-subagent-agent.*` | The subagent's own transcript and `.meta.json` from `<session>/subagents/`. |

Anonymised with a script: paths are `/tmp/ensemble-claude/proj` and `/Users/me`, session ids are
`00000000-0000-4000-8000-00000000000N`, thinking text is replaced with neutral words, thinking signatures with `SIG`,
the init line's tool, skill, plugin, MCP and agent lists are cut to generic values, hook output is emptied, and
`credential_expires_at`, account and organisation ids and hook command lines are removed. Nothing credential-like is kept.
