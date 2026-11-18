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

## M1.5: Subscription engines

- **WP-J Claude Code engine** (owns `Packages/EnsembleKit/Sources/EnsembleKit/Engines/ClaudeCode/`): runs the official `claude` CLI headless per agent session with stream-json input and output, maps its events to `EngineEvent`s and `TranscriptItem`s, permission prompts answered from Ensemble, resume by session id, subagents shown nested, usage and limits.
- **WP-K ACP engine** (owns `Engines/ACP/`): a generic Agent Client Protocol client (JSON-RPC over stdio: initialize, session/new, session/prompt, streamed session/update, session/request_permission, cancel) implementing `OpenCodeAPI` per agent tool. First target Google's `agy acp` (installed: `brew install --cask antigravity-cli`, v1.5.10, already signed in through the Antigravity app). Then test each other ACP tool (Gemini CLI, Qwen Code, Codex ACP adapter, Cursor CLI, Kiro CLI, Goose, `opencode acp`) and keep a registry of the ones that work: install command, launch command, sign-in hint.
- **WP-L Router and Accounts UI** (owns `Engines/EngineRouter.swift`, `Apps/Mac/Settings/Accounts*`): `EngineRouter` picks the engine per session. Settings > Accounts lists "Subscriptions" (Claude, Google AI, every OpenCode `oauth` integration with a Sign in button that runs `integration.oauth.connect`, opens the browser and polls until done, every coding plan, every working ACP tool) and "API keys" (searchable list of all OpenCode key integrations), each with connected state and Sign out.

Done when: one room runs a Claude agent on the Claude subscription and a Gemini agent on the Google subscription, and they debate.

## M1.6: Import from Claude Code

- **WP-M Claude Code import** (owns `Packages/EnsembleKit/Sources/EnsembleKit/Import/`, `Apps/Mac/Import/`): a Settings screen and first-run offer that reads Claude Code's own files (works for any user, no app-private data needed):
  - Projects and sessions from `~/.claude/projects/<project>/*.jsonl` (folder from each transcript's `cwd`, title from the last `custom-title` entry, else the last prompt; skip sidechains; long folder names are cut to 200 characters plus a hash). Imported sessions are linked, not copied, and open in the Claude Code engine, which resumes them with `claude --resume`. Warn when a session is also open in Claude Code (file still being written).
  - Instructions and memory: `~/.claude/CLAUDE.md`, project `CLAUDE.md`, memory folders, shared live.
  - MCP servers from `~/.claude.json` (user and project scopes) into the engines' configs, never printing secret values.
  - Permission allow-lists mapped to the nearest Ensemble mode, with a summary of what did not map.
  - Claude desktop app sidebar groups, sections and pins: optional JSON import (Luke's exported once by the orchestrator through the app's own tools); otherwise group by folder.
  - Hooks and SSH/cloud environments are listed as not imported, with the reason.
- Done when: Luke's 100+ sessions show under their folders in Ensemble, one old session resumes on the Claude subscription, and his MCP servers appear under Connectors.

## M1.7: MacBook power, zoom, defaults (requested 2026-11-18)

- Ensemble targets MacBooks first (Apple silicon laptops). Windows and Linux are out of scope for now.
- Auto is the default permission mode (done).
- **Zoom:** Cmd + / Cmd - / Cmd 0 scale the whole window through the theme, saved between launches (WP-B).
- **WP-N Power** (owns `Apps/Mac/Power/`): per session and room, "Keep Mac awake" (IOPMAssertion that stops idle sleep and display sleep, like `caffeinate -d`) and "Keep running with the lid closed" (`pmset disablesleep 1` through a narrow sudoers rule, the same method as Luke's `lidlock`). Lid lock always turns on Keep awake; Keep awake can be on alone. Released when the session finishes (after a grace period) or when switched off, on quit, and at launch after a crash. Never turns off a lid lock the user set outside Ensemble. One-time setup asks for the admin password in the macOS dialog to install the sudoers rule; Ensemble never sees the password. Hidden on Macs without a lid.

## M1.8: Claude Code polish, slash commands, GitHub (requested 2026-11-18)

- **Transcript polish (WP-B, queued):** collapsible activity groups, a live working row (spinner, current step, elapsed time), a pinned task-list card from agents' todo tools, hover actions on user messages (relative time with exact-time tooltip; Fork, Rewind, Edit, Copy icons; Rewind and Edit disabled while the agent works), inline visuals from `widget` code blocks in a sandboxed web view, effort and fast-mode pickers, and a `/` command menu (Ensemble commands plus each engine's commands and skills). Engines expose these through the optional protocols in `OpenCode/EngineCapabilities.swift`.
- **WP-P GitHub** (owns `Packages/EnsembleKit/Sources/EnsembleKit/GitHub/`, `Apps/Mac/GitHub/`): use the official `gh` CLI when it is installed and signed in (fall back to GitHub's device sign-in flow later). Shows the repo, branch and changes for the session's folder; Commit and push, Create pull request (title and body drafted by the agent), pull request status with CI checks in the context panel, review comments into the session, a "Fix CI" action that hands failing logs to the agent, open in browser. Never stores GitHub tokens itself.

## M1.9: Workspace trust (security, 2026-11-18)

- First time a folder is used, Ensemble asks "Trust this folder?" (like Claude Code). Until trusted, every engine runs without that folder's own settings, hooks, config and instructions: Claude Code with `--setting-sources user`, OpenCode without project `opencode.json`/plugins (mechanism being checked), agy without workspace `.agents/` hooks and plugins. Shared `WorkspaceTrust` store in `Engines/WorkspaceTrust.swift`; the prompt and a Trusted folders list in Settings come with the UI work.

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

## M5: Deep polish and release (starts ONLY when Luke gives the okay)

Luke's goal: nothing should look quickly generated. Do not start this milestone until he explicitly says go.
- Bug hunt with Luke's bug-hunt workflow (~/Bug Fixing hub: hunters and skeptics per area, then parallel fixers, tests).
- Design pass: every screen side by side with the Claude Code desktop app in dark and light, at 80/100/150% zoom and on both iPhone Duo screens: spacing, alignment, type scale, icon weights, hover and pressed states, animations, empty, loading and error states, copy (no filler, no em dashes).
- Real-use pass: real sessions with Claude, Gemini and free models, rooms, the phone; fix every rough edge found.
- Accessibility (VoiceOver labels, keyboard navigation, contrast) and performance (long transcripts, many sessions, memory).
- Code tidy: dead code, naming, comments, README with screenshots.

## M5 (original list): Polish and release

- App icon, onboarding (install OpenCode check, add first key), empty states, keyboard shortcuts, accessibility labels.
- Full end-to-end pass, bug hunt, README screenshots, GitHub release with a built `.app` zip.

## Working rules

- One owner per file. Shared types change only through the orchestrator.
- Every WP ends with: builds, tests pass, short report (what works, what does not, files touched).
- Commit per finished piece with plain-language messages. No secrets in the repo, ever.
- No em dashes in UI text or docs.
