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

The work rules write to `.ensemble/worktrees/ensemble-mock-team-<agent>/`, the worktree `ProcessGitOps` makes for a
room titled `Mock Team` with agents named `Ada` and `Byron` (branch `ensemble/mock-team/<agent>`). Keep the test's
room title and agent names in step with this file.

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
