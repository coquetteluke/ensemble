# Ensemble

**Code with several AI models at once, and let them work it out together.**

Ensemble is a native Mac app, with an iPhone remote, for coding with Claude, GPT, Grok, Gemini, or any model you have an API key for. Each model is a full coding agent with real tools. Put several on one project as equal teammates and let them debate a decision, or split a job and build it together while you watch every message they send each other.

> Status: early development (started November 2026). Not ready for daily use yet. Progress: [docs/PROGRESS.md](docs/PROGRESS.md).

## What it does

- **Your subscriptions or your keys.** Use your Claude, ChatGPT, SuperGrok or Google AI subscription through each company's own official app or sign-in, or API keys for Anthropic, OpenAI, xAI, Google, OpenRouter, any OpenAI-compatible URL, or local models.
- **Teams of equal agents.** Pick a lead or none. Modes: Team (split the work, build in parallel, review each other), Debate (argue it out, then a verdict), Round table (agree on a plan, one builds, the rest review), or Solo.
- **See them talk.** Every message between agents shows up live, colour-coded by agent.
- **Subagents.** Any agent can start helpers for side tasks.
- **Familiar layout.** Session sidebar, chat with tool cards, a context panel (environment, context usage, outputs, connectors), split view.
- **Session Hub.** One screen that sorts every session into Needs you, Running, Finished and Old, so nothing waiting on you gets forgotten.
- **Permission modes.** Ask, Accept edits, Auto, Bypass.
- **Usage and spending caps** per agent and per provider.
- **Scheduled tasks.**
- **iPhone remote.** Watch and steer from anywhere over Tailscale. Pair by scanning one QR code.

## Built on OpenCode

The agent engine underneath is [OpenCode](https://github.com/anomalyco/opencode) (MIT), a mature open-source coding agent. Ensemble is a new front end and a multi-agent layer that talks to the OpenCode service through its HTTP API. It does not copy or modify OpenCode's code. Thank you to the OpenCode team.

Ensemble is not affiliated with Anthropic, OpenAI, xAI, Google or OpenCode. Its look is inspired by the Claude Code desktop app; the code, name and icon are its own.

## Requirements

- macOS 26 or later, Xcode 27 to build
- [OpenCode](https://opencode.ai) 2.3 or later: `brew install opencode`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project: `brew install xcodegen`
- API keys for the providers you want to use
- For the iPhone remote: iOS 26 and [Tailscale](https://tailscale.com) on both devices

## Build

```bash
brew install opencode xcodegen
```

```bash
xcodegen
```

```bash
open Ensemble.xcodeproj
```

## How it works

See [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT. See [LICENSE](LICENSE).
