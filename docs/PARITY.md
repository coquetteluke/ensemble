# Parity with the reference app

What the desktop app that Ensemble's layout follows can do, feature by feature, and where Ensemble stands on each. Written 2026-11-20 from a read-only tour. Words only: no screenshots, no copied wording, no private data.

Ensemble copies features, behaviour and layout ideas. It keeps its own name, colours, icon and wording.

## How this was gathered

| Source | What it covered | How |
|---|---|---|
| The reference app's web version, in the owner's signed-in browser | The coding home screen, one open session, the side panel and its tabs, the activity panel, Scheduled and its new-task form, the artifacts gallery, the plugins directory, the search dialog, the sidebar editor, nine of eleven Settings pages, the chat home, one chat, Projects | Opened every menu and closed it again without choosing anything |
| The reference desktop app's own agent tools | Sidebar sections, grouping and sorting values, pane names, split view and pop-out windows, the Code settings keys and their allowed values, the usage card, the new-session picker, the storage breakdown, pull request monitoring, scheduled tasks, side sessions, the task list, the next-step box, chapters | Read the tool descriptions, called only the read-only ones |
| Official documentation | Keyboard shortcuts, desktop Settings pages, the work-tasks tab, menu bar items, error states, recent release notes | A documentation helper fetched the pages |
| The earlier catalog | `docs/research/claude-code-and-antigravity.md` (2026-11-18, 262 rows) | Read in full |
| Ensemble | All 369 Mac snapshots rendered from this branch, plus a 76-point check of the code | `--render-snapshots`, two read-only code inventories |

### What could not be seen

- **The desktop window itself.** Screen control refuses the app the agent runs inside, and full-screen control leaves that app out of its pictures. So the terminal pane, browser pane, plan pane, pull request bar, split view, pop-out windows, menu bar menus, the desktop-only Settings pages (Desktop app, This computer, Storage, Developer) and the work-tasks tab were not seen directly. Their rows below come from the tools and the documentation.
- **The light theme.** Changing it would have meant flipping a setting. Rows about light and dark describe Ensemble only.
- **Account and Billing settings.** Skipped on purpose.
- **Anything shared by other people.** Not opened.
- **The phone app.** Not available to the tour. Phone rows come from documentation.
- **Ensemble on the iPhone Duo simulator.** Another session had the simulator booted with its own build, so nothing was installed over it. The iPhone column comes from the code.

Nothing in the owner's account was changed. Three prompts were dismissed without accepting (an informational notice, a request to sign in again, a request to turn on notifications).

## Legend

| Ensemble column | Meaning |
|---|---|
| Has | Works on this branch |
| Partly | Exists, the note says what is missing |
| Missing | Not in the code |
| In progress | Another session is building it now |
| Not planned | Outside Ensemble's goals (see `docs/DESIGN.md`, Non-goals) |

Rank is how soon the owner would notice the gap: **1** every session, **2** most days, **3** now and then, **4** rarely or never. Rows Ensemble already has carry no rank.

## 1. Sidebar and sessions

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| Session list with New, a search entry and status marks per row | Has | | |
| Three-way switch at the top between the chat, work-tasks and coding products | Not planned | 4 | Ensemble is a coding app |
| Nav items for an artifacts gallery, plugins and Scheduled, and a dialog to choose which of them show | Partly | 3 | Session Hub and Scheduled; no gallery, no plugins entry, no choice of items |
| Built-in sections (Pinned, Scheduled, Sessions) that can each be collapsed or switched off | Partly | 2 | Pinned and Sessions; the collapsed state is forgotten on relaunch |
| Sections the user makes: create, rename, delete, move a session in | Missing | 2 | |
| Group by date, status, folder, environment or nothing | Partly | 3 | Project, state and date; no "nothing", no environment |
| Sort by last updated, created or name, ascending or descending | Partly | 3 | Three sorts, no direction |
| Show active, archived or all; a "view all" page with an Archived tab | Partly | 2 | Archived sessions appear only in the Session Hub and in search |
| Row marks: working, needs input, failed, unread; Mark as unread; Mark as completed | Has | | |
| Row menu: open in (split, own window, another surface), pin, unread, rename, fork, share, copy link, move to section, archive, delete, each with a one-letter key | Partly | 2 | No fork, own window, share, link or move to section; no keys |
| Rename from the row | Has | | |
| Dragging: a session into a section, a session to the window edge for split view | Missing | 3 | Dragging folders to reorder is in progress |
| Sessions started by another session nest under it; detach to top level | In progress | 2 | |
| Sidebar width by dragging its edge | Missing | 3 | Fixed at 260 |
| Account menu at the foot: settings, usage, language, help, feedback | Partly | 4 | Settings button and engine status |
| Auto-archive after N quiet days, and when a pull request merges or closes | Partly | 3 | Per session, on merge only |
| A session in its own window | Missing | 3 | One main window |
| Split view by option-click, menu or drag; a key to leave it | Partly | 3 | No drag; up to four panes |
| Keys for next and previous session, and Control-Tab | Has | | Built in this pass |
| Delete asks first and names the sessions | Has | | |
| Labels a session as blocked, ready for review or done by itself | Partly | 3 | The Session Hub buckets do this without a model call |
| A warning before resuming a long, costly session; a one-line recap on return | Missing | 4 | |

## 2. The session window: title bar and transcript

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| Click the title to rename it | Has | | Built in this pass |
| A menu beside the title: open in, rename, fork, copy link, transcript view, archive, delete | Has | | Built in this pass, with pin and marks as well; the view menu stays its own control |
| Transcript views: normal, thinking, verbose | Has | | |
| Your messages as bubbles on the right; agent text without a bubble, in a serif face | Has | | |
| Under your message on hover: time, fork from here, rewind to here, edit, copy | Has | | |
| Under the agent's reply: copy, fork from here, pin as chapter, read aloud, time | Partly | 2 | Copy and Second opinion; no fork, chapter, read aloud or time |
| Folded runs of tool calls, a live working row | Has | | |
| **Next-step box** when a turn ends: a short recap of what changed, one question, one or two buttons (reply, commit, open a pull request, verify) | Partly | 3 | Built in this pass from the transcript: recap, the closing question, Yes, No and Review changes. The agent does not write the recap, and there are no commit or pull request buttons on the card |
| **Chapters**: named dividers in a long transcript and a floating list to jump between them | Partly | 3 | Built in this pass as a jump list of your messages in the title row, with pins as chapters. No dividers in the transcript and no pin button on a message yet |
| Task list pinned under the newest message, one step in progress | In progress | 1 | A first version is on this branch |
| Pictures inside messages | In progress | 2 | |
| Cards that offer a separate session: start, do it here | Has | | |
| Permission cards, question cards with choices, plan approval | Has | | |
| A row where the conversation was compacted | Has | | |
| Find in the transcript | Has | | |
| Jump to the newest message | Has | | |
| A grey suggested next message in the empty box, accepted with Tab | Missing | 3 | Costs one model request per reply |
| A findings card after a code review: by file, walk through, fix one, apply all | Missing | 3 | |
| Diagrams drawn from diagram code blocks | Missing | 3 | Widgets render; diagram blocks do not |
| Transcript width: narrow or wide | Missing | 3 | Fixed at 760 |
| Export a transcript as a file; share a link | Partly | 3 | Copy as Markdown only |
| Thumbs up and down, retry on a reply | Partly | 4 | Retry on a failed turn only |

## 3. The message box

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| Text box, Return sends, Shift-Return adds a line, Stop while working | Has | | |
| A "+" menu: add files or photos, commands, connectors, plugins, add a folder | Missing | 2 | One attach button |
| Typing @ lists files to mention | Missing | 2 | @ names agents in rooms only |
| Drag and drop, attachment chips | Has | | |
| Paste a picture | In progress | 2 | |
| Typing / lists commands and skills with a description, and filters as you type | Has | | |
| Model menu with number keys, effort, fast mode, older models | Has | | |
| Permission mode menu with a line per mode and number keys | Partly | 3 | Has the lines and Plan; Shift-Tab cycles, no number keys |
| Where it runs (this computer, another machine, the cloud), folder, and a worktree switch under the box | Partly | 3 | Folder and worktree; this computer only |
| Add another folder to a running session | Missing | 3 | |
| Plan-limit ring that opens the limits | Has | | |
| Dictation | Has | | |
| Spoken two-way conversation | Missing | 4 | |
| Messages typed while the agent works wait in a queue: send now, cancel | Has | | |
| Bring back the last message with Command-Up | Missing | 2 | |
| Side question that reads the session without adding to it | Has | | |

## 4. Side panes

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| One side panel with tabs and a "+" that opens Changes, Files, Background tasks, Terminal, Browser or Plan; tabs stay open together | Partly | 3 | Built in this pass for Changes, a file, Browser and Terminal. No Background tasks, Plan or files-tree tab |
| Make a pane fill the window; shrink it to a small floating view; move it to its own window | Partly | 3 | Fill the window was built in this pass |
| Drag the edge between chat and panel | Missing | 3 | Width follows the window |
| Session details beside the chat: where it runs, changes, context | Has | | |
| Context: percent, used and limit, coloured bar, a row per kind, groups that open | Has | | |
| Context: how many tokens are left before it compacts by itself, and a Compact button | Has | | Built in this pass |
| Changes: every change of the branch, uncommitted only, or one commit; compare against another branch | Partly | 3 | Whole session, last turn, per agent |
| Changes: comment on a line, send all comments at once, refresh | Has | | |
| Files: a tree with a search field beside the viewer | Missing | 2 | The viewer opens from a link only |
| Files: edit with auto save | Missing | 3 | Read-only |
| Files: copy path, show in Finder, open in an editor | Has | | No "attach as context" |
| Terminal with tabs | Has | | |
| Browser with dev servers, pick an element, phone and tablet widths | Has | | |
| Browser: keep cookies, clear browsing data | Missing | 4 | Always private |
| Plan beside the chat | Missing | 3 | Plans are cards in the transcript |
| Background tasks as a pane: running and finished groups, how long each took, clear finished, stop, open the output | Partly | 3 | A popover, not a pane. The Finished group, durations and Clear were built in this pass; finished rows are forgotten on quit |
| A pane for one helper agent's output | Partly | 3 | Opens the helper's session in the main area |
| A pane for pages a session published | Not planned | 4 | Ensemble does not publish pages |
| A simulated iPhone that the agent can run and tap | Missing | 4 | |

## 5. Git and pull requests

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| A worktree per session, a switch for it, clean up old ones | Has | | |
| Branch prefix and worktree location in Settings | Missing | 3 | Fixed `ensemble/session-<id>` and `.ensemble/worktrees` |
| Pull request bar with checks; create as draft | Has | | |
| Fix failing checks and answer review comments by itself | Partly | 3 | A manual Fix checks button |
| Merge when ready | Has | | |
| Archive the session when its pull request merges or closes | Partly | 3 | On merge |
| Track a pull request opened elsewhere by its address | Missing | 4 | |
| Commit and push from the review pane | Has | | Pushes only when the owner presses it |

## 6. Scheduled tasks

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| A Scheduled page with run now, pause, edit, delete and history | Has | | |
| Search, filter and sort the list | Missing | 3 | |
| A gallery of ready-made tasks to start from | Missing | 2 | |
| Create a task by describing it in a chat | Missing | 3 | |
| Hourly, daily, weekdays, weekly | Has | | Plus custom cron |
| Monthly and one-time | Missing | 3 | |
| Start a run from a repository event or a web call | Not planned | 4 | Needs a server |
| Catch up one missed run after sleep | Has | | |
| Per-task permission mode | Has | | |
| Per-task notifications and connector list | Missing | 4 | |
| Status of the last run in words | Has | | |

## 7. Search, commands and keys

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| A search dialog on Command-K over titles and message text | Has | | |
| Before you type: what needs attention, what is working, recent sessions, and actions such as New session | Has | | Built in this pass |
| Scopes for sessions, scheduled tasks and other kinds | Partly | 3 | All, this folder, archived |
| Key hints along the bottom | Has | | |
| A list of every shortcut on Command-slash | Has | | |
| A command palette | Has | | The reference app has none |
| Keys for the diff, browser and terminal panes, the mode, model and effort menus, the side question, view modes | Partly | 3 | All but the effort menu have a key; some keys differ |
| Numbers pick an item in any open menu | Partly | 3 | Model picker only |
| Menu bar: check for updates, show logs, make a diagnostic report | Missing | 3 | |

## 8. Settings

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| Theme: system, light, dark | Has | | |
| Interface font, reply font | In progress | 2 | Branch `claude/font-picker-a410bf` |
| Code font and code font size; light and dark code colours | Missing | 3 | |
| Reduce motion, more contrast, how long pop-ups stay | Missing | 4 | The iPhone app honours Reduce Motion |
| Notifications by kind (approval needed, question, finished): off, badge, or banner; sound; bounce the Dock icon | Partly | 3 | One switch, two sounds, Dock badge, menu bar icon, phone alerts |
| Default transcript view, default permission mode, default model | Has | | |
| Keep the Mac awake while working, and on battery | Has | | Plus lid-closed |
| Storage: what takes space, remove old worktrees, clear caches | Partly | 3 | Worktree list with Remove unused |
| Archive quiet sessions after N days | Missing | 3 | |
| Connect new sessions to the phone by default | Partly | 4 | One Remote Control switch for the Mac |
| Reply style for new sessions (plain, concise, explanatory, teaching) | Missing | 3 | |
| Release channel, check for updates, About with the version | Missing | 3 | Matters now that there is an installer |
| Your own instructions for every session; view and edit memory | Missing | 3 | Customizations shows the files and opens them elsewhere |
| Break reminders and quiet hours | Missing | 4 | |
| Accounts and keys | Has | | Many more providers than the reference app |

## 9. Usage and limits

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| Plan limit bars with reset times, per plan | Has | | Two plans side by side |
| A warning when the current pace runs out before the reset, with a lighter model suggested | Missing | 3 | |
| A week of use by hour | Missing | 4 | |
| Use by product and by device | Partly | 4 | By provider, agent and session |
| Limit reached card, continue when it resets | Has | | |
| Spending caps | Has | | The reference app has credits instead |

## 10. Attention, phone and cloud

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| A notification when a session finishes or needs you | Has | | |
| Follow and steer a session from the phone | Has | | Own iPhone app, end-to-end encrypted |
| Approve, answer, send, switch model and mode from the phone | Has | | |
| Phone alerts | Has | | Through ntfy |
| Send photos and files from the phone | Missing | 3 | |
| Sessions that run in the cloud with the Mac closed | Not planned | 4 | |
| Sessions on another machine over SSH | Missing | 4 | |
| Move a session between computer, cloud and terminal | Not planned | 4 | |

## 11. Customizing

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| See which rules, skills, tool servers and hooks an agent loads | Has | | For three engines side by side |
| A directory to browse and add connectors, skills and plugins | Missing | 3 | |
| Turn a connector on or off for one session | Missing | 3 | Sign-in is not wired either |
| Controlling other Mac apps by screen | Missing | 4 | |
| Using the owner's own browser | Missing | 4 | Ensemble has its own browser pane |

## 12. Outside the coding tab

| Feature in the reference app | Ensemble | Rank | Note |
|---|---|---|---|
| A home screen with a greeting, a message box and recent work | Partly | 3 | The new session page; with nothing selected the centre is nearly empty |
| A small entry box from any app on a system-wide key, with a screen capture | Missing | 3 | |
| A chat that is not saved | Missing | 4 | |
| Projects that hold files, instructions and chats | Partly | 4 | Folders group sessions |
| A gallery of made documents, slides, sheets and designs | Not planned | 4 | |
| Read a reply aloud | Missing | 3 | |
| A work-tasks tab for office files | Not planned | 4 | |

## 13. Empty, loading and error states

| State | Ensemble | Rank | Note |
|---|---|---|---|
| No sessions yet | Has | | One line in the sidebar |
| Nothing selected | Partly | 3 | Icon, one line, one button |
| No scheduled tasks | Partly | 3 | One line; the reference app adds starting points |
| No changes, nothing running, no search matches | Has | | |
| Files pane with nothing open | Missing | 3 | There is no files pane to be empty |
| Engine missing, too old or failed | Has | | With setup steps on the installer branch |
| A session that fails to load | Partly | 3 | A generic alert |
| Plan limit reached | Has | | |
| First run | Partly | 3 | Import offer only; onboarding waits for the polish pass |

## 14. Light and dark

Ensemble renders every screen in both. The reference app's light theme was not toured, so there is nothing to compare.

## Things Ensemble has that the reference app does not

Rooms (team, debate, round table), agents on different engines talking to each other, a second opinion from another model, switching engine in the middle of a chat, the Session Hub, a command palette, spending caps, lid-closed running, an Auto mode decided by Ensemble for every engine, and its own encrypted relay.

## Top gaps, ranked

Counting only gaps nobody else is building.

| # | Gap | Rank | Can it be built now |
|---|---|---|---|
| 1 | Next-step box at the end of a turn | 1 | Built, worked out from the transcript |
| 2 | Title-bar session menu, click the title to rename | 1 | Built |
| 3 | Side panel with tabs and a "+" | 1 | Built for Changes, a file, Browser and Terminal, with fill the window |
| 4 | Chapters and a list to jump between them | 2 | Built as a jump list with pinned chapters |
| 5 | Sidebar: your own sections, sort direction, saved collapse, archived view, fuller row menu | 2 | After the sidebar session lands |
| 6 | Message box: "+" menu, @ files, bring back the last message | 2 | After the pictures session lands |
| 7 | Search: needs you, working, recent and actions before you type | 2 | Built |
| 8 | Context: tokens left before compacting, a Compact button; Background tasks with a Finished group | 2 | Built |
| 9 | Scheduled: ready-made tasks, search and sort, monthly, one-time | 2 | Yes |
| 10 | Keys for next and previous session; check for updates and About | 2 | Keys built; updates and About not yet |
| 11 | Files pane with a tree and search | 2 | Yes |
| 12 | Agent reply actions: fork from here, read aloud, time | 2 | After the pictures session lands |
| 13 | Settings: notifications by kind, storage, branch prefix, quiet-session archiving, reply style | 3 | After the font session lands |
| 14 | Usage pace warning | 3 | Yes |
| 15 | A session or pane in its own window | 3 | Yes |
| 16 | Entry box from any app | 3 | Yes |
| 17 | Review scopes: uncommitted, one commit, another branch | 3 | Yes |
| 18 | Diagram blocks, review findings card, suggested next message | 3 | After the pictures session lands |
| 19 | Plugins directory, instructions and memory editor | 3 | Yes |
| 20 | Home screen, onboarding | 3 | Waits for the owner's polish go-ahead |

## Built in this pass

Details in `docs/PROGRESS.md`.

- Title-bar session menu, and click the title to rename (gap 2).
- Next-step card under a finished turn (gap 1).
- Context card: room left before compacting and a Compact button. Background list: a Finished group (gap 8).
- Search start screen (gap 7) and keys for next and previous session (half of gap 10).
- Jump list of your messages with pinned chapters (gap 4).
- Side panel tabs with a "+" and fill the window (gap 3).

Not clicked through in a running window: the owner's own Ensemble was open during the work, so each piece stands on its tests, both builds and its rendered snapshot.
