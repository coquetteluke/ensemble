# Rooms: how agents work together

A room is a project folder, one or more agents, and a mode. Each agent is its own OpenCode session (its own model, tools, subagents and permissions). The RoomEngine is the only thing that moves messages between agents, and every message it moves is shown to the user on the room board.

## Pieces

- `RoomState`: the RoomSpec, `agentID -> sessionID`, the board, the phase, assignments, review state, per-agent usage. Saved as JSON in `~/Library/Application Support/Ensemble/rooms/<roomID>.json` after every change.
- `BoardMessage`: `id`, `from` (agent, user, or room), `to` (agent ids, empty = everyone), `kind` (chat, plan, assignment, update, question, review, argument, verdict, notice), `round`, `text`, `date`.
- `RoomEngine` (@MainActor, in EnsembleKit/Rooms, no AppKit): drives phases, listens to `EngineEvent`s for its sessions, decides who speaks next. Git operations go through an injected `GitOps` protocol (the Mac app implements it with `git`), so the engine stays testable.

## Getting messages between agents

1. When an agent's turn ends (`executionEnded` for its session), the engine takes the agent's final text of that turn and posts it to the board.
2. Lines in that text that start with `@name` (or `@all`) are delivered to those agents. Everything else goes to the board for the user and the lead.
3. Delivery uses `injectSynthetic(sessionID, text, wake:)` with the text formatted as:
   `[Room] <Name> (<model>) to you: <text>`
   `wake: true` when the receiver should answer now, `false` when it is just for its information (it reads it on its next turn).
4. Every agent's instructions (session instruction entries) describe the room: who is in it (name, model, role), the mode, its own role, how to address others, the reply keywords below, file ownership, and "keep room messages short; do the work in your own session".

Keywords the engine parses (case-insensitive, at the start of a line):

| Keyword | Meaning |
|---|---|
| `ASSIGN @name: task` | Lead gives a piece of work (Team). One per agent. |
| `PLAN:` | Start of the plan text. |
| `DONE` | The agent finished its piece. |
| `APPROVE` | Review passed. |
| `CHANGES: ...` | Review failed, with what to change. |
| `AGREE` | Round table: agrees with the current plan. |
| `TAKEOVER` | Round table: a reviewer offers to take over building. |
| `VERDICT:` | Debate judge's decision. |

If an agent ignores the format, the engine asks it once to restate in the format; after that it falls back (for example, treats the turn's end as DONE) and posts a notice.

## Modes

### Solo
One agent, one session. Like a normal chat.

### Team (default with 2+ agents)
1. **Plan.** The user's task goes to the lead with the roster. The lead replies with `PLAN:` and one `ASSIGN` per agent, including itself. Every agent gets real work or a review duty.
2. **Approve.** In Ask and Accept-edits modes, the plan waits for the user (Approve / Edit / Redo). In Auto and Bypass it starts at once; the user can still pause.
3. **Work.** All agents start at the same time with the plan and their own assignment. In a git repo, each agent works in its own worktree and branch (`ensemble/<room>/<agent>`), created with the engine's worktree API; otherwise they share the folder and the plan names which files each owns. Agents message each other with `@name` lines; questions usually go to the lead.
4. **Review.** When an agent says `DONE`, the engine picks a reviewer (a different agent, round robin) and sends it the author's assignment and changed files (session diff). `APPROVE` marks the piece ready. `CHANGES:` goes back to the author; at most two fix rounds, then the user decides.
5. **Merge.** In git repos the engine merges approved branches into the room's base branch in assignment order (`GitOps.merge`). A conflict goes to the lead to resolve in the base worktree.
6. **Finish.** The lead posts a short summary to the user: what was built, who did what, anything left.

### Debate
1. The user's question goes to every agent at once: give a position and reasons, no file edits.
2. Rounds 2..N (default 3): each agent gets the others' latest arguments and answers them: agree where they are right, push back where they are wrong, update or defend its position. Agents speak in parallel within a round.
3. The judge (the lead, or the user if no lead) gets every argument and writes `VERDICT:` with the decision, the reasons, and the strongest dissent.
4. The verdict card offers "Build it" (starts a Team or Solo run with the verdict as the task) and "Debate again".

### Round table
1. Agents take turns, lead first, proposing and refining one plan, each seeing everything said so far. It ends when every agent says `AGREE`, or after 4 rounds (then the lead's last version wins).
2. The builder (the lead by default) builds. After each builder turn, the others review what changed since the last review, in parallel: `APPROVE`, `CHANGES: ...`, or `TAKEOVER`.
3. A `TAKEOVER` the user accepts (automatic in Auto/Bypass) passes the builder role to that agent with a handoff of the plan and progress.
4. It ends when the builder says `DONE` and every reviewer approves.

## Busy agents, subagents and worktrees (from live tests)
- Messages only for an agent's information (`wake: false`) wait while that agent is in a turn (`RoomState.held`) and go out when the turn ends: OpenCode reads such a message at the end of a running turn and takes another step, which added replies like "OK." to the turn the room parses.
- OpenCode runs subagents in the background, so an agent's turn can end as soon as it starts one, and the subagent's result wakes it later. While any of an agent's child sessions work, the room does not nudge it, fall back for it, send it a new turn, or treat the room as idle. If nothing wakes the agent within a few seconds of its last subagent finishing, the room checks on it as usual.
- Worktrees live in `<room folder>/.ensemble/worktrees/<branch>`. In Accept edits and Auto, Ensemble's rules ask before any edit under a dot folder, so before each work message the room adds an allow scoped to the agent's own worktree to its OpenCode session (`PermissionRules.worktreeEditRules`); dot paths, OpenCode's config shape and build files inside the worktree still ask, and so do other agents' worktrees. Claude and Gemini agents follow their own CLI's mode for the worktree path.

## User controls

- Talk to the room (everyone) or `@name` one agent.
- Pause: interrupts every session and stops scheduling. Resume continues from the saved phase.
- Stop: ends the run; sessions and the board stay.
- Take over: the user becomes the lead.
- Spending caps: when an agent hits its cap, it is interrupted, gets no more turns, and the board shows why. The room continues without it if it can, otherwise pauses.

## Permission prompts in rooms
Each agent's session uses the room's permission mode. Prompts show on the room view (with the agent's name and colour), in the Session Hub, and on the iPhone. A room waiting on a prompt shows as Needs you.

## Testing
The mock model (`tools/mock-llm/`) answers by keyword so whole rooms run deterministically with no cost: a debate prompt gets a canned argument, a planning prompt gets `PLAN:` and `ASSIGN` lines, a review prompt gets `APPROVE` or `CHANGES:`, a work prompt makes a small file edit through the engine's edit tool and says `DONE`. End-to-end tests run a 2-agent debate and a 3-agent team in a temp git repo and check the board, the files, the branches and the merge.
