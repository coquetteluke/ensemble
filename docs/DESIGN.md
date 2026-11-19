# Ensemble design

Ensemble is a native Mac app (plus an iPhone remote) for coding with several AI models at once. Each model is a full agent with real tools, and you can let them talk to each other: debate a decision, or split a job and build it together while you watch. It looks and feels like the Claude Code desktop app, but it works with any model you have an API key for.

Owner: Luke (GitHub `coquetteluke`). Started 2026-11-17. Public, MIT licensed.

## Goals

1. Feel like the Claude Code desktop app: left session sidebar, chat with tool-call cards, composer with model and permission-mode menus, right-hand context panel (environment, context usage, outputs, connectors), split view.
2. Your subscriptions first, API keys too: Claude Pro/Max, ChatGPT Plus/Pro, SuperGrok and Google AI Pro/Ultra through each company's own official app or sign-in, plus API keys for Anthropic, OpenAI, xAI, Google, OpenRouter, any OpenAI-compatible URL, and local models. (See "Engines".)
3. Several equal agents per project. Every agent has a real role. None are side helpers. You choose who leads, or nobody.
4. Agents talk to each other in the open: you see every message they send each other.
5. Each agent can start its own subagents.
6. Folders and projects, scheduled tasks, usage and spending per agent and provider, permission modes (Ask, Accept edits, Auto, Bypass).
7. Session Hub: one screen that shows every session sorted into Needs you, Running, Finished, Old, and lets you answer a waiting session without opening it.
8. iPhone remote control from anywhere (through an end-to-end encrypted cloud relay by default, or direct over Tailscale and local Wi-Fi), set up by scanning one QR code.

## Non-goals

- Copying Claude Code's code or branding. Ensemble has its own name, icon and code. Only the layout and feel are similar.
- Copying or reusing subscription logins inside Ensemble. Anthropic and Google suspend accounts whose subscription sign-ins are used by third-party apps. Ensemble instead runs each company's own official program (Claude Code CLI, Antigravity CLI) under your own login, and uses the official sign-ins that OpenAI and xAI allow in other tools.
- Windows or Linux apps (SwiftUI, Apple platforms only).

## Architecture

```
┌──────────────── Ensemble.app (macOS, SwiftUI) ────────────────┐      ┌─ Ensemble Remote (iOS) ─┐
│ UI: sidebar · transcript · composer · context panel · hub     │      │ hub · chats · approvals │
│ RoomEngine: team / debate / round table, message relay        │◀────▶│ (EnsembleKit UI)        │
│ RemoteServer: WebSocket + REST on localhost and Tailscale     │ WS   └─────────────────────────┘
│ EngineManager: starts / checks the OpenCode service           │
└──────────────┬────────────────────────────────────────────────┘
               │ HTTP (Basic auth) + Server-Sent Events
┌──────────────▼──────────── OpenCode 2.3.x service (MIT) ──────┐
│ agent loop · tools (read/edit/bash/grep/web) · subagents ·     │
│ permissions · providers & credentials · sessions · schedules · │
│ MCP · LSP · worktrees · usage and cost per session             │
└────────────────────────────────────────────────────────────────┘
```

### Why OpenCode underneath

OpenCode (github.com/anomalyco/opencode, MIT) is a mature open-source coding agent that already does the hard parts: the tool loop, file editing, shell, subagents (child sessions), permission prompts, 75+ providers, MCP servers, compaction, scheduling, and per-session cost. Version 2.x runs as one background service with a full HTTP API (139 endpoints, OpenAPI spec saved in `docs/reference/opencode-2.3.0-openapi.json`) and a live event stream (98 event types). Ensemble is a new front end and a multi-agent layer on top of it. Ensemble does not copy or modify OpenCode's code; it talks to the installed service. Writing our own agent engine would take months and be worse.

### Engines: subscriptions and keys

An agent's model decides which engine runs it. Every engine implements the same `OpenCodeAPI` protocol (to be renamed `AgentEngine`), and an `EngineRouter` sends each session to the right one, so rooms can mix them: a Claude agent on your Claude subscription can debate a Gemini agent on your Google subscription.

Ensemble is public, so it supports every subscription that can be linked legitimately, not only the ones Luke uses.

| Engine | Runs | Pays with | How |
|---|---|---|---|
| OpenCode | 330+ providers | Official sign-ins (browser login): ChatGPT Plus/Pro, SuperGrok, GitHub Copilot, GitLab Duo, Poe, OpenCode Console/Zen and OpenCode Go. Coding-plan keys: Kimi For Coding, Z.AI and Zhipu GLM Coding Plan, MiniMax, Alibaba, Tencent, Volcengine, StepFun, Xiaomi, Umans, KUAE, Ollama Cloud, Synthetic and others. Cloud logins: AWS Bedrock (SSO profile), Google Vertex (gcloud). API keys for everything else, including OpenRouter. Local: LM Studio, Ollama. | OpenCode service; Settings reads `GET /api/integration` and shows a Sign in button for `oauth` methods, setup steps for `external` methods, and a key field otherwise. |
| ACP agents | any coding tool that speaks the Agent Client Protocol over stdio | that tool's own subscription and login | One generic ACP client in Ensemble: Google's `agy acp` (Google AI Pro/Ultra) first; then each other ACP tool that works when tested (candidates: Gemini CLI for Workspace/Code Assist accounts, Qwen Code, Codex via its ACP adapter, Cursor CLI, Kiro CLI, Goose, OpenCode itself). Only tools verified to work are listed in the app. |
| Claude Code | Claude Opus, Sonnet, Haiku | your Claude Pro/Max subscription | Ensemble runs the official, unmodified `claude` CLI headless (`-p`, stream-json in and out), one process per agent session, logged in as you; Anthropic's docs allow this and it draws from your plan limits. Ensemble never touches the login. Rules and flags: `docs/reference/claude-code-engine-notes.md`. |
| (Antigravity, via ACP) | Gemini models (and Claude models Google includes) | Google AI Pro/Ultra subscription | Ensemble runs Google's official `agy acp`, logged in as you. Notes: `docs/reference/antigravity-engine-notes.md`. |

OpenCode also lists a "Claude Agent" integration that uses the official Claude Code login. Ensemble's own Claude Code engine is preferred (full Claude Code tools and subagents), with OpenCode's as a fallback to compare.

The model picker has a folder per model maker (Claude, Gemini, ChatGPT, Grok, then DeepSeek, Qwen, Kimi, GLM, Mistral, Meta, MiniMax, free models and models on this Mac): the newest model of each tier first, the rest under Older models, with the session's maker at the top. The same model from several engines is one entry; picking it asks once whether to use the subscription or an API key (and takes the key right there when none is saved), and remembers the answer. The rules live in `ModelPicker/` in EnsembleKit. The usage popover shows each subscription's remaining limits where the engine reports them, so a long debate does not quietly use up a weekly allowance.

### Talking to OpenCode

- Service: `opencode service start` prints its URL. `~/.local/state/opencode/service.json` holds `url`, `pid`, `password`, `version`.
- Auth: HTTP Basic, user `opencode`, password from that file. (Bearer and custom headers return 401.)
- Key endpoints: `POST /api/session` (create, with `model`, `agent`, `location.directory`, `permissions`, `parentID`), `POST /api/session/{id}/prompt` (`text`, `files`, `delivery: steer|queue`), `POST /api/session/{id}/synthetic` (inject text without the user speaking: used to relay other agents' messages), `POST /api/session/{id}/permission/{req}/reply` (`once|always|reject`), `POST /api/session/{id}/interrupt`, `GET /api/session/{id}/message`, `GET /api/session/{id}/context`, `GET /api/session/{id}/diff`, `POST /api/session/{id}/model`, `GET /api/event` (SSE, filter with `types`), `GET /api/model`, `GET/POST /api/credential`, `GET /api/integration`, `GET /api/mcp`, `/api/experimental/schedule`, `/api/experimental/usage/limits`, `/api/experimental/session/stats`.
- Events Ensemble renders: `session.text.delta`, `session.reasoning.delta`, `session.tool.called|progress|success|failed`, `session.step.*`, `session.usage.updated`, `session.execution.started|succeeded|failed|interrupted`, `session.status`, `session.idle`, `permission.asked|replied`, `session.created` (subagents carry `parentID`), `filesystem.changed`, `mcp.status.changed`.
- Minimum engine version is checked at launch; Ensemble tells you how to update if it is older.

### Agents and rooms

- **Agent**: a name, a model (`providerID/modelID#variant`), a role prompt, a colour, a spending cap. Backed by one OpenCode session per room.
- **Room**: a project folder plus one or more agents plus a mode. A plain chat is a room with one agent.
- Modes:
  - **Solo**: one agent, like Claude Code.
  - **Team** (default for 2+ agents): the lead (your choice) writes the plan and splits it into pieces with owners. Each agent works at the same time on its own files (in its own git worktree when the project is a git repo). Agents post progress, questions and diffs to the room board. Before finishing, each piece is reviewed by another agent. The lead merges.
  - **Debate**: agents argue a question in rounds (default 3). Each round every agent sees all prior arguments. Then a judge (the lead, or you) writes the decision with reasons. No file edits unless you allow them.
  - **Round table**: agents discuss in turns until they agree on a plan, then one builds while the others review each step and can take over.
- Relay: Ensemble's RoomEngine is the only thing that moves messages between agents. When agent A posts to the board, the engine injects it into the other agents' sessions with `session/synthetic` (tagged with A's name). Every board message is shown to you live in the room view, with each agent's colour.
- Equal agents: the lead only coordinates. Every agent owns real work or a review duty, and any agent can object on the board.
- You can talk to the whole room or to one agent (`@name`), pause the room, or take over.

### Permission modes

| Mode | Behaviour |
|---|---|
| Ask | Every edit and command asks you (OpenCode default ruleset). |
| Accept edits | File edits allowed; commands ask. |
| Auto | Edits inside the project and an allowlist of read-only and build/test commands run without asking; every other command, web fetches and anything outside the project ask. (An allowlist, not a deny list: deny lists are easy to slip past.) |
| Bypass | Everything allowed. Shown in red. |

Permission prompts from any agent appear in that agent's pane, in the room view, in the Session Hub, and on the iPhone.

### Usage and spending

- Per agent and per provider: tokens in and out, cost in USD, from `session.usage.updated` and session stats.
- Spending caps per agent and per room. When a cap is hit, that agent pauses and the room tells you.
- The usage button at the bottom of the window opens a popover: today, this week, per provider, per agent, and provider rate limits where OpenCode reports them.

### Window layout (Claude Code feel)

- **Left sidebar**: New session, Session Hub, projects with their sessions and rooms (agent colour dots, running spinner, needs-you badge), Scheduled, Settings.
- **Centre**: transcript. User messages, agent text (Markdown), collapsible tool cards (command, file edit with diff, search), subagent cards that open the child session, permission cards with Allow once / Always / Reject. In rooms, each message carries the agent's name and colour, and board messages between agents show as a thread you can follow.
- **Composer**: text box, attach, agent picker (or `@agent`), model chip, permission-mode menu, send or stop. Usage button and context meter in the status line under it.
- **Right context panel** (toggleable, like Claude Code): Environment (This computer, project folder and extra folders, Remote Control toggle), Context (percent used, used / limit, coloured bar, breakdown rows: Messages, Tools, System prompt, Skills, MCP, Memory files, Agents, Autocompact buffer, Free space), Outputs (files changed this session, click to open diff), Connectors (MCP servers with status and Authenticate buttons).
- **Split view**: two to four panes side by side; drag a session onto the window edge or use Open in split.
- Dark theme by default, matching the Claude Code desktop palette closely but with Ensemble's own accent.

### Session Hub

The same rules as Luke's existing `~/Session Hub` control room, as a screen:

| Bucket | Rule |
|---|---|
| Needs you | Not running, active in the past 7 days, and it ended with something for you: a question, a permission prompt, a failure, a spending cap hit. |
| Running | An agent in it is working (including background subagents). |
| Finished | Not running, active in the past 3 days, last message asks nothing of you. |
| Old | Everything else. |

Rows show title, project, agents, age and the ask in a few words, with one or two quick-reply buttons and a reply box. Archive and Mark done on every row. Later: also list Claude Code desktop sessions (read-only, from `~/.claude/projects`), using the agent bridge's parsing.

### Scheduled tasks

Create, pause, resume and delete schedules through OpenCode's schedule API: a prompt, a room or agent, a folder, and a cron-style time. Results land as sessions in the Hub.

### iPhone remote

- Ensemble Mac runs a `RemoteServer` (WebSocket) on localhost, its Tailscale addresses, and optionally the local network, plus a `RelayHost` connection to the cloud relay (on by default when Remote Control is on).
- Pairing: the Mac shows a QR code containing its direct hosts (if any), port, optional relay `{ url, mailbox }`, Mac name, protocol version, and a random 32-byte pairing token. With the cloud relay on, the QR code works even with no Tailscale or local network listener. The iPhone scans it once and saves it in the Keychain.
- The iPhone app shows the Session Hub, rooms and chats live, lets you send messages, approve or reject permission prompts, answer questions and plans, switch permission mode, control rooms, and see usage.
- The Mac never exposes the OpenCode service itself; only `RemoteServer`, authenticated with the pairing token.
- **Protocol version 4 (end-to-end encrypted with forward secrecy):**
  - Minimum accepted version is **4** on both Mac and phone; older versions (1 to 3) are refused before reading further frames.
  - On connect, the Mac sends a plaintext `challenge` containing a fresh 32-byte `serverNonce` and a fresh ephemeral X25519 public key (`macKey`).
  - The phone answers with a plaintext `hello` carrying a fresh 32-byte `clientNonce`, its own ephemeral X25519 public key (`phoneKey`), `dialedHost`, `dialedPort`, and `clientProof = HMAC-SHA256(token, serverNonce || clientNonce || macKey || phoneKey || "ensemble-client")`. The token itself never travels on the wire.
  - Both sides compute the 32-byte X25519 `sharedSecret` and immediately discard both ephemeral private keys after the handshake, so recorded traffic stays unreadable even if the pairing token leaks later.
  - Channel keys are derived with `HKDF-SHA256(ikm: token UTF-8 || sharedSecret, salt: serverNonce || clientNonce, info: "ensemble-remote/<version>|<direction>|<normalizedHost>|<port>", 32 bytes)` with separate keys for `client-to-server` and `server-to-client`. Direct connections bind the dialed host and port; relayed connections bind `relay:<relay host>/<mailboxID>` on port `443`, so keys for one mailbox or path cannot open frames on another.
  - Every frame after `hello` is sealed with ChaChaPoly (`ciphertext || 16-byte tag`, AAD `ensemble-remote/<version>`, 12-byte nonce of 4 zero bytes + big-endian 64-bit per-direction counter) and sent as binary WebSocket frames. Any plaintext, modified, replayed, or out-of-order frame closes the connection.
  - The first sealed frame is the Mac's `welcome`, carrying `serverProof = HMAC-SHA256(token, clientNonce || serverNonce || phoneKey || macKey || "ensemble-server")` and echoing the phone's `deviceID`. When a relay is active, the Mac immediately follows `welcome` with a sealed `relayDetails` frame.
- Free Apple developer accounts sign apps for 7 days. A small launchd job rebuilds and reinstalls the iPhone app weekly when the phone is connected (same approach as CoquettePanel).

### Cloud relay

- **Architecture:** A TypeScript Cloudflare Worker (`relay/src/index.ts`) accepts WebSocket upgrades on `/v1/mailbox/<id>/host`, `/v1/mailbox/<id>/phone`, and `/v1/mailbox/<id>/data/<conn>` (rejecting other paths with `404` and non-upgrades with `426`) and routes them to a SQLite-backed `Mailbox` Durable Object (`relay/src/mailbox.ts`) per paired Mac, plus a `ClaimLimiter` Durable Object (`relay/src/claim-limiter.ts`) for per-address claim throttling. It runs on the Workers free plan using the WebSocket Hibernation API (`ctx.acceptWebSocket`, tags, `serializeAttachment`, and a `"ping"` to `"pong"` text auto-response) so idle Macs cost no duration while connected.
- **Identity and proofs:**
  - **Mailbox ID:** 32 random bytes, base64url (43 chars), stored in the Mac Keychain alongside the pairing token. It is a routing address in the URL path, not a secret.
  - **Host key:** Per-mailbox Ed25519 key pair in the Mac Keychain. On first connection the Mac claims the mailbox (`claim` frame with `hostKey`, `accessKey`, and Ed25519 signature); later connections prove ownership (`auth`) by signing `ensemble-relay-host|<id>|<nonce>`. If a mailbox was cleaned up after 90 days idle or lost in a redeploy, the Mac silently reclaims the same ID with the same key; if held by a different key (`4009` / `4001`), the Mac marks it taken and rotates to a new identity.
  - **Access key and phone proof:** `accessKey = HKDF-SHA256(ikm: token UTF-8, salt: "ensemble-relay", info: "ensemble-relay-access", 32 bytes)`. One-way, so the relay never learns the token. Phones must prove knowledge via `HMAC-SHA256(accessKey, "ensemble-relay-phone|<id>|<nonce>")` before the relay notifies the Mac, turning strangers away at the edge.
- **Forwarding and connection racing:**
  - The Mac keeps one hibernated control socket (`/host`). When an authorized phone connects to `/phone`, the relay assigns a 16-byte base64url `<conn>` ID, replies `waiting`, and sends `phone` (`conn` + single-use 32-byte `token`) to the Mac.
  - The Mac opens `/data/<conn>`, sends `data` with that token, and hands the socket to `RemoteServer.adopt` (isolated under address `relay:<conn>` with a separate pending handshake budget per relay identity). The relay sends `paired` to the phone and forwards all subsequent frames (binary or text) unchanged between the two sockets; closing either side closes the other. Any phone frame before `paired` closes the phone with `4002`.
  - The phone races its direct hosts and the relay together. A direct connection wins if it completes before or within 300 ms of the relay; otherwise the relay wins and losing attempts are cancelled cleanly.
- **Size caps and per-mailbox limits:**
  - Frame caps: 1 MiB phone to Mac, 16 MiB Mac to phone (both under Cloudflare's 32 MiB received-message cap; oversized frames close both sides with `4013`). Control frames are JSON text up to 2 KiB on a strict fixed schema.
  - Concurrency and timeouts: up to 8 phones per mailbox, 3 waiting for a data socket, and 3 unproven phone sockets per source address; 10 s challenge timeout and 15 s pairing/data-token timeout (close `4008`).
  - Daily budget: 40,000 incoming messages and 200 MiB per mailbox per UTC day (counts sit in socket attachments across hibernation and flush to storage at most once a minute and on close). Overspending closes paired sockets with `4029` and sends a `limit` frame to waiting phones and the Mac's control socket.
  - Abuse protection: 10 mailbox claims per normalized IP per hour (`ClaimLimiter`). When a relayed phone fails the inner protocol 4 handshake, the Mac reports `badHandshake` with `<conn>`, and the Durable Object blocks that phone's hashed normalized IP (full IPv4, `/64` for IPv6) for 15 minutes after 5 failures without ever exposing phone IPs to the Mac. Unused mailboxes are deleted by alarm after 90 days idle.
- **Zero-rescan relay migration:**
  - The Mac sends its current relay URL and mailbox ID inside the encrypted channel (`relayDetails`) after `welcome` and whenever the active relay changes.
  - The phone saves the new `relay` and keeps its last working relay in `previousRelay` as a fallback until it connects once through the new one (and clears an unproven target if the Mac rolls back).
  - When the Mac switches relay addresses (for example moving off the default `wss://relay.coquettemc.com` to a self-hosted relay or a new domain), it keeps the previous relay host active for 30 days so returning phones learn the new relay details without rescanning the QR code.
- **Privacy and self-hosting:** Logging and Worker observability are off. See `docs/reference/relay-privacy.md` for what Cloudflare can and cannot see, `docs/reference/relay-notes.md` for platform limits, and `relay/README.md` to deploy your own relay on the Workers free plan.

## Project layout

```
project.yml                  XcodeGen spec (run `xcodegen` to make Ensemble.xcodeproj; not committed)
Packages/EnsembleKit/        shared Swift package (macOS + iOS)
  Sources/EnsembleKit/
    Model/                   Agent, Room, Message, Part, Usage, PermissionMode, SessionSummary
    OpenCode/                OpenCodeClient (REST), EventStream (SSE), DTOs
    Engine/                  EngineManager (service start, health, version)
    Rooms/                   RoomEngine, modes, relay
    Remote/                  RemoteProtocol, RemoteAuth, RemoteChannel, RemoteServer, RemoteClient, RelayHost, RelayDialer
    UI/                      shared SwiftUI views (transcript, tool cards, theme)
  Tests/EnsembleKitTests/
Apps/Mac/                    Ensemble.app (window, sidebar, panels, settings, RemoteControlController)
Apps/iOS/                    Ensemble Remote
relay/                       Cloudflare Worker + Mailbox / ClaimLimiter Durable Objects (TypeScript)
tools/mock-llm/              OpenAI-compatible mock model server for tests (scripted replies and tool calls)
scripts/                     build, test, install helpers
docs/                        DESIGN.md, PLAN.md, PROGRESS.md, reference/
```

## Testing

- Unit tests in EnsembleKit for DTO decoding (against real captured OpenCode responses), event parsing, room relay rules, hub bucketing, permission-mode rulesets.
- End-to-end tests drive a real OpenCode service with the mock model provider: create session, prompt, stream, tool call, permission prompt, reply, subagent, room relay between two mock agents. No real API keys or money needed.
- UI checked by building and launching the real app and taking screenshots.
- Real-provider smoke test only with keys Luke adds himself.

## Decisions made without Luke (he asked for autonomous work on 2026-11-17)

- Native SwiftUI for Mac and iPhone, sharing EnsembleKit.
- OpenCode 2.3.x as the engine, installed with Homebrew, not bundled.
- Team-with-a-lead as the default multi-agent mode; Debate and Round table also included.
- Started with remote over Tailscale (already on his Mac and iPhone); on 2026-11-18 Luke approved adding the end-to-end encrypted Cloudflare Workers cloud relay on by default alongside direct/Tailscale.
- XcodeGen project file so parallel workers do not fight over the Xcode project.
- Commits use GitHub's no-reply email so his real address stays off a public repo.
