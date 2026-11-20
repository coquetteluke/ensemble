# Room scripts for the mock model

`room-script.json` answers the room engine's prompts by keyword, so whole rooms run against the real OpenCode
service with no keys and no cost. The live room tests (`Packages/EnsembleKit/Tests/EnsembleKitTests/RoomLiveTests.swift`)
start `mock_llm.py` with it.

| Prompt from the room | Matched by | Reply |
|---|---|---|
| Debate opening | `Debate question from the user` | a position with reasons |
| Later debate rounds | `The others' latest arguments` | an answer to the other side |
| Judge | `You are the judge` | `VERDICT:` with reasons and dissent |
| Team plan (and its retry) | `You are the lead. Do not edit files yet` | `PLAN:` and `ASSIGN @Ada`, `ASSIGN @Byron` |
| Review | `Please review` | `APPROVE` |
| Work for Ada / Byron | `Your assignment: create ada.txt` / `byron.txt` | `write` into the agent's worktree, then `DONE` |
| Summary | `Post a short summary` | a one-line summary |
| Format retries, resume | `Reply DONE on its own line`, `The room resumed` | `DONE` |
| A real dot path | `git config marker` | `write` to `.git/config` (the test rejects the prompt) |
| Another agent's worktree | `other worktree marker` | `write` into Ada's worktree (the test rejects the prompt) |

Room worktree folders end in short room and agent id suffixes (branch `ensemble/mock-team-<room id>/<agent>-<agent id>`),
so the work rules write to `{{worktree}}/<file>`. `mock_llm.py` fills `{{worktree}}` with
`.ensemble/worktrees/<folder>` from the agent's own brief (`Work only in your own git worktree: ...`), or else from the
newest worktree path any message mentions, which is how Byron's subagent finds his worktree. The `other worktree
marker` rule keeps a fixed path on purpose: any path outside Byron's own worktree must still ask.

`pause-script.json` streams the opening argument slowly so the pause test can interrupt it mid-turn.

`subagent-script.json` is the team script with one change: Byron's work starts a background subagent (`subagent` tool)
that writes `byron.txt` slowly, and Byron says `DONE` only when the subagent's result (`<subagent ...>`) wakes him.

The team tests answer every permission prompt from the room's sessions with Allow once, as the room view does. In
Auto mode there should be none: each agent's session allows edits in its own worktree
(`PermissionRules.worktreeEditRules`), while `.git/config` and other agents' worktrees still ask.

Run the live room tests:

```bash
cd Packages/EnsembleKit
ENSEMBLE_LIVE_TESTS=1 swift test --filter RoomLiveTests
```
