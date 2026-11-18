#!/bin/bash
# Builds the Mac app from the last commit (not the working folder, so other in-progress edits never break it),
# installs it to /Applications, registers it for Spotlight and Raycast, and reopens it.
# Usage: scripts/install-mac.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="${TMPDIR:-/tmp}/ensemble-install-$$"
dd="${TMPDIR:-/tmp}/ensemble-install-dd"
cleanup() { git -C "$repo" worktree remove --force "$work" >/dev/null 2>&1 || true; }
trap cleanup EXIT

git -C "$repo" worktree add -q "$work" HEAD
[ -f "$repo/Config/Local.xcconfig" ] && cp "$repo/Config/Local.xcconfig" "$work/Config/"
cd "$work"
xcodegen -q
xcodebuild -project Ensemble.xcodeproj -scheme Ensemble -destination 'platform=macOS' -derivedDataPath "$dd" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
app="$dd/Build/Products/Debug/Ensemble.app"
[ -d "$app" ] || { echo "build failed"; exit 1; }

pkill -x Ensemble 2>/dev/null || true
sleep 1
rm -rf /Applications/Ensemble.app
cp -R "$app" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Ensemble.app
open /Applications/Ensemble.app
echo "Installed /Applications/Ensemble.app from $(git -C "$repo" rev-parse --short HEAD)"
