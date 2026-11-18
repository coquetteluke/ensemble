#!/bin/zsh
# Runs EnsembleKit's live engine tests: the real local OpenCode service plus the scripted mock model
# (tools/mock-llm). Needs `opencode` 2.3+ installed; starts the shared service if it is not running and leaves it
# running. Each test uses a temporary project folder and deletes the sessions it creates. No API keys are used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v opencode >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/opencode ]; then
  echo "opencode is not installed (brew install opencode)." >&2
  exit 1
fi
OPENCODE="$(command -v opencode || echo /opt/homebrew/bin/opencode)"

# Make sure the background service is up (start only; never stop the shared service).
if ! "$OPENCODE" api get /api/info >/dev/null 2>&1; then
  echo "Starting the OpenCode service..."
  "$OPENCODE" service start >/dev/null
fi

cd "$ROOT/Packages/EnsembleKit"
ENSEMBLE_LIVE_TESTS=1 swift test --filter LiveEngineTests "$@"
