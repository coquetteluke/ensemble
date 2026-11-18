# Other AI coding apps and the UI ideas Ensemble should borrow

Research snapshot, 2026-11-18. Covers the agent features and UI patterns of the main AI coding apps as they stand in November 2026, then lists 30 concrete ideas for Ensemble, each marked Has, Plans (with the PLAN.md milestone) or Missing.

Method: official docs and changelogs first, then reputable reviews, read on 2026-11-18. Each section ends with its sources. "Unverified" means only a third-party source backs the claim, or the official page could not be read. Products change monthly, so check the dates before building on any single claim.

## 1. What changed in 2026 (read this first)

- **Windsurf is gone as a name.** Cognition renamed it Devin Desktop on 2026-06-02 and removed Cascade on 2026-09-08. Devin Local is now its only built-in agent, and other agents plug in over ACP.
- **Codex moved into ChatGPT.** The standalone Codex Mac app launched 2026-02-02. On 2026-07-09 it was folded into a new ChatGPT desktop app, where Codex sits beside Chat and Work. The docs moved to learn.chatgpt.com.
- **Roo Code shut down** on 2026-05-15, and its repo is archived. Kilo Code (whose CLI is a fork of OpenCode) and Cline took its users.
- **OpenCode dropped session sharing** on 2026-10-15 ("Session sharing has been discontinued", v1.19.1). Its desktop app gained tabs, an Inbox, worktrees and phone pairing by QR code.
- **Amp left the editor.** The extension shut down 2026-03-05, public threads ended 2026-06-02, and Amp is now web, CLI and native apps, with "Spaces" (a coordinator agent that runs threads).
- **Every tool now hosts several agents at once.** Cursor 3 has the Agents Window and Projects. GitHub ships the Copilot app, which runs Claude and Codex. Devin Desktop has the Agent Command Center, Zed 1.0 has Parallel Agents, Kiro 1.0 has Agent Focus, Antigravity 2.0 has /swarm, and JetBrains Air is new. Claude Code itself gained agent teams and `claude agents`.
- **Some parallel-agent apps did not last.** Crystal became Nimbalyst, Superset became Paradev, Vibe Kanban is community-maintained after Bloop closed (2026-04-10), Terragon shut down, and Emdash moved its new work to a cloud product.

### The common shape in late 2026

Almost every product converged on the same layout:

- a sidebar of sessions grouped by status, with "needs you" at the top
- one git worktree per agent session, with a Local / Worktree / Cloud picker
- a diff pane where line comments go back to the agent as one batch
- a PR and CI strip with a merge button
- side chats that do not derail the main run
- native notifications, a phone remote, and a keep-awake option
- other vendors' agents brought in over the Agent Client Protocol (ACP)

What almost nobody does is let agents from different vendors talk to each other as equals: debate in rounds, review each other, hand work over. Antigravity's /swarm board and Cursor's multiplayer Projects (coordinators messaging each other) come closest. Both are one vendor's models in a coordinator-and-workers setup. That gap is Ensemble's opening.

## 2. Product catalog

Each line says what the feature does and how the UI presents it.

### 2.1 Cursor (Cursor 3.x, date-named releases since July 2026)

1. **Agents Window (3.0, April 2026):** an agent-first window beside the classic IDE ("Open Agents Window" / "Open IDE"). It lists agents running locally, in worktrees, in the cloud and over SSH, across repos.
2. **Tiled layout (3.1):** drag agents into split panes, expand one to focus, move between panes from the keyboard, and the layout is kept between sessions.
3. **New diffs view:** word-level diffs. Stage, commit and open a PR in place, and click a diff to jump to the line in the file.
4. **Worktrees:** every agent in the Agents Window gets its own checkout. One click brings its branch to your local checkout (3.2). The IDE has `/worktree` and `/apply-worktree`, and `.cursor/worktrees.json` holds setup commands.
5. **Best-of-N:** `/best-of-n sonnet,gpt,composer <task>` runs each model in its own worktree. Since 2.2 Cursor recommends a winner with a comment saying why, and you apply the winner yourself.
6. **/multitask (3.2):** queued messages run as parallel async subagents instead of waiting.
7. **Plan mode:** plans are editable files with inline Mermaid diagrams. You can select to-dos and send them to new agents, and export a plan as Markdown.
8. **Cloud Agents (formerly Background Agents):**
   - Start from the "Cloud" option under the input, cursor.com/agents, the iOS app, or `@cursor` in Slack, Linear or GitHub.
   - The agent page shows the conversation, the diffs and artifacts (screenshots, videos, logs).
   - You can take over the agent's remote desktop and hand it back.
9. **Projects (beta 2026-09-10, multiplayer 2026-11-10):** a coordinator agent that never writes code plans the work and delegates to worker agents. A shared task board shows each task's assignee, agent activity and PR. In multiplayer, each teammate's coordinator messages the others to flag overlapping work. (Multiplayer details are from secondary sources.)
10. **iPhone remote and voice:** the iOS app lists the agents on your Mac, lets you reply, and has a "Keep this computer awake" option. Voice chat puts a waveform button next to Send and shows a Live Activity on the Lock Screen.
11. **Side chats (3.11):** `/side` or `/btw` opens a side thread without derailing the running agent. Cmd+K searches every agent transcript.
12. **Bugbot:** PR comments with an explanation and a suggested fix, plus "Fix in Cursor" and "Fix in Web" buttons. It adds a CI check, and Autofix runs a cloud agent. Newer bots: Security Review (severity and attack path) and Rollouts (each environment marked healthy, regressed or inconclusive).
13. **Built-in browser and Design Mode:** a browser pane where the agent's actions and screenshots appear in the chat. Cmd+Shift+D lets you select and annotate page elements and add them to the chat.
14. **Context breakdown (3.3):** how much of the context rules, skills, MCP servers and subagents use. The Usage tab lists each turn with its model and tokens. Dollar amounts were reportedly removed for self-serve plans (unverified).
15. **Auto-review run mode (3.6):** every tool call goes through an allowlist, then a sandbox, then an AI judge that decides to run it, run it sandboxed, or ask you. `hooks.json` covers about 20 events, including `subagentStart` and `subagentStop`.

Memories were removed in 2.1.17 in favour of rules and skills.

Sources: https://cursor.com/changelog, https://cursor.com/changelog/3-0, https://cursor.com/changelog/3-1, https://cursor.com/changelog/2-2, https://cursor.com/docs/agent/agents-window, https://cursor.com/docs/cloud-agent, https://cursor.com/docs/bugbot, https://cursor.com/docs/agent/hooks, https://cursor.com/docs/agent/browser, https://cursor.com/docs/configuration/worktrees, https://cursor.com/docs/context/rules, https://www.eesel.ai/blog/cursor-projects-review, https://hermes-ai.net/news/cursor-s-projects-goes-multiplayer-so-coding-agents-coordinate-before-conflicts/, https://www.developersdigest.tech/blog/cursor-removes-dollar-costs-usage-page

### 2.2 OpenAI Codex (inside the ChatGPT desktop app, plus CLI, IDE extension and cloud)

1. **App layout:** Codex is a mode of the ChatGPT desktop app. Its sidebar has New chat, Pinned, Projects and Recents.
2. **Where the work runs:** Local or Worktree (Cloud as a separate surface), with a branch picker. The chat header has "Hand off" (moves the chat and its code between your checkout and a worktree), "Create branch here", and "Open" (opens your editor there).
3. **Worktree cleanup:** keeps the 15 most recent worktrees, never deletes one tied to a pinned or running chat, and saves a snapshot first so reopening the chat restores it.
4. **Review pane:** switch the diff between Unstaged, Staged, Commit, Branch and Last turn. Stage or revert everything, one file, or one hunk.
5. **Comments on the diff:** hover a line, click "+", write a note, then ask Codex to address the notes.
6. **/review:** pick "against a base branch" or "uncommitted changes". Findings land as comments in the review pane, optionally in a separate "Detached" chat.
7. **Subagents view:** read-only, with Active and Done lists. Each subagent has its own thread and the main chat gives one combined answer. The IDE extension has a "Stop all" strip.
8. **Approvals:** Auto, Read-only and "Dangerous full access". With Auto-review on, a reviewer agent decides, and each request shows a status: Reviewing, Approved, Denied, Aborted or Timed out.
9. **Scheduled tasks (formerly Automations):** a sidebar inbox with unread markers. Each task runs in your folder or in a fresh worktree, can be triggered by Gmail, Slack or GitHub events, and has "Run now".
10. **GitHub review:** comment `@codex review` and Codex reacts with 👀, then posts a review that flags only the worst issues, tagged P0 or P1. A "## Code Review Rules" section in AGENTS.md steers it.
11. **Cloud tasks:** choose a saved environment and follow up from web, phone or desktop. `codex cloud` applies the results locally. Several attempts per task (`--attempts 1-4`) appear only in third-party guides (unverified).
12. **CLI agent command center (November 2026):** `codex agents` marks unread results. Approval prompts say which thread asked, and `o` jumps to it. Side chats open as resizable tabs or panes.
13. **Appshots:** sends the frontmost Mac window (a screenshot plus its text) to Codex. Local chats resume after a crash.

Sources: https://learn.chatgpt.com/docs/app, https://learn.chatgpt.com/docs/environments/git-worktrees, https://learn.chatgpt.com/docs/code-review?surface=app, https://learn.chatgpt.com/docs/automations?surface=app, https://learn.chatgpt.com/docs/agent-configuration/subagents, https://learn.chatgpt.com/docs/agent-approvals-security, https://learn.chatgpt.com/docs/cloud, https://learn.chatgpt.com/docs/third-party/github, https://learn.chatgpt.com/docs/codex/cli, https://learn.chatgpt.com/docs/changelog, https://9to5mac.com/2026/02/02/openai-launches-codex-app-for-macos-here-are-the-details, https://codex.danielvaughan.com/2026/04/01/codex-cloud-exec-best-of-n-attempts/

### 2.3 Windsurf, now Devin Desktop (Cognition)

1. **Agent Command Center (2026-04-15):** a kanban board of local and cloud sessions grouped by status. "Spaces" bundle sessions, PRs, files and context into one task. A list view has batch-archive checkboxes.
2. **New Agent Window (2026-10-23):** a sidebar grouped by workspace with "+" per folder, and up to 8 sessions side by side. Each session has Files, Changes, Terminal and Preview tabs.
3. **Session tabs:** pills showing state and PR icons, with badges for Fast, Ultra and Fusion sessions.
4. **Native notifications:** one OS notification per session when it finishes or needs input, including ACP agents. Off by default.
5. **Location picker:** Local, Worktree or Cloud when starting a session. Worktree sessions get a Merge button.
6. **Plan mode:** writes a Markdown plan with an Implement button, and implementing returns you to the session that made the plan.
7. **Fusion:** the model picker pairs a frontier "lead" model with a cheaper "sidekick" that does the execution, behind one agent.
8. **ACP agents:** Claude, Codex and OpenCode agents run in the Command Center next to Devin Local.
9. **Previews:** a browser pane where "Send element" turns a clicked element into an @-mention pill in the composer. Console errors can be sent too.
10. **Codemaps:** a panel that builds a flow map of the code. Clicking a node jumps to the code, and maps can be shared or @-mentioned.
11. **Subagents:** nested under the parent with a count of how many are running. Each can be stopped on its own.
12. **Context indicator:** shows a prompt-cache timer, and each response card shows its token count.
13. **Arena Mode (2026-01-30):** two agents side by side with the model names hidden. You vote, and there are personal and global leaderboards. It was built on Cascade, so whether it still exists is unverified.

Patterns from the removed Cascade:
- an in-chat todo list
- a revert arrow when you hover a prompt
- auto-generated Memories
- a dropdown to switch between parallel Cascades

Sources: https://docs.devin.ai/desktop/changelog, https://docs.devin.ai/desktop/agent-command-center.md, https://docs.devin.ai/desktop/previews.md, https://docs.devin.ai/desktop/codemaps.md, https://docs.devin.ai/desktop/fusion.md, https://docs.devin.ai/windsurf/plugins/cascade/memories.md, https://devin.ai/blog/windsurf-wave-13

### 2.4 Devin (Cognition)

1. **Agent Command Center:** a Board or List toggle. The board has three columns: Running, Waiting for review, Done. Each card shows a status line ("Working...", "PR is ready", "Waiting for CI", "Merged"), PR icons, age and its Space. Filter by status, Space, PR or agent.
2. **Sidebar:** sessions grouped Working, Ready, Blocked, Inactive. A "Waiting" badge shows while Devin sleeps, cards preview on hover, and "Mark done" closes a session without stopping it. Filter by origin (Slack, Web, API, Jira, Linear).
3. **Devins that start Devins:** child sessions show as tree lines in the sidebar, with a "Reveal child sessions" switch and an Agents tab that shows each child's status.
4. **Session workspace:** Activity (progress and shell merged, searchable), Terminal, Files, Changes (word-level diffs), a PR tab with Checks and Smart diffs, and a Desktop tab that works like remote desktop.
5. **Artifacts rail (2026-11-13):** a strip beside the chat listing PRs, Changes, previews, Desktop, Agents and Plan.
6. **Side chats:** attached to any point in the session and shown in a panel beside the work log. They can queue behind the main work or interrupt it.
7. **Request cards:** similar asks (credentials, approvals) merge into one card. There is a notification inbox (2026-10-07) and a command palette.
8. **DeepWiki:** a wiki generated from your code, with architecture diagrams. You pick an effort level (Low, Medium, High) and the credit cost is shown before you run it.
9. **Devin Review:**
   - A Guide view groups related edits across files, and moved code shows as a move.
   - Findings are marked by severity: red bug, orange warning, Investigate, Informational.
   - A Bugs view has four groups: Needs your attention, Devin is fixing, Fixed, Invalidated.
   - Buttons: "Add to Chat" and "Auto-fix with Devin".
10. **Slack and Linear:** Slack commands like `!ultra` and `!fast`. Follow-ups carry "Sent from" badges, and Slack actions appear in the work log with a Slack icon.
11. **Model health:** long sessions alert you when the main model degrades or recovers. Knowledge and Playbooks are being folded into Skills.

Sources: https://docs.devin.ai/release-notes/2026, https://docs.devin.ai/work-with-devin/devin-review, https://docs.devin.ai/work-with-devin/deepwiki, https://devin.ai/desktop, https://cognition.com/blog/introducing-devin-desktop

### 2.5 Zed (1.0, April 2026)

1. **Threads Sidebar:** threads grouped by project. Each row shows title, status and which agent runs it, "+" on a project header starts a thread, and Ctrl+Tab cycles recent threads.
2. **Agentic layout:** a setting that puts the Agent Panel and sidebar on the left and the Project and Git panels on the right.
3. **Worktree picker in the title bar:** archiving a thread saves its git state and removes the worktree. Restoring brings it back.
4. **External agents through the ACP Registry:** Claude Agent, Codex, Gemini CLI, OpenCode, Copilot, Cursor and others appear in the "New Thread" menu. Their old threads can be imported.
5. **Terminal Threads (2026-05-20):** claude, codex or amp run as a managed sidebar thread with a terminal icon and a title that updates itself.
6. **Review Changes:** a collapsible bar above the composer summarises edited files and lines. It opens a multi-file review tab with accept or reject per hunk.
7. **Follow the agent:** a crosshair icon makes the editor jump to each file the agent touches.
8. **Profiles:** Write, Ask and Minimal, each forkable with its own tools and default model.
9. **Token meter:** next to the profile picker. Auto-compaction at 90% leaves a "Context Compacted" row, and near the limit a banner offers "Start New Thread" or "New From Summary".
10. **Permission card menu:** Allow once, Deny once, Always for this tool, Always for this pattern.
11. **Subagent cards:** show each subagent's model and open full screen. An ask_user tool shows the agent's choices as options to pick.
12. **Queued messages:** with a "Steer" toggle and "Send Now". Click a sent message to edit and resend it.
13. **Notifications:** desktop and sound alerts when an agent waits or finishes, and the Mac is kept awake while threads run.
14. **Checkpoints removed (2026-11-04):** you undo by rejecting hunks or with git.

Sources: https://zed.dev/docs/ai/agent-panel, https://zed.dev/docs/ai/parallel-agents, https://zed.dev/docs/ai/external-agents, https://zed.dev/docs/ai/agent-profiles, https://zed.dev/docs/ai/tool-permissions, https://zed.dev/blog/terminal-threads, https://zed.dev/releases/stable

### 2.6 Conductor (conductor.build, Mac app, v0.95)

1. **Workspaces:** each is a git worktree and branch running Claude Code, Codex, Cursor Agent or OpenCode. ⌘⇧N creates one from a branch, PR, GitHub issue or Linear issue.
2. **Sidebar (rebuilt in v0.44):** each row shows GitHub state (merged, failing CI, conflicts) and a marker when an agent needs permission. Hovering shows next actions without leaving the chat.
3. **Workspace status (v0.35):** backlog, in progress, in review, done. The row takes the PR title once a PR exists.
4. **Unread:** mark workspaces unread. Clicking the selected workspace jumps to its oldest unread chat.
5. **Several chats per workspace:** several agents can share one branch.
6. **Diff viewer (⌘⇧D):** has a file tree. Inline comments become attachments in the composer, a "Review" action starts an agent review, and files can be edited in the diff.
7. **Checks tab:** the final gate. It shows git status, PR, CI, deployments, review threads and todos, and can block merge while todos are open or checks fail.
8. **PRs:** ⌘⇧P opens one with a drafted description. Automerge and stacked-PR merging are supported.
9. **Run button:** run scripts with ten ports per workspace, and a "nonconcurrent" mode for shared resources.
10. **Archive:** finished workspaces go to History and can be restored with their chat.
11. **Conductor for iOS (October 2026):** chat with agents and merge PRs from the phone, with pinned workspaces synced across devices.

Sources: https://www.conductor.build/, https://www.conductor.build/docs, https://www.conductor.build/docs/reference/checks, https://www.conductor.build/docs/concepts/parallel-agents, https://www.conductor.build/changelog, https://www.conductor.build/changelog/0.35.0-workspace-status, https://www.conductor.build/changelog/0.44.0-new-sidebar-rebuilt-composer-codex-checkpoints, https://www.conductor.build/changelog/0.90.0-conductor-for-ios

### 2.7 Other parallel-agent apps

**Crystal, now Nimbalyst** (Stravu, MIT; Crystal deprecated February 2026)
1. A session kanban with Backlog, Planning, Implementing and Complete columns.
2. Opt-in worktree per session in one click.
3. One Agent Window for every model, with inline interactive questions.
4. A File Edits sidebar with git state and an AI-drafted commit.
5. Red/green diffs inside the rendered document, accepted or rejected per edit.
6. Shared visual editors (Markdown, Mermaid, Excalidraw, CSV) that agents and humans edit together.
7. An iOS dashboard split into "needs you" and "still working", with voice replies and swipe-through diff review.

**Claude Squad** (smtg-ai, terminal app, v1.0.20)
1. Session list on the left. The right pane has Preview, Diff and Terminal tabs.
2. One tmux session and one worktree per agent.
3. Single-key actions: `n` new, `s` commit and push, `c` checkout and pause, `r` resume.
4. An auto-yes mode for unattended runs, and profiles for Claude Code, Codex, Gemini, Aider, OpenCode and Amp.

**Parallel Code** (johannesjo, MIT, v5.1)
1. Tasks grouped "Needs you", "Stopped", "Working", "In pull request". Ctrl+Tab jumps to the next task waiting for you.
2. Three layouts: Focus, Tiles and Board.
3. A diff viewer with inline comments sent to the agent, and a guided "change tour".
4. Task briefs (v5.0): confidence ratings from a separate reviewer model, per-file test coverage, and before/after screenshots.
5. A Finish button that merges or pushes for a PR and removes the worktree.
6. Arena: one prompt to 2 to 4 agents side by side.
7. A `KANBAN.md` board that mixes live tasks and GitHub issues.
8. A phone remote paired by QR code over Wi-Fi or Tailscale, with notifications when a task needs you.

**Emdash** (YC W26; the open-source app is now "Emdash Classic")
1. Add Task (⌘N) from a branch, issue or PR, with a worktree each.
2. Status dots fed by the agents' own hooks.
3. Custom notification sounds. Clicking one focuses the exact task and conversation tab.
4. Editable diffs with per-file +/- counts and draft comments you attach to the chat.
5. PR, CI and merge in the app.
6. A usage page for Claude Code and Codex subscription allowances.
7. Best-of-N side-by-side comparison (official docs now 404, unverified).

**JetBrains Air** (preview March 2026, relaunched 2026-09-22 on desktop, IDEs, web and CLI)
1. Hand tasks to several agents at once: Claude Agent, Codex, Gemini CLI, Junie, Copilot, OpenCode or any ACP agent.
2. An "Add to task context" menu for files, branches, commits, symbols, terminals and photos.
3. Isolation per task: local, worktree, Docker or cloud.
4. Each reply shows file-change chips like `Header.tsx +26−2` and a cost and time line ("0.58 credits · 4s").
5. A bell for task status, with an alert when one task needs you while the others keep running.
6. An automations table showing runs, last run and credits spent.

**Agentty** (Rust terminal app, v0.18)
1. Sessions grouped merge-queue, active and archive, each row showing model, reasoning level and a coloured status.
2. An explicit lifecycle: Draft, InProgress, Review, AgentReview, Question, Queued, Rebasing, Merging, Merged, Done, Canceled.
3. An automatic "focused review" when a session enters Review, and `/apply` has the agent apply valid findings.
4. Green `[ready]` and red `[merge conflict]` labels, a queued squash merge, and automatic rebase of stacked sessions.

**Briefly:**
- **Vibe Kanban** (community-maintained): To Do, In Progress, In Review, Done columns. Diff "+" comments are sent as one message, and the card goes back to In Progress.
- **Sculptor** (Imbue): a Docker container per agent, and Pairing Mode that syncs the agent's branch with your checkout.
- **Paradev** (formerly Superset): a sidebar grouped by where each workspace runs, with +/- stats and "finished in N min".
- **Terragon:** shut down, code released January 2026.

Sources: https://github.com/stravu/crystal, https://github.com/Nimbalyst/nimbalyst, https://nimbalyst.com/, https://github.com/smtg-ai/claude-squad, https://github.com/johannesjo/parallel-code, https://github.com/generalaction/emdash, https://emdash.com/changelog, https://rywalker.com/research/emdash, https://www.jetbrains.com/air/, https://www.jetbrains.com/help/air/quick-start-with-air.html, https://www.techzine.eu/news/devops/139409/jetbrains-air-agentic-development-environment-in-preview, https://github.com/agentty-xyz/agentty, https://agentty.xyz/docs/usage/workflow/, https://github.com/BloopAI/vibe-kanban, https://www.imbue.com/sculptor, https://paradev.com/

### 2.8 Warp

1. **Agent Management Panel:** one row per conversation or cloud run, with Source, Status (Working, Blocked, Canceled, Failed, Success, each with an icon) and Duration. Filters for source, day, creator and status.
2. **Orchestration (2026-05-18):** a parent agent starts children. A pill bar above the agent header shows one pill per child with a live status badge, pills that need attention sort first, and clicking one swaps the pane. Children can be Claude Code or Codex.
3. **Less notification noise:** only the parent sends notifications. Each child's state stays in its pill.
4. **Notifications:** three kinds, Complete, Request and Error. Up to two corner toasts (hover pauses them, click jumps to the agent), plus a bell mailbox with All, Unread and Errors filters.
5. **Tab icons:** show working, blocked, completed or errored, plus an unread badge.
6. **Vertical tabs, "Summary" mode:** each pane's title, folder, branch and agent status, with the PR link and diff stats when expanded.
7. **Code review panel:** file-by-file diffs with line comments, a list of pending comments, and one batch send (Cmd+Enter). The button shows +/- counts.
8. **Full terminal use:** the agent drives psql, vim or a REPL in the live pane. A takeover control lets you type, then hand control back.
9. **Wraps other CLI agents:** Claude Code, Codex, Gemini CLI, OpenCode, Kiro CLI and others get a rich input editor, inline review comments and remote control.
10. **Task-list chip:** sits lower right with "4 of 6 tasks completed" and markers in the conversation as steps finish.
11. **Usage popover:** in the agent input footer. Rules that were used are listed under "References" on each reply.
12. **Local and cloud handoff:** send a local conversation to an Oz cloud agent, or "Continue locally".

Sources: https://docs.warp.dev/changelog/2026/, https://docs.warp.dev/agents/capabilities/agent-notifications/, https://docs.warp.dev/platform/managing-cloud-agents/, https://docs.warp.dev/platform/orchestration/, https://docs.warp.dev/agents/local-agents/interactive-code-review/, https://docs.warp.dev/agents/capabilities/full-terminal-use/, https://docs.warp.dev/agents/cli-agents/overview/, https://docs.warp.dev/agents/capabilities/task-lists/, https://www.warp.dev/newsroom/2026/2/10/warp-launches-oz-the-orchestration-platform-for-cloud-coding-agents

### 2.9 Kiro (AWS)

1. **Specs:** Feature (requirements first or design first), Bugfix (current, expected and unchanged behaviour) and Quick Spec (one pass, no approval steps).
2. **Spec files with Markdown Review:** `requirements.md`, `design.md`, `tasks.md`. A floating Review button lets you comment on passages and send all comments together.
3. **Run all Tasks (2026-05-06):** works out dependencies and runs independent tasks in parallel waves. `tasks.md` shows live in-progress and done states.
4. **Analyze Requirements:** a check before design that returns clarifying questions.
5. **Property-based correctness:** properties come from the requirements. A failure shows the smallest failing input with "fix spec / fix code / fix test" options.
6. **Agent Focus (1.0, 2026-06-25):** a chat-first layout for parallel sessions with status at a glance and inline diffs.
7. **Attention cards (2026-08-11):** when another session needs input, a card beside the current chat shows its question and options as buttons, so you answer without switching.
8. **Permission menu (2026-11-10):** Supervised (accept, reject or discuss each hunk), Accept file changes, and Approve for me (a model approves safe actions, blocks risky ones and asks when unsure).
9. **Agent hooks:** describe a hook in plain language and Kiro writes the JSON. Triggers include file save, prompt submit, tool use, before or after a spec task, and session end.
10. **Steering files:** four inclusion modes (always, fileMatch, manual, auto). Manual ones become slash commands.
11. **Workflows (2026-09-30):** multi-step background runs, one session per step, with a progress strip (pause, resume, stop) above the chat.
12. **Small touches:** live status on editor tabs, fork a chat from any turn, and a chat row whenever Kiro uses or changes a memory.
13. **Kiro Crew (2026-08-04, separate product):** "Ultra Mode" hands tasks to worker chats shown on a Board.

Sources: https://kiro.dev/changelog, https://kiro.dev/changelog/ide/1-0/, https://kiro.dev/docs/specs/, https://kiro.dev/docs/specs/correctness/, https://kiro.dev/docs/steering/

### 2.10 Amp (Amp Frontier Corporation, ampcode.com)

1. **Spaces (2026-11-06):** a chat with one coordinating agent that starts and organises threads. A side panel lists its threads by status, teammates comment and tag Amp, and lasting documents (a ledger) live there.
2. **Puck:** an assistant available anywhere on the site that launches agents, finds and archives threads, and explains usage.
3. **Agents start agents (2026-07-17):** threads start other threads locally, in the cloud or on other machines, and message them. Example: four threads test four screen sizes and report back with screenshots.
4. **Orbs:** a cloud machine per thread with a file browser, terminal and "portals" (open web ports you can mark up and share).
5. **Model picker (2026-11-12):** "Staff Pick" on top. Each row shows who bills it (Claude, ChatGPT or Amp credits). Switching models mid-thread writes "Switched to ... · High" into the transcript, with a note that the next message costs more.
6. **Oracle and Librarian:** "Ask the oracle" sends a reviewing subagent, and "use the librarian" a research one.
7. **Artifacts (2026-11-02):** documents a thread owns, opened beside it. People edit them, and the agent reads the edits before changing them.
8. **Working together:** `@` a teammate to view, drive and chat in a thread, plus a live call per thread with screen share.
9. **Sharing:** workspace or unlisted links only. Public threads were removed because they could leak code.
10. **Usage:** an "Explain Usage" button asks Puck to explain your spend.
11. **CLI rebuild (May 2026):** messages queue by default (↑ picks one, Enter sends it sooner, Esc Esc interrupts), and compaction at 90% replaced handoff.

Sources: https://ampcode.com/chronicle, https://ampcode.com/news/spaces, https://ampcode.com/news/bye-bye-dial, https://ampcode.com/news/meet-puck, https://ampcode.com/news/from-agent-to-agent, https://ampcode.com/news/artifacts, https://ampcode.com/news/end-of-public-threads, https://ampcode.com/news/explain-usage, https://ampcode.com/manual

### 2.11 GitHub Copilot

1. **Copilot app (desktop, generally available):** a "My Work" view gathers sessions, issues, PRs and automations, with saved views. Each session gets a worktree, and you can pin sessions and archive the ones whose PR merged.
2. **Canvases:** shared surfaces (plan, PR, browser, terminal, deployment) that agents update live and you can edit, reorder, approve or redirect.
3. **Agents panel and Agents tab:** opens from any GitHub page and includes sessions others started. Each log shows reasoning, tools, tokens and run time. You steer by typing under the log, and the message applies after the current tool call.
4. **Third-party agents (2026-02-04):** pick Claude or Codex in the input, the header dropdown or the Assignees menu. One issue can go to Claude, Codex and Copilot at once, and each opens its own draft PR.
5. **Cloud agent (formerly coding agent):** works in GitHub Actions, reviews its own changes, then opens a draft PR. "View session" in the PR timeline opens its log.
6. **VS Code Agents window:** a session list across projects with status and change counts. The New Session controls pick environment (This Computer, SSH, Dev Tunnels), isolation (Branch or New Worktree) and harness (Copilot, Claude or Codex).
7. **Edit review:**
   - A pill above the input shows how many files changed and the diff stats.
   - Keep or Undo per change, per file or for everything, plus "Mark as Reviewed" per file.
   - The Changes filter switches between Branch, Uncommitted, Session and Last Turn.
8. **Plan agent:** `/plan` asks clarifying questions, then shows a "Review Plan" card with inline comments and four buttons: "Implement Plan", "Approve Plan Only", "Implement with Autopilot", "Reject".
9. **Code review agent:** an effort picker in Reviewers (Lite, Balanced, Max, Adaptive). It posts an overview with an approval assessment and inline suggestions, and you can hand suggestions to the cloud agent for a fix PR.
10. **Agent Merge:** watches CI and required reviews and merges when your conditions are met.
11. **Copilot projects (preview, 2026-10-28):** managed parallel sessions across several repos, with one place to track progress and decisions.
12. **Assisted approval:** your own written instructions decide which tool requests run without asking. Fusion picks models automatically.

Sources: https://github.blog/changelog/label/copilot/, https://github.blog/changelog/2026-02-04-claude-and-codex-are-now-available-in-public-preview-on-github/, https://github.blog/news-insights/product-news/github-copilot-app-the-agent-native-desktop-experience/, https://github.blog/news-insights/company-news/github-universe-2026-evolving-every-layer-of-the-stack/, https://docs.github.com/en/copilot/concepts/agents/about-third-party-agents, https://docs.github.com/en/copilot/how-tos/use-copilot-agents/manage-agents, https://docs.github.com/en/copilot/concepts/agents/code-review, https://code.visualstudio.com/docs/copilot/agents/agents-window, https://code.visualstudio.com/docs/copilot/agents/planning, https://code.visualstudio.com/docs/copilot/chat/review-code-edits

### 2.12 OpenCode's own UIs (2.3.x)

1. **Desktop app with tabs (redesign July 2026):** each tab is a session from any project, with Cmd+Shift+T to reopen and per-panel Cmd+W.
2. **Inbox and unread:** the Inbox groups unread sessions. Tabs show a failed-run marker, and "Mark as unread" works on tabs, rows and inbox cards.
3. **Worktree picker:** "Run session in" on the new-session screen. Since v2.3.1 the base branch shows as a composer chip ("from dev ▾").
4. **Terminals per session:** keep scrollback across server restarts and stay in sync with the TUI.
5. **Comments:** one compact comment editor for quotes, terminal output and browser annotations, plus an "Add comment" toolbar on code selected in a diff (v2.3.1).
6. **Background subagents (v2.3.0):** run as child sessions and report back when idle. Their permission prompts appear when you view the child.
7. **Collapsed activity:** tool calls fold into one activity row, with a Verbosity setting. Alt+Enter queues a follow-up; Enter steers the running session.
8. **Agents:** Build and Plan (primary), General and Explore (subagents). Custom agents are Markdown files with a model, ordered permission rules and a hex `color`.
9. **Undo and redo:** `/undo` restores files and puts the prompt back in the composer, and "Revert" on any message rolls back to it. Snapshots live in a separate git store.
10. **Phone pairing:** `opencode pair` prints a QR code and a link that expires in 5 minutes. The iPhone and Android apps start, steer and approve sessions.
11. **Go plan limits:** when you hit one, a composer tray shows the reset time and an account link.

Session sharing (opencode.ai/s links) was discontinued on 2026-10-15, so export and import JSON is the fallback.

Sources: https://opencode.ai/changelog.md, https://opencode.ai/changelog/v1.19.1.md, https://opencode.ai/docs/agents, https://opencode.ai/docs/tui, https://opencode.ai/docs/snapshots/, https://opencode.ai/docs/permissions/, https://opencode.ai/docs/console/go/, https://opencode.ai/download, https://www.explainx.ai/blog/opencode-desktop-tabs-sessions-worktrees-july-2026

### 2.13 Cline, Roo Code, Kilo Code

**Cline** (VS Code 4.1, CLI 2.0, Desktop, Kanban)
1. **Plan and Act:** a toggle by the input, with optional different models for each.
2. **Checkpoints:** a "Checkpoint" marker after each tool use, joined by a dotted line to "Compare" and "Restore". Restore offers files, task, or both.
3. **Task header:** a context bar with ↑ input and ↓ output tokens and cost. Cost is hidden for flat-rate subscription tasks (4.1.16).
4. **Auto-approve menu:** granular toggles, from "Read project files" up to "Execute all commands", plus notifications.
5. **Handoff and planning commands:** `/newtask` hands off to a fresh task with a summary, `/deep-planning` writes `implementation_plan.md` and then starts a tracked task, and `/smol` compacts.
6. **Kanban (research preview, March 2026):** `npx kanban` opens a browser board with a worktree and terminal per card. The card detail has the diff with line comments and Commit / Open PR, and cards can depend on each other. It drives Cline, Claude Code, Codex or OpenCode.
7. **Cline Desktop (September 2026):** parallel sessions, a Schedule view, and import of Claude Code and Codex conversations.
8. **CLI status area:** shows model, context, cost, branch, diff stats, Plan/Act and auto-approve.

Focus Chain (the "3/8" todo in the header) is deprecated.

**Roo Code** (shut down 2026-05-15; patterns as last shipped)
1. **Mode dropdown:** Code, Ask, Architect, Debug and Orchestrator, each with a sticky model.
2. **Orchestrator (Boomerang) subtasks:** you approve each subtask at start and finish, and only the child's summary returns. History shows an indented subtask tree, and the parent shows the cost of the whole tree.
3. **Custom modes form:** role, when to use, allowed tools, and instructions.
4. **Context bar:** shows used, reserved and free space, with "Condense Context". The condense row shows tokens before and after and the cost of the summary call.
5. **Todo panel:** empty, yellow and green circles, editable items, and approve or reject of updates.
6. **Grouped file edits:** consecutive edits collapse into one block with "Save All" / "Deny All".

**Kilo Code** (extension rebuilt April 2026; Kilo CLI is a fork of OpenCode, the closest analogue to Ensemble)
1. **Agent Manager (Cmd+Shift+M):** a worktree list with colour stripes, session tabs per worktree, a terminal per session, and a strip of child agents (running, completed, cancelled, failed).
2. **Diff panel (Cmd+D):** unified or split, with scope Branch / Staged / Unstaged / Session. Inline comments go to the chat or the PR, and "Apply to local" handles conflicts.
3. **PR panel:** merge, squash or rebase, auto-merge, and "Fix with Kilo" for conflicts. State badges are colour coded: grey draft, green open, purple merged, red failing, pulsing yellow pending.
4. **Versions:** up to 4 parallel versions of one prompt, each with its own model and worktree, for side-by-side comparison.
5. **Agents replace modes:** each agent has its own model, and a read-only Subagents panel shows child transcripts in tabs.
6. **Model picker:** shows price per million tokens, context size and favourites. Cost per request appears in the chat, and a usage page breaks spend down by day, model and project, with spend alerts.
7. **Code reviews:** Strict / Balanced / Lenient, with a `REVIEW.md` policy file and severity tags.
8. **Share links:** last from 1 hour to never, can follow new messages, and recipients can fork them.

Sources: https://docs.cline.bot/core-workflows/checkpoints.md, https://docs.cline.bot/core-workflows/plan-and-act.md, https://docs.cline.bot/features/auto-approve.md, https://docs.cline.bot/usage/kanban.md, https://docs.cline.bot/usage/cline-desktop.md, https://docs.cline.bot/usage/tui.md, https://docs.cline.bot/resources/deprecations.md, https://raw.githubusercontent.com/cline/cline/main/CHANGELOG.md, https://github.com/RooCodeInc/Roo-Code, https://roocodeinc.github.io/Roo-Code/features/boomerang-tasks, https://roocodeinc.github.io/Roo-Code/features/checkpoints, https://roocodeinc.github.io/Roo-Code/features/intelligent-context-condensing, https://roocodeinc.github.io/Roo-Code/update-notes/v3.48.0, https://kilo.ai/docs/code-with-ai/platforms/vscode/whats-new, https://kilo.ai/docs/automate/agent-manager, https://kilo.ai/docs/automate/code-reviews/overview, https://kilo.ai/docs/collaborate/sessions-sharing, https://blog.kilo.ai/p/agent-manager-run-multiple-agents

### 2.14 Google Antigravity (2.0 desktop app, May 2026)

1. **Overview panel (top right of a conversation):** a Review row ("+24 -0"), then Subagents, Background Tasks (hover to Cancel), Goals and Artifacts. Running items always stay visible, and each section shows four items plus "See all".
2. **Side panel:** artifacts, diffs, terminals, subagent conversations and web pages open beside the chat, so you inspect without losing your place.
3. **Comments on plans:** highlight a passage and click Add Comment. Comments collect as a "2 Comments" chip above the composer, and "Proceed" on the plan card sends them with the approval.
4. **Walkthrough artifact:** "Changes Made" and "Validation Results" with screenshots or recordings ("Verify with Artifacts, not logs").
5. **/swarm pane:**
   - **Board:** a live feed of posts showing sender, recipients, post number and time, with Search, member filters and a Follow toggle.
   - **Members:** the coordinator, then workers grouped Active, Standing by and Retired, each with status, model and latest post.
   - **Graph:** @mention arrows weighted by post count, with replay controls and a Live button.
6. **Two steering targets in /swarm:** talking to the coordinator posts instructions to the board. Typing in one worker's own conversation goes only to that worker, not the board.
7. **/teamwork:** a scoping interview produces a prompt artifact you approve. Then named roles run (Sentinel, Workers, Critic, Challenger, Auditor), and Alt+J jumps to a subagent waiting for approval.
8. **Inbox (2025 IDE Agent Manager):** one place to approve terminal commands, browser actions and plans from every agent. Whether it survives in 2.0 is unverified, and the IDE Agent Manager is being removed.

Sources: https://antigravity.google/docs/swarm, https://antigravity.google/docs/teamwork, https://antigravity.google/docs/side-panel, https://antigravity.google/docs/implementation-plan, https://antigravity.google/docs/walkthrough, https://antigravity.google/docs/artifacts, https://antigravity.google/blog/introducing-google-antigravity-2, https://techcrunch.com/2026/05/19/google-launches-antigravity-2-0-with-an-updated-desktop-app-and-cli-tool/

### 2.15 Claude Code (the reference Ensemble follows)

1. **Agent View (`claude agents`):**
   - Groups, top to bottom: Pinned, Ready for review (open PR or failing checks), Needs input, Working, Completed.
   - State icons: animated (working), yellow (needs input), dimmed (idle), green (done), red (failed), grey (stopped). The shape also tells you whether the process is still alive.
   - Answering: Space opens a peek panel with just the question or result, and number keys answer a choice.
2. **Agent teams:** an agent panel under the prompt with one row per teammate. When more than three are idle they collapse into one "N idle agents" row. Enter opens a teammate to message it.
3. **Split-pane display:** each teammate in its own live tmux or iTerm2 pane.
4. **Shared task list (Ctrl+T):** pending, in progress, completed and blocked (until dependencies finish). Teammates claim tasks themselves, with file locking.
5. **Approvals bubble up:** teammates' permission prompts appear in the lead session naming the agent asking. A message from another agent can never count as your approval.
6. **Quality gates:** TeammateIdle and TaskCompleted hooks can refuse (exit code 2) to keep a teammate working or block "done" until a check passes.
7. **Desktop app (redesign 2026-04-14):**
   - Sidebar by project with status filters, and sessions auto-archive when their PR merges.
   - Drag-and-drop panes (terminal, preview, diff, chat).
   - Side chats (Cmd+;) that read the main thread but add nothing to it.
   - Diff "+" comments submitted together with Cmd+Enter.
   - A Background tasks pane with stop controls.
   - Normal, Verbose and Summary view modes.
   - A usage ring and a Context % card.
   - An OS notification when a session you are not viewing finishes.
   - Cross-session messages arrive as a card linking back to the sender.
8. **Subagents:** shown as `name(task)` rows tinted with the agent's colour. Nested agents form a tree with a "(+N)" count.

Sources: https://code.claude.com/docs/en/agent-view, https://code.claude.com/docs/en/agent-teams, https://code.claude.com/docs/en/desktop, https://code.claude.com/docs/en/sub-agents, https://claude.com/resources/articles/claude-code-desktop-redesign

### 2.16 Multi-agent coordination UIs beyond coding apps

**Framework UIs**
- **Magentic-UI (Microsoft):**
  - Plan and progress on the left, the live browser on the right.
  - Before anything runs, you can add, delete, edit or regenerate plan steps.
  - Action guards show Approve / Reject before irreversible steps, and you set how often it asks.
  - You can take over the browser, then hand it back.
  - Its paper's lesson: a linear plan cannot express parallel work, so plan multi-agent work as a graph.
- **AutoGen Studio:** a Team Builder plus a Playground that streams messages next to a graph of who spoke to whom, with pause and stop.
- **LangGraph / LangSmith Studio:** a Graph mode with the path taken and the state between steps. You can edit a step's state and fork from that checkpoint ("time travel").
- **OpenAI Agents SDK traces and CrewAI traces:**
  - The OpenAI traces nest spans by type (agent, generation, tool, guardrail, handoff).
  - CrewAI shows an execution timeline of task start and end that makes parallel work visible, plus token and cost estimates.

**Debate and comparison**
- **LMArena (arena.ai):** two anonymous panes, Model A and Model B, with four votes (A better, B better, Tie, Both bad). Names are revealed after the vote.
- **Karpathy's llm-council:** each model's answer in its own tab, then each model ranks the others anonymised as "Response A, B...", then a Chairman model writes the final answer.
- **Perplexity Model Council (2026-02-05):** three models in parallel, then a synthesis that marks where they agree and where they differ. Per-model tabs are third-party reports only (unverified).
- **Coding tools:**
  - Cursor `/best-of-n` recommends a winner.
  - Kilo Versions and Parallel Code Arena run 2 to 4 attempts side by side.
  - Copilot lets you assign one issue to three agents.
  - Windsurf Arena hid the model names and kept leaderboards.

**Boards and lanes**
- **Factory Missions (2026-02-26):**
  - A Mission Control page with a feature list, progress log and validation output.
  - Work is split into milestones, each ending in validation.
  - Token counts include subagents, and a mission uses about 12x the tokens of a normal session.
- **Linear agent sessions:**
  - Visible states: pending, active, awaitingInput, error, complete, stale.
  - A typed activity stream: thought, action, elicitation, response, error.
  - Temporary "Searching" rows become "Searched" when done.
  - A plan checklist, and the agent must acknowledge within 10 seconds or it is marked unresponsive.
- **Slack:** an Agents & tools tab lists agent sessions as Active, Needs attention, Inactive, Done or Archived. Agent notifications carry Approve and Decline buttons.

Sources: https://www.microsoft.com/en-us/research/blog/magentic-ui-an-experimental-human-centered-web-agent/, https://arxiv.org/abs/2507.22358, https://microsoft.github.io/autogen/stable/user-guide/autogenstudio-user-guide/, https://docs.langchain.com/langsmith/studio, https://openai.github.io/openai-agents-python/tracing/, https://docs.crewai.com/en/enterprise/features/traces, https://arena.ai/blog/hello-from-lmarena, https://github.com/karpathy/llm-council, https://www.perplexity.ai/hub/blog/introducing-model-council, https://factory.com/news/missions, https://linear.app/developers/agent-interaction, https://linear.app/changelog/2026-06-11-coding-sessions, https://slack.com/help/articles/33076000248851

### 2.17 General agent-app patterns and design write-ups

- **Smashing Magazine (2026-02-11), six patterns:**
  - Intent Preview: a numbered plan with Proceed, Edit and "do it myself".
  - Autonomy Dial: per task, from suggest-only to act-then-notify.
  - Explainable Rationale: a card with View and Undo.
  - Confidence Signal: a score or a check/question mark.
  - Action Audit & Undo: a timestamped log with undo windows.
  - Escalation Pathway: the agent asks, offers options or flags a human.
- **Linear Agent Interaction Guidelines:**
  - always disclose that it is an agent
  - give instant feedback
  - make internal state visible (thinking, waiting, executing, finished)
  - stop when asked
  - a human stays accountable
- **Vercel AI Elements:**
  - a Context ring with a token breakdown (input, output, reasoning, cache) and cost
  - a Queue with collapsible counted sections, where completed items get strikethrough and lower opacity
  - Plan, Confirmation and Task components
- **Approval fatigue:** match autonomy to risk, and ask only before sending, paying, deleting or publishing. Spinners alone fail for long agent runs: show a progress ledger.

Sources: https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/, https://linear.app/developers/aig, https://elements.ai-sdk.dev/components/context, https://elements.ai-sdk.dev/components/queue, https://pub.towardsai.net/designing-for-ai-agents-8-ux-patterns-that-build-trust-in-2026-713a0c926933

## 3. Patterns worth borrowing for Ensemble

Status key:
- **Has:** in the code today.
- **Plans:** named in PLAN.md (milestone and work package given).
- **Missing:** not in the code or the plan.

Difficulty is S (a day or less), M (a few days) or L (a week or more, or engine work). Ideas that make several agents working together clearer come first. ★ marks the top 15.

### A. Seeing the room at a glance

**1. ★ Agent pills sorted by who needs you, with state icons that differ in shape as well as colour**
- **Where:** the room header's agent chips, and the Rooms rows in the sidebar.
- **Why:** with 3 or 4 agents, the first question is "who is stuck". Sort the pills: needs you, failed, working, idle, done. Each icon differs in both shape and colour (animated working, yellow hand, red cross, green check, grey stop, capped). One live line per pill gives the current step and elapsed time.
- **From:** Warp child pills, Claude Agent View icons, Linear session states.
- **Difficulty:** S. **Status:** Has in part. Chips exist and the side panel shows a spinner, permission hand or Capped tag. Sorting, shape coding and the live line are Missing.

**2. ★ Attention cards: answer any agent's question or permission prompt from wherever you are**
- **Where:** a strip above the room board, and a floating card in solo sessions when another session needs you.
- **Why:** the card shows the asking agent (colour and name), the question and its options as buttons, so you never switch away from what you are reading. It removes the main cost of running several agents: hunting for the one that is blocked.
- **From:** Kiro attention cards, Claude Agent View peek, Antigravity Inbox, Devin merged request cards.
- **Difficulty:** M. **Status:** Has in part (room decision cards and permission cards in the room view). Cross-session cards are Missing. The Hub inline reply Plans M3 WP-E.

**3. ★ Lanes view: every agent's live work side by side**
- **Where:** a toggle in the room header, Board / Lanes.
- **Why:** each column is one agent with its colour header, model, current step, collapsed activity rows and spend. More than three idle agents fold into "N idle". You watch real parallel work instead of reading it after the fact on the board.
- **From:** Claude agent teams split panes, Cursor tiled layout, Devin's 8 sessions side by side.
- **Difficulty:** M. **Status:** Plans M2 WP-D ("per-agent lanes"). Not built yet: the room currently shows one agent's session at a time in the side panel.

**4. Board, Members and Graph tabs, with replay**
- **Where:** the room's main column.
- **Why:** these are three views of the conversation between agents:
  - **Board:** the thread Ensemble already has, plus a Follow toggle and search.
  - **Members:** roster with status, model and latest message.
  - **Graph:** who talked to whom, arrows weighted by message count.

  A replay scrubber steps through the board after the run. Together they let you understand and explain a multi-agent run.
- **From:** Antigravity /swarm (Board, Members, Graph, replay), AutoGen Studio's transition graph.
- **Difficulty:** M (graph and replay). **Status:** Board Has. Members Has in part (side panel agents). Graph and replay Missing.

**5. Typed board messages with filter chips, and live rows that settle**
- **Where:** the board thread.
- **Why:** BoardMessage already has kinds (plan, assignment, update, question, review, argument, verdict, notice). Show an icon per kind and add filter chips (Questions, Reviews, Decisions) so a long run can be scanned. A "Byron is reviewing Ada's parser..." row turns into "Byron reviewed: 2 changes".
- **From:** Linear typed activities and settling rows, Claude Code subagent rows.
- **Difficulty:** S. **Status:** kinds Has. Icons, filters and settling rows Missing.

**6. ★ Team pieces as a board that moves through review**
- **Where:** the room side panel's Team section, expandable to a full Board tab.
- **Why:** lanes Assigned, Working, In review (reviewer named and coloured), Changes requested (round n of 2), Approved, Merged. Each card shows owner, worktree branch, +/- lines and the latest review note. Peer review only builds trust if you can see where each piece stands.
- **From:** Vibe Kanban, Conductor workspace status, Agentty lifecycle, Cursor Projects task board, Devin Command Center.
- **Difficulty:** M. **Status:** Has in part (side panel lists pieces with review state). The lane board is Missing.

**7. Piece dependencies, blocked state, parallel waves**
- **Where:** the lead's plan (an `AFTER @name` or `needs:` keyword) and the piece cards above.
- **Why:** a blocked piece shows what it waits on, and the engine starts independent pieces in waves. This stops agents building on each other's half-done work.
- **From:** Claude Code shared task list (blocked until dependencies finish), Kiro "Run all Tasks" waves, Cline Kanban dependencies.
- **Difficulty:** M (RoomEngine and ROOMS.md change). **Status:** Missing.

**8. A readiness check before merge**
- **Where:** each Team piece card, and the room's merge step.
- **Why:** one view per piece: reviewed by whom, tests or build run (pass or fail), conflicts with base, CI. Merge stays disabled until it is green, or until you choose "Merge anyway". It makes the lead's merge safe and visible.
- **From:** Conductor Checks tab, Agentty `[ready]` / `[merge conflict]` labels, Copilot Agent Merge, Kilo PR badges.
- **Difficulty:** M. **Status:** Plans in part (M2 WP-C merge step; M1.8 WP-P CI checks). The readiness view is Missing.

**9. ★ Structured review cards between agents**
- **Where:** the board, when a reviewer replies.
- **Why:** instead of plain `CHANGES:` text, show findings as rows with a severity (blocker, should fix, nit), file and line links, and "Send to author" / "Dismiss" buttons for you. Approved reviews collapse to one line. You can see whether peer review is catching real problems.
- **From:** Codex P0/P1 review, Devin Review severity icons and Bugs groups, Agentty `/apply`.
- **Difficulty:** M. **Status:** the review step Has (RoomEngine Team). Structured findings are Missing.

**10. "Done means" gates per room**
- **Where:** the new room sheet (Team and Round table), shown as a checklist on each piece.
- **Why:** you pick what "done" requires: peer approval (default), tests pass, build passes, a named verifier agent. The engine refuses `DONE` until the gates pass, which stops agents declaring victory early.
- **From:** Claude Code TaskCompleted hook, Factory milestone validation, Antigravity Critic and Auditor roles.
- **Difficulty:** M. **Status:** peer approval Has. Other gates Missing.

### B. Debate and comparison

**11. ★ A Compete mode: one task, several agents, pick the winner**
- **Where:** a fifth room mode in the new room sheet, beside Solo, Team, Debate and Round table.
- **Why:** each agent builds the same task in its own worktree. A compare view shows the diffs side by side with size, tests passed, cost and time, and a judge agent recommends one with reasons. You click "Use this one" to merge it, and the other worktrees are archived. Every major tool now offers best-of-N, but none lets different vendors' agents critique each other's attempts before you choose. Ensemble can do that.
- **From:** Cursor `/best-of-n` with recommendation, Kilo Versions, Parallel Code Arena, Copilot's one issue to three agents, Emdash.
- **Difficulty:** L. **Status:** Missing.

**12. ★ Blind debate**
- **Where:** a toggle in the new room sheet (Debate) and a "Reveal" button on the verdict card.
- **Why:** in rounds 2 and later, agents see each other's arguments as "Response A / B / C". The judge also judges blind. Names and models are revealed after the verdict. This reduces brand bias and agents deferring to each other, so the debate tests ideas rather than models.
- **From:** llm-council anonymised ranking, LMArena reveal-after-vote, Windsurf Arena.
- **Difficulty:** S to M (prompt formatting in RoomEngine+Debate and a UI toggle). **Status:** Missing.

**13. ★ A verdict card that maps agreement**
- **Where:** the verdict card.
- **Why:** sections "Everyone agreed", "Disagreed" (each side's position in the agent's colour), "Raised by only one agent", and "Strongest dissent". Buttons: Build it, Debate again, Pick another position, Ask a follow-up. You see how solid the decision is, not only what it is.
- **From:** Perplexity Model Council, llm-council Chairman.
- **Difficulty:** M. **Status:** Has in part (verdict card with Build it and Debate again; the prompt asks for the strongest dissent). The agreement map is Missing.

**14. Your votes and a per-project model scoreboard**
- **Where:** a thumbs control on verdicts, review findings and Compete results, with a small Scoreboard section in the room side panel and Settings.
- **Why:** Ensemble learns which models win which kinds of task for you, and the new room sheet suggests a team from it. It turns many runs into a reason to pick a lineup.
- **From:** Windsurf Arena personal leaderboard, LMArena votes.
- **Difficulty:** M. **Status:** Missing.

**15. Role presets and room templates**
- **Where:** the new room sheet: a "Start from" menu (Build and review, Debate a decision, Red team a design, Council) and role chips per agent (Builder, Reviewer, Critic, Devil's advocate, Verifier, Researcher).
- **Why:** good role prompts are hard to write, and named roles make the board easier to read ("Critic: Grok").
- **From:** Antigravity /teamwork roles (Critic, Challenger, Auditor), Amp's Oracle and Librarian, Roo custom modes.
- **Difficulty:** S. **Status:** Missing (the sheet has a free-text role field).

### C. Steering several agents

**16. ★ A visible message target: the room, one agent, or one agent privately**
- **Where:** a target chip at the left of the room composer: "To room" / "To Ada" / "Only Ada (private)". `@name` sets it.
- **Why:** you always know who will read what you type. Private messages go to one agent's session and are not put on the board for others. Agents' messages must also never count as your approval: label them and keep approvals human-only.
- **From:** Antigravity /swarm's coordinator versus a worker's own conversation, Claude Code's rule that teammate messages are never your approval.
- **Difficulty:** S. **Status:** Plans in part (`@name` routing in M2 WP-C/WP-D and ROOMS.md). The target chip and private mode are Missing.

**17. ★ Highlight to comment on plans, verdicts and diffs, sent as one batch**
- **Where:** the plan decision card, the verdict card, the diff view, and agents' long messages.
- **Why:** select text, click Comment, and the comments pile up as a "3 comments" chip above the composer. Approve / Proceed sends them with your decision. Precise feedback beats a retyped paragraph, and batching stops each comment from interrupting the agents.
- **From:** Antigravity plan comments, Kiro Markdown Review, Codex and Conductor diff comments, Warp batch send, Copilot Review Plan.
- **Difficulty:** M. **Status:** Missing.

**18. Side chat with one agent**
- **Where:** "Side chat" on an agent's pill or lane, which opens a sheet or right pane.
- **Why:** ask "why did you choose X" without derailing that agent's work, and without putting it on the board. The side chat reads the agent's context but adds nothing back unless you click "Send to room".
- **From:** Cursor `/side` and `/btw`, Claude desktop side chats (Cmd+;), Devin side chats, Kiro `/tangent`.
- **Difficulty:** M (use engine fork where supported). **Status:** Missing. Fork exists (EngineCapabilities) and could back it.

**19. Queue or steer while agents work**
- **Where:** the composer: Enter queues, Option+Enter steers now, or the reverse. Queued messages show as editable chips above the composer, with "Send now".
- **Why:** with long multi-agent runs you often want to add a thought without interrupting. OpenCode already supports `delivery: steer|queue` on prompt.
- **From:** OpenCode Alt+Enter, Zed's Steer toggle and Send Now, Amp's queue by default.
- **Difficulty:** S. **Status:** Missing in the UI (the engine supports it).

**20. Where it runs: Local or Worktree, with a hand-off button**
- **Where:** the new session sheet (a location picker plus a base-branch chip like "from main ▾") and a "Hand off" button in the session header.
- **Why:** solo sessions get the same isolation room agents get, and you can move a session's work into or out of your main checkout. Archiving a session keeps its worktree as a snapshot.
- **From:** Codex Local/Worktree and Hand off with snapshot cleanup, Zed worktree picker, Devin Desktop, OpenCode "Run session in".
- **Difficulty:** M. **Status:** Plans for rooms (M2 WP-C, per-agent worktrees; GitOps.createWorktree Has). Solo sessions and hand-off are Missing.

### D. Reviewing what the agents did

**21. ★ Diff scope switcher: Last turn, This agent, Whole room, Uncommitted, Branch**
- **Where:** the Outputs section of the context panel and the room side panel, opening a full diff pane.
- **Why:** when four agents edit, "what changed" needs a scope. Per-agent and per-room scopes are unique to Ensemble and answer "what did Gemini actually do".
- **From:** Codex review pane scopes, Copilot Changes filter, Kilo diff scopes.
- **Difficulty:** M. **Status:** Plans in part (DESIGN.md Outputs: "files changed this session, click to open diff"; DiffView Has). Scopes are Missing.

**22. Keep or undo per hunk, and Mark as reviewed per file**
- **Where:** the diff pane.
- **Why:** a review checklist across many files and agents, with partial acceptance instead of all or nothing.
- **From:** Copilot Keep/Undo and Mark as Reviewed, Zed Review Changes, Kiro Supervised hunks.
- **Difficulty:** M. **Status:** Missing.

**23. An artifacts rail per room**
- **Where:** a tab in the room side panel.
- **Why:** plan, assignments, verdict, review summaries, walkthrough, screenshots and diffs as named documents with versions, instead of being lost in the scrollback. You can comment on them (idea 17) and reopen them in the next room.
- **From:** Devin artifacts rail, Antigravity artifacts, Amp Artifacts, Copilot canvases.
- **Difficulty:** M. **Status:** Missing.

**24. ★ A walkthrough card when a run ends**
- **Where:** the end of the room board.
- **Why:** the lead's summary becomes a card in five parts:
  - what was built, piece by piece, each line with the owner's colour
  - who reviewed what
  - validation (tests run, results)
  - cost per agent and the total
  - what is left

  Buttons: Open diff, Create PR, Start follow-up room. It is the one thing you read after a long run.
- **From:** Antigravity walkthrough, Parallel Code task briefs (confidence, coverage, screenshots), Factory validation output.
- **Difficulty:** S to M. **Status:** Plans in part (ROOMS.md step 6, "Finish": the lead posts a short summary). The structured card is Missing.

### E. Attention, notifications and overview

**25. ★ Hub board view, a "Ready for review" bucket, and keyboard answers**
- **Where:** the Session Hub.
- **Why:**
  - **View toggle:** List or Board.
  - **New bucket:** "Ready for review" (a finished run with an open PR, or approved pieces waiting to merge) sits between Needs you and Running.
  - **Peek and keys:** Space shows the question, number keys answer a choice.
  - **Status lines:** each card says "Waiting for CI" or "PR ready" in plain words.

  This makes the Hub the place you run your day from.
- **From:** Claude Agent View (Ready for review, peek, number keys), Devin Command Center board, Parallel Code groups.
- **Difficulty:** M. **Status:** Plans (M3 WP-E: buckets, quick replies, inline reply; HubBucketing Has, iOS HubView Has). The board view, Ready for review bucket and keyboard answers are Missing.

**26. ★ Notifications: few, typed, and they open the exact agent**
- **Where:** macOS notifications, the Dock badge, and a bell inbox in the sidebar.
- **Why:**
  - **Types:** Needs you, Finished, Failed, Cap reached.
  - **One sender per room:** notifications come from the room, not from each agent.
  - **Click target:** opens the exact agent and card.
  - **Dock badge:** shows the Needs you count.
  - **Inbox filters:** Unread and Errors.
  - **Quiet when watching:** nothing fires for a session you are looking at.

  Without this, parallel agents mean polling.
- **From:** Warp (only the parent notifies; toasts and bell mailbox), Zed, Emdash (focus the exact tab), Devin Desktop per-session notifications, Claude desktop.
- **Difficulty:** S to M. **Status:** Missing (no UserNotifications code yet; not in PLAN.md).

**27. Unread state and "next waiting"**
- **Where:** the sidebar and Hub rows (a bold title and dot), a "Mark as unread" menu item, and a shortcut (Ctrl+Tab or Cmd+J) that jumps to the next session or agent that needs you.
- **Why:** this is how people actually work through many parallel agents.
- **From:** Parallel Code Ctrl+Tab, Conductor unread, OpenCode Inbox and Mark as unread, Codex unread markers.
- **Difficulty:** S. **Status:** Missing.

**28. A command palette (Cmd+K) with transcript search**
- **Where:** a global overlay.
- **Why:** jump to any session, room or agent, run any action (new room, pause room, switch mode, open diff, toggle Keep awake), and search across all transcripts and boards. It scales the app past dozens of sessions.
- **From:** Cursor Cmd+K transcript search, Devin command palette, Warp.
- **Difficulty:** M. **Status:** Missing. The M5 "keyboard shortcuts" item and the `/` command menu (SlashCommands Has, M1.8) cover part of it.

**29. PR and CI state on sidebar and Hub rows**
- **Where:** a small PR glyph on the row, coloured by state (draft, open, checks failing, pending, merged). Sessions auto-archive when their PR merges.
- **Why:** you see "done and merged" versus "needs a fix" without opening anything.
- **From:** Conductor sidebar, Claude Agent View PR label, Kilo PR badges, Copilot app auto-archive.
- **Difficulty:** S once WP-P lands. **Status:** Plans (M1.8 WP-P: PR status with CI checks in the context panel). The row glyphs and auto-archive are Missing.

### F. Cost

**30. ★ Cost everywhere it matters, including before you start**
- **Where:**
  - a footer on each reply ("$0.04 · 12s", or "3% of weekly limit" on subscriptions)
  - a context ring per agent pill
  - the room total in the header, including subagents
  - a cost estimate in the new room sheet ("3 agents × 3 rounds ≈ $0.80, about 6% of your Claude weekly limit")
  - a transcript note when a model switch changes the price
- **Why:** multi-agent runs burn several times the tokens (Factory measured about 12x for missions). People only trust a room if they can see and cap what it costs. Show limit percentages instead of dollars for subscription engines, as Cline and Cursor now do.
- **From:** JetBrains Air credits line, Amp model-switch note, Roo tree cost, Vercel Context ring, Devin DeepWiki cost before running, Kilo spend alerts.
- **Difficulty:** M. **Status:**
  - Has in part: per-agent spend against caps in the room side panel.
  - Plans: usage popover in M3 WP-G, caps in M2 WP-C.
  - Missing: the estimate and the per-reply footer.

### Top 15, in suggested build order

1. Agent pills sorted by who needs you (1)
2. Attention cards (2)
3. Notifications (26)
4. Visible message target (16)
5. Team pieces board (6)
6. Structured review cards (9)
7. Walkthrough card (24)
8. Highlight to comment (17)
9. Diff scope switcher (21)
10. Hub board view and Ready for review (25)
11. Lanes view (3)
12. Blind debate (12)
13. Verdict agreement map (13)
14. Cost everywhere (30)
15. Compete mode (11)

Board, Members and Graph tabs (4) is the 16th, and the most distinctive once the basics are in.

## 4. Surprises and what they mean for Ensemble

1. **Multi-agent hosting is now table stakes; agents talking to each other is not.** Devin Desktop, Zed, JetBrains Air, Warp, Conductor, Kilo, the Copilot app and Antigravity all run several agents, many from other vendors over ACP. Only Antigravity /swarm and Cursor's multiplayer Projects let agents message each other, and both use one vendor's models in a coordinator-and-workers setup. No product found runs a debate with a judge across Claude, Gemini, GPT and Grok, or peer review between different vendors' agents. Ensemble should lead with that in the UI: rooms, the board, blind debate and the verdict card.
2. **Ensemble's iPhone remote design is now standard.** Parallel Code pairs a phone by QR code over Wi-Fi or Tailscale, almost exactly Ensemble's design. OpenCode added `opencode pair` with QR. Cursor's iOS remote even has "Keep this computer awake". The remote is still worth having but will not set Ensemble apart. The room views on the phone might.
3. **The ground under Ensemble moved.**
   - OpenCode dropped session sharing in October 2026, so Ensemble should not plan on OpenCode share links.
   - Kilo Code's CLI is a fork of OpenCode, and its Agent Manager (worktree list, diff scopes, PR panel, Versions) is the closest existing reference for an OpenCode-based multi-agent UI.
   - Roo Code and Windsurf's Cascade both disappeared within months: avoid depending on any one tool's extension surface.
4. **Checkpoints are going away in favour of git.** Zed removed agent checkpoints (2026-11-04) and Cline deprecated Focus Chain, while worktrees, snapshots and per-hunk undo took over. Ensemble's Rewind should lean on the engine's git snapshots and worktrees rather than its own checkpoint store.
5. **AI-judged approvals are everywhere.** Cursor auto-review, the Codex Auto-review agent, Kiro "Approve for me" and Copilot assisted approval all let a model approve tool calls. Ensemble's Auto mode allowlist is the safer default. If a room agent is ever allowed to triage others' prompts, keep Claude Code's rule that an agent's message never counts as the user's approval, and log every such decision.
6. **Subscription-first cost display.** Cline hides dollar cost on flat-rate plans, Cursor reportedly removed dollars for self-serve, Emdash shows subscription allowances, and Amp labels who bills each model. Ensemble already plans "remaining limits"; the usage UI should show percent of limit first and dollars only for API keys.
7. **Quieter notifications are a deliberate design choice.** Warp lets only the parent agent notify, Claude Code collapses idle teammates into one row, and Devin merges similar requests into one card. With several agents per room, Ensemble needs the same discipline from day one, or rooms will feel noisy.
8. **Debate-style UIs come from outside coding.** The best patterns (anonymised critiques, reveal after the verdict, agreement maps) come from LMArena, llm-council and Perplexity Model Council, not coding tools. No coding app has a real debate view, so Ensemble's debate rounds view and verdict card have no direct competitor.
