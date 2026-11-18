# ACP fixtures

Recorded on 2026-11-18 from the real agents over stdio with a small probe client (initialize with protocol version 1,
no file system or terminal capabilities), in throwaway folders:

| File | What it is |
|---|---|
| `agy-edit.jsonl` | `agy acp` 1.5.10: initialize, session/new (models, modes, config options), session/set_model to `gemini-3.8-flash-low`, "Reply with exactly: hello there", a new file with a permission prompt answered allow, an edit answered deny. |
| `agy-load-cancel.jsonl` | `agy acp`: session/list, session/load of the session above (history replayed as updates), a shell command answered allow, a long reply stopped with session/cancel (`stopReason: cancelled`), then a reply with thought chunks. |
| `agy-config.jsonl` | `agy acp`: session/set_config_option for model, thought_level and mode (`accept-edits`: the edit runs without asking), session/set_mode, session/close. |
| `agy-ask-under-turbo.jsonl` | `agy acp` on a Mac whose Antigravity preset is Turbo: in `default` mode a shell command, a write outside the project and a read outside the project all ask; in `accept-edits` a command still asks; in `auto` the model asked in text before an `rm -rf`. All prompts were denied. |
| `opencode-mock.jsonl` | `opencode acp` 2.3.0 with the scripted mock model (`tools/mock-llm`, project `opencode.json` with `edit` and `shell` set to ask): text, reasoning, write (allow once), edit (always), shell (reject, which ends the turn as cancelled), a failing `todowrite`, a cancelled slow reply, session/list. |
| `agy-usage-prompt.jsonl` | `agy acp` 1.5.10: a session in an empty folder whose only prompt is "/usage" (Gemini 3.8 Flash low). ACP offers no usage command, so it ran as a model turn (21k input tokens). |
| `agy-usage.json` | `agy -p "/usage" --output-format json` (1.5.10): agy answers its own `/usage` command, no turn. Plan groups with five-hour and weekly buckets (`remaining_fraction`, `reset_time`). Not anonymised: it holds no account details. |
| `agy-usage-stream.jsonl` | The same command with `--output-format stream-json`: a `command_result` event, then `result`. |
| `fake_acp_agent.py` | A scripted ACP agent for deterministic engine tests (see its header). |

Each line is `{"dir": "in" | "out", "msg": <JSON-RPC message>}`: `out` is what the client sent, `in` what the agent
sent. Anonymised with a script: project paths are `/private/tmp/ensemble-acp/proj` (and `.../outside`), the home
folder is `/Users/me`, user-installed skills are removed from `available_commands_update` (Antigravity's built-in
commands are kept), other sessions in `session/list` have generic titles, the account tier in `_meta` is generic, and
the list cursor is `CURSOR`. Nothing credential-like was ever in the stream.
