# Claude Code engine: rules and flags (checked 2026-11-18)

Ensemble's Claude agents run the official `claude` CLI on the user's Mac, signed in with the user's own Claude subscription. Findings from Anthropic's docs (code.claude.com/docs: legal-and-compliance, headless, cli-reference, permission-modes, agent-sdk/permissions, costs; support.claude.com articles on the Agent SDK with a Claude plan and monthly API credits):

## Allowed, with conditions
- Anthropic's legal page allows "an end user ... signing in to the unmodified Claude Code binary with their own Claude subscription", and the help center says signed-in `claude -p` and the Agent SDK "still draw from your subscription limits".
- The separate monthly credit pool for `claude -p` announced for 2026-06-15 is paused ("For now, nothing has changed").
- Third-party apps may not offer Claude.ai login, or collect, store or intermediate Claude.ai credentials or session tokens. Ensemble therefore:
  - only spawns the unmodified `claude` binary; it never reads, copies or stores tokens or the keychain entry;
  - removes `ANTHROPIC_API_KEY` from the child environment (in `-p` mode a present key always wins and would bill the API instead of the plan), unless the user picked API-key billing for that agent;
  - never passes `--bare` (bare mode ignores subscription credentials);
  - does not use "Claude Code" or Anthropic names or logos in its own name or icon (plain text "runs Claude Code" is fine);
  - each user signs in with their own subscription; Ensemble never pools or proxies usage.
- Open point: Anthropic's consumer terms ban automated access except via API keys, which the docs never reconcile with the help center's endorsement of signed-in `claude -p`. Before promoting Ensemble widely, ask Anthropic for written confirmation that a local GUI wrapper spawning the user's own `claude` login is fine.

## Flags (claude 2.1.319)
- Streaming: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`, one long-lived process per agent session; resume with the session id.
- Permission modes: `--permission-mode default|acceptEdits|plan|auto|dontAsk|bypassPermissions`. Since 2.1.302 a `-p` run with no mode starts in Manual, where anything needing approval is denied unless an allow rule, hook or prompt tool approves it.
- `--permission-prompts host|none`: `host` sends prompts to the SDK host or the `--permission-prompt-tool`; `none` denies them.
- `--permission-prompt-tool mcp__<server>__<tool>` with `--mcp-config <file>`: Ensemble serves a small MCP tool that forwards each request to the app and returns allow (`{"behavior":"allow","updatedInput":{...}}`) or deny (`{"behavior":"deny","message":"..."}`); confirm the exact return shape by testing (the docs confirm it for the SDK callback). The CLI waits up to 30 s for the MCP server to connect.
- The raw stream-json control messages for permission requests are only documented through the Agent SDK; prefer the prompt tool, which is documented.
- `--max-budget-usd` caps one run using a client-side estimate.
