#!/bin/bash
# Builds the installer for the Mac app: dist/Ensemble-<version>.dmg and dist/SHA256SUMS.
# Usage: scripts/make-installer.sh [--keep]
#
#   --keep   keep the build folder afterwards (its path is printed).
#
# The app is built for Apple silicon only. An Intel build has not been tried on an Intel Mac, so none is made.
#
# What it does:
#   1. Exports the last commit (not the working folder) to a folder under /private/tmp, so nothing uncommitted,
#      no Config/Local.xcconfig and no path with your user name can end up in the app.
#   2. Builds the Release configuration with no signing team.
#   3. Strips debug information and signs the app ad hoc. There is no Developer ID certificate, so the app is not
#      notarized and macOS warns on first launch. docs/INSTALL.md explains that to the people who install it.
#   4. Checks that the app holds no home path, user name, team id, email address or key.
#   5. Puts the app inside "Install Ensemble", the graphical installer, and signs that the same way.
#   6. Makes the disk image (the installer and first launch help) and its SHA-256.
#
# Needs: Xcode (the full app, not only the command line tools), XcodeGen (`brew install xcodegen`), git.
set -euo pipefail

keep=0
for argument in "$@"; do
  case "$argument" in
    --keep) keep=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "error: unknown option $argument (see --help)" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
dist="$repo/dist"

# ---- What this needs ----
command -v git >/dev/null || fail "git is missing. Install the Xcode command line tools: xcode-select --install"
command -v xcodegen >/dev/null || fail "XcodeGen is missing. Install it: brew install xcodegen"
xcodebuild -version >/dev/null 2>&1 \
  || fail "xcodebuild needs the full Xcode app. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
for tool in hdiutil diskutil codesign ditto shasum plutil; do
  command -v "$tool" >/dev/null || fail "$tool is missing (it ships with macOS)"
done
git -C "$repo" rev-parse --verify -q HEAD >/dev/null || fail "$repo has no commit to build"
if git -C "$repo" ls-files --error-unmatch Config/Local.xcconfig >/dev/null 2>&1; then
  fail "Config/Local.xcconfig is committed. It holds a personal signing team and must stay out of the repository."
fi

commit="$(git -C "$repo" rev-parse --short HEAD)"
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  echo "note: uncommitted changes are not part of this build. It is built from commit $commit."
fi

# ---- A clean copy of the last commit, outside the home folder ----
work="$(mktemp -d /private/tmp/ensemble-installer.XXXXXX)"
mount="$work/volume"
cleanup() {
  [ -d "$mount/Install Ensemble.app" ] && diskutil eject "$mount" >/dev/null 2>&1 || true
  if [ "$keep" = 1 ]; then echo "Build folder kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

step "Exporting commit $commit"
mkdir -p "$work/src"
git -C "$repo" archive --format=tar HEAD | tar -x -C "$work/src"
[ ! -e "$work/src/Config/Local.xcconfig" ] || fail "Config/Local.xcconfig reached the export"
layout="$work/src/scripts/installer"
for file in DS_Store "First launch.txt"; do
  [ -f "$layout/$file" ] || fail "scripts/installer/$file is not in commit $commit"
done

cd "$work/src"
xcodegen -q || fail "xcodegen could not generate the project"

# ---- Build ----
archs="arm64"
step "Building Release for $archs (about five minutes)"
log="$work/build.log"
for scheme in Ensemble EnsembleInstaller; do
  if ! xcodebuild -project Ensemble.xcodeproj -scheme "$scheme" -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath "$work/dd" \
      ARCHS="$archs" ONLY_ACTIVE_ARCH=NO \
      CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
      build >>"$log" 2>&1; then
    mkdir -p "$dist"
    cp "$log" "$dist/make-installer.log"
    grep -E "error:|BUILD FAILED" "$log" | head -40 >&2 || true
    fail "the build of $scheme failed. Full log: dist/make-installer.log"
  fi
done
built="$work/dd/Build/Products/Release/Ensemble.app"
built_installer="$work/dd/Build/Products/Release/Install Ensemble.app"
[ -d "$built" ] || fail "the build finished without $built"
[ -d "$built_installer" ] || fail "the build finished without $built_installer"

stage="$work/stage"
mkdir -p "$stage" "$work/payload"
app="$work/payload/Ensemble.app"
ditto "$built" "$app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
[ -n "$version" ] || fail "the app has no version (CFBundleShortVersionString)"

# ---- Strip and sign ----
step "Stripping debug information and signing ad hoc"

sign() {
  # Keeps what Xcode gave the program (its identifier, its entitlements, the hardened runtime), except the
  # debugging entitlement Xcode adds to local builds: a copy for other people must not be open to debuggers.
  # (Building with CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO would drop that one too, and the microphone
  # entitlement with it, which breaks dictation.)
  local target="$1" entitlements="$work/entitlements.plist"
  local options=(--force --sign - --options runtime --timestamp=none --preserve-metadata=identifier)
  rm -f "$entitlements"
  if codesign -d --entitlements - --xml "$target" >"$entitlements" 2>/dev/null && [ -s "$entitlements" ]; then
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements" >/dev/null 2>&1 || true
    options+=(--entitlements "$entitlements")
  fi
  codesign "${options[@]}" "$target" 2>/dev/null || fail "codesign failed for $target"
}
# Strips and signs one app: every program in it (helpers before the main program), then the app itself.
# Programs inside a nested app (the installer's copy of Ensemble) are left alone: that app is already done.
finish_app() {
  local bundle="$1" main program
  main="$bundle/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist")"
  [ -f "$main" ] || fail "$bundle has no main program"
  while IFS= read -r program; do
    if file -b "$program" | grep -q "Mach-O"; then
      xcrun strip -S -x "$program" 2>/dev/null || fail "strip failed for $program"
      [ "$program" = "$main" ] || sign "$program"
    fi
  done < <(find "$bundle/Contents" -type f -perm +111 ! -path "$bundle/Contents/Resources/*.app/*")
  sign "$bundle"
  codesign --verify --deep --strict "$bundle" || fail "$(basename "$bundle") does not verify after signing"
  local signature kept
  signature="$(codesign -dvv "$bundle" 2>&1)"
  echo "$signature" | grep -q "^Signature=adhoc" || fail "$(basename "$bundle") is not signed ad hoc"
  echo "$signature" | grep -q "^TeamIdentifier=not set" || fail "the signature of $(basename "$bundle") names a team"
  kept="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  case "$kept" in *get-task-allow*) fail "$(basename "$bundle") carries the debugging entitlement (get-task-allow)" ;; esac
}
finish_app "$app"
kept="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
# The app asks for the microphone (dictation). Under the hardened runtime that needs the entitlement too.
if plutil -extract NSMicrophoneUsageDescription raw "$app/Contents/Info.plist" >/dev/null 2>&1; then
  case "$kept" in
    *com.apple.security.device.audio-input*) ;;
    *) fail "the app lost its microphone entitlement, so dictation would not work" ;;
  esac
fi
built_archs="$(lipo -archs "$app/Contents/MacOS/Ensemble")"

# The installer carries the finished app in its Resources, so the app is signed first and the installer after it.
installer="$stage/Install Ensemble.app"
ditto "$built_installer" "$installer"
ditto "$app" "$installer/Contents/Resources/Ensemble.app"
finish_app "$installer"
codesign --verify --deep --strict "$installer/Contents/Resources/Ensemble.app" || fail "the app inside the installer does not verify"

# ---- Nothing personal in the bundle ----
step "Checking the installer and the app for personal details and keys"
needles=("$HOME")
login="$(id -un)"
[ "${#login}" -ge 6 ] && needles+=("$login")
email="$(git -C "$repo" config user.email || true)"
case "$email" in ""|*noreply*) ;; *) needles+=("$email") ;; esac
team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$repo/Config/Local.xcconfig" 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "$team" ] && needles+=("$team")
for needle in "${needles[@]}"; do
  if found="$(grep -rlF -- "$needle" "$installer" | head -5)" && [ -n "$found" ]; then
    echo "$found" >&2
    fail "the installer contains \"$needle\" (files above)"
  fi
done
# Shapes of real keys: Anthropic, OpenAI, GitHub, AWS, Slack, Google, private key blocks.
keys='sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|BEGIN [A-Z ]*PRIVATE KEY'
if found="$(grep -rlaE -- "$keys" "$installer" | head -5)" && [ -n "$found" ]; then
  echo "$found" >&2
  fail "the installer contains something shaped like a key (files above)"
fi
[ -z "$(find "$installer" -name embedded.provisionprofile)" ] || fail "the installer holds a provisioning profile"
echo "Clean: no home path, user name, team id, email address or key."

# ---- Disk image ----
step "Making the disk image"
cp "$layout/First launch.txt" "$stage/"
cp "$layout/DS_Store" "$stage/.DS_Store"
mkdir -p "$dist" "$mount"
dmg="$dist/Ensemble-$version.dmg"
rm -f "$dmg"
# macOS 27 replaces `hdiutil create` and `hdiutil attach` with `diskutil image`. Use it where it exists.
# `diskutil image create from <folder>` leaves .DS_Store (the window layout) out, so the files go onto a blank
# writable image first, and that image is then compressed.
if diskutil image create from --help >/dev/null 2>&1; then
  megabytes=$(( $(du -sm "$stage" | cut -f1) + 40 ))
  {
    diskutil image create blank --format RAW --size "${megabytes}m" --volumeName "Ensemble $version" --fs APFS "$work/writable.dmg" \
      && diskutil image attach --nobrowse --mountPoint "$mount" "$work/writable.dmg" \
      && ditto "$stage" "$mount" \
      && diskutil eject "$mount" \
      && diskutil image create from --format ULMO "$work/writable.dmg" "$dmg" \
      && diskutil image attach --readOnly --nobrowse --mountPoint "$mount" "$dmg"
  } >"$work/image.log" 2>&1 || { cat "$work/image.log" >&2; fail "diskutil could not make $dmg"; }
  rm -f "$work/writable.dmg"
else
  hdiutil create -quiet -volname "Ensemble $version" -srcfolder "$stage" -fs HFS+ -format ULMO "$dmg" \
    || fail "hdiutil could not make $dmg"
  hdiutil attach "$dmg" -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" \
    || fail "the disk image does not mount"
fi

# The image must hold what was staged, and the app inside must still verify.
[ -d "$mount/Install Ensemble.app" ] || fail "the disk image has no Install Ensemble.app"
[ -d "$mount/Install Ensemble.app/Contents/Resources/Ensemble.app" ] || fail "the installer on the disk image has no Ensemble.app inside"
[ -f "$mount/First launch.txt" ] || fail "the disk image has no First launch.txt"
[ -f "$mount/.DS_Store" ] || fail "the disk image has no window layout (.DS_Store)"
codesign --verify --deep --strict "$mount/Install Ensemble.app" || fail "the installer on the disk image does not verify"
codesign --verify --deep --strict "$mount/Install Ensemble.app/Contents/Resources/Ensemble.app" \
  || fail "the app inside the installer on the disk image does not verify"
diskutil eject "$mount" >/dev/null || fail "the disk image did not eject"
hdiutil verify -quiet "$dmg" || fail "the disk image does not verify"

(cd "$dist" && shasum -a 256 "Ensemble-$version.dmg" >SHA256SUMS)
rm -f "$dist/make-installer.log"

step "Done"
echo "Disk image: $dmg"
echo "Size:       $(du -h "$dmg" | cut -f1 | tr -d ' ')"
echo "Built from: commit $commit, version $version, $built_archs"
echo "SHA-256:    $(cut -d' ' -f1 "$dist/SHA256SUMS")"
