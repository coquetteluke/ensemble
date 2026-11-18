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

## Anthropic support's answer (2026-11-18, first reply; a human reply is pending)

Asked through support.claude.com whether Ensemble's design is allowed. The support assistant's summary of the published policies:

- Supported: an end user signing in to the unmodified Claude Code binary with their own Claude subscription.
- Not allowed: apps collecting, storing or intermediating Claude.ai credentials or session tokens (sign-in must go through Anthropic's own flow); routing requests through Free, Pro, Max or Ultra plan credentials on behalf of other users; using Anthropic or Claude Code names or logos in the product name or logo, or implying endorsement (saying in plain text that it runs Claude Code is fine); apps that misrepresent their identity to Anthropic's servers or route third-party traffic against subscription limits.
- Not decided by published policy: approval of a specific app, publishing it publicly, limits on concurrent processes or scheduled runs. For developer-facing products the recommended path is API keys.

What this means for Ensemble:
- Keep running only the unmodified `claude` binary as itself (no changed user agent, no proxying, no token handling).
- A Claude subscription in Ensemble serves only its owner. The iPhone remote pairs only the owner's own devices; Ensemble must never let other people send work through someone else's Claude plan (no shared rooms, no hosted mode on a subscription).
- Offer Claude through an API key as well, and say in the README that subscription mode is for your own personal use under Anthropic's terms.

## How the engine answers permission prompts (2026-11-18)
- Uses the CLI's stream-json control channel (`--permission-prompts host --permission-prompt-tool stdio`): prompts arrive as `can_use_tool` requests on the process's stdout and are answered on stdin. No port or helper process, so nothing else on the Mac can answer a prompt. These flags are accepted by 2.1.319 but are not in `claude --help`; re-check on CLI updates.
- "Always" rules are kept in Ensemble (the CLI is not sent `updatedPermissions`), matched with a shell-word parser.
- Ensemble's Auto maps to Claude Code's own auto mode, where Anthropic's classifier approves most actions. Kept on purpose: it is the behaviour Luke uses daily in Claude Code. OpenCode agents use Ensemble's stricter allowlist until Ensemble has its own AI safety check.
- Subscription agents report costUSD 0 and show plan limits (`planLimits()`: five-hour and weekly use, reset time); spending caps do not apply to them.
- Rewind restores only files changed by Claude's edit tools.

## Plan mode and questions (checked 2026-11-18, claude 2.1.319)
- Ensemble's Plan is `--permission-mode plan` (or `set_permission_mode` `plan` live). The agent ends with `ExitPlanMode`, which arrives as a `can_use_tool` request with `input.plan` (Markdown) and `input.planFilePath` (the CLI's own file under `~/.claude/plans`, which plan mode writes without asking). Allow means Proceed; a deny with a message means Keep planning: the agent reads the message, revises and calls `ExitPlanMode` again in the same turn.
- Proceed first sends `set_permission_mode` with the chosen mode, then the allow, so the rest of the turn runs in that mode.
- The CLI's plan mode alone is not read-only: `echo hi > shell.txt` ran without a prompt, approved by the auto-mode classifier. While a session is in Plan, Ensemble adds `Bash` to `permissions.ask` with `apply_flag_settings` (then the command comes as a prompt; setting the list back lifts it) and refuses file edits itself. Remembered "Always" rules approve nothing in Plan.
- `AskUserQuestion` arrives as `can_use_tool` with `input.questions` (`question`, `header`, `options` with `label` and `description`, `multiSelect`) and `requires_user_interaction`. The answer is an allow whose `updatedInput` is the input plus `answers`, a map from question text to the chosen label (several joined with ", ", or the typed text); the agent then reads `"<question>"="<answer>"`. A deny declines.
