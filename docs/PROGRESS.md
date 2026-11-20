# Progress log

Newest first. One line per finished piece; details in commits.

## 2026-11-17

- Picked OpenCode 2.3.0 (MIT, Homebrew) as the engine after comparing OpenCode, Goose, OpenHands, Kilo Code, Cline and Aider. Verified locally: background service, Basic auth `opencode:<password>` from `~/.local/state/opencode/service.json`, 139 endpoints, 98 event types. Spec saved in `docs/reference/`.
- Wrote DESIGN.md and PLAN.md. Started M0.

## 2026-11-17 (night)

- M0 done: XcodeGen project, EnsembleKit skeleton with shared types and the `OpenCodeAPI` interface, both apps build, 4 unit tests pass. Public repo: https://github.com/coquetteluke/ensemble
- Wrote docs/ROOMS.md (how Team, Debate and Round table run).
- M1 started: WP-A (engine client, mock model) and WP-B (Mac window, Claude Code-style layout, context panel) running in parallel.

## 2026-11-18

- WP-A engine client done and committed: OpenCodeClient, EventStream, permission rules (Auto is an allowlist), EngineManager, mock model, 40 unit tests plus 10 live tests against the real service. Engine behaviour notes in docs/reference/opencode-engine-notes.md.
- Subscriptions: Claude via the official `claude` CLI, Google AI via `agy` (installed, signed in), every OpenCode sign-in and coding plan, and a generic ACP engine. Anthropic support's first answer recorded in docs/reference/claude-code-engine-notes.md.
- iPhone app must fit the iPhone Duo's outer and inner screens; landscape enabled.

## 2026-11-18 (later)

- Remote security fixes committed (protocol v2, mutual HMAC, pre-pairing limits). Mac side of the remote wired: Window > Pair iPhone.
- Icon: Luke picked option 2, Constellation.
- Paired physical iPhone Duo over home Wi-Fi (protocol v2), confirmed 2026-11-18.
- Auto mode hardened: dot paths ask in any case, Auto runs only read-only commands (committed). Remote protocol 3 (encrypted frames) committed. Zoom, Auto default, keep awake and lid lock committed and installed. Planned: AI safety check for Auto (like Claude Code's auto mode) so safe builds and tests run without asking.

## 2026-11-18 (evening and night)

- Committed after clean-copy checks (both apps build, full unit suite passes): UI polish (sandboxed widgets, slash menu above the composer, permission shortcuts), Auto asks for every git command and protects opencode.json, the room screen (not wired into the window yet), Claude engine workspace trust and stricter web and symlink rules, the engine router with the Accounts tab, permission cards that always show the whole command and the real Always rule, and Claude project settings on an allowlist, pinned once confirmed.
- Research: docs/research/claude-code-and-antigravity.md (262 features) and docs/FEATURES.md (build waves). Wave 1 running: W1-A notifications and sidebar states, W1-B composer queue, side questions and dictation, W1-C search, file links, view modes and command palette.
- Fonts: interface text uses Inter (bundled, SIL OFL). Agent messages use Ensemble Serif, built from Merriweather (SIL OFL, renamed as its licence requires) and tuned by measurement to read like the reference app's serif; Anthropic's own fonts have no licence for reuse. Build script and notes in tools/fonts/.
- Gemini engine (WP-K): `agy acp` over ACP, Turbo cannot leak into Ensemble sessions, untrusted folders refused. Findings in docs/reference/antigravity-engine-notes.md.
- Later that night: Wave 1 done (alerts, Dock badge and menu bar count, sidebar pins, unread and completed; composer queue with Send now, /btw side questions, dictation, plan limits and grouped models; Command-K search, file links, view modes, command palette). Review pane (diffs, line comments, stage and commit) and rooms in the main window with one shared side pane committed and installed.
- Security passes on every new piece: Claude settings pinned and allowlisted, Gemini fails closed on modes and remembers only exact Always rules, permission cards show the whole command, agent-written links open only for web and mail, no default-app action for file links.


## 2026-11-19 (overnight)

- Wave 2 finished: plan mode and question cards on all three engines (Ensemble enforces read-only Plan on Claude, whose own plan mode let a shell write through), background work list, plan limit ring and auto-continue, workspace trust card with a private OpenCode server for untrusted folders, GitHub pull request bar (pushes only to the branch's own repository or the user's own fork).
- Wave 3 so far: Session Hub (Needs you, Running, Finished, Old, with actions in place), split view (2 to 4 panes, narrow-pane layouts), scheduled tasks on every engine with catch-up after sleep, usage view and API-key spending caps, rewind with choices and redo, per-session worktrees, Customizations (what each agent loads per folder), browser pane with dev-server preview, rooms on the iPhone, phone alerts (local, and optional ntfy).
- Claude session import: 416 sessions in 91 folders found locally; sessions the desktop app does not list come in archived by default, starred ones pinned.
- Every piece went through a security review; fixes included Gemini fail-closed modes and exact Always rules, Claude settings pinning, git with repository programs switched off and only in trusted folders, agent-written links limited to web and mail, no default-app opening of files.
- Model picker rework (Luke's request): folders by maker with the newest of each tier and Older models, keys 1 to 9, Effort and Fast mode in the picker, subscription or API key per model (remembered, key entered in place), and a model of another engine no longer fails: an empty session starts over on that engine, a session with history offers a new session. Claude models are listed once each with their real 1M windows (checked with the CLI's own `get_context_usage`, notes in docs/reference/claude-code-engine-notes.md); Fable 5.2 is listed by its full id because the `fable` alias still means 5.1.
- Auto on Gemini is decided by Ensemble: agy's own `auto` sent no prompts at all (rm -rf, curl, a BypassSandbox retry), so Auto now runs agy in `default` and Ensemble answers each prompt with the same rules and model as the OpenCode safety check. Edits inside the project and read-only commands run, risky commands, sandbox escapes and anything unknown ask. Notes in docs/reference/antigravity-engine-notes.md.
- Google AI plan next to the Claude plan (Luke's request): agy answers its own `/usage` command in print mode (no turn, no quota spent) with a five-hour and a weekly limit per model group, so the usage popover lists both plans (the session's own first), the status line ring in a Gemini session shows Gemini's limits, and the Usage screen and the iPhone show both. A Gemini turn that stops on a quota error gets the limit card and auto-continue. ACP has no usage command. Notes in docs/reference/antigravity-engine-notes.md (Plan usage).
- Cloud relay built and verified locally (Tasks 1 to 8 complete and reviewed, Task 9 local `wrangler dev` E2E and docs complete): Cloudflare Worker and SQLite-backed `Mailbox` / `ClaimLimiter` Durable Objects with WebSocket hibernation, protocol 4 (X25519 ephemeral forward secrecy, `relay:<host>/<id>:443` channel binding, minimum version 4), `RelayHost` and `RelayDialer`, parallel direct-vs-relay racing with 300 ms direct grace window, zero-rescan relay migration (sealed `relayDetails`, `previousRelay`, 30-day fallback host), Mac Remote settings UI (cloud relay on by default), privacy and self-hosting docs, and opt-in `RelayLiveTests` passing end-to-end against real `wrangler dev` (transcript round trip, >5 MiB Mac-to-phone frame, and idle WebSocket ping/pong survival). First production deploy to `relay.coquettemc.com` and iPhone Duo cellular test pending Luke's `npx wrangler login` and deploy approval.

## 2026-11-19

- Typography upgrade (Option C3): replaced Merriweather with Source Serif 4 (`opsz=20`, dark-mode weight curve `430..740`, calligraphic italic) as `Ensemble Serif`.
- Fixed four known bugs: OpenCode no longer double-asks on `ensemble_*` MCP tools, duplicate Opus 5.5 entries deduplicated in New Session and Settings pickers, empty search fields no longer steal digit shortcuts `1` to `9` in `ModelPicker`, and iPhone no longer flashes permission cards before Mac `SafetyCheck` auto-answers them.
- Cross-engine mid-chat model switching: switch between Claude, Gemini, and OpenCode inside one continuous thread, staged for the next sent message with compact handoff context, linked backing sessions, and an inline switch divider.
- Agent-to-agent talk and Second opinion: added `list_agents`, `message_agent`, and `ask_agent` MCP tools with a 4-hop loop guard, `AgentExchangeCardView`, one-click `"Add agent"` solo-to-Room promotion in `CenterHeader`, and inline `"Second opinion"` critiques on completed assistant replies.
- iPhone Duo redesign and power remote: rebuilt all 12 iOS views for both the compact outer cover screen and unfolded split layout, and added backward-compatible protocol v4 RPCs for mid-chat model switching, creating solo sessions and Rooms from phone, inspecting git diffs, and requesting Second opinions on phone.
- Mac UI polish (M5 deep polish): refined Sidebar, Hub, Context Panel, Split View, and Rooms styling and verified snapshots across 100% and 150% zoom.
- Full verification passed on `continue_claude_session`: 88/88 Relay Vitest tests (`0` TS errors), 1,212/1,212 `EnsembleKit` Swift tests across 148 suites, and both `Ensemble` (macOS) and `EnsembleRemote` (iOS Simulator) builds succeeded cleanly.

## 2026-11-20

- Deployed `ensemble-relay` live to Cloudflare Workers at `https://relay.coquettemc.com` (SQLite-backed `Mailbox` and `ClaimLimiter` Durable Objects, observability off), hardened with `403` browser `Origin` rejection, immediate `4004` orphan `data` socket rejection, per-IP and per-DO unproven socket caps across all roles, and `verifyPhone` failure IP blocking; verified live end-to-end against `wss://relay.coquettemc.com` via `RelayLiveTests`.
- Security and privacy audit and hardening across the full repo: replaced the OpenCode `ensemble_*` wildcard with exact tool names, enforced trust, same-folder, and non-escalation boundaries in `list_agents` and `message_agent`, fixed Room 4-hop loop guard propagation, locked down one-shot `ask_agent` / `Second opinion` helpers in `.plan` mode and hid them from UI and MCP lookup, failed closed on cross-engine permission sync and revoked trust checks, neutralized handoff marker injection, validated remote folder/agent/diff/reply inputs, added click-time symlink checks on `FileLinkHitAreas` and `SearchCenter`, set `ThisDeviceOnly` on `ClaudeKeychain`, and scrubbed all personal username chunks from test fixtures and unit tests.
- Fixed 19 core and remote bugs: cross-engine MCP tool resolution, live streaming text/reasoning deltas and backing-session permissions on iPhone, `.sessionReplaced` navigation desync in `RemoteAppModel` and `ChatView`, cross-engine first-prompt rollback ordering and orphan guard, inactive-backing `.executionEnded` isolation, restart usage/timestamp folding, and `.plan` to `.ask` room promotion with secret redaction.
- GUI/UX polish and new features across Mac and iPhone Duo: one-tap `"Continue with <Model>"` on Second Opinion cards, inline model attribution tags after mid-chat switches, one-click Retry on failed turns, Copy and Share as Markdown (`TranscriptExport`), dismissible `"Next message"` banner and real keyboard shortcuts (`Cmd+Shift+M`, `Cmd+Shift+H`, `Cmd+L`) on Mac, dead button cleanup in `ContextPanelView`, WCAG AA contrast upgrade, compact iPhone Duo toolbar and composer fixes, shared `DiffView` with line numbers and word highlights in `RemoteDiffSheet`, `MarkdownView` in `RemoteSecondOpinionCard`, floating `"Jump to latest"` pill, and sensory feedback haptics.
- Final verification passed on `continue_claude_session`: 92/92 Relay Vitest tests (`0` TS errors), 1,231/1,231 `EnsembleKit` Swift tests across 149 suites, live `RelayLiveTests` against `wss://relay.coquettemc.com`, 369 Mac GUI snapshots plus built-in GUI checks, and visual inspection of Mac and iPhone Duo dark/light captures.

## 2026-11-20 (hardening sprint, started in Antigravity, finished in Claude Code)

- Round 1 features: find inside a transcript (Cmd+F on Mac, live highlight and jump), Room board filtering and jump to an agent, and Session Hub triage with Archive all, also from the iPhone (new `archiveSession` remote call). Shared models `TranscriptFinder`, `RoomBoardFilter` and `HubFilter` with unit tests.
- Round 2 visual audit of Mac and iPhone Duo (outer and unfolded, light and dark): preview data without a real username, Command Palette bottom edge, Room Filter chip, iPhone composer and room agents bar. Debug-only unfolded split-view snapshots (`RemoteSnapshots.swift`, `#if DEBUG`).
- Round 3 bug hunt: 34 candidates from three hunters, all confirmed by two skeptics and fixed with regression tests. Remote and relay (10), SessionStore and UI (11), Rooms and agent tools (13): turn-end reentrancy, pause and stop re-checked after every await, room members reached only through their room, CHANGES kept after a later keyword, hop chains that a shallow hop cannot reset, goal checks and takeovers that survive a capped agent, unique room branch names with validated git arguments, duplicate JSON-RPC ids refused, cancelled browser calls stop at once, browser agent navigation and console locked to the approved origin, proposals fail closed without a session folder, and messages from other agents are not posted as the user.
- Round 4 security review fixes: rooms run git through `GitRunner` (no repository hooks, file system monitor or filters) and only in trusted folders; a room worktree is never created through a linked `.ensemble` folder; a message another agent delivers no longer counts as the user's turn, so the agent-to-agent hop limit holds for solo sessions too. Test client sockets set `SO_NOSIGPIPE` (a test run could die with signal 13). The mock model fills `{{worktree}}` so the live room scripts follow the new branch names.
- Verification: 1,291/1,291 `EnsembleKit` tests in 158 suites, 6/6 live room tests against OpenCode and the mock model, live relay test against local `wrangler dev`, 96/96 relay tests, Mac and iOS Simulator builds.
