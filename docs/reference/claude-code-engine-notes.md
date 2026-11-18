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
- The CLI's plan mode alone is not read-only: `echo hi > shell.txt` ran without a prompt, approved by the auto-mode classifier. While a session is in Plan, Ensemble adds to `permissions.ask` with `apply_flag_settings`: every shell tool (Bash, PowerShell, Monitor), every edit tool (Edit, MultiEdit, Write, NotebookEdit), worktree switches, tools with outside effects (CronCreate, CronDelete, RemoteTrigger, ScheduleWakeup, SendMessage, SendToProject, SendToProjectContext, PushNotification, DesignSync, Workflow) and all MCP tools (`mcp__*`, checked live: without the rule an MCP tool ran with no prompt). Setting the list back lifts it.
- The guard fails closed: it is a tracked control request whose reply is checked before any turn in Plan is sent. If the CLI refuses it or does not answer, nothing is written to the agent and the process stops; switching a running session into Plan rolls back to the previous mode if the guard cannot be confirmed.
- Second layer: in Plan, Ensemble decides every prompt itself whatever the CLI suggests. File-changing tools are refused, everything else waits for the user; the only write allowed is the CLI's own plan file (a `.md` directly in `~/.claude/plans`, links resolved). Remembered "Always" rules approve nothing in Plan.
- `AskUserQuestion` arrives as `can_use_tool` with `input.questions` (`question`, `header`, `options` with `label` and `description`, `multiSelect`) and `requires_user_interaction`. The answer is an allow whose `updatedInput` is the input plus `answers`, a map from question text to the chosen label (several joined with ", ", or the typed text); the agent then reads `"<question>"="<answer>"`. A deny declines.

## Models and context windows (checked 2026-11-18, claude 2.1.319)
How it was checked, with no prompt sent and no tokens used: one short `claude -p --input-format stream-json --output-format stream-json --verbose --permission-mode default --no-session-persistence --setting-sources ""` process per model (`--model <id>`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` removed, signed in with the subscription), asked `initialize` and then `get_context_usage`. Only the model and fast-mode parts of the answers were read; the account part was not printed or kept.
- `initialize` lists, in this order: `default` (resolves to `claude-opus-5-5`), `opus` (Opus 5.5), `claude-fable-5-2` (Fable 5.2), `sonnet` (Sonnet 5.5), `haiku` (Haiku 5.5), `fable` (Fable 5.1), then older full ids: `claude-haiku-4-5-20251001`, `claude-sonnet-5`, `claude-opus-5`, `claude-fable-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-6`. No `[1m]` ids are listed.
- The `fable` alias still resolves to Fable 5.1. The newest Fable (5.2) is only reachable by its full id, so Ensemble lists `claude-fable-5-2` as "Fable 5.2" and `fable` under Older models.
- Fast mode: `supportsFastMode` is true for `default`, `opus`, `claude-opus-5` and `claude-opus-4-8` only. With no fast-mode flag the answer says `fast_mode_state: off`, `fast_mode_disabled_reason: sdk_opt_in_required`; Ensemble opts in with `--fast-mode on|off` at launch and `apply_flag_settings {fastMode}` live.
- Context windows (`get_context_usage` `rawMaxTokens`, the number `/context` shows and autocompact uses):
  - 1,000,000 with the plain id: `opus`, `sonnet`, `haiku`, `fable`, `claude-fable-5-2`, `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-opus-4-8`, `claude-opus-4-7`. The `[1m]` suffix changes nothing for these (`opus[1m]` and `sonnet[1m]` also answer 1,000,000), so the catalog has one entry per model with the plain alias, and the old 200k entries are gone.
  - 200,000: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`. For the two 4.6 models the `[1m]` id raises it to 1,000,000 (`autocompactSource: auto`); Ensemble lists their plain ids.
- A turn still reports the real window in `result.modelUsage.<model>.contextWindow`; that number wins over the catalog when present.
- The old picker's "200k context" came from Ensemble's own catalog (`opus` and `sonnet` were written down as 200k next to separate `[1m]` entries), not from the CLI.
