# Progress log

Newest first. One line per finished piece; details in commits.

## 2026-11-17

- Picked OpenCode 2.3.0 (MIT, Homebrew) as the engine after comparing OpenCode, Goose, OpenHands, Kilo Code, Cline and Aider. Verified locally: background service, Basic auth `opencode:<password>` from `~/.local/state/opencode/service.json`, 139 endpoints, 98 event types. Spec saved in `docs/reference/`.
- Wrote DESIGN.md and PLAN.md. Started M0.

## 2026-11-17 (night)

- M0 done: XcodeGen project, EnsembleKit skeleton with shared types and the `OpenCodeAPI` interface, both apps build, 4 unit tests pass. Public repo: https://github.com/coquetteluke/ensemble
- Wrote docs/ROOMS.md (how Team, Debate and Round table run).
- M1 started: WP-A (engine client, mock model) and WP-B (Mac window, Claude Code-style layout, context panel) running in parallel.
