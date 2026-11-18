# OpenCode 2.3 behaviour notes (found while building the engine client, 2026-11-18)

Things the UI, the room engine and the remote need to know. Verified against the real service.

## Names
- The shell tool is `shell` (not `bash`); subagents use the `subagent` tool (not `task`).
- Permission action names: `shell`, `edit` (also covers write and patch), `read`, `webfetch`, `external_directory`, `subagent`.
- Provider id equals integration id (`openai`, `xai`, `github-copilot`, ...).

## Permissions
- OpenCode's default ruleset allows every tool, so Ensemble's Ask mode sends explicit ask rules (edit, shell, webfetch, external_directory, image generation). Session rules override agent rules.
- `permission.asked` carries the scanned command or path and the patterns "Always" would save (for example `echo *`).
- The pending list is per project folder; the client merges all loaded folders.
- Rejecting one prompt rejects every pending prompt in that session.

## Activity, usage, streaming
- `session.status` and `session.idle` did not fire in testing. Activity comes from `session.execution.started|succeeded|failed|interrupted`.
- `session.usage.updated` carries cumulative session totals after every step, not deltas. Each model step is its own assistant message. Title generation also costs tokens.
- Live text ids are `msgID:text:N` and `msgID:reasoning:N` (numbered per kind) and match transcript rows.
- The event stream sends `data:` lines and heartbeats only; missed events are not replayed. Every (re)connect yields `.other("server.connected")`: refresh state then.
- `filesystem.changed` only fires for files registered with `watchFile`.

## Sessions and subagents
- Subagents run in the background: the tool call returns at once, the child appears as `session.created` with `parentID` (title = task description, agent `general`), and the tool card gets `childSessionID`. When the child goes idle the parent receives a synthetic `<subagent ... state="completed">` message and wakes.
- Synthetic messages with `wake` start a turn; without `wake` they wait for the next run.
- The message list is newest-first by default (the client sends `order=asc`); `order` cannot be combined with a cursor.
- The diff endpoint covers only the newest turn by default; `changedFiles` asks for first-to-last prompt.

## Providers, context, schedules
- The first `integration.list` for a new project folder can return 0 items before providers load; a second request returns the full list (332). The client retries once.
- Credential listings include secrets; the client never decodes them.
- Custom providers work from a project `opencode.json` (`providers.<id>` with `@opencode/ai/providers/openai-compatible`), no restart needed.
- `/context` returns messages, not a breakdown. Ensemble estimates the breakdown: "used" is the newest step's real token count; messages, tools and skills are estimated from text; the rest goes under System prompt; the buffer is the model's output limit capped at 32k.
- Schedules only work when the engine config has `experimental.schedules: true`. Schedules belong to sessions.
- OpenCode loads the user's `~/.claude` skills into every system prompt (about 9k tokens even for "hello"). Worth a setting to turn off.

## Recommended protocol changes (apply when the UI and room engine land)
1. EngineEvent: add `.reasoningEnded` and an error case for `session.step.failed`.
2. `models()`, `providers()`, `connectors()` take `directory:` (answers are per project).
3. Add `defaultModel(directory:)`.
4. ScheduleInfo: add `sessionID` and status; add `schedules(sessionID:)`.
5. TranscriptItem.user: attachments.
6. `injectSynthetic(..., metadata:)` and a synthetic transcript case (board messages currently come back as `.notice`).
7. Add `activeSessionIDs()` for the Hub's Running bucket.
8. `ConnectorInfo.toolCount` is always 0 and `PermissionRequest.created` is the time the client first saw the prompt.
