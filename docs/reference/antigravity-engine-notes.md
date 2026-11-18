# Antigravity engine: Gemini on a Google AI subscription (checked 2026-11-18)

Ensemble's Gemini agents run Google's official Antigravity CLI, `agy`, signed in with the user's own Google account. Google stopped serving Gemini CLI for free, AI Pro and Ultra personal accounts on 2026-06-18 and points those users to `agy`. Google has suspended accounts whose Antigravity sign-in was used inside unofficial tools, so Ensemble only runs the official binary and never reads or reuses its credentials.

## Install and sign-in
- `brew install --cask antigravity-cli` (downloads from Google's `antigravity-public` storage; Homebrew manages updates, so use `brew upgrade --cask antigravity-cli`, not `agy update`).
- `agy` shares the Antigravity desktop app's sign-in on the same Mac. If it is not signed in, running `agy` once opens the browser.
- `agy models` lists what the account can use (on Ultra: Gemini 4 Carbon/Argon/Hydrogen, Gemini 3.8 Flash, plus Claude and GPT-OSS models Google includes). Quota refreshes every 5 hours with a weekly cap.

## Headless use (agy 1.5.10)
- One turn: `agy -p "<prompt>" --output-format stream-json --model <id> [--mode accept-edits|auto|plan] [--conversation <id>]`, run in the project folder (`--add-dir` for more folders).
- Multi-turn in one process: `--input-format stream-json --output-format stream-json`, one NDJSON message per stdin line, one turn each.
- `agy acp` starts an Agent Client Protocol stdio server (the protocol Zed uses), which includes structured tool calls and `session/request_permission`, so the host app can approve or deny. Prefer ACP when Ensemble needs to answer permission prompts; use stream-json for simple runs.
- `--dangerously-skip-permissions` approves everything (Bypass mode only).
- stream-json events (sample: `agy-1.5.10-stream-json-sample.jsonl`): `init` (conversation_id, model, cwd, tools, permission_mode such as `request-review`), `step_update` (step_index, state ACTIVE/DONE, step_type user_input/system_message/agent_response/tool steps, `text_delta`, `usage`), `result` (status, response, num_turns, usage).
- Conversations also appear in the Antigravity app's history, and their transcripts are under `~/.gemini/antigravity-cli/` (the agent bridge reads these).

## Running agy through ACP (found while building the engine, 2026-11-18)
- Ensemble drives `agy acp` over stdio (ACP v1, schema 1.32). One process serves every session; Bypass sessions get a second process started with `--dangerously-skip-permissions`. At most 3 turns run at once.
- agy 1.5.10 differs from the spec: it still uses `models` and `session/set_model`, sends string request ids, adds a non-standard `args` field and snake_case copies of capabilities, sends no plan updates, and its edit diffs hold only the replaced fragment.
- `session/load` resets the model and mode to agy's defaults, so Ensemble sets both again every time a session opens.
- **Turbo leaks unless the mode is set.** A user config with Turbo (commands always proceed, sandbox off) applies to ACP sessions too. Ensemble sets the session mode explicitly on every start and load (Ask and Auto are `default`, Accept edits is `accept-edits`, Plan is `plan`) and refuses to send work if agy does not report the mode back.
- **Project files run without asking.** agy runs a folder's `.agents/hooks.json` hooks and applies its `GEMINI.md` in any folder, and has no switch to turn that off (it rejects `--settings`). Ensemble only starts agy in folders listed in `WorkspaceTrust`.
- **Symlinked folders.** If the session folder's path goes through a symlink (for example `/var` to `/private/var`), agy silently runs shell commands in its own working folder instead of the project. Ensemble sends the fully resolved path and runs the process from an empty folder of its own.
- Effort is agy's `thought_level` config option; there is no fast mode and no rewind.
- `opencode acp` works through the same engine (provider id `opencode-acp`), but its modes are agents, not permission levels, so Ensemble keeps using the OpenCode service for OpenCode sessions.

## Plan mode and questions (checked 2026-11-18, agy 1.5.10, gemini-3.8-flash-low)
- agy offers a `plan` mode. In it every shell command asks (even `find`), and the agent writes an implementation plan with `write_file` into its artifact folder (`~/.gemini/antigravity-cli/brain/<conversation>/`, no prompt) with `ArtifactMetadata.RequestFeedback: true`, then ends the turn asking for "Proceed". Ensemble shows that file's content as the plan card; Proceed sets the chosen mode (reported back as for any mode change) and sends "The plan is approved. Carry it out now.". Ensemble also refuses file edits in Plan, and remembered "Always" rules approve nothing there.
- With `clientCapabilities.elicitation.form` advertised, agy's `ask_question` tool sends `elicitation/create` (mode `form`): properties `q1`, `q2`, ... (a string with `oneOf` `const`/`title` for one choice, an array whose `items` have `anyOf` for several) plus `q1_other` for a typed answer. Answer `{"action": "accept", "content": {"q1": "2", "q2": ["1", "3"]}}`; decline `{"action": "decline"}`; withdraw `{"action": "cancel"}`. Without the capability it prints the question as text.
- Other ACP agents get Plan only when their registry entry names the mode: a mode merely called "plan" is not trusted to be read-only (OpenCode's ACP `plan` agent runs shell commands without asking).

## Modes and what they ask, and Ensemble's Auto (checked 2026-11-18, agy 1.5.10, gemini-3.8-flash low)
agy offers four ACP modes. What each sends as `session/request_permission`:
- `default` ("Ask before edits and commands, per your permission settings"): every shell command asks (`run_command`, `rawInput` `{"CommandLine", "WaitMsBeforeAsync", "toolSummary"}`, `kind: execute`), and so does every file edit, inside the project too (`write_file` with `Path` and `Content`, `edit_file` with `Path`, `Target` and `Replacement`, `kind: edit`, the absolute path in `locations`, a diff in `content`). Reads and writes outside the project ask. `search_web` runs without asking. "Per your permission settings" means the user's own grants in agy's settings (`globalPermissionGrants`, specific files) still apply.
- `accept-edits`: edits inside the workspace run, commands ask.
- `auto` ("Approve edits and safe commands; ask before irreversible actions"): no prompts at all in practice. It ran `npm test`, `rm -rf build` and a `curl` to example.com, then retried the curl with `"BypassSandbox": true`, all without asking.
- `plan`: every shell command asks, edits are refused by Ensemble (see above).

agy's `run_command` also takes `Cwd`, `Blocking`, `SafeToAutoRun` (the model's own opinion), `toolAction`, `explanation` and `BypassSandbox` (true asks to run outside agy's terminal sandbox; agy's own instructions call that "requesting explicit user permission"). Every request repeats its arguments in a non-standard `args` field.

So Ensemble's Auto runs agy in `default` and answers each prompt itself (`ACPAgentDefinition.ensembleDecidesAuto`, `Engines/ACP/ACPAutoPrompts.swift`, `Store/SafetyCheck+Agents.swift`):
- Edits inside the session's folder are answered "allow once", except hidden paths, protected build, config and agent instruction files (`PermissionRules`, `SafetyCheckHardRules.nameReason`) and paths a link takes outside the folder.
- Commands go past the safety check's fixed rules, then the read-only commands OpenCode's Auto allows run, and anything else goes to the safety check's model chosen in Settings. agy sessions have no provider in OpenCode, so with "Same provider as each session" those commands ask. The check never calls Google and never reads agy's credentials.
- A sandbox argument that does not keep the command in the sandbox, an argument Ensemble does not know, `args` that differ from `rawInput`, a folder outside the project, and every other kind of request (reads, fetches, deletes, moves, other tools) ask. So does anything that fails or times out.
- Every automatic decision shows as for OpenCode: "Checked" on the tool card and the session's Safety check list.
- Tools agy runs without asking in `default` (`search_web`, reads inside the project) cannot be seen before they run.

Live check (`ACPLiveTests.antigravityAutoAsksBeforeRiskyCommands`, one turn): in Auto through Ensemble's store, `ls` was answered by Ensemble as a read-only command and `rm -rf build` produced a prompt ("Deletes folders"); after Reject the folder was still there. In agy's own `auto` the same command ran unasked.

