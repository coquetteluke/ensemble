# Claude Code and Google Antigravity: feature catalog

Research for Ensemble, 2026-11-18. Every user-facing feature and UI element found in Claude Code (the desktop app's Code tab, the CLI, claude.ai/code, the mobile app, the IDE extensions) and Google Antigravity (the 2.x desktop app, the Antigravity IDE, the `agy` CLI), with Ensemble's status for each one. The 25 features most worth adding to Ensemble are listed first.

## Scope and versions

| Product | Latest version found | On this Mac |
|---|---|---|
| Claude Code CLI | 2.1.327 (2026-11-17) | 2.1.319 |
| Claude desktop app, Code tab | Stable and Latest release channels announced 2026-11-17; the docs give minimum build numbers per feature, not a current build | not checked |
| Antigravity App (2.x desktop) | 2.33.0 (2026-11-17) | 2.32.2 |
| Antigravity IDE | 2.7.0 (2026-11-12) | 2.6.0, built on VS Code OSS 1.107.0 |
| `agy` CLI | 1.5.10 (Homebrew), release notes up to 1.5.9 (2026-11-14) | 1.5.10 |

How this was gathered:

- Official docs first: code.claude.com/docs (desktop, web, mobile, CLI, commands, hooks, permissions, changelog), support.claude.com release notes, antigravity.google/docs and its changelog, Google blog posts and codelabs. Press reviews only to fill gaps.
- Local evidence: `claude --help`, `agy --help` and every `agy` subcommand's help, Antigravity's bundled docs in `~/.gemini/antigravity/builtin/skills/`, strings and keybinding tables in the installed Antigravity app and IDE bundles, and the Claude desktop app's own session tools that agents in this Mac's desktop app can see (sidebar, pane, pull request, worktree and session tools). Those tools confirm desktop details the public docs leave out, such as sidebar group-by options and the list of side panes; rows that rely on them cite "Claude desktop agent tools".
- Nothing was prompted in either product.
- Rows marked "(unverified)" were not confirmed in an official source.
- The Antigravity 1.x docs (Agent Manager, Inbox, Playground, Knowledge) were taken off the official site when 2.0 shipped. Rows about them are tagged "1.x" and come from the 1.x changelog and a mirror of the old docs.

### Legend

Products:

| Code | Product |
|---|---|
| CC-D | Claude Code desktop: the Code tab in the Claude app for Mac (and Windows) |
| CC-CLI | Claude Code in the terminal |
| CC-Web | Claude Code on the web, claude.ai/code (cloud sessions) |
| CC-M | The Claude mobile app's Code view |
| CC-IDE | Claude Code for VS Code, Cursor and JetBrains |
| AG-App | Antigravity 2.x desktop app (agent-first, no code editor) |
| AG-IDE | Antigravity IDE (VS Code based). "AG-IDE 1.x" means the retired Nov 2025 to May 2026 version with the Agent Manager |
| agy | Antigravity CLI |
| AG-Ext | Antigravity extensions for VS Code, Visual Studio and JetBrains |

Ensemble status:

| Status | Meaning |
|---|---|
| Has | In the Ensemble working tree on 2026-11-18 (some of it is uncommitted work from parallel workers) |
| Has (partial: ...) | Exists, but narrower than the reference; the note says what is missing |
| Planned (Mx WP-y) | Named in `docs/PLAN.md`; milestone and work package cited |
| Missing | Not in the code and not in `docs/PLAN.md` |

## What Ensemble has today (the baseline for the status column)

- **Window:** left sidebar (New session, Session Hub, Scheduled, title search, sessions grouped by project folder, row menu with Rename, Reveal in Finder, Archive, Delete), centre transcript, composer, status line, toggleable right context panel, zoom (Cmd+plus, Cmd+minus, Cmd+0), light and dark themes that follow the system.
- **Transcript:** user bubbles with a hover bar (sent time, Fork, Rewind, Edit, Copy; Rewind and Edit disabled while the agent works), Markdown agent text, collapsed Thinking rows, tool cards (command, edit with diff, read, search, web), subagent cards with Open, permission cards (Allow once, Always allow, Reject, with Cmd+Y, Opt+Cmd+Y and Cmd+period), activity groups ("Ran a command, read 3 files"), a working row (spinner, current step, elapsed time), a pinned task-list card from todo tools, inline widgets from `widget` code blocks, error rows, a jump-to-newest button.
- **Composer:** text box, attach by file picker or drag and drop, permission-mode menu (Ask, Accept edits, Auto, Bypass; Shift+Tab), model chip, effort chip, fast-mode toggle, send and stop (Esc), a `/` menu with Ensemble's commands (`/new`, `/model`, `/effort`, `/fast`, `/mode`, `/compact`, `/fork`, `/rewind`, `/clear`, `/hub`, `/usage`, `/help`) plus each engine's commands and skills.
- **Status line:** session cost and tokens, context percent.
- **Context panel:** Environment (This computer, folder, Remote Control switch), Context (percent, used and limit, bar, breakdown groups), Outputs (files changed with +/- counts), Connectors (MCP servers with status and tool counts; the Authenticate button is not wired yet).
- **Settings:** General, Providers (API keys), Models (default model), Engine, Power.
- **Engines:** OpenCode service, the official `claude` CLI (headless, stream-json), an engine router.
- **Rooms:** Team, Debate and Round table modes, a board of agent-to-agent messages in each agent's colour, debate rounds and verdict cards, a new-room sheet, a room side panel, per-agent git worktrees in Team mode.
- **Power:** Keep Mac awake and Keep running with the lid closed, with a status chip and menu.
- **iPhone remote:** QR pairing over Tailscale, Hub, chats, rooms, usage and settings tabs, approvals, Remote Control switch on the Mac.
- **Placeholders:** the Session Hub (lists sessions waiting on a permission) and Scheduled screens are stand-ins until M3.

## Top 25 features to add to Ensemble

Ordered by value to Ensemble's goals (several agents at once, Claude Code feel, a Hub that tells you what needs you, the iPhone remote). Mostly features nobody has planned yet; four planned ones are included because the research gives them a concrete design to copy.

| # | Feature | Seen in | Ensemble | Why it adds value |
|---|---|---|---|---|
| 1 | Plan mode with a plan document you can comment on line by line, then Proceed, Proceed in Auto, or Keep planning | CC (plan mode, plan pane, VS Code plan review), AG (implementation plan artifact with Google Docs-style comments) | Missing | A Team room's lead writes a plan before several agents edit at once; reviewing and correcting it before anyone touches files is the cheapest place to catch a bad split. |
| 2 | Review pane: full diff of the session or room with line comments sent back to the agent, filters by turn or by agent, stage and commit | CC-D Changes pane, AG-App Review tab | Missing (commit and push Planned M1.8 WP-P) | With several agents editing, the Outputs list and per-tool diffs are not enough to review the combined result; line comments are the fastest way to give precise feedback. |
| 3 | macOS notifications, Dock badge, sounds and a menu bar count of running agents | CC-D, AG-App | Missing | Parallel agents finish and block at random times; without alerts the user has to poll the window, which defeats running several at once. |
| 4 | Question cards: the agent's multiple-choice questions docked above the composer, answerable from the Hub and the iPhone | CC (AskUserQuestion cards), AG-App (docked questions) | Missing | Agents ask clarifying questions often; a one-tap card is what makes Hub quick replies and phone approvals practical. |
| 5 | Sidebar attention states: needs-input, failed and unread dots, Mark as completed, pin, group by state | CC-D, AG-App, CC-IDE | Missing (Hub buckets Planned M3 WP-E) | The sidebar should show what needs you without opening the Hub; pinning keeps long-running rooms in reach. |
| 6 | Queued messages strip with Send now (steer mid-turn) and Cancel | CC-D, CC-CLI, AG-App, agy | Has (partial: you can send while an agent works, but there is no visible queue, Send now or Cancel) | Steering a running agent without stopping it is a core Claude Code habit, and in a room it lets you redirect one agent while the others continue. |
| 7 | Per-session worktree switch, branch picker, worktree cleanup | CC-D, AG-App | Has (partial: per-agent worktrees in Team rooms only) | Two solo sessions in the same repo currently edit the same checkout; a switch under the composer makes parallel solo work safe. |
| 8 | One background-work list: subagents, background shells, workflows, scheduled runs, with output and Stop | CC-D tasks pane, AG-App Overview panel and Background Tasks | Missing (subagent tree Planned M3 WP-F) | Multi-agent work spawns many hidden processes; one place to see and stop them prevents runaway cost. |
| 9 | Subscription limit meter next to the composer (5-hour and weekly per plan or quota pool, reset times), and auto-continue when a limit resets | CC-D usage ring, AG-App quota ring and pools, CC Projects auto-continue | Planned (M3 WP-G, usage popover; ring and auto-continue not planned) | Ensemble runs on subscriptions first; a debate that quietly burns a weekly allowance is the failure DESIGN.md calls out. |
| 10 | Pull request bar with CI checks, Auto-fix, Merge when ready and auto-archive on merge | CC-D, CC-Web | Planned (M1.8 WP-P; auto-merge and auto-archive not listed) | Copy Claude Code's switches exactly: they turn a finished session into a self-closing loop. |
| 11 | Terminal pane with tabs, in the session's folder | CC-D, AG-App | Missing | Users check builds and run commands next to the agent all the time; leaving the app breaks flow. |
| 12 | Built-in browser pane with dev-server preview (a `launch.json` of servers) and agent control of the page | CC-D Browser pane, AG-App built-in browser and browser subagent | Missing | Agents can verify UI changes themselves and the user sees the result without switching apps. |
| 13 | One Customizations screen across engines: rules and memory files, skills, MCP servers (add, sign in, restart, "fix with agent"), hooks, and what each engine loaded for this project | AG-App Customizations, CC `/mcp`, `/memory`, `/skills`, `/hooks` | Has (partial: Connectors list only) | Ensemble mixes engines; users need one place to see which instructions and tools each agent actually has. |
| 14 | Transcript view modes: Normal, Thinking, Verbose | CC-D, CC-CLI (Ctrl+O) | Missing | Lets users drop to full tool detail when debugging an agent, then return to the calm view. |
| 15 | Full-text search across transcripts (Cmd+K) with filters for unread, archived and scheduled | AG-App, CC-CLI picker, CC-D agent tools | Has (partial: title filter in the sidebar) | With 100+ imported Claude Code sessions (M1.6), title search will not find "where did we decide X". |
| 16 | Room swarm views: Members (active, standing by, retired), a graph of who messaged whom with replay, Follow mode | AG-App and agy swarm board | Has (partial: board thread and agent lanes) | Rooms are Ensemble's main feature; Antigravity's swarm board shows how to make many-agent traffic readable. |
| 17 | Goal mode: keep a session or room working until an evaluator confirms a stated condition, with an Active goal indicator | CC `/goal`, AG `/goal` | Missing | Fits rooms well: "keep going until tests pass" without the user re-prompting each round. |
| 18 | Side questions (`/btw`, Cmd+;): ask about a session using its context without adding to it, promote to a new session | CC-D, CC-CLI, AG-App | Missing | Users can ask "what is agent B doing?" without derailing a working agent. |
| 19 | Scheduled tasks with trigger cards (hourly, daily, weekdays, weekly, custom), Run now, history, missed-run catch-up and an always-allowed list | CC-D, CC-Web routines, AG-App Automations | Planned (M3 WP-G) | Copy the trigger card and catch-up rules; a missed 9am run after the Mac slept is a common complaint otherwise. |
| 20 | File viewer pane, clickable file paths in chat, Open in editor (Xcode, VS Code, Cursor, Zed) | CC-D, AG-App | Has (partial: Reveal in Finder only) | Users constantly jump from an agent's message to the file; a one-click open is cheap and saves the most clicks. |
| 21 | Rewind with choices (code and conversation, conversation only, code only, summarize from here) and a confirm list of files that will change | CC-CLI, CC-IDE, AG-App Confirm Undo | Has (partial: Rewind exists, one behaviour, no file list) | Rewinding a multi-file change blind is risky; seeing the files first builds trust in the button. |
| 22 | Voice dictation in the composer and on the iPhone | CC-CLI, CC-IDE, AG-App, agy | Missing | Dictating long briefs is faster, especially from the phone remote. |
| 23 | iPhone alerts when a session needs you | CC-M push, AG web app notifications | Missing | The remote is most useful when it tells you to look; a free Apple account cannot send push, so a self-hosted ntfy topic or Live Activity polling are options to evaluate. |
| 24 | Suggested side-task card: an agent proposes a separate session with Start, Do it here, Options and Start all | CC-D | Missing | Turns "also, X should be fixed" into a parallel session with one click, which is Ensemble's whole idea. |
| 25 | Keyboard shortcut overlay (Cmd+/), command palette (Cmd+Shift+P) and rebinding | CC-D, AG-App | Planned (M5, shortcuts; palette and rebinding not listed) | Power users drive both reference apps from the keyboard; an overlay makes the shortcuts discoverable. |

## 1. Sessions, projects and the sidebar

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Session sidebar | CC-D, CC-Web, AG-App | Lists sessions for switching | CC-D: left column of the Code tab, "+ New" at top (Cmd+N), "..." row menu on hover, built-in sections Pinned, Scheduled (was Routines) and Sessions plus custom sections. CC-Web: sidebar, archived list at claude.ai/code/sessions. AG-App: left sidebar with New Conversation, Projects, Automations, Customizations, Settings and plugin entries; Cmd+B toggles | Has |
| Group, sort and filter | CC-D, AG-App | Changes how the list is organised | CC-D: "Group and sort" icon on a section header; group by date, project, state, custom or none; sort by recency, name or created; status active, archived or all; last activity 1, 3, 7 or 30 days. AG-App: Display Options menu: group by project, status or recency; sort conversations or projects; Auto Pin; archived-only view | Has (partial: grouped by folder only) |
| Custom groups (sections) | CC-D, AG-App | User-named folders of sessions | CC-D: create, rename, delete sections; move sessions in from the row menu or by dragging; pinned sessions keep their group. AG-App: New Group, Move to Group, Rename Group in the right-click menu; drag between sections | Missing |
| Pin | CC-D, AG-App, CC-CLI | Keeps a session at the top and out of automatic archiving | CC-D: Pinned section, row menu. AG-App: Pinned section with its own sort menu, Opt+Cmd+P. CC-CLI agent view: Ctrl+T | Missing |
| Status dots | CC-D, CC-IDE, AG-App, CC-CLI | Shows working, needs input, failed, unread | CC-D: spinner while running, dot for needs-input or failed, blue unread dot; row menu "Mark as completed" clears the dot until the session needs you again; "Mark unread". CC-IDE: blue Spark dot for a pending permission, orange for a finished hidden tab. AG-App: status icons, needs-attention icon, one-line subagent rows, Mark All as Read. CC-CLI agent view: yellow needs input, green done, red failed, grey stopped | Has (partial: running spinner; the Hub placeholder counts pending permissions; no unread or failed dots) |
| Sidebar search | CC-D, AG-App, CC-CLI | Finds sessions | CC-CLI picker: type to filter, Ctrl+A all projects, Ctrl+B current branch, Ctrl+W worktrees. AG-App: magnifier at top left or Cmd+K, full text over titles, folders, prompts and responses; filters Only Unread, Only Archived, Only Automations; sort Last Updated or Last Prompt. CC-D: full-text transcript search exists for agents (unverified as a user control) | Has (partial: filters by title) |
| Rename | CC-D, CC-CLI, CC-Web, AG-App, agy | Changes a session title | CC-D: click the title in the title bar. CC-CLI: `/rename`, Ctrl+R in the picker. CC-Web: session menu. AG-App: three-dot menu. agy: F2 in `/resume` | Has |
| Automatic titles | CC (all), AG-App | Names a session from its first prompt; accepting a plan retitles it | Shown in sidebar and picker | Has (Claude engine titles from the first prompt) |
| Archive and unarchive | CC-D, CC-Web, AG-App | Hides finished sessions and keeps the transcript | CC-D: row menu Archive; warns "Archive anyway" when the worktree has uncommitted changes; local worktrees removed about 30 days later; restore from the Archived list. AG-App: Cmd+Opt+A, "(Archived)" heading, archive icon in search results, unarchive from search | Has (partial: Archive only; no archived list or unarchive) |
| Auto-archive after PR merge or close | CC-D | Archives sessions whose pull request finished | Settings > Code toggle; per-PR switch in the PR menu; skips pinned and running sessions | Missing |
| Delete | CC-D, CC-Web, AG-App, agy | Removes a session for good | CC-Web: "..." > Delete with confirm. CC-D: approval card that lists every session by title. AG-App: bottom of the conversation menu. agy: F4 in `/resume` | Has |
| Split view | CC-D, AG-App, AG-IDE 1.x | Several sessions side by side | CC-D: Option-click a row, right-click > Open in > Split view, or drag a row to the window edge; Cmd+Ctrl+W removes a pane. AG-App: More actions > Split > Split Right (Cmd+D) or Split Down (Cmd+Shift+D), Equalize Split Panes, Remove from Split | Planned (M3 WP-F) |
| Pop-out window | CC-D, AG-App | Opens a session or pane in its own window | CC-D: Cmd-click a row or Open in > New window; diff and terminal panes can pop out. AG-App: File > New Window (Cmd+Shift+N), Dock menu New Window | Missing |
| Side sessions started by an agent | CC-D | An agent starts a separate session for side work; it nests under the parent | Suggested-task card with Start, Do it here, Options (environment, model, worktree, permissions) and Start all; child rows nest under the parent; "Detach to top level" | Missing |
| Background sessions and agent view | CC-CLI, CC-D | Sessions that run with no window open, monitored on one screen | CC-CLI: `claude --bg "task"`, `claude agents` dashboard (sections, Space to peek, Enter to attach, Ctrl+X to stop), `claude attach`, `logs`, `stop`, `respawn`. CC-D: Background tasks in the title-bar "..." menu | Has (partial: sessions keep running when not selected; no dashboard yet) |
| Per-session git worktree | CC-D, CC-CLI, AG-App | Isolates a session's edits in its own checkout | CC-D: Worktree switch in the row under the prompt (off by default), stored in `.claude/worktrees/`, settings for location and branch prefix. CC-CLI: `-w` / `--worktree`, `#1234` makes one from a PR. Both: `.worktreeinclude` copies gitignored files such as `.env`. AG-App: Local or New Worktree mode, combined branch and worktree menu, Previous Worktrees, Fork in Shared Workspace | Has (partial: per-agent worktrees in Team rooms only) |
| Propose a branch before the first edit | CC-D | Asks whether changes go on a new branch or the current one | Card before the agent's first edit in a git repo, with a suggested branch name (Claude desktop agent tools) | Missing |
| Worktree cleanup and storage | CC-D | Frees disk used by old sessions | Settings > This computer > Storage: Clean up inactive sessions older than 30, 60 or 90 days; list of worktrees kept after archiving because they hold uncommitted changes (Claude desktop agent tools) | Missing |
| Environment selector | CC-D, AG-App | Chooses where a session runs: this computer, SSH, WSL, cloud | CC-D: first control under the prompt, New environment dialog with Local, SSH and Cloud tabs, Cmd+Opt+1 to 9, gear to edit. AG-App: Environment selector (Cmd+.): This Computer, cloud, SSH host, WSL | Has (partial: "This computer" only, shown in the context panel) |
| SSH sessions | CC-D, AG-App | Runs the agent on another machine | CC-D: SSH tab, "Add SSH connection...", fingerprint prompt "Trust and connect". AG-App: "Connect to SSH Host..." in the sidebar, project menu and palette | Missing |
| Folder picker and extra folders | CC-D, AG-App, CC-CLI | Picks the working folder and adds more | CC-D: folder control beside the environment, "+ > Add folder" on a running session. AG-App: projects span several folders, Add Folder. CC-CLI: `--add-dir`, `/add-dir` | Has (partial: one folder per session from the New session sheet) |
| Projects with their own settings | AG-App, agy | Groups conversations over folders with their own permissions and resources | Sidebar Projects section, New Project (folder with +), gear per project; Project Settings with File Access, Internet Access, Sandbox, Auto-Execution and Permission Grants, each defaulting to "Inherit Global" | Has (partial: folders group sessions; no per-project settings) |
| Claude Projects (threads by state) | CC-Web, CC-D, CC-M | One conversation that starts and tracks cloud threads | "Projects" in the sidebar; "Threads" button grouped Ready for review, Waiting on you, Working, Landing, Idle, Resolved; Library of files; settings General, Memory, Environment, Plugins, Usage; "Auto-continue when usage limits reset"; Pro, Max and Ultra beta | Has (partial: Hub buckets cover the state view, Planned M3 WP-E; no project threads) |
| Scratch conversations | AG-App, AG-IDE 1.x | A chat with no project | AG-App: "Outside of Project" section. AG-IDE 1.x: Playground, with a button to turn it into a workspace | Missing |
| Fork | CC-CLI, CC-Web, CC-IDE, AG-App, agy | Copies a conversation into a new session | CC-Web and Remote Control: session menu Fork or fork from an earlier message. CC-CLI: `/branch` switches into the copy, `/fork` makes a background copy, `/subtask` runs a forked subagent. CC-IDE: hover a message > fork. AG-App: Fork in this folder, Fork in New Workspace, Fork in Shared Workspace (opens a split with a worktree). agy: `/fork` copies history, not files | Has (hover Fork, `/fork`) |
| Export transcript | CC-D, CC-CLI, AG-App | Takes a conversation out of the app | CC-D: session menu Export writes a zip (transcript, subagent transcripts, metadata) to Downloads. CC-CLI: `/export` to clipboard or file, `/copy` the last reply. AG-App: Copy Conversation Markdown, Copy Message, Export Markdown as PDF | Missing |
| Share a session | CC-Web | Gives others a link | Visibility toggle: Private, Team, or Public by plan | Missing |
| Continue in cloud, teleport, hand off | CC-D, CC-Web, CC-CLI | Moves a session between computer, cloud and terminal | CC-D: session menu Open in > Cloud. CC-Web: Open in > Terminal. CC-CLI: `--teleport`, `/teleport`, `/desktop` opens the session in the desktop app | Missing |
| Conversation navigator rail | AG-App | Jumps between turns of a long conversation | Rail with a dot per turn, hover previews, date chapters; Cmd+Opt+[ and ] for previous and next prompt | Missing |
| Session switching keys | CC-D, AG-App | Moves between sessions from the keyboard | CC-D: Ctrl+Tab, Cmd+Shift+[ and ]. AG-App: Opt+Up and Down, Opt+Shift+Up and Down to reorder | Has (Cmd+1 to Cmd+9 open the first nine sessions) |
| Resume cost warning | CC-CLI, CC-D | Warns before resuming a long, expensive session | "Resume this conversation?" dialog with Resume or Start a new conversation | Missing |
| Session recap | CC-CLI | One-line summary when you come back after a few minutes away | Shown automatically after 3+ minutes unfocused; `/recap` on demand; 400-character cap | Missing |
| Best of N (battle mode) | AG-App, AG-IDE | Runs one prompt on several models and lets you pick the winner | Route `/battle/<id>`, "Best of N Models", winner survey; option to use full git clones (local bundle strings; rollout unverified) | Has (partial: Debate rooms compare models on a question) |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/sessions.md, https://code.claude.com/docs/en/worktrees.md, https://code.claude.com/docs/en/agent-view.md, https://code.claude.com/docs/en/claude-projects.md, https://code.claude.com/docs/en/claude-code-on-the-web.md, https://code.claude.com/docs/en/vs-code.md, https://antigravity.google/docs/projects/, https://antigravity.google/docs/search/, https://antigravity.google/docs/side-panel/, https://antigravity.google/docs/changelog/, https://antigravity-doc.pages.dev/en/agent-manager/playground, local: Antigravity app bundle keybinding table and labels, Claude desktop agent tools (sidebar, session, host).

## 2. Transcript

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Tool cards | CC (all), AG (all) | Shows each tool call and its result | CC-D: collapsed in Normal view, clickable file paths, "+12 -1" change indicator that opens the diff. AG-App: steps inside a "Worked for" expander; terminal steps collapsed by default | Has |
| Activity groups | CC-D, AG-App | Folds runs of tool calls into one row | CC-D: consecutive tool calls collapse in Normal view. AG-App: collapsible groups for edits, commands and reads (2.21.1) | Has |
| Transcript view modes | CC-D, CC-CLI | Normal, Thinking or Verbose detail | CC-D: "Transcript view" in the title-bar menu, Ctrl+O; Normal hides tool detail, Thinking adds thinking summaries, Verbose expands every call. CC-CLI: Ctrl+O transcript viewer with timestamps and model per message, `/focus` view. AG-App: Appearance > Conversation Steps detail level | Missing |
| Thinking display | CC (all), AG-App | Shows the model's reasoning | CC: Thinking view; Option+T toggles extended thinking in CC-CLI. AG-App: reasoning inside steps | Has (collapsed Thinking row) |
| Working indicator | CC (all), AG (all) | Shows the agent is busy | CC-CLI: spinner with elapsed time and live output tokens ("10m 27s, 5.5k tokens"). CC-D: Stop replaces Send. AG-App: "Worked for" timer, "Thinking..." | Has (spinner, current step, elapsed time) |
| Task list | CC-CLI, CC-D, AG-IDE 1.x, AG-App | The agent's checklist for multi-step work | CC-CLI: Ctrl+T shows up to five tasks in the status area. AG-IDE 1.x: Task artifact; task groups with goal, edited-file pills and collapsible subtasks. AG-App: Task artifact | Has (pinned task-list card) |
| Subagent rows | CC-D, AG-App, agy | Shows delegated agents inside the transcript | CC-D: subagent pane. AG-App: live subagent cards with a stop control, a message box to talk to a subagent directly (2.19.1). agy: rows above the prompt | Has (subagent card with Open) |
| Message hover actions | CC-D, CC-Web, CC-IDE, AG-App | Actions on one message | CC-IDE: hover > rewind (fork conversation, rewind code, or both). CC-Web: "Rewind to here". AG-App: Copy Message, Undo to Here, Good or Bad Response, Ask `/btw` on selected text | Has (sent time, Fork, Rewind, Edit, Copy) |
| Rewind and checkpoints | CC-CLI, CC-IDE, CC-D, AG-App, agy | Restores code, conversation or both to an earlier prompt | CC-CLI: Esc Esc or `/rewind`; options restore code and conversation, conversation only, code only, summarize from here, summarize up to here; 100 checkpoints kept; Bash-only edits not tracked. AG-App: "Undo to Here", Confirm Undo dialog with a scrollable file list and "Revert only the conversation". agy: `/rewind` with relative timestamps | Has (partial: one rewind behaviour; files restored when the engine supports it; no options or file list) |
| Edit and resend | CC-CLI, CC-D | Changes an earlier prompt and reruns from there | Rewind puts the old prompt back in the input box for editing | Has (Edit in the hover bar) |
| Queued messages | CC-D, CC-CLI, CC-Web, AG-App, agy | Holds messages typed while the agent works | CC-CLI: Enter queues, queued lines grey, Up takes them back, Ctrl+Enter sends now. CC-Web: X on a queued message returns it to the box. AG-App: queue strip with Send Now and Cancel Sending; setting Queue or Send Immediately. agy: Alt+M sends with the opposite mode | Has (partial: sending while working is allowed; no visible queue) |
| Steering mid-turn | CC-CLI, CC-D, AG-App | Redirects the agent without a new turn | Queued messages go in after the current tool calls finish | Has (partial: depends on the engine; no UI to choose steer or queue) |
| Permission cards | CC (all), AG (all) | Asks before a risky action | CC-D: Allow once, Always allow, Deny; per-site card for browser pages. AG-App: card in the chat; file, URL and MCP grants can be widened by editing the target; voice approvals for safe actions | Has |
| Question cards | CC (all), AG-App, agy | The agent asks a question with choices | CC: AskUserQuestion card waits for an answer; number keys in agent view. AG-App: docked question cards above the composer (2.26.0), collapsible, Cancel; `/grill-me` asks one question at a time with suggested answers | Missing |
| Plan approval | CC-CLI, CC-D, CC-IDE, AG (all) | Approves a plan before edits start | CC-CLI: "Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"; Ctrl+G edits the plan in an editor. CC-IDE: the plan opens as a Markdown document you can comment on. AG: Implementation Plan card with Proceed; status changes to "Proceeded with Implementation Plan" | Missing |
| Inline visuals | CC (all), AG-App | Interactive HTML in the chat | CC: artifacts and MCP App widgets in the Code tab. AG-App: `/generative_ui` widgets inline (up to 500 px) or standalone in the side panel, sandboxed, theme-aware; MCP Apps up to 800 px | Has (widget code blocks in a sandboxed web view) |
| Compaction marker | CC-CLI, CC-D, AG-App | Marks where history was summarised | "Conversation compacted" row; AG: "The conversation was compacted while generating this response" | Has (partial: `/compact` command; no marker row) |
| Suggested next prompt | CC-D, CC-CLI, CC-IDE | Offers a likely next message | Grey text in the empty box; Tab or Right arrow accepts, Enter sends; toggle in settings | Missing |
| Cross-session message rows | CC-D, CC-CLI | Shows a message another session sent | Dim one-line preview with the sender's link; Ctrl+O expands | Has (partial: room board messages between agents) |
| Code review findings card | CC-D | Lists findings from a local review | Findings grouped by file with "Walk through in Changes", "Fix this one", "Apply fixes" | Missing |
| Suggested plugin card | CC-Web, AG-App | Proposes a plugin for the task | Card with Add; AG resumes the conversation after install | Missing |
| Response feedback | AG-App, AG-IDE | Rates an answer | Good Response, Bad Response, Provide Feedback dialog (optional logs) | Missing |
| Find in conversation | AG-App | Searches the open conversation | Cmd+F with Match Case, Whole Word and Regex; Enter and Shift+Enter step through | Missing |
| Voice transcript card | AG-App | Record of a voice session | "Stopped voice chat" marker and a "Voice transcript" card with Open and Copy | Missing |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/checkpointing.md, https://code.claude.com/docs/en/permission-modes.md, https://code.claude.com/docs/en/cross-session-messaging.md, https://code.claude.com/docs/en/artifacts.md, https://antigravity.google/docs/changelog/, https://antigravity.google/docs/implementation-plan/, https://antigravity.google/docs/commands/generative-ui/, https://antigravity.google/docs/voice-mode/, https://antigravity.google/docs/tools/, local: Antigravity app bundle strings, Claude desktop agent tools (transcript view).

## 3. Composer

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Prompt box | CC (all), AG (all) | Writes and sends prompts | Enter sends. CC-CLI: Shift+Enter or Ctrl+J for a new line. AG-App: Cmd+L focuses, lists with Shift+Enter and Tab, optional Enter to Send setting | Has |
| "+" menu | CC-D, CC-Web, AG-App | Attaches things and adds capabilities | CC-D: Slash commands, Add connectors, Add plugins, Add folder, Add files or photos. CC-Web: Connectors per thread. AG-App: Add Context (+) with Mentions, files, terminal, browser | Has (partial: attach button only) |
| Attachments | CC (all), AG (all) | Adds images, PDFs and files | CC: "+" menu, drag and drop, Ctrl+V pastes an `[Image #N]` chip in the CLI. AG-App: any file type up to 20 MB, folders, drag highlight, paste | Has (partial: file picker and drag and drop; no image paste) |
| @ mentions | CC (all), AG (all) | Pulls a file, folder or other context into the prompt | CC: type @ for fuzzy paths; CC-IDE adds line ranges (`@file.ts#5-10`), `@terminal:name`, `@browser`. AG-App: files, folders, rules, past conversations, plugins, artifacts, terminals, MCP resources, `@drive:`; chips with icons | Has (partial: `@agent` routing in rooms; no file mentions) |
| Quote selection | AG-App, CC-IDE | References selected text from a reply, file, diff or terminal | AG-App: select text > Quote or Cmd+L; chips like `bookmarks.js #L13-17`. CC-IDE: the current selection is attached automatically | Missing |
| Slash command menu | CC (all), AG (all) | Lists commands, skills and plugin skills | Type `/`. CC-IDE groups Customize and Context sections. AG-App: pills with the skill's logo, hover card with the plugin name | Has |
| Model picker | CC (all), AG (all) | Chooses the model | CC-D: right end of the row under the prompt, Cmd+Shift+I, Enter saves as default. CC-CLI: `/model`, Option+P. AG-App: under the prompt box, Cmd+/, Refresh button, agent picker inside the model menu, quota pools shown | Has |
| Effort | CC (all), AG (all) | Sets reasoning depth | CC: slider in the model picker (arrow keys), Cmd+Shift+E, `/effort`; levels low to max plus auto; "ultrathink" keyword raises one turn. AG-App: per-model levels Low, Medium, High, Extra in the dropdown; agy `/effort` gauge | Has |
| Fast mode | CC (all) | Faster output at a higher price | `/fast`, Option+O, a lightning icon by the prompt; cooldown on rate limits | Has |
| Permission mode selector | CC (all), AG-App, agy | Sets how much the agent asks | CC-D: row under the prompt, Cmd+Shift+M; CC-CLI: Shift+Tab cycle with a status bar label. AG-App: permissions picker above the composer, per-conversation preset. agy: Shift+Tab cycles auto, plan, default, accept-edits | Has |
| Plan mode | CC (all), AG (all) | Explores and writes a plan without editing | CC: "Plan" in the selector, `/plan`, Shift+Tab. AG: `/plan` slash command (replaced 1.x Planning mode), Shift+Tab mode in agy | Missing |
| Voice dictation | CC-CLI, CC-IDE, AG-App, agy | Speaks prompts | CC-CLI: hold Space or `/voice tap`; CC-IDE: Cmd+D. AG-App: mic button beside the box, hold Ctrl+M; also in artifact comments. agy: F5 | Missing |
| Voice mode (two-way) | AG-App, agy | Spoken conversation while the agent works | AG-App: sound-bars button in an empty box, voice picker (nine voices), call bar with mute, speed 0.75x to 2x, minimize, End; floating orb across conversations. agy: `/voice live`, F6 | Missing |
| Context meter | CC (all), AG-App | Shows how full the context window is | CC-D: Context card with a percentage; click for the breakdown. AG-App: ring next to Send, click for breakdown and quota | Has (status line and context panel) |
| Usage indicator | CC-D, AG-App | Shows plan usage | CC-D: usage ring at the right end of the row under the prompt. AG-App: quota in the same ring | Has (partial: session cost and tokens; no plan limits) |
| Worktree and environment row | CC-D | Session setup under the prompt | Environment selector, folder, Worktree switch | Has (partial: folder chosen in the New session sheet) |
| Prompt stash and external editor | CC-CLI, agy | Sets a draft aside; edits the prompt in `$EDITOR` | Ctrl+S stashes and restores; Ctrl+G opens the editor | Missing |
| Large paste collapse | CC-CLI | Keeps big pastes readable | `[Pasted text #1 +120 lines]` chip | Missing |
| Invisible character cleanup | CC-CLI, CC-IDE | Strips hidden Unicode before sending | "Removed 3 invisible characters" | Missing |
| Starter prompts | AG-App | Suggested first tasks | Up to three dismissible chips above the Home box; clicking installs the plugin and fills the prompt | Missing |
| Session colour | CC-CLI | Colours the prompt bar per session | `/color` with eight colours | Has (partial: agent colours in rooms) |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/model-config.md, https://code.claude.com/docs/en/fast-mode.md, https://code.claude.com/docs/en/permission-modes.md, https://code.claude.com/docs/en/vs-code.md, https://antigravity.google/docs/models/, https://antigravity.google/docs/at-mentions/, https://antigravity.google/docs/slash-commands/, https://antigravity.google/docs/voice-mode/, https://antigravity.google/docs/getting-started, https://antigravity.google/docs/permissions/.

## 4. Panes and panels

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Pane system | CC-D, AG-App | Arranges chat, diff, browser, terminal, file, plan, tasks, subagent and simulator panes | CC-D: drag a pane header to move, drag edges to resize, Cmd+\ closes the focused pane, layout kept per session. AG-App: side panel with tabs, preview tabs in italics until double-clicked, Pin Tab, Cmd+T New Tab page, Cmd+W, Cmd+Shift+T reopens, Ctrl+Tab cycles, Cmd+Shift+M maximizes | Has (partial: one toggleable right panel) |
| Title-bar pane buttons | CC-D, AG-App | Opens panes | CC-D: Terminal, Changes, Browser, Files buttons, overflow in "..." when narrow. AG-App: Toggle Side Panel (Cmd+Shift+B) and Toggle Overview Panel (Cmd+Opt+O) at top right | Has (sidebar and context panel toggles) |
| Session details panel | CC-D, CC-Web | Environment, Changes and Context cards beside the chat | "Hide session rail" or "Show session rail" in the title bar | Has (context panel: Environment, Context, Outputs, Connectors) |
| Overview panel | AG-App | Index of everything a conversation produced | Rows Review (+/- counts), Files, Terminal, Extensions; sections Subagents, Background Tasks, Goals, Documents, Artifacts, Links, Side Questions, Pull Requests, Modified Files, Uploads, four items each with "See all"; Customize Sections menu | Has (partial: Outputs and subagent groups in the context panel) |
| Diff / Changes pane | CC-D, CC-Web, AG-App | Shows the session's changes | CC-D: Changes card "+12 -1", Changes button, Cmd+Shift+D; scope all branch changes, uncommitted only, or one commit; "Compare against" another branch. AG-App: Review tab (see section 5) | Missing (diffs only inside tool cards; Outputs lists files) |
| File viewer and editor pane | CC-D, AG-App | Views and edits files | CC-D: Files button or click a path; auto save with Override or Discard on conflict; view only in cloud, SSH and WSL; right-click: Attach as context, Open in, Show in Finder, Copy path. AG-App: Cmd+P file picker, Cmd+Shift+E file viewer, PDF, Jupyter, Markdown, Mermaid, image and video viewers | Missing |
| Terminal pane | CC-D, AG-App | A shell in the session's folder | CC-D: Terminal button or Ctrl+`, "+" for tabs, right-click a folder > Open in terminal, pop out. AG-App: Cmd+J or Ctrl+`, Cmd+T new tab, Cmd+\ split, persistent terminals, "Terminal: Add to Chat" (Cmd+L) | Missing |
| Browser pane and dev-server preview | CC-D, AG-App | Shows a running app or any site inside the window | CC-D: Browser button or Cmd+Shift+B, "Dev servers" menu from `.claude/launch.json` (name, command, args, port, cwd, env, autoPort, url, autoVerify), element select Cmd+Shift+S, menu with Keep cookies, Clear browsing data, Open links in built-in browser, Auto-verify changes. AG-App: address bar, Back, Forward, Reload, Downloads drawer, "Add screenshot to conversation", Open in external browser, Cmd+F | Missing |
| Plan pane | CC-D | Shows the current plan beside the chat | Appears in the "..." menu once a plan exists | Missing |
| Background tasks pane | CC-D, AG-App, CC-CLI, agy | Lists subagents, background shells and workflows | CC-D: title-bar "..." > Background tasks; click for output or stop. AG-App: Background Tasks across all conversations with Cancel Task and Cancel All. CC-CLI and agy: `/tasks` (Ctrl+T in agy) | Missing |
| Subagent pane | CC-D, AG-App | Watches one subagent's work | Pane type; AG-App adds Stop Subagent, Stop All, Pause and Resume | Has (partial: Open shows the child session in the main view) |
| Artifacts pane | CC-D, AG-App | Shows published pages or agent documents | CC-D: artifact pane for pages this session published. AG-App: artifact cards open in the side panel and are listed under Overview > Artifacts | Missing |
| iOS Simulator pane | CC-D (macOS) | Shows and taps a simulated iPhone or iPad | Opens when the agent runs an app; "Attach simulator", device menu; Cmd+Shift+H Home, Cmd+L lock, Cmd+S screenshot, Cmd+R record; iPhone Duo pose buttons and hinge slider | Missing |
| Side chat pane | CC-D, AG-App | Side questions beside the main chat | CC-D: Cmd+; opens a pane with Minimize. AG-App: Side Question tab with next and previous, Promote to Conversation, Insert into main conversation | Missing |
| Minimize and float | CC-D | Shrinks a terminal, browser, simulator or side chat | Minimize in the pane header; it floats in the chat corner; Expand restores | Missing |
| UI plugin panes | AG-App | Plugin-built web views | Side pane, full pane or sidebar entry; Overview > Extensions; chat links `sidecar://<id>/<path>` open them | Missing |
| Swarm pane | AG-App | Live view of a swarm | Opened from the conversation header "+" menu; tabs Overview, Board (search, filters, Follow), Members (status dots, Show killed), Graph (@mention edges with replay), Raw | Has (partial: room board and side panel) |
| Interface layout presets | AG-App | Software Engineering or Knowledge Work layout | Settings > General; Knowledge Work hides Review and Terminal and renames Files to Folders | Missing |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/desktop-ios-simulator.md, https://code.claude.com/docs/en/claude-code-on-the-web.md, https://antigravity.google/docs/side-panel/, https://antigravity.google/docs/features/, https://antigravity.google/docs/swarm/, https://antigravity.google/docs/jupyter-notebooks/, local: `~/.gemini/antigravity/builtin/plugins/swarm/sidecars/swarm_board/README.md`, `~/.gemini/antigravity/builtin/skills/ui-plugin-navigation/SKILL.md`, Claude desktop agent tools (`show_pane` lists diff, file, terminal, pr, tasks, plan, preview, artifact).

## 5. Review, diffs and version control

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Inline diff comments | CC-D, CC-Web, AG-App, AG-IDE | Comments on exact lines and sends them to the agent | CC-D: "+" beside a line number, Enter, Cmd+Enter submits all. AG-App: hover "+" or select lines > Comment > Add Comment; comments collect as a chip on your next message. AG-IDE: Cmd+Opt+M or gutter "+", "Add Comment to Chat" | Missing |
| Comparison modes | AG-App, CC-D, CC-CLI | Chooses what the diff compares | AG-App: Uncommitted (staged or not), Branch, Agent Edits, plus a "For Turn" filter. CC-D: base branch, uncommitted, a commit, "Compare against". CC-CLI: `/diff` panel, Ctrl+X B cycles the base | Missing |
| Diff display options | AG-App | Controls diff layout | Split or Stacked, Hide Whitespace, Collapse or Expand All, search, word-level highlights, image and SVG diffs | Has (partial: inline diff in edit tool cards) |
| Per-change accept or reject | CC-IDE, AG-IDE, AG-Ext | Accepts or rejects each hunk | CC-IDE: "Accept this change" and "Reject this change" in the side-by-side diff. AG-IDE: controls above each change, Opt+Enter accepts, Opt+Shift+Enter rejects, Accept All and Reject All, pending edits bar "1 File With Changes" | Missing |
| Stage, unstage, discard | AG-App | Per-file git actions | Hover + and - on each file; "Discard unstaged changes" has no confirm | Missing |
| Commit, amend, push | AG-App, AG-IDE | Git from inside the app | Commit dialog; an empty message lets the agent write one ("Generate Commit Message" sparkle); arrow menu Amend and Push; Open Commit Graph (Cmd+Shift+C) | Planned (M1.8 WP-P: commit and push) |
| Create pull request | CC-D, CC-Web | Opens a PR from the session | "Create PR" in the Changes card; right-click for "Create draft PR" on the web; desktop uses `gh` | Planned (M1.8 WP-P) |
| PR bar with CI checks | CC-D, CC-Web, CC-CLI, AG-App | Shows the PR and its checks | CC-D: PR in the Changes card with coloured check status; agent view colours yellow pending or failed, green passed, purple merged, grey draft. CC-CLI: footer badge `PR #446` green approved, yellow pending, red changes requested, Cmd-click opens. AG-App: status pills with hover cards, Pull Requests section in Overview, optional sidebar indicator (2.33.0) | Planned (M1.8 WP-P) |
| Auto-fix CI and review comments | CC-D, CC-Web, CC-CLI | Wakes the session on CI failures, merge conflicts and review comments, then pushes fixes | PR "..." > Auto-fix; CC-CLI `/autofix-pr`; replies are labelled as the agent | Planned (M1.8 WP-P: Fix CI action, review comments into the session) |
| Merge when ready | CC-D | Turns on GitHub auto-merge | PR "..." > "Merge when ready", squash unless a merge queue applies | Missing |
| Bind a PR by URL | CC-D | Tracks a PR opened elsewhere | Paste a PR URL; dismiss with the bar's X (Claude desktop agent tools) | Missing |
| Local code review | CC-CLI, CC-D | Reviews the diff for bugs | `/code-review [level] [--fix] [--comment]`, runs as a background subagent; desktop shows a findings card; `/security-review`; `/simplify` | Missing |
| Cloud deep review | CC-CLI, CC-Web | Multi-agent review of a branch or PR in the cloud | `/code-review ultra` launch dialog with scope and cost; tracked in `/tasks` | Missing |
| Code Review GitHub app | CC-Web | Automatic PR reviews for organisations | "Claude Code Review" check run, `@claude review` comments, Quick, Standard and Deep levels | Missing |
| CLI diff viewer | agy, CC-CLI | Full-screen diff in the terminal | agy `/diff`: All Changes, Per Turn, Commit Tree, `c` comment, unsent comments prompt on exit; git, Mercurial and JJ | Missing |
| Branch picker | CC-D, AG-App | Starts from a chosen branch | CC-Web: repository and branch selectors. AG-App: combined branch and worktree menu | Missing |
| GitHub permissions | AG-App | Limits what the agent may do with `gh` and `git` | Settings "GitHub Permissions" with grants like `gh.update({...})` requested at run time | Missing |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/claude-code-on-the-web.md, https://code.claude.com/docs/en/code-review.md, https://code.claude.com/docs/en/code-review-local.md, https://code.claude.com/docs/en/ultrareview.md, https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/vs-code.md, https://antigravity.google/docs/review-changes/, https://antigravity.google/docs/ide/review-changes-editor/, https://antigravity.google/docs/cli/commands/diff/, local: `~/.gemini/antigravity/builtin/skills/permissioned-github/SKILL.md`, Claude desktop agent tools (`ccd_pr`).

## 6. Agents, multi-agent work and automation

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Subagents | CC (all), AG (all) | Delegated workers with their own context | CC: built-in Explore, Plan, general-purpose; custom agents in `.claude/agents/` with frontmatter (tools, model, effort, permission mode, isolation, colour); Ctrl+B sends one to the background. AG: built-in research, browser and self types; custom `.agents/agents/<name>.md`; up to 10 nesting levels; agy `/agents` panel with Alt+J to the next approval | Has (subagent cards; engines run subagents) |
| Custom main agent | AG-App, agy, CC-CLI | Runs a saved persona as the primary agent | AG-App: agent picker inside the model menu. CC-CLI: `--agent`. agy: `--agent`, `agy agents` | Has (partial: agents in rooms have names and role prompts) |
| Agent teams | CC-CLI | Several sessions share a task list and message each other | Experimental flag; panel below the prompt, or tmux or iTerm2 split panes; `TeammateIdle`, `TaskCreated`, `TaskCompleted` hooks | Has (rooms: Team mode with a lead, assignments, review, merge) |
| Swarms | AG-App, agy | Named workers plus verifier and monitor on a shared board | `/swarm <task>` "(Preview and Quota Heavy)", Pro and Ultra; board addressing `@name`, `@all`, `@#channel`; workers in shared or branched workspaces; App Swarm pane (Board, Members, Graph); agy Alt+S board with Roster, Posts and Message panes | Has (partial: rooms with a board; no monitor, channels or graph) |
| Swarm narrator and monitor | AG-App, agy | Keeps a summary view current and catches stalls | `narrator` worker writes `swarm_view/view.json` (goal, threads, attention, progress, screenshot reel); `monitor` checks every 3 minutes and posts `@coordinator [stall]` | Missing |
| Teamwork (multi-day team) | AG-App, agy | A long-running team with fixed roles | `/teamwork`: scoping interview, prompt artifact to approve, roles Sentinel, Orchestrator, Workers, Critic, Challenger, Auditor | Has (partial: Team and Round table rooms) |
| Boost | AG-App, agy | Multi-round challenge and verify for hard bugs | `/boost` slash command, paid plans | Has (partial: Debate rooms) |
| Dynamic workflows | CC-CLI, CC-D, AG-App, agy | The agent writes a script that runs many subagents | CC: approval per run, `/workflows` progress view (pause, stop, save as command), "Large workflow" warning over 25 agents, `/deep-research`. AG: `/run-workflow` Python script, "Allow running this workflow script?", step like "workflow, Review, 3/4 agents" with agent cards | Missing |
| Batch changes | CC-CLI | Splits a large change across 5 to 30 worktree subagents | `/batch` shows a plan for approval, then background subagents | Has (partial: Team rooms split work by owner) |
| Goal mode | CC-CLI, CC-D, AG (all) | Keeps working until a condition is verified | CC: `/goal <condition>`, indicator "/goal active", `/goal clear`. AG: "Active Goal" indicator above the composer, Goals section with Active, Completed, Cancelled | Missing |
| Side questions | CC-CLI, CC-D, CC-IDE, AG-App, agy | Asks about the session without adding to it | `/btw`; CC-D Cmd+;; CC-CLI overlay with copy and fork to subagent; AG-App Side Question tab, promote or insert | Missing |
| Requirements interview | AG-App, agy | Agent interviews you before planning | `/grill-me`, one question at a time with suggested answers; stackable with `/plan` | Missing |
| Learn from corrections | AG (all), CC (auto memory) | Turns session corrections into rules or skills | AG: `/learn` writes a `learning_proposal.md` artifact to comment on and approve. CC: auto memory notes (section 8) | Missing |
| Session-scoped loops | CC-CLI, CC-D | Repeats a prompt while the session is open | `/loop 5m check deploy`, self-paced without an interval, seven-day expiry | Missing |
| In-conversation timers | AG (all) | One-shot or cron timers inside a conversation | `/schedule`: "Timed" or "Scheduled" step, Pending then Fired | Missing |
| Scheduled tasks on this computer | CC-D, AG-App | Runs prompts on a schedule, locally | CC-D: Scheduled in the sidebar, New task, trigger card Hourly, Daily, Weekdays, Weekly, Manual, Custom; detail page with Run now, Active or Paused, Edit, Delete, History, Always allowed panel; one catch-up run within 7 days after sleep. AG-App: Automations page (Scheduled, Always on, Paused), "Create with Prompt", Run Now, model tier, Cmd+U | Planned (M3 WP-G) |
| Cloud routines and triggers | CC-Web, CC-CLI | Runs a cloud session on a schedule, an API call or a GitHub event | claude.ai/code/routines; trigger "+" with Schedule, API (fire URL and token) and GitHub event filters; history with status filter; `/schedule` | Missing |
| Event triggers | AG-App | Runs a prompt when something happens | Trigger editor "On a schedule" or "When something happens" (local bundle strings; public event sources unverified) | Missing |
| Guided automation setup | AG-App | Builds an automation by conversation | `/automation`: cadence, time, prompt, optional test run that records the permissions the run needs | Missing |
| Sidecars | AG-App | Managed background processes owned by plugins | `sidecar.json` (command, restart policy, web UI, agent permissions); states Running, Stopped, Errored, Backoff; sidecar pills; `agentapi` starts conversations | Missing |
| Cross-session messaging | CC-CLI, CC-D | One session lists and messages others | `SendMessage`, `/list-agents`, `@session` mentions, notify-when-idle, `crossSessionInbound` setting | Has (rooms relay board messages between agents) |
| Channels | CC-CLI | MCP servers push chat, CI or webhook events into a running session | `--channels plugin:telegram@...`, research preview | Missing |
| Headless mode | CC-CLI, agy | Runs non-interactively for scripts | `-p` with text, json or stream-json output, JSON Schema output, budget and turn caps | Has (Ensemble drives `claude -p` stream-json as an engine) |
| ACP server | agy | Antigravity as an agent inside other editors | `agy acp` over JSON-RPC stdio, modes default, accept-edits, plan, auto | Planned (M1.5 WP-K, Ensemble as an ACP client) |
| Agent SDK | CC | Claude Code as a library | Python and TypeScript packages | Missing (not needed) |
| Advisor model | CC-CLI | Consults a second model at key moments | `/advisor [model]`, `--advisor` | Has (partial: rooms can pair models) |
| Coordinators and Chief of Staff | AG-App | Long-running goal agents and an assistant with a canvas | Present in the app bundle behind flags (unverified who gets them) | Missing |

Sources: https://code.claude.com/docs/en/sub-agents.md, https://code.claude.com/docs/en/agent-teams.md, https://code.claude.com/docs/en/workflows.md, https://code.claude.com/docs/en/goal.md, https://code.claude.com/docs/en/scheduled-tasks.md, https://code.claude.com/docs/en/desktop-scheduled-tasks.md, https://code.claude.com/docs/en/routines.md, https://code.claude.com/docs/en/cross-session-messaging.md, https://code.claude.com/docs/en/channels.md, https://code.claude.com/docs/en/headless.md, https://antigravity.google/docs/subagents/, https://antigravity.google/docs/swarm/, https://antigravity.google/docs/teamwork/, https://antigravity.google/docs/boost/, https://antigravity.google/docs/dynamic-workflows/, https://antigravity.google/docs/commands/goal/, https://antigravity.google/docs/commands/btw/, https://antigravity.google/docs/commands/learn/, https://antigravity.google/docs/commands/automation/, https://antigravity.google/docs/commands/schedule/, https://antigravity.google/docs/sidecars/, https://antigravity.google/docs/cli/acp/, local: `~/.gemini/antigravity/builtin/skills/native_swarm/`, `swarm_narrator/`, `swarm_monitor/`, `automation/`, `run-workflow/`.

## 7. Remote control, cloud and mobile

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Remote Control | CC-D, CC-CLI, CC-Web, CC-M, AG-App, agy | Follows and steers a local session from a phone or browser | CC-D: Remote Control switch in the Environment card; setting to connect every new session. CC-CLI: `/remote-control` (`/rc`) with a status panel, URL, QR and disconnect; `claude remote-control` server mode (Space shows a QR, capacity 32). AG-App: Settings > Application > Enable Remote Control and Device Name, QR dialog, instance list. agy: `agy remote-control start, status, stop` | Has (Remote Control switch, QR pairing over Tailscale) |
| Phone view of a session | CC-M, CC-Web, AG web app | What the phone shows | CC: computer icon with a green dot for remote sessions; diff of local changes; model and effort controls; text-output commands like `/compact`, `/usage`. AG: antigravity.google.com/remote with an instance switcher; mobile pickers | Has (iPhone Hub, chats, rooms, approvals, usage) |
| Phone attachments | CC-M, CC-Web | Sends photos and files to a local session | Photos go in directly; files saved under `~/.claude/uploads/` and referenced with @ | Missing |
| Push notifications to the phone | CC-M, AG web app | Alerts when the agent finishes or needs action | CC: `/config` "Push when Claude decides" and "Push when actions required". AG: add the web app to the home screen for notifications | Missing |
| Dispatch | CC-D, CC-M | Message a task from the phone and it runs in the desktop app | Persistent Dispatch conversation; spawned sessions appear in the desktop sidebar; push on completion | Has (partial: the iPhone can message a Mac session; no dedicated dispatch thread) |
| Trusted devices | CC (admin) | Requires an enrolled device for Remote Control | Admin setting "Require trusted devices" (beta) | Has (partial: paired phones only, mutual HMAC) |
| Cloud sessions | CC-Web, CC-D, CC-M, CC-CLI | Runs a session on Anthropic's machines that survives a closed laptop | claude.ai/code repository and branch selectors; desktop environment selector Cloud group; `claude --cloud "task"`; environment editor with network access Limited, Full or None and a setup script | Missing (non-goal for now: Ensemble runs locally) |
| Remote agents | AG-App, agy, AG web | Runs conversations in Google-managed cloud sandboxes | "+" next to Projects > New Remote Project > Add Resource (GitHub, Drive, uploads); "Runs remotely"; daily environment time; agy `--remote-agent` | Missing |
| Mobile start of a cloud task | CC-M | Starts cloud work from the phone | Pick repository and branch, describe the task | Missing |
| Web app | CC-Web, AG web | Browser access to sessions | claude.ai/code session menu (Open in, Share, Fork, Rename, Archive, Delete); antigravity.google.com | Missing (iPhone app instead) |
| Keep the computer awake | CC-D, AG-App | Stops idle sleep while agents work | CC-D: held through each turn by default; settings for scheduled tasks and Remote Control; agents can ask to keep it awake until the session goes idle. AG-App: Prevent Sleep setting; kept awake while an agent runs | Has (Keep Mac awake, lid lock) |

Sources: https://code.claude.com/docs/en/remote-control.md, https://code.claude.com/docs/en/mobile.md, https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/claude-code-on-the-web.md, https://code.claude.com/docs/en/web-quickstart.md, https://antigravity.google/docs/remote-control/, https://antigravity.google/docs/remote-agents/, https://antigravity.google/docs/faq/, local: Claude desktop agent tools (`request_keep_awake`, `set_remote_control`).

## 8. Customization

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Instruction files | CC (all), AG (all) | Persistent instructions loaded every session | CC: `CLAUDE.md` (managed, user, project, subfolders), imports, also reads `AGENTS.md`; `/memory` edits; `/init` writes one. AG: `AGENTS.md`, `GEMINI.md` per folder | Has (partial: engines read their own files; no viewer or editor) |
| Scoped rules | CC (`.claude/rules/`), AG (`.agents/rules/`) | Topic or path-scoped instruction files | CC: `paths` frontmatter. AG: triggers always_on, model_decision, glob, manual; 20k-token budget; App Rules tab with "+ Global" and "+ Workspace" | Missing |
| Auto memory | CC (all) | The agent writes notes from your corrections | Per repository, first 200 lines loaded; `/memory` toggles | Missing |
| Knowledge Items | AG-IDE 1.x | Memory distilled from past conversations | Each item had a title, summary and artifacts, viewed in the Agent Manager; toggle to disable (1.14.2). No screen in 2.x; only system-prompt text remains, and `/learn` replaced it | Missing |
| Conversation history as memory | AG-IDE, agy | Lets the agent read past conversations | IDE setting "Conversation History"; "Generate personalized rules" | Missing |
| Skills | CC (all), AG (all) | On-demand instruction folders (`SKILL.md`) usable as slash commands | CC: `~/.claude/skills`, `.claude/skills`, plugins; `/skills` with token sort and visibility; frontmatter for tools, model, effort, fork. AG: `.agents/skills`, `~/.gemini/config/skills`; skills chip hover card; built-in help skills `/antigravity-guide`, `/agy-customizations` | Has (partial: engine skills appear in the `/` menu; no management screen) |
| Workflows (saved prompts) | AG-IDE | Prompts invoked with `/` | Customizations > Workflows, "+ Global" or "+ Workspace"; deprecated in favour of skills (`/migrate-workflows`) | Missing |
| Plugins and marketplaces | CC (all), AG (all) | Bundles of skills, agents, hooks, MCP servers | CC: `/plugin` tabs Discover, Installed, Marketplaces; scopes user, project, local; "+ > Add plugins" in the desktop. AG-App: Customizations > Marketplace and Installed tabs, featured shelves, "Sign in required" badge, setup dialog for credentials; agy `/plugin` | Missing |
| Customizations screen | AG-App, AG-IDE | One place for everything the agent loads | AG-App: tabs Overview, Accounts, Skills, MCP, Agents, Hooks, Rules, UI Extensions, Automations, Context Providers; Settings > Projects > Customizations shows token count and Global or Workspace badges. AG-IDE: "..." menu > Customizations | Missing |
| MCP servers | CC (all), AG (all) | External tools for the agent | CC: `/mcp` list with Authenticate, Clear authentication, Reconnect, Disable; scopes local, project (`.mcp.json`), user; tool search keeps tools out of context. AG-App: Customizations > MCP: Add MCP Server (searchable), status Pending, Ready, Error, Authenticate, Restart, "Ask the agent to diagnose and fix this server" | Has (partial: Connectors list with status; Authenticate not wired; no add or remove) |
| Connectors (account integrations) | CC-D, CC-Web, CC-M | claude.ai integrations shown as MCP servers | "+ > Add connectors", per-session switch in the "+" menu | Has (partial: shown under Connectors when the engine reports them) |
| MCP Apps | CC-D, AG-App | Tools that draw their own interface | Inline widgets; AG-App inline up to 800 px, in the side pane, or full page | Has (partial: widget blocks only) |
| Hooks | CC (all), AG (all) | Scripts at points in the agent loop | CC: 33 events (SessionStart, PreToolUse, PermissionRequest, Stop, PreCompact and more); handler types command, http, mcp_tool, prompt, agent; `/hooks` menu. AG: `hooks.json` with SessionStart, Pre and PostToolUse, Pre and PostInvocation, Stop; Settings > Customizations > Hooks | Missing (import lists hooks as not imported, M1.6) |
| Output styles | CC (all) | Changes tone and format | `/output-style`: Default, Proactive, Concise, Explanatory, Learning, custom files; session title-bar menu in CC-D | Missing |
| Status line | CC-CLI, agy | Custom footer from a script | `statusLine` command gets session JSON on stdin; `/statusline` generates one | Has (partial: fixed status line with cost, tokens and context) |
| Keybindings | CC-CLI, CC-D, AG-App, agy | Remaps shortcuts | CC-CLI: `~/.claude/keybindings.json` with contexts, `/keybindings`. CC-D: Cmd+/ lists shortcuts. AG-App: Settings > Shortcuts with Add, Edit, Remove, Reset All; overlay Cmd+? | Missing |
| Themes | CC-CLI, AG-App, agy | Colour schemes | CC-CLI: `/theme` auto, light, dark, colour-blind, ANSI, custom JSON. AG-App: Onyx (default), Vesper, Darcula, Gruvbox Material, Everforest, Nord; follows the system | Has (partial: dark and light follow the system; no theme choice) |
| Appearance options | AG-App | Text and layout | Font (System UI, Inter, Google Sans), size 12, 14 or 16 px, conversation width, Markdown artifact width, Screen Reader Mode | Has (partial: window zoom) |
| Import from other agents | CC-CLI, AG-App, agy | Brings in another tool's MCP servers, skills, rules and agents | CC-CLI: `/import codex, gemini, cursor`. AG-App: offered during onboarding for Claude Code, Codex, Cursor and Gemini CLI; agy `plugin import claude` | Planned (M1.6 WP-M: import from Claude Code) |
| Settings files and scopes | CC (all), agy | Layered configuration | CC: managed, user, project, local `settings.json` with precedence; `/config`; `/status` shows sources. agy: `~/.gemini/antigravity-cli/settings.json`, `--settings` per session | Missing (Ensemble settings live in its own app) |
| Vim mode | CC-CLI, agy | Vim keys in the prompt | `/config` Editor mode | Missing |

Sources: https://code.claude.com/docs/en/memory.md, https://code.claude.com/docs/en/skills.md, https://code.claude.com/docs/en/plugins/overview.md, https://code.claude.com/docs/en/mcp.md, https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/output-styles.md, https://code.claude.com/docs/en/statusline.md, https://code.claude.com/docs/en/keybindings.md, https://code.claude.com/docs/en/terminal-config.md, https://code.claude.com/docs/en/settings.md, https://antigravity.google/docs/rules/, https://antigravity.google/docs/skills/, https://antigravity.google/docs/marketplace/, https://antigravity.google/docs/plugins/, https://antigravity.google/docs/mcp/, https://antigravity.google/docs/hooks/, https://antigravity.google/docs/customization-discovery/, https://antigravity-doc.pages.dev/en/artifacts/knowledge, local: `~/.gemini/antigravity/builtin/skills/agy-customizations/` (docs on rules, skills, plugins, MCP, hooks, JSON configs).

## 9. Integrations

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Browser agent in the app | AG-App, CC-D | The agent clicks, types and reads pages in the built-in browser | AG-App: started automatically or with `/browser`; each subagent gets its own tab; tab icon becomes an agent arrow with a spinner; animated cursor and status pill; red Stop then "Browser: you took over"; pauses on sign-in pages for you. CC-D: Browser pane with per-site approval cards (Allow once, Always allow, Deny) and "Auto-verify changes" | Missing |
| Drive your own Chrome | CC-CLI, CC-IDE, agy, AG-IDE | Uses your signed-in Chrome | CC: Claude in Chrome extension, `claude --chrome`, `/chrome` status panel, `@browser` in VS Code. AG: Chrome DevTools MCP, enable remote debugging, `/browser`, click Allow within 60 s | Missing |
| Browser recordings and screenshots | AG-IDE, AG-App, agy, CC-CLI | Video and stills of browser sessions | AG: `recording.webm` player with back and forward 5 s and speed; screenshots with drag-to-comment regions; agy MP4. CC-CLI: Chrome GIF recording | Missing |
| Computer use | CC-D, CC-CLI | Controls native apps on screen | Settings "Enable computer use", per-app approval "Allow for this session", tiers view only, click only, full control; Denied apps list; Esc aborts | Missing |
| Open in editor | CC-D, AG-App | Opens files in another app | CC-D: "Open in" from the session menu or right-click (VS Code, Cursor, Windsurf, Zed). AG-App: Open IDE button | Missing |
| Reveal in Finder | CC-D | Shows a file in Finder | Right-click > Show in Finder | Has (session folder) |
| IDE connection | CC-CLI, CC-IDE, agy, AG-Ext | Links the agent to an editor for selection, diagnostics and diffs | CC: built-in IDE MCP server, `/ide`, diagnostics sharing, selection context. AG: VS Code, Visual Studio and JetBrains extensions; ACP for Zed, JetBrains, Android Studio, Xcode | Missing |
| Editor AI completions | AG-IDE | Tab completions and inline edits | Supercomplete (grey insertions, red deletions), Tab to Jump, Tab to Import, Cmd+I inline command, code lenses (Refactor, Write Tests, Explain), "Explain and Fix Problem" | Missing (out of scope: Ensemble has no code editor) |
| GitHub app and Actions | CC-CLI, CC-Web | Runs the agent in CI and on `@claude` mentions | `/install-github-app`, `anthropics/claude-code-action` | Missing |
| Slack | CC-Web | The agent works in Slack threads | Claude Tag, `@Claude` in channels, Team and Enterprise | Missing |
| Google stacks | AG-App | Curated Firebase, Android, Cloud, Maps bundles | Settings > Customizations > Build with Google Plugins, filter tabs | Missing |
| Cloud billing | AG (all), CC-CLI | Bill usage to a cloud project or provider | AG: Google Cloud pay as you go. CC: Bedrock, Vertex, Foundry, gateways | Has (OpenCode providers, including Bedrock and Vertex) |
| Artifacts (published pages) | CC-CLI, CC-D, CC-Web | Publishes a live page from a session | Gallery at claude.ai/code/artifacts, Share with viewer or editor roles, versions, comments sent to the agent, `/artifacts` | Missing |
| Generative UI | AG-App, CC | Interactive HTML widgets | AG: `/generative_ui`, inline or side panel, Export Artifact. CC: widgets and artifacts | Has (widget code blocks) |
| Jupyter notebooks | AG-App, AG-IDE | Views or runs notebooks | App: Preview or Raw, comment on cells. IDE: run cells, pick kernels | Missing |
| Image generation | AG (all) | Mockups and diagrams | Built-in image model, not user-configurable | Missing |
| Deep links | AG-App | Links that open items or pre-filled conversations | `antigravity://` scheme | Missing |

Sources: https://code.claude.com/docs/en/chrome.md, https://code.claude.com/docs/en/computer-use.md, https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/vs-code.md, https://code.claude.com/docs/en/jetbrains.md, https://code.claude.com/docs/en/github-actions.md, https://code.claude.com/docs/en/artifacts.md, https://claude.com/docs/claude-tag/overview.md, https://antigravity.google/docs/browser/, https://antigravity.google/docs/ide/browser/, https://antigravity.google/docs/ide/browser-recordings/, https://antigravity.google/docs/screenshots/, https://antigravity.google/docs/ide/tab/, https://antigravity.google/docs/ide/extensions/, https://antigravity.google/docs/build-with-google/, https://antigravity.google/docs/jupyter-notebooks/.

## 10. Safety and permissions

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Permission modes | CC (all), agy | How much runs without asking | CC: Manual (default), Accept edits, Plan, Auto, Bypass, plus dontAsk by flag; status bar labels; Auto is the default for new interactive sessions (2.1.283+). agy: default, accept-edits, plan, auto (default since 1.5.7) | Has (Ask, Accept edits, Auto, Bypass; Auto is the default; no Plan) |
| Permission presets | AG-App | One-click safety level | Request Review, Default (sandboxed commands run without asking), Auto, Turbo; Settings > General > Global Permissions; per-project "Inherit Global"; picker above the composer | Has (modes play this role) |
| Auto mode classifier | CC (all), AG-App | A second model approves or blocks actions | CC: blocked actions listed under `/permissions` Recently blocked; pauses after 3 blocks in a row or 20 in total; custom allow and soft-deny rules. AG-App: Auto preset checks risky commands outside the sandbox | Has (partial: Auto is an allowlist, not a classifier) |
| Allow, ask and deny rules | CC (all), AG (all) | Fine-grained rules per tool | CC: `Bash(npm run test *)`, `Read(./.env)`, `WebFetch(domain:...)`, `mcp__server__tool`. AG: `command(...)`, `read_file(...)`, `write_file(...)`, `read_url(...)`, `execute_url(...)`, `mcp(server/tool)`; deny beats ask beats allow | Has (partial: Always allow saves a pattern; no rule editor) |
| Rule editor | CC-CLI, agy, AG-App | Views and edits saved rules | CC-CLI `/permissions`: rules by scope, working directories, Recently blocked, Auto mode tab. AG-App: Tool Permissions pages per resource type. agy `/permissions` | Missing |
| Permission prompt scope | CC (all), AG (all) | How far an approval reaches | CC: yes once, yes and do not ask again (scoped), no; Tab adds a comment. AG: once, conversation, workspace, project or global; agy "allow this prefix for the conversation" | Has (partial: once or always) |
| Sandbox | CC-CLI, AG (all) | OS-level isolation for agent commands | CC: macOS Seatbelt, Linux bubblewrap, `/sandbox` panel with Mode, Overrides, Config, Dependencies; network allowlist; credential masking. AG: Seatbelt, namespaces, AppContainer; no network unless granted; blocks `~/.ssh` and `.env`; sandbox shield badge | Missing |
| Protected paths | CC (all) | Writes to `.git`, `.claude`, shell rc files and `.mcp.json` always ask | Prompted in Manual and Accept edits | Has (partial: config edits ask, per commit 9e81e75) |
| Folder access | CC-D, AG (all) | Controls which folders the agent can touch | CC-D: Add folder; request-directory card with a folder picker. AG: Non-Workspace File Access Allow, Ask or Deny | Has (partial: Auto only allows edits inside the project) |
| Internet access policy | AG-App, CC-Web | Controls network use | AG-App: Allow, Ask or Deny, global and per project. CC-Web: Limited, Full or None per environment | Has (partial: web fetches ask in Auto) |
| Browser URL rules | AG-App, AG-IDE | Which sites the browser agent may act on | Settings > Browser: Execute URLs and Download files lists; prompt "Allow executing actions on this URL?"; JavaScript execution policy Request Review, Always Proceed, Disabled | Missing |
| Strict mode | AG-IDE | Locks the agent to review for terminal, browser JS and artifacts | Settings toggle, options greyed out while on | Missing |
| Workspace trust | CC (all), agy | Asks before loading project hooks, MCP servers and settings from a new folder | Trust dialog on first start | Missing |
| Prompt-injection guards | CC (all) | Defends against instructions in content | Network commands ask; command injection checks; pasted text marked untrusted; asks before sending your account email (2.1.317) | Missing |
| Managed settings | CC (all), AG (all) | Organisation policy | CC: managed settings and admin console toggles. AG: `admin_settings.json`, plugin controls, "This setting is managed by your organization" | Missing (not needed for a personal app) |
| Unattended permissions | CC-CLI, AG-App | Scheduled runs deny instead of waiting | CC: `--permission-prompts none`. AG: automation runs use only grants recorded during a test run | Missing |
| Voice approvals | AG-App | Approve prompts by voice | Allow once, conversation, project or global, or Deny; destructive actions still need a click | Missing |

Sources: https://code.claude.com/docs/en/permission-modes.md, https://code.claude.com/docs/en/permissions.md, https://code.claude.com/docs/en/sandboxing.md, https://code.claude.com/docs/en/security.md, https://code.claude.com/docs/en/auto-mode-config.md, https://code.claude.com/docs/en/headless.md, https://antigravity.google/docs/permissions/, https://antigravity.google/docs/sandbox/, https://antigravity.google/docs/agent-settings/, https://antigravity.google/docs/ide/allowlist-denylist/, https://antigravity.google/docs/settings/, https://antigravity.google/docs/voice-mode/, local: Antigravity app bundle permission preset list, `~/.gemini/antigravity/builtin/skills/automation/SKILL.md`.

## 11. Usage, limits and cost

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| Plan limit meter | CC-D, AG-App | Shows plan usage at a glance | CC-D: usage ring at the right of the row under the prompt; 5-hour, weekly, per-model weekly and extra-usage figures with reset times. AG-App: context and quota ring next to Send; two quota pools (Gemini; Claude plus GPT), each with weekly and 5-hour limits, shown in the model picker | Planned (M3 WP-G: usage popover with provider rate limits; no ring) |
| Usage screen | CC-CLI, CC-IDE, AG-App, agy | Detailed usage | CC-CLI `/usage`: session block (cost, duration, lines changed, by model), plan bars, prompt-cache stats, a breakdown of which skills, subagents and MCP servers use the most, `f` applies fixes. CC-IDE: Account and usage dialog with Day and Week. AG-App: Settings > Models and Usage with Your Plan, quota bars per model, AI Credits. agy: `/usage` "Models and Quota" with reset times in local time | Has (partial: session cost and tokens; iPhone Usage tab) |
| Session cost and tokens | CC-CLI, CC-D | Cost of this session | `/usage` session block; live output tokens beside the spinner | Has (status line) |
| Context breakdown | CC (all), AG-App, agy | What fills the context window | CC-D Context card; CC-CLI `/context` coloured grid with hints. AG-App: token usage bars. agy: `/context` panel | Has (context panel breakdown) |
| Limit reached flow | CC-CLI, CC-D, AG-App | What happens at a limit | CC-CLI: "Usage limit reached, limit resets 3:45pm", "Continuing automatically, Esc to cancel", `/rate-limit-options`. AG: "Model quota reached", "Insufficient AI Credits" | Missing |
| Auto-continue on reset | CC-Web, CC-D | Resumes work when the limit resets | Project setting "Auto-continue when usage limits reset" | Missing |
| Extra usage and credits | CC (all), AG-App, agy | Pays beyond the plan | CC: `/usage-credits`, spend limit row. AG: "Enable AI Credit Overages" (Never or Always), Purchase Credits, agy `/credits` | Missing |
| Spending caps | CC-CLI | Stops a run at a budget | `--max-budget-usd` for `-p` runs | Planned (M2 WP-C: caps per agent and per room) |
| Usage insights report | CC-CLI | HTML report on how you work | `/insights` writes `~/.claude/usage-data/report.html` | Missing |
| Quota-aware model switching | AG-App, agy | Switches a swarm member's model when quota runs out | `swarm` tool shows `quota_remaining` and `quota_resets` | Missing |

Sources: https://code.claude.com/docs/en/costs.md, https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/claude-projects.md, https://antigravity.google/docs/models/, https://antigravity.google/docs/plans/, https://antigravity.google/docs/cli/commands/usage/, local: Antigravity app bundle (Models and Usage strings), Claude desktop agent tools (`get_usage`).

## 12. Notifications

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| System notifications | CC-D, AG-App, AG-IDE | Alerts when a session finishes or needs input while out of view | CC-D: native notification; project notifications for posts, errors and input needed. AG-App: Settings > Notifications "Enable Notifications for Agent", toasts stacked bottom right | Missing |
| Sounds | AG-App, AG-IDE, CC-CLI | Audible alerts | AG: "Enable Sounds for Agent" with volume (action-required and done sounds). CC-CLI: terminal bell, or a Notification hook that plays a sound | Missing |
| Menu bar agent count | AG-App | Shows how many agents run | Tray label "N agents running"; quitting asks because agents may be running | Missing |
| Dock badge | CC-D (unverified) | Count on the app icon | Not documented | Missing |
| Terminal notifications and title | CC-CLI, agy | Alerts in the terminal | `preferredNotifChannel` (bell, iTerm2, Kitty, Ghostty), session status in the terminal title (OSC 7501) | Missing (not applicable) |
| Scheduled run notices | CC-D | Tells you about catch-up runs and failures | Notification when a missed task runs or a scheduled task fails | Missing |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/desktop-scheduled-tasks.md, https://code.claude.com/docs/en/terminal-config.md, https://antigravity.google/docs/changelog/, local: Antigravity app `tray.js` and sound files in the app bundle.

## 13. Onboarding, settings and keyboard

| Feature | Product(s) | What it does | How the UI presents it | Ensemble |
|---|---|---|---|---|
| First run | CC-D, AG-App, agy | Sign-in and setup | CC-D: download, sign in, Code tab. AG-App: "Continue with Google" or "Use Business Account", role question (Software Engineering, Knowledge Work, Data and Analytics, Science, Design, Other) that sets the layout, tour cards, theme and plugin picks, import from other agents. agy: colour scheme, rendering mode, workspace trust | Has (partial: engine missing or too old screens; full onboarding Planned M5) |
| Settings window | CC-D, AG-App | All preferences | CC-D: Settings > Code (prompt suggestions, bypass mode allowed, browser tools, Remote Control for new sessions, auto-archive, branch prefix, worktree location), Desktop app, This computer (Storage, System), Capabilities (computer use, denied apps). AG-App (Cmd+,): Projects, Agents, Environments, Application (General, Appearance, Notifications, Models and Usage, Customizations, Browser, App, Account, Shortcuts, Developer, Labs) | Has (General, Providers, Models, Engine, Power) |
| Accounts and sign-in | CC, AG | Subscription and API sign-in | CC: `/login`, `/logout`. AG: Google or business account, license picker | Planned (M1.5 WP-L: Settings > Accounts) |
| Shortcut list | CC-D, AG-App, CC-CLI | Shows all shortcuts | CC-D: Cmd+/. AG-App: Cmd+? overlay. CC-CLI: `?` | Planned (M5) |
| Command palette | AG-App | Runs any app command | Cmd+Shift+P or type `>`; includes Pin, Archive, Find in Conversation, Toggle theme, Download Diagnostics | Missing |
| Pickers | AG-App | Fast navigation | Cmd+P files, Cmd+K conversations, Cmd+Shift+K projects, Cmd+. environments | Missing |
| Core desktop shortcuts | CC-D | Everyday keys | Cmd+N new, Cmd+W close, Cmd+Shift+D diff, Cmd+Shift+B browser, Ctrl+` terminal, Cmd+Shift+M modes, Cmd+Shift+I model, Cmd+Shift+E effort, Esc stop, Ctrl+O view mode | Has (partial: Cmd+N, Cmd+Return, Esc, Cmd+1 to 9, Ctrl+Cmd+S sidebar, Opt+Cmd+I context panel, zoom) |
| Core Antigravity shortcuts | AG-App | Everyday keys | Cmd+B sidebar, Cmd+Shift+B side panel, Cmd+J terminal, Cmd+L focus input or add selection, Cmd+/ model, Opt+Enter continue or accept step, Ctrl+C cancel a turn (not Esc), hold Ctrl+M to dictate | Missing |
| Release channel and updates | CC-D, AG-App | Picks build stream, checks updates | CC-D: Stable or Latest (2026-11-17), Claude > Check for Updates. AG-App: Automatic Check for Updates, Restart to Update | Missing (built from source with `scripts/install-mac.sh`) |
| Labs and developer settings | AG-App | Early features and diagnostics | Labs section; Developer section with feature flags, Reset onboarding, Download Diagnostics | Missing |
| Feedback | CC-CLI, AG-App | Sends product feedback | CC `/feedback`, `/bug`. AG Settings > Feedback | Missing |
| Accessibility | CC-CLI, AG-App | Screen reader support | CC-CLI `--ax-screen-reader`. AG-App Screen Reader Mode | Planned (M5: accessibility labels) |

Sources: https://code.claude.com/docs/en/desktop.md, https://code.claude.com/docs/en/desktop-quickstart.md, https://support.claude.com/en/articles/12138966-release-notes, https://antigravity.google/docs/getting-started, https://antigravity.google/docs/settings/, https://antigravity.google/docs/search/, local: Antigravity app bundle settings list and keybinding table.

## 14. Antigravity concepts in detail

| Concept | Where it lives now | What it is and how it looks | Ensemble |
|---|---|---|---|
| Agent Manager vs Editor | AG-IDE 1.x; replaced by the 2.0 App | 1.x: the Agent Manager was a separate mission-control window for many agents across workspaces, with an Inbox and Playground; Cmd+E or the top-right "Open Editor" / "Open Agent Manager" button switched views. 2.0 (May 19 2026) split them into two apps: the agent-first Antigravity App and the Antigravity IDE. The IDE still has an "Agent Window" setting (on by default) and a "Keep in Background" choice when closing a window | Has (Ensemble is an agent-first app like the 2.0 App) |
| Inbox | AG-IDE 1.x | All conversations, flagged when they need approval, with a "pending" switch. Gone in 2.x; replaced by unread badges, status icons and the IDE's Inline Actions card | Planned (Session Hub, M3 WP-E) |
| Artifacts | All Antigravity products | Documents the agent writes for review, stored in `brain/<conversation-id>/`: Task (task list), Implementation Plan, Walkthrough (changes made, validation results, screenshots), screenshots, browser recordings, generative UI widgets. Cards in the chat open in the side panel; Overview > Artifacts lists them; Export as PDF | Has (partial: task-list card and widgets) |
| Inline comments on artifacts | AG-App, AG-IDE, agy | Highlight text, type, Add Comment; comments collect in a chip above the composer ("2 Comments") and go with Proceed or your next message; image comments by dragging a region; also on diffs, editor lines and terminal output; agy uses `c` in its viewers | Missing |
| Review policy | AG (all) | Whether the agent waits for plan approval: Always Ask (Request Review), Agent Decides, Always Proceed | Missing |
| Knowledge Items | AG-IDE 1.x | Self-building memory from past conversations (title, summary, artifacts), browsable in the Agent Manager. No screen and no folder in 2.x; `/learn` turns lessons into rules or skills instead | Missing |
| Planning vs Fast mode | AG-IDE 1.x | Chosen per conversation: Planning made task groups and artifacts, Fast acted directly. Replaced by `/plan` and the Shift+Tab mode cycle; agy dropped `/fast` in 1.1.0 | Missing (plan mode) |
| Swarm board | AG-App, agy | Shared board for `/swarm` workers: Board (search, filters, Follow, unread divider), Members (Active, Standing by, Retired), Graph (who mentioned whom, with replay), Overview kept current by a narrator worker | Has (partial: room board) |
| Sidecars | AG-App | Background processes defined by `sidecar.json`, owned by plugins or the user, with optional web UI panels; automations are sidecars that start conversations on a cron schedule | Missing |
| Browser agent | AG-App, AG-IDE, agy | Built-in browser subagent with a live cursor, per-tab work, Stop and take over, sign-in handoff, URL allow lists, recordings | Missing |
| Remote agents and Remote Control | AG-App, agy | Cloud-run conversations and phone or browser control of local ones | Has (partial: iPhone remote over Tailscale) |

Sources: https://antigravity-doc.pages.dev/en/agent-manager, https://antigravity-doc.pages.dev/en/agent-manager/inbox, https://antigravity-doc.pages.dev/en/agent/agent-modes-settings, https://antigravity-doc.pages.dev/en/artifacts/knowledge, https://antigravity.google/blog/introducing-google-antigravity-2, https://antigravity.google/docs/artifacts/, https://antigravity.google/docs/implementation-plan/, https://antigravity.google/docs/walkthrough/, https://antigravity.google/docs/artifact-review/, https://antigravity.google/docs/swarm/, https://antigravity.google/docs/sidecars/, https://antigravity.google/docs/browser/, local: Antigravity IDE workbench strings (Agent Window, Keep in Background), `~/.gemini/antigravity/builtin/skills/antigravity_guide/references/app.md`.

## 15. Terminal-only features (CC-CLI and agy)

These matter to Ensemble mostly as engine behaviour to surface, since Ensemble drives both CLIs headless.

| Feature | Product(s) | What it does | How it is presented | Ensemble |
|---|---|---|---|---|
| Shell mode | CC-CLI, agy | Runs a shell command and feeds the output to the agent | Type `!` first | Missing |
| History search | CC-CLI | Searches past prompts | Ctrl+R; scope session, project or all | Missing |
| Fullscreen renderer and focus view | CC-CLI, agy | Flicker-free alternate screen | `/tui fullscreen`, `/focus`; agy rendering mode | Missing (not applicable) |
| Prompt suggestions, spell check, emoji codes | CC-CLI | Typing aids | Grey suggestion, aspell underline, `:name:` popup | Missing |
| Built-in commands list | CC-CLI | About 100 slash commands | Session (`/clear`, `/compact`, `/context`, `/resume`, `/branch`, `/fork`, `/rename`, `/export`, `/copy`), models (`/model`, `/effort`, `/fast`, `/advisor`, `/autocompact`), config (`/config`, `/permissions`, `/hooks`, `/mcp`, `/plugin`, `/skills`, `/memory`, `/init`, `/keybindings`, `/statusline`, `/theme`, `/sandbox`, `/status`, `/doctor`), review (`/code-review`, `/security-review`, `/simplify`), automation (`/loop`, `/goal`, `/schedule`, `/workflows`, `/batch`, `/background`, `/tasks`), remote (`/remote-control`, `/teleport`, `/desktop`, `/mobile`), usage (`/usage`, `/usage-credits`, `/insights`) | Has (partial: engine commands appear in the `/` menu and run through the engine) |
| agy commands list | agy | About 50 slash commands | `/config`, `/model`, `/effort`, `/usage`, `/quota`, `/credits`, `/context`, `/compact`, `/resume`, `/fork`, `/rewind`, `/diff`, `/artifact`, `/btw`, `/agents`, `/tasks`, `/skills`, `/plugin`, `/mcp`, `/hooks`, `/permissions`, `/plan`, `/goal`, `/grill-me`, `/learn`, `/swarm`, `/teamwork`, `/browser`, `/projects`, `/voice`, `/remote-control`, `/codesearch` | Planned (M1.5 WP-K, through ACP) |
| CLI artifact review panel | agy | Approves or rejects agent files | Ctrl+R picker with new, approved and rejected marks, bulk keys, Mermaid drawn with Kitty graphics | Missing |
| Background dispatch | CC-CLI | Starts a session with no terminal | `claude --bg`, `--exec` | Missing |
| Code search | agy | Progressive code search | `/codesearch` (`/cs`) with `f:` filters | Missing |
| Mic over SSH | agy | Streams a microphone to a remote CLI | `agy mic-serve` | Missing (not applicable) |

Sources: https://code.claude.com/docs/en/commands.md, https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/cli-reference.md, https://antigravity.google/docs/cli/using/, https://antigravity.google/docs/cli/artifacts/, https://antigravity.google/docs/cli/reference/, local: `claude --help` (2.1.319), `agy --help` (1.5.10).

## 16. IDE extension features (CC-IDE, AG-IDE, AG-Ext)

Ensemble has no code editor, so these are reference only.

| Feature | Product(s) | What it does | How it is presented | Ensemble |
|---|---|---|---|---|
| Agent panel in the editor | CC-IDE, AG-IDE, AG-Ext | Chat beside the code | CC: Spark icon, Cmd+Esc focus, Cmd+Shift+Esc new tab, movable panel. AG: activity bar container, Cmd+L, Cmd+Shift+L new conversation | Not applicable |
| Selection and open file context | CC-IDE, AG-IDE | Sends the selection automatically | Footer shows selected lines; Cmd+L adds selection in AG | Not applicable |
| Diagnostics sharing | CC-IDE | The agent reads lint and type errors | Built-in IDE MCP server | Not applicable |
| Multiple sessions as tabs | CC-IDE | Several conversations in the editor | Tabs with coloured status dots, history button | Not applicable |
| Terminal mode toggle | CC-IDE | Runs the CLI in the editor terminal | `claudeCode.useTerminal` | Not applicable |
| Tab completions and inline command | AG-IDE | Editor AI | Supercomplete, Tab to Jump, Cmd+I | Not applicable |
| Settings import | AG-IDE | Moves settings from VS Code or Cursor | Import flow, Open VSX extensions | Not applicable |

Sources: https://code.claude.com/docs/en/vs-code.md, https://code.claude.com/docs/en/jetbrains.md, https://antigravity.google/docs/ide/agent-side-panel/, https://antigravity.google/docs/ide/extensions/vscode/, https://antigravity.google/docs/ide/tab/.

## Notable changes in the last six months

- Claude Code 2.1.283 to 2.1.327 (about Jul to Nov 2026): Auto became the default permission mode for interactive sessions; `/goal`, dynamic workflows and `/workflows`, `/advisor`, Code Mode (experimental), `/fork` as background copies, ExitWorktree asks before removing a worktree with unsaved work (2.1.327), sandboxed Bash follows the normal permission flow by default (2.1.325), cross-session message limit raised (2.1.323). Fast mode for Opus 4.8 is being removed on 2026-11-30.
- Claude desktop: release channels Stable and Latest (2026-11-17); iOS Simulator pane with iPhone Duo poses; scheduled tasks renamed from Routines; Claude Projects beta with threads grouped by state; Dispatch from the phone.
- Antigravity 2.0 (2026-05-19) split the product into the agent-first App and a separate IDE, then shipped fast: `/plan` (2.17.0), Automations (2.21.1), Overview panel and `/compact` (2.24.0), notification settings (2.26.0), built-in browser and PDF viewer (2.28.0), voice mode, remote agents and Settings > Shortcuts (2.29.0), Knowledge Work layout and the built-in browser subagent (2.30.0), `/swarm` (2.31.0), dynamic workflows (2.32.0), SSH hosts and GitHub PR status (2.33.0). `agy` gained ACP in 1.5.0 and made Auto the default in 1.5.7.

## Surprises and notes for Ensemble

1. **Both products converged on the same shape.** Plan document with comments, review pane with line comments, side panel with tabs, background-task list, `/btw` side questions, `/goal`, dynamic workflows that script many subagents, scheduled tasks, phone remote. Ensemble's rooms are its answer to swarms and teams; the rest are table stakes now.
2. **Antigravity dropped its signature 1.x ideas.** Knowledge Items, the Inbox, Playground and the Planning/Fast toggle are gone from 2.x docs and UI strings; `/learn`, unread badges and `/plan` replaced them. Copy the 2.x versions, not the 1.x ones.
3. **The Antigravity desktop interface ships inside its `language_server` binary**, not the Electron bundle, and the internal codename "Jetski" leaks into labels ("Include Jetski Default Customizations"). The bundle also carries Google-internal features (Coordinators, Chief of Staff, Best of N battle mode) behind flags.
4. **Cancelling a turn in the Antigravity App is Ctrl+C on macOS, not Esc.** Ensemble uses Esc like Claude Code, which is the better fit for its users.
5. **This Mac's Antigravity config is set to the Turbo preset**, "Always Proceed" for terminal commands, sandbox off and non-workspace access Allow (`~/.gemini/config/config.json`). Sessions Ensemble starts through `agy acp` inherit that unless Ensemble passes its own mode, which matters for WP-K.
6. **Claude Code's Auto mode is a model classifier; Ensemble's Auto is an allowlist.** DESIGN.md chose the allowlist on purpose; the reference apps show users expect "Recently blocked" visibility either way.
7. **The Claude desktop app exposes its own session tools to agents** (pin, group, move to section, show pane, bind PR, start side session, archive), so Ensemble's Claude Code engine sessions could, in principle, be organised by agents the same way if Ensemble offers similar tools through MCP.
8. **Version drift on this Mac:** Claude Code 2.1.319 (8 releases behind 2.1.327), Antigravity IDE 2.6.0 (behind 2.7.0), Antigravity App 2.32.2 (behind 2.33.0).
9. **iPhone push is the gap with the most reach.** Both references push to the phone; Ensemble's free Apple account cannot use APNs, so a self-hosted ntfy topic or a similar relay is the obvious bridge to evaluate.

## Reviews consulted

- Pragmatic Engineer called the Antigravity 2.0 rollout rushed: the forced update replaced the IDE, naming confused users, Ultra quota ran out in minutes, and the CLI lacked ACP at launch. https://blog.pragmaticengineer.com/the-pulse-antigravity-2-0-takes-ide-out-of-its-new-ide/
- InfoWorld liked the chat-first App, multi-folder projects, worktree mode, `/btw` and `/grill-me`; criticised a timeout that lost a session. https://www.infoworld.com/article/4234567/hands-on-with-antigravity-2-no-ide-just-agent-chat.html
- TechCrunch covered the 2.0 launch: parallel agents, scheduled tasks, voice, new $100 and $200 Ultra tiers. https://techcrunch.com/2026/05/19/google-launches-antigravity-2-0-with-an-updated-desktop-app-and-cli-tool-at-io-2026/
- Wikipedia summarises early reception and security incidents (a Turbo-mode drive wipe report, a strict-mode prompt-injection bypass fixed 2026-02-28). https://en.wikipedia.org/wiki/Google_Antigravity
