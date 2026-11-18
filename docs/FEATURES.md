# Feature map: what to build next, in waves

Built from the two research catalogs (`docs/research/claude-code-and-antigravity.md`, 262 rows, and `docs/research/other-agent-apps-and-ui.md`). Numbers in brackets are the research's top-25 ranks. Waves are grouped so that helpers working at the same time never edit the same files. At most 5 helpers run at once on the MacBook Air.

The deep polish (PLAN.md M5) starts only after Luke says go, when these waves are done.

## Status (2026-11-19, early morning)
- Done and committed: engines (Claude, Gemini, OpenCode, router, Accounts), Wave 1 (alerts and sidebar states, composer queue, side questions, dictation, search, file links, view modes, palette), Wave 2 (review pane, rooms in the window, plan mode and question cards, background work, plan limit ring, auto-continue, workspace trust card with a private OpenCode server for untrusted folders), Claude session import, GitHub pull request bar, Inter and Ensemble Serif.
- Running (Wave 3): W3-A Session Hub and split view, W3-B scheduled tasks and usage, W3-C rewind with choices and per-session worktrees, W3-D Customizations.
- Later in Wave 3: terminal pane, browser pane, iPhone alerts, side-task cards, rooms on the iPhone.

## Wave 1 (files nobody else is editing)
| Item | Features | Main files |
|---|---|---|
| W1-A Attention | macOS notifications, Dock badge, sounds, menu bar count of running agents [3]; sidebar needs-you, failed and unread dots, pin, Mark as completed, group by state [5] | new `Apps/Mac/Attention/`, `SidebarView.swift`, new `Store/SessionStore+Attention.swift` |
| W1-B Composer | visible queue of messages sent while an agent works, with Send now and Cancel [6]; voice dictation [22]; side questions `/btw` that don't add to the session [18] | `Apps/Mac/Composer/`, new `Store/SessionStore+Queue.swift` |
| W1-C Finding things | Cmd+K search across all transcripts [15]; clickable file paths, Open in editor, file viewer pane [20]; Normal, Thinking and Verbose transcript views [14]; shortcut overlay (Cmd+/) and command palette [25] | new `Apps/Mac/Search/`, `UI/TranscriptViews.swift`, `UI/Markdown.swift` (links only) |

Each helper reports insertion points in `MainView.swift` and `EnsembleApp.swift` instead of editing them; the orchestrator wires them in one pass.

## Wave 2 (after WP-K and WP-L land; needs the router)
| Item | Features |
|---|---|
| W2-A Plan and questions | Plan mode with a plan you comment on line by line, then Proceed or Keep planning [1]; question cards docked above the composer, answerable from the Hub and the iPhone [4]. Needs each engine (Claude CLI, OpenCode, agy) to surface plans and questions. |
| W2-B Review and GitHub | Review pane: whole-session or whole-room diff, line comments sent back to the agent, filters by turn or agent, stage and commit [2]; pull request bar with checks, Auto-fix, Merge when ready, auto-archive (WP-P) [10] |
| W2-C Rooms in the window | Wire the room screen into the sidebar and window; Members list and a who-messaged-whom graph with replay [16]; goal mode, "keep going until tests pass" [17]; room engine fixes found in live tests (hold messages to a busy agent, wait for background subagents, worktree edits asking in Auto) |
| W2-D Background work and limits | One list of subagents, background shells and scheduled runs with Stop [8]; subscription limit meter by the composer and auto-continue when a limit resets [9] |
| W2-E Workspace trust prompt | "Trust this folder?" card for every engine, using `WorkspaceTrust` and each engine's "ignores project settings" check |

## Wave 3
- Per-session worktree switch, branch picker, worktree cleanup [7]
- One Customizations screen across engines: rules and memory, skills, MCP servers, hooks [13]
- Scheduled tasks with trigger cards, history and catch-up after sleep (M3 WP-G) [19]
- Rewind with choices and a list of the files it will change [21]
- Terminal pane with tabs [11] and a built-in browser pane with dev-server preview [12]
- iPhone alerts when a session needs you (self-hosted ntfy or Live Activity polling) [23]
- Suggested side-task cards (Start, Do it here) [24]
- Claude Code import (M1.6 WP-M)
- Inter for interface text, if Luke approves downloading it (closest legal match to the Claude app's interface font)
