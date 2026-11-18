#!/bin/bash
# Builds the Mac app from the last commit (not the working folder, so other in-progress edits never break it),
# installs it to /Applications, registers it for Spotlight and Raycast, and reopens it.
# Usage: scripts/install-mac.sh
#
# Signing: when Config/Local.xcconfig names a DEVELOPMENT_TEAM and an "Apple Development" certificate is in the
# keychain, the app is signed with it. Its identity then stays the same from build to build, so the keychain keeps
# "Always Allow" for the pairing code instead of asking again after every install. Otherwise it is signed ad hoc.
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
signing=()
team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Config/Local.xcconfig 2>/dev/null | tr -d '[:space:]')"
if [ -n "$team" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development'; then
  signing=(-allowProvisioningUpdates CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team")
  echo "Signing with your Apple Development certificate"
fi
xcodebuild -project Ensemble.xcodeproj -scheme Ensemble -destination 'platform=macOS' -derivedDataPath "$dd" ${signing[@]+"${signing[@]}"} build \
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
