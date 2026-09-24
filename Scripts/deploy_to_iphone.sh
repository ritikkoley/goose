#!/usr/bin/env bash
# Build Goose (Rust core + Swift app) and install it on a connected iPhone.
#
# Usage:
#   Scripts/deploy_to_iphone.sh              # first paired iPhone found
#   DEVICE=<udid-or-name> Scripts/deploy_to_iphone.sh
#   LAUNCH_ARGS="--goose-enable-diagnostics" Scripts/deploy_to_iphone.sh
#   CONFIGURATION=Release Scripts/deploy_to_iphone.sh
#   NO_LAUNCH=1 Scripts/deploy_to_iphone.sh  # install without launching
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="$APP_DIR/build/DerivedData-device"
LOCAL_XCCONFIG="$APP_DIR/Config/Local.xcconfig"

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: run this on a Mac with Xcode installed." >&2
  exit 1
fi
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  echo "error: Config/Local.xcconfig is missing. Run Scripts/setup_mac.sh first." >&2
  exit 1
fi

if [[ -z "${DEVICE:-}" ]]; then
  devices_json="$(mktemp)"
  trap 'rm -f "$devices_json"' EXIT
  xcrun devicectl list devices --json-output "$devices_json" >/dev/null
  DEVICE="$(/usr/bin/python3 - "$devices_json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
iphones = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("deviceType", "iPhone") == "iPhone"
    and d.get("hardwareProperties", {}).get("udid")
]
# Prefer phones that are reachable now over stale pairings.
iphones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") == "unavailable")
if iphones:
    print(iphones[0]["hardwareProperties"]["udid"])
PY
)"
  if [[ -z "$DEVICE" ]]; then
    echo "error: no iPhone found. Connect it by cable, unlock it, tap 'Trust', enable Developer Mode," >&2
    echo "       then check 'xcrun devicectl list devices'." >&2
    exit 1
  fi
fi
echo "Target iPhone: $DEVICE"
if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{20,}$ ]]; then
  destination="platform=iOS,id=$DEVICE"
else
  destination="platform=iOS,name=$DEVICE"
fi

bundle_id="$(sed -n 's/^[[:space:]]*GOOSE_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$LOCAL_XCCONFIG" | tail -n1)"
bundle_id="${bundle_id:-com.goose.swift}"

echo "Building $CONFIGURATION (first build compiles the Rust core and takes a few minutes)..."
xcodebuild \
  -project "$APP_DIR/GooseSwift.xcodeproj" \
  -scheme GooseSwift \
  -configuration "$CONFIGURATION" \
  -destination "$destination" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/GooseSwift.app"
echo "Installing $app_path"
xcrun devicectl device install app --device "$DEVICE" "$app_path"

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  echo "Launching $bundle_id"
  # shellcheck disable=SC2086 # LAUNCH_ARGS is intentionally word-split into app arguments.
  if ! xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$bundle_id" ${LAUNCH_ARGS:-}; then
    echo "Launch failed. With a free Personal Team, trust the developer first on the iPhone:"
    echo "  Settings > General > VPN & Device Management > (your Apple ID) > Trust"
    echo "then open Goose from the home screen."
  fi
fi
