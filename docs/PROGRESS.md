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

- GitHub reports the `coquetteluke` account as suspended (push refused, repo page 404). Keep committing locally; push when Luke has it restored. Do not create another account or push anywhere else.
- Remote security fixes committed (protocol v2, mutual HMAC, pre-pairing limits). Mac side of the remote wired: Window > Pair iPhone.
- Icon: Luke picked option 2, Constellation.
- Luke paired his real iPhone Duo with the Mac over home Wi-Fi (protocol v2), confirmed 2026-11-18.
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
- Claude session import: 416 sessions in 91 folders found on Luke's Mac; sessions the desktop app does not list come in archived by default, starred ones pinned.
- Every piece went through a security review; fixes included Gemini fail-closed modes and exact Always rules, Claude settings pinning, git with repository programs switched off and only in trusted folders, agent-written links limited to web and mail, no default-app opening of files.
- Model picker rework (Luke's request): folders by maker with the newest of each tier and Older models, keys 1 to 9, Effort and Fast mode in the picker, subscription or API key per model (remembered, key entered in place), and a model of another engine no longer fails: an empty session starts over on that engine, a session with history offers a new session. Claude models are listed once each with their real 1M windows (checked with the CLI's own `get_context_usage`, notes in docs/reference/claude-code-engine-notes.md); Fable 5.2 is listed by its full id because the `fable` alias still means 5.1.
