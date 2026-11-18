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

## Permission matching (checked 2026-11-18)
- Wildcards: one matcher that escapes regex characters, turns `*` into `.*` and `?` into `.`, case-sensitive, no character classes (`[Mm]` is literal). So protected file names cannot be matched case-insensitively with rules; dot-segments (`.*`, `*/.*`) are used instead, and Auto keeps only read-only commands allowed.
- OpenCode normalises edit paths (`./a` to `a`, `sub/../x` to `x`) but keeps the model's spelling.
- `cd` and the shell tool's `workdir` are not checked by the permission system; a folder of plain files can act as a git repository, so `git diff/log/show` ask in Auto.
- `VAR=value` prefixes stay part of the checked command; commands inside `<(...)` are checked on their own.
- Open gap: oddly spelt non-dot files that run later outside the agent (`LeFtHoOk.yml`, hooks inside package.json, Jenkinsfile). Fix later with an OpenCode plugin using the permission "evaluate" hook, or an Ensemble-side safety check.
- Shell reads of `.env` (`cat .env`) bypass the read rule that asks for `.env`.

## Plan mode and questions (checked 2026-11-18)
- OpenCode's `plan` agent adds a "You are in Plan mode, discuss the plan in the conversation" reminder but still allows every shell command and writes under `~/.opencode/plan`. Ensemble's Plan switches the session to that agent (`POST /api/session/{id}/agent`) and sets `PermissionRules.planRuleset`: everything denied except reads, searches, questions, skills, subagents, the read-only commands Auto allows, and web access (asks). Checked live with the mock: a write and `echo hi > shell.txt` were refused without a prompt.
- The plan agent has no tool that hands a plan over, so when its turn ends the client turns the last reply into a plan request (`plan-<messageID>`). Proceed sets the mode's rules and the `build` agent and sends "The plan is approved. Carry it out now."; Keep planning sends the comments as one message.
- The `question` tool opens a form: `form.created` with `fields` (a `string` field with `options` and `custom: true` per single-choice question, keys `q0`, `q1`, ...). Reply with `POST /api/session/{id}/form/{formID}/reply` `{"answer": {"q0": "Blue"}}`, decline with `DELETE` on the form. The turn waits meanwhile; `form.replied` or `form.cancelled` follows. Open forms are listed per folder (`GET /api/form`, location-scoped).

## Private server for untrusted folders (checked 2026-11-18)
- OpenCode reads a project's own config (`opencode.json(c)`, `.opencode/`, `AGENTS.md`, from the folder and every folder above it) in every folder it serves. The only switch is `OPENCODE_DISABLE_PROJECT_CONFIG=1`, read once at start, so Ensemble runs a second `opencode serve` with it for untrusted folders (`PrivateOpenCodeServer`) and `EngineRouter` sends every call that names an untrusted folder there (`registrations(forFolder:)`). The shared service is never stopped, restarted or reconfigured.
- A user-level config passed with `OPENCODE_CONFIG` still loads with the switch on; only project config is skipped.
- `opencode serve` prints `server listening on http://127.0.0.1:PORT` (the case of "server" varies) to stdout; `--port 0` picks a free port.
- `OPENCODE_SERVER_PASSWORD` sets the password, but every command an agent runs inherits the server's environment, so the variable reached agent shells (checked with an `env` dump). Ensemble uses `opencode serve --service` with its own `XDG_STATE_HOME` instead: OpenCode makes the password and writes it with the address to `$XDG_STATE_HOME/opencode/service.json` (0600), the way the shared service does, and nothing secret is in the environment.
- What agent commands in untrusted folders inherit from the private server: `XDG_DATA_HOME` and `XDG_STATE_HOME` (paths into `~/Library/Application Support/Ensemble/OpenCode untrusted/`), `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `OPENCODE_DISABLE_AUTOUPDATE=1`, and the app's own environment. The data folder holds the database (sessions, transcripts, copied API keys), logs and snapshots; the state folder holds `service.json` and terminal sockets. Folders are 0700, the database and service file 0600. Like the shared service's own files, they are protected from other users, not from commands the user lets an agent run as them. Tools that use `XDG_DATA_HOME` or `XDG_STATE_HOME` (uv, pipx, neovim) see the private folders in those sessions.
- Credentials live in each server's database (`credential` table; there is no `auth.json`), so a second server starts with none. `GET /api/credential` lists them with their secret values; `POST /api/credential` with an `id` stores one. Ensemble copies `key` and `external` credentials from the shared service and keeps them in step (checked: a copied key is sent to the provider). Browser sign-ins (`oauth`) are not copied, because two servers refreshing one sign-in would log each other out.
- A session whose provider has no credential on the server is still created; its first turn fails. A built-in provider that is not signed in fails at once with `provider.no-route` "Model unavailable: openai/gpt-5.1" (no request is sent); a config-defined provider whose key is missing sends the request without a key and fails with the provider's own 401 (`provider.auth`). Ensemble now refuses such models before creating the session in an untrusted folder (`EngineRouterError.signInNeedsTrustedFolder`) and says so on the trust card and in the new-session sheet.
