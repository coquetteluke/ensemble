# OpenCode fixtures

Real responses from the OpenCode 2.3.0 background service, captured on 2026-11-17 with the mock model
(`tools/mock-llm`). Paths were replaced with `/tmp/ensemble-probe` and `/Users/me`. The only key in
`integration-accounts.json` is a fake one (`fake-test-key-not-real`) that was stored and then removed.

- `session.json`, `sessions.json`, `children.json`: `GET /api/session/{id}`, `GET /api/session`, `GET /api/session?parentID=`
- `messages.json`: `GET /api/session/{id}/message?order=asc` for a session that ran a subagent, a synthetic board message,
  write and edit tools (with reasoning), a failing read, an interrupted reply, an attachment and a reasoning reply
- `messages-permission.json`: a session in Ask mode whose shell call was approved once
- `context.json`: `GET /api/session/{id}/context`
- `diff.json`: `GET /api/session/{id}/diff?from=&to=&context=3`
- `models.json`, `model-default.json`, `integrations.json`, `integration-accounts.json`, `mcp.json`, `schedules.json`, `info.json`,
  `locations.json`, `active.json`
- `events.sse`: the raw `GET /api/event` stream for the same runs (heartbeats included), plus the permission ask and
  reply from the Ask mode session and `filesystem.changed` / `mcp.status.changed` events
