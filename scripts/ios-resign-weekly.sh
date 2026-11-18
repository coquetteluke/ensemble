#!/bin/bash
# Rebuilds Ensemble Remote and reinstalls it on a connected iPhone, so the 7-day signature from a free
# Apple developer account never runs out. Meant for a launchd job (see com.ensemble.ios-resign.plist.template)
# that runs daily: the script only rebuilds when the last install is older than ENSEMBLE_RESIGN_DAYS days.
#
# Usage:
#   scripts/ios-resign-weekly.sh [--device "Name or UDID"] [--force] [--configuration Debug|Release]
#
# Environment:
#   ENSEMBLE_DEVICE        device name or UDID (default: first paired, connected iPhone)
#   ENSEMBLE_RESIGN_DAYS   rebuild when the last install is at least this many days old (default 5)
#
# Signing uses DEVELOPMENT_TEAM from Config/Local.xcconfig (not committed).
# Exit codes: 0 installed or not due yet, 2 no iPhone connected, 1 build or install failed.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$HOME/Library/Application Support/Ensemble"
LOG_DIR="$HOME/Library/Logs/Ensemble"
STAMP="$STATE_DIR/ios-resign-last-success"
DERIVED="$REPO/build/dd-resign"
SCHEME="EnsembleRemote"
APP_NAME="Ensemble Remote.app"

DEVICE="${ENSEMBLE_DEVICE:-}"
DAYS="${ENSEMBLE_RESIGN_DAYS:-5}"
CONFIGURATION="Debug"
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$STATE_DIR" "$LOG_DIR"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() {
    /usr/bin/osascript -e "display notification \"$1\" with title \"Ensemble Remote\"" >/dev/null 2>&1 || true
}

# Not due yet?
if [[ $FORCE -eq 0 && -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    age_days=$(( (now - last) / 86400 ))
    if (( age_days < DAYS )); then
        log "Last install was $age_days days ago (rebuild after $DAYS). Nothing to do."
        exit 0
    fi
fi

# Pick the device.
DEVICES_JSON="$(mktemp -t ensemble-devices)"
trap 'rm -f "$DEVICES_JSON"' EXIT
if ! xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1; then
    log "devicectl could not list devices."
    exit 1
fi

read -r DEVICE_ID DEVICE_UDID DEVICE_NAME < <(/usr/bin/python3 -I - "$DEVICES_JSON" "$DEVICE" <<'PY'
import json, sys
path, wanted = sys.argv[1], sys.argv[2].strip()
devices = json.load(open(path)).get("result", {}).get("devices", [])
def fields(d):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    props = d.get("deviceProperties", {})
    return (d.get("identifier", ""), hw.get("udid", ""), props.get("name", ""), hw.get("deviceType", ""),
            conn.get("pairingState", ""), conn.get("tunnelState", ""))
chosen = None
for d in devices:
    ident, udid, name, kind, pairing, tunnel = fields(d)
    if wanted:
        if wanted in (ident, udid, name):
            chosen = (ident, udid, name)
            break
    elif kind == "iPhone" and pairing == "paired" and tunnel != "unavailable":
        chosen = (ident, udid, name)
        break
if chosen:
    print(chosen[0], chosen[1], chosen[2].replace(" ", "_"))
else:
    print("- - -")
PY
)

if [[ "$DEVICE_ID" == "-" || -z "$DEVICE_ID" ]]; then
    log "No paired iPhone connected${DEVICE:+ matching \"$DEVICE\"}. Will try again next run."
    exit 2
fi
log "Device: ${DEVICE_NAME//_/ } ($DEVICE_UDID)"

cd "$REPO"
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen >/dev/null
else
    log "xcodegen is not installed (brew install xcodegen)."
    exit 1
fi

log "Building $SCHEME ($CONFIGURATION)"
if ! xcodebuild -project Ensemble.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination "id=$DEVICE_UDID" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build \
        > "$LOG_DIR/ios-resign-build.log" 2>&1; then
    log "Build failed. See $LOG_DIR/ios-resign-build.log"
    notify "Weekly rebuild failed. See ~/Library/Logs/Ensemble/ios-resign-build.log"
    exit 1
fi

APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/$APP_NAME"
if [[ ! -d "$APP" ]]; then
    log "Built app not found at $APP"
    exit 1
fi

log "Installing on the iPhone"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG_DIR/ios-resign-build.log" 2>&1; then
    log "Install failed (is the iPhone unlocked?). See $LOG_DIR/ios-resign-build.log"
    notify "Could not install on the iPhone. Unlock it and try again."
    exit 1
fi

date +%s > "$STAMP"
log "Installed. The signature is good for another 7 days."
