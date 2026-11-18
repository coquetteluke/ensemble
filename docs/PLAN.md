# Ensemble build plan

Each milestone ends with something that runs and is tested. Work packages (WP) inside a milestone can run in parallel when their file ownership does not overlap. Status lives in `docs/PROGRESS.md`.

## M0: Foundation (orchestrator)

- Repo, MIT license, README, docs, `.gitignore`, project CLAUDE.md.
- `project.yml` (XcodeGen): `Ensemble` macOS app (macOS 26+), `EnsembleRemote` iOS app (iOS 26+), local package `Packages/EnsembleKit`.
- EnsembleKit skeleton with the shared model types and protocols every WP codes against (`Model/`, `OpenCode/OpenCodeAPI.swift` protocol, `Remote/RemoteProtocol.swift`).
- Both apps build empty. Public GitHub repo `coquetteluke/ensemble`.

Done when: `xcodegen && xcodebuild` builds both apps, `swift test` passes in EnsembleKit, repo is pushed.

## M1: Engine and solo chat

- **WP-A Engine client** (owns `Packages/EnsembleKit/Sources/EnsembleKit/OpenCode/`, `Engine/`, `tools/mock-llm/`, matching tests)
  - `EngineManager`: find `opencode` (PATH, `/opt/homebrew/bin`), check version >= 2.3.0, `opencode service start`, read `service.json`, health check `GET /api/info`, restart on failure.
  - `OpenCodeClient` (async/await, URLSession, Basic auth) for sessions, prompt, synthetic, interrupt, messages, permission reply, model list, providers and credentials, context, diff, MCP list, schedules, usage stats.
  - `EventStream`: SSE parser with reconnect, decoding the event types listed in DESIGN.md into typed `EngineEvent`s.
  - `tools/mock-llm`: OpenAI-compatible server (Python stdlib) with scripted replies, streaming, and tool calls; config snippet to register it as an OpenCode provider.
  - Tests: decode captured real responses; live test against the real service plus the mock model (prompt, stream text, tool call, permission ask and reply, subagent).
- **WP-B Mac UI shell** (owns `Apps/Mac/`, `Packages/EnsembleKit/Sources/EnsembleKit/UI/`)
  - Window with left sidebar, centre transcript, composer, status line, toggleable right context panel, matching the Claude Code desktop look (dark, same spacing and typography feel, own accent and icon).
  - Transcript rendering: Markdown text, streaming, tool cards (bash, edit with diff, read, search, web), subagent cards, permission cards, error rows.
  - Composer: agent/model chip, permission-mode menu (Ask, Accept edits, Auto, Bypass), attach, send/stop.
  - Context panel: Environment, Context bar and breakdown, Outputs, Connectors.
  - Settings: API keys per provider (Anthropic, OpenAI, xAI, Google, OpenRouter, custom OpenAI-compatible URL), default model, engine status.
  - Built against `OpenCodeAPI` protocol with a preview/fake implementation, so it does not wait on WP-A.
- **Orchestrator** wires WP-A into WP-B, runs end-to-end with the mock model, screenshots.

Done when: you can add a key (or use the mock), start a session in a folder, chat, watch tools run, approve a permission, see context and usage update.

## M2: Rooms (multi-agent)

- **WP-C RoomEngine** (owns `Rooms/`, its tests): room model and persistence, Team / Debate / Round table / Solo, board, relay via `session/synthetic`, lead plan and assignments, worktrees per agent in git projects, review step, pause/resume, `@agent` routing, spending caps.
- **WP-D Room UI** (owns `Apps/Mac/Rooms/`): new-room sheet (pick agents, models, roles, lead, mode), room view with board thread and per-agent lanes, agent status chips, debate rounds and verdict card.

Done when: two or three mock agents debate a question and produce a verdict, and a team of mock agents splits a small coding task, edits files, reviews, merges.

## M3: Hub, split view, subagents, schedules, usage

- **WP-E Session Hub** (owns `Apps/Mac/Hub/`, `Model/HubBucketing.swift`): buckets, quick replies, inline reply, archive, mark done.
- **WP-F Split view and subagents** (owns `Apps/Mac/Split/`): 2 to 4 panes, open in split, subagent tree in sidebar and transcript.
- **WP-G Schedules and usage** (owns `Apps/Mac/Schedules/`, `Apps/Mac/Usage/`): schedule list and editor, usage popover with per-agent and per-provider totals and caps.

## M4: iPhone remote

- **WP-H RemoteServer** (owns `Apps/Mac/Remote/`, `Remote/` in EnsembleKit): WebSocket + REST, token pairing, QR code, binds to localhost and the Tailscale interface, Remote Control toggle.
- **WP-I iOS app** (owns `Apps/iOS/`): pairing by QR scan, Hub, room and chat views (shared UI), approvals, send messages, permission mode, usage.
- Weekly re-sign job script for the free developer account.

Done when: from the iPhone on cellular with Tailscale on, you can see a running room, approve a permission, and send a message.

## M5: Polish and release

- App icon, onboarding (install OpenCode check, add first key), empty states, keyboard shortcuts, accessibility labels.
- Full end-to-end pass, bug hunt, README screenshots, GitHub release with a built `.app` zip.

## Working rules

- One owner per file. Shared types change only through the orchestrator.
- Every WP ends with: builds, tests pass, short report (what works, what does not, files touched).
- Commit per finished piece with plain-language messages. No secrets in the repo, ever.
- No em dashes in UI text or docs.
