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
  [ -n "$mounted" ] && diskutil eject "$mounted" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Stand-ins with the real names: Finder saves each icon's place under its file name.
mkdir -p "$work/stage/Ensemble.app/Contents"
ln -s /Applications "$work/stage/Applications"
cp "$here/First launch.txt" "$work/stage/"
# A writable scratch image. macOS 27 replaces `hdiutil create` and `hdiutil attach` with `diskutil image`.
if diskutil image create blank --help >/dev/null 2>&1; then
  diskutil image create blank --format RAW --size 20m --volumeName "$volume" --fs APFS "$work/layout.dmg" >/dev/null
  diskutil image attach "$work/layout.dmg" >/dev/null
else
  hdiutil create -quiet -size 20m -fs HFS+ -volname "$volume" "$work/layout.dmg"
  hdiutil attach "$work/layout.dmg" -quiet -readwrite -noautoopen
fi
mounted="/Volumes/$volume"
[ -d "$mounted" ] || { echo "error: could not mount the scratch disk image" >&2; exit 1; }
ditto "$work/stage" "$mounted"

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
    set bounds of container window to {240, 160, 840, 590}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    set shows item info of viewOptions to false
    set position of item "Ensemble.app" of container window to {150, 110}
    set position of item "Applications" of container window to {450, 110}
    set position of item "First launch.txt" of container window to {300, 280}
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
