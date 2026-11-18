# Ensemble: notes for agents working in this repo

Ensemble is a native SwiftUI Mac app plus an iPhone remote for coding with several AI models at once, built on the OpenCode 2.3 service. Read `docs/DESIGN.md` (what and why) and `docs/PLAN.md` (milestones and who owns which files) before changing anything. Log finished pieces in `docs/PROGRESS.md`.

## Build and test

```bash
xcodegen                                   # regenerate Ensemble.xcodeproj from project.yml
xcodebuild -project Ensemble.xcodeproj -scheme Ensemble -destination 'platform=macOS' build
xcodebuild -project Ensemble.xcodeproj -scheme EnsembleRemote -destination 'generic/platform=iOS Simulator' build
cd Packages/EnsembleKit && swift test      # unit tests
scripts/install-mac.sh                     # build the last commit, install to /Applications, reopen
```

- Never edit `Ensemble.xcodeproj` by hand; change `project.yml` and run `xcodegen`. Sources are picked up by folder, so new files need no project edit.
- Swift 6 language mode, strict concurrency. macOS 26 / iOS 26 deployment targets. No third-party Swift packages unless the orchestrator approves one.
- After using an iOS Simulator, shut it down (`xcrun simctl shutdown <udid>`), then check `xcrun simctl list devices booted`.

## The engine (OpenCode)

- Installed with Homebrew (`/opt/homebrew/bin/opencode`, v2.3.0). Start it with `opencode service start`; it prints the URL.
- `~/.local/state/opencode/service.json` has `url`, `pid`, `password`, `version`. Auth is HTTP Basic: user `opencode`, that password.
- The full API is in `docs/reference/opencode-2.3.0-openapi.json` (OpenAPI 3.1, 139 paths). Read the schema for an endpoint before calling it; do not guess field names. `opencode api <operationId>` makes authenticated test calls from the shell.
- Live events: `GET /api/event` (SSE), filter with `?types=`.
- Tests that need a model use the mock provider in `tools/mock-llm/` (no real keys, no cost). Never put real API keys in the repo, tests or logs.

## Rules

- One owner per file (see PLAN.md). If you need a shared type changed (`Packages/EnsembleKit/Sources/EnsembleKit/Model/`, `OpenCode/OpenCodeAPI.swift`, `Remote/RemoteProtocol.swift`), say so in your report instead of editing it.
- The look follows the Claude Code desktop app's layout and feel, with Ensemble's own name, accent colour and icon. Never use Anthropic or Claude logos or the word "Claude Code" in the UI.
- No em dashes anywhere (UI text, docs, comments, commits). Use commas, colons or full stops.
- No filler text in the UI. Labels say exactly what the control does.
- Commit messages: plain-language subject saying what changed, no conventional-commit prefixes.
- Reports back to the orchestrator: what now works (and how you verified it), what does not, files touched, open questions. Short.
