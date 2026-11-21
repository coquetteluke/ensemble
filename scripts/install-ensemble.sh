#!/bin/bash
# Installs Ensemble on this Mac from the terminal, with no installer window. Made for AI assistants and for people
# who prefer a command. It does what the Install Ensemble app does:
#   1. Downloads the newest release and checks it against the SHA-256 published with it.
#   2. Copies Ensemble to Applications (or ~/Applications when that folder may not be changed).
#   3. Installs the engine, OpenCode, if it is missing: downloaded from OpenCode's own releases, checked against
#      OpenCode's checksum and signature, put in ~/.opencode/bin.
#   4. Opens Ensemble.
# It needs no password and no sudo, changes no system setting, and removes its temporary files.
#
# Usage: bash install-ensemble.sh [--no-open] [--skip-engine]
#
# For testing only: ENSEMBLE_RELEASES_JSON=<file> reads a saved release list (its files may be on disk), and
# anything after "--" is passed to the installer (for example --destination <folder>).
set -euo pipefail

repository="coquetteluke/ensemble"
open_flag="--open"
engine_flag=""
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-open) open_flag="" ;;
    --skip-engine) engine_flag="--skip-engine" ;;
    --) shift; extra=("$@"); break ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Ensemble is a Mac app."
[ "$(uname -m)" = "arm64" ] || fail "Ensemble needs a Mac with Apple silicon. There is no Intel build."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "Ensemble needs macOS 26 or later. This Mac has $(sw_vers -productVersion)."

work="$(mktemp -d /private/tmp/ensemble-install.XXXXXX)"
mount="$work/volume"
cleanup() {
  [ -d "$mount/Install Ensemble.app" ] && diskutil eject "$mount" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# ---- Find the newest release that has the disk image and its checksums ----
echo "Finding the newest Ensemble release"
if [ -n "${ENSEMBLE_RELEASES_JSON:-}" ]; then
  cp "$ENSEMBLE_RELEASES_JSON" "$work/releases.json"
else
  curl -fsSL --max-time 60 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$repository/releases?per_page=10" -o "$work/releases.json" \
    || fail "could not reach GitHub to list the releases of $repository"
fi
image_url=""
image_name=""
sums_url=""
tag=""
# The list is newest first. Take the first release that is not a draft and has both files.
for r in 0 1 2 3 4 5 6 7 8 9; do
  candidate="$(plutil -extract "$r.tag_name" raw -o - "$work/releases.json" 2>/dev/null)" || break
  [ "$(plutil -extract "$r.draft" raw -o - "$work/releases.json" 2>/dev/null)" = "true" ] && continue
  image_url=""
  sums_url=""
  assets="$(plutil -extract "$r.assets" raw -o - "$work/releases.json" 2>/dev/null || echo 0)"
  for ((a = 0; a < assets; a++)); do
    name="$(plutil -extract "$r.assets.$a.name" raw -o - "$work/releases.json")"
    url="$(plutil -extract "$r.assets.$a.browser_download_url" raw -o - "$work/releases.json")"
    case "$name" in
      Ensemble-*.dmg) image_url="$url"; image_name="$name" ;;
      SHA256SUMS) sums_url="$url" ;;
    esac
  done
  if [ -n "$image_url" ] && [ -n "$sums_url" ]; then
    tag="$candidate"
    break
  fi
done
[ -n "$tag" ] || fail "no release of $repository has both a disk image and SHA256SUMS"
if [ -z "${ENSEMBLE_RELEASES_JSON:-}" ]; then
  for address in "$image_url" "$sums_url"; do
    case "$address" in
      "https://github.com/$repository/releases/download/"*) ;;
      *) fail "the release points at an unexpected address: $address" ;;
    esac
  done
fi

# ---- Download and check ----
echo "Downloading $image_name ($tag)"
curl -fL --max-time 900 -s -o "$work/$image_name" "$image_url" || fail "the download of $image_name failed"
curl -fL --max-time 60 -s -o "$work/SHA256SUMS" "$sums_url" || fail "the download of SHA256SUMS failed"
(cd "$work" && grep -F "  $image_name" SHA256SUMS | shasum -a 256 -c - >/dev/null) \
  || fail "$image_name does not match its published SHA-256. Nothing was installed."
echo "Checksum matches"

# ---- Mount it out of sight and run the installer without its window ----
mkdir -p "$mount"
if diskutil image attach --help >/dev/null 2>&1; then
  diskutil image attach --readOnly --nobrowse --mountPoint "$mount" "$work/$image_name" >/dev/null || fail "the disk image did not mount"
else
  hdiutil attach "$work/$image_name" -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" || fail "the disk image did not mount"
fi
installer="$mount/Install Ensemble.app/Contents/MacOS/Install Ensemble"
[ -x "$installer" ] || fail "this release has no Install Ensemble app (it is older than the installer)"
codesign --verify --deep --strict "$mount/Install Ensemble.app" || fail "the installer on the disk image is damaged"

status=0
"$installer" --unattended $open_flag $engine_flag ${extra[@]+"${extra[@]}"} || status=$?
case "$status" in
  0) echo "Done: Ensemble $tag is installed." ;;
  3) echo "Ensemble $tag is installed, but the engine is not. Open Ensemble and press Install the engine." ;;
  *) fail "the install did not finish (see the lines above)" ;;
esac
exit "$status"
