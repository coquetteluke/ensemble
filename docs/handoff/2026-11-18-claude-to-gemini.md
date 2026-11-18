# Handoff: Claude to Gemini (2026-11-18)

Luke is moving this Ensemble session from Claude Code to Antigravity. This note is what you need to carry on. The full session is long; this is the reliable summary.

## Start here
1. Read `CLAUDE.md` (repo rules), then `docs/FEATURES.md` (status), then this file.
2. Main is clean at `4d14e8e`, and that build is installed in /Applications (signed with Luke's Apple Development certificate).
3. The cloud relay is half built on the branch `cloud-relay`, in the worktree `.claude/worktrees/cloud-relay`. See "Cloud relay" below.

## Rules that matter most
- **No em dashes anywhere:** code, comments, UI text, docs, commits. Use commas, colons or full stops.
- **Plain-language commit messages.** No conventional-commit prefixes.
- **Never push.** Luke's GitHub account is suspended; keep committing locally.
- **Never deploy to Cloudflare** until Luke has run `npx wrangler login` himself and said yes to that deploy.
- **The deep polish pass (PLAN.md M5) waits for Luke's explicit okay.**
- **Anthropic:** Ensemble only runs the unmodified `claude` binary. Never read or store its OAuth tokens or keychain items.
- **Google:** only the official `agy`. Never call Google APIs directly or reuse agy's credentials.
- **No secrets** in the repo, tests or logs. A commit hook blocks secret-shaped strings; never add an "allow" marker to get past it.
- **Luke's style:** he reads on his phone. Lead with the action or the result, keep it short, use numbered steps, and give concrete times.
- **iOS Simulators:** shut down any you boot (`xcrun simctl shutdown all`).
- **Low battery:** don't stop work for it unless the battery is at 2% with the charger out.

## How to build, test and install
- `xcodegen`, then the two `xcodebuild` schemes: `Ensemble` (macOS) and `EnsembleRemote` (iOS Simulator).
- `cd Packages/EnsembleKit && swift test --scratch-path <own path>`.
  - Run it as a background job. Spawning tests fail with "Permission denied" when run in the foreground in the Claude sandbox; this may not apply to you.
  - A few suites flake under load: rooms, terminal, ACP, the composer queue, the GitHub controller. Rerun one alone before calling it broken.
- `cd relay && npx vitest run && npx tsc --noEmit` for the relay.
- `scripts/install-mac.sh` builds the last commit, signs it with Luke's certificate and installs it.
- `scripts/ios-resign-weekly.sh --force --device <udid>`, run from a clean copy of HEAD, puts the iPhone app on Luke's Duo. Copy `Config/Local.xcconfig` into the copy first.
- Verify on a clean worktree from HEAD plus the change before committing. Most bugs today were caught that way.

## Done today (all committed on main and installed)
- **Wave 4:**
  - room swarm views and goal mode (`/goal`);
  - agent tools (propose-session cards, browser tools; "Always for this site" works only in Claude sessions);
  - the safety check for Auto on OpenCode, where the model may only approve builds, tests, linters and read-only commands;
  - Gemini Auto decided by Ensemble.
- **Model picker:**
  - folders by maker, with newest models first and an "Older models" folder;
  - subscription or API key per model, with secure key entry;
  - Fast mode and Effort, and a free-models folder;
  - picking a model from another engine no longer errors.
- **Gemini plan usage:** shown next to Claude's, read from agy's own `/usage`.
- **"Trust and Start":** shown when an engine refuses an untrusted folder. The home folder can be trusted on its own, without its subfolders.
- **Looks:**
  - the serif is Merriweather's own Regular (400) at normal spacing, Luke's pick "C";
  - the working spinner is the app icon's constellation, drifting and connecting.
- **Fixes:**
  - signed installs, so the keychain stops asking;
  - the composer queue holds after Stop;
  - a dev server's last output now comes before its exit.

## Cloud relay (the main open work)
- **Design:** `docs/superpowers/specs/2026-11-18-cloud-relay-design.md`, approved by Luke.
- **Plan:** `docs/superpowers/plans/2026-11-18-cloud-relay.md`, 9 tasks.
- **Progress log:** `.claude/worktrees/cloud-relay/.superpowers/sdd/2026-11-18-cloud-relay/progress.md` (git-ignored). Read it before anything else on the relay: it holds the pre-flight scan, rulings 1 to 20, every review result, and the deferred minor findings for the final review.
- **Process Luke chose:** one task at a time, each implemented, then reviewed for spec and quality, then put through fix rounds, until clean. Keep that process.
- **Order:** 1, 2, 3, 4, 5, 7, 6, 8, 9. Task 6 needs Task 7's dialer.
- **Status:**
  - Tasks 1 to 3, the Cloudflare Worker and Durable Object: done and reviewed. 77 relay tests pass.
  - Task 4, protocol 4 with a fresh X25519 key per connection: done and reviewed.
  - Task 5, the Mac's relay host: implemented in commit `4aa817e` (120 relay and remote tests pass, both schemes build), but NOT YET REVIEWED. Run its task review first.
    - The progress log lists the implementer's four concerns and one security finding (relayed connections need their own pending budget) to carry into that review.
    - One item can only be checked live, in Task 9: whether Cloudflare answers WebSocket pings on the Mac's per-phone data socket. If it doesn't, idle relayed phones drop after about 46 s.
  - Next: Task 7 (the phone dials direct and through the relay at once), then 6, 8, 9.
- **Before merging cloud-relay into main:**
  - run the final whole-branch review;
  - fix the deferred minors it keeps. Two security mediums are parked in the ledger under Ruling 19: the IP normalizer fails open on odd forms, and table trimming can drop an active block.
- **Task 9:** ends with Luke signing in to Cloudflare (`npx wrangler login`) and approving the deploy to `relay.coquettemc.com`. Then test on his iPhone Duo with Wi-Fi off.

## Small known leftovers (not started)
- OpenCode asks twice before an agent uses Ensemble's own tools (its own card, then Ensemble's).
- The New Session sheet's model list still shows Opus 5.5 twice.
- With the model search box empty, typing a digit picks a model instead of searching.
- iPhone: a prompt the safety check then answers can flash briefly on the phone.

## Memory sync (new today)
- Claude's memories and yours sync both ways every minute: `~/bin/memory-sync`, launchd job `com.lukegarito.memory-sync`, which starts at login.
- Your memories are the topic files in `~/.gemini/memory/`, indexed in `~/.gemini/GEMINI.md`. Save lasting facts there as "## " sections, and they reach Claude within about a minute.
- Log: `~/Library/Logs/memory-sync.log`.
