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
