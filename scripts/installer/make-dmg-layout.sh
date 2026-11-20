#!/bin/bash
# Rebuilds scripts/installer/DS_Store: the saved window layout of the disk image (icon places, icon size,
# window size). Only needed when the layout changes; make-installer.sh just copies the saved file.
# It asks Finder to arrange a scratch disk image, so it needs a logged-in desktop and permission to control Finder.
# Usage: scripts/installer/make-dmg-layout.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /private/tmp/ensemble-layout.XXXXXX)"
volume="Ensemble layout $$"
mounted=""
cleanup() {
  [ -n "$mounted" ] && hdiutil detach "$mounted" -quiet >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Stand-ins with the real names: Finder saves each icon's place under its file name.
mkdir -p "$work/stage/Ensemble.app/Contents"
ln -s /Applications "$work/stage/Applications"
cp "$here/First launch.txt" "$work/stage/"
hdiutil create -quiet -volname "$volume" -srcfolder "$work/stage" -fs HFS+ -format UDRW "$work/layout.dmg"
mounted="$(hdiutil attach "$work/layout.dmg" -readwrite -noautoopen | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)"
[ -d "$mounted" ] || { echo "error: could not mount the scratch disk image" >&2; exit 1; }

osascript <<SCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set pathbar visible of container window to false
    end try
    set bounds of container window to {240, 160, 840, 600}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set shows item info of viewOptions to false
    set position of item "Ensemble.app" of container window to {150, 140}
    set position of item "Applications" of container window to {450, 140}
    set position of item "First launch.txt" of container window to {300, 320}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
SCRIPT

# Finder writes the layout a moment after the window closes.
sync
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$mounted/.DS_Store" ] && break
  sleep 1
done
[ -s "$mounted/.DS_Store" ] || { echo "error: Finder did not save a layout" >&2; exit 1; }
cp "$mounted/.DS_Store" "$here/DS_Store"
echo "Saved $here/DS_Store"
