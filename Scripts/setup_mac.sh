#!/usr/bin/env bash
# One-time Mac setup for building Goose onto a physical iPhone.
#
# Checks Xcode, installs the Rust iOS targets, and writes Config/Local.xcconfig
# with your Apple Developer Team ID and a bundle identifier you own.
#
# Usage:
#   Scripts/setup_mac.sh                                  # interactive
#   TEAM_ID=ABCDE12345 BUNDLE_ID=com.me.goose Scripts/setup_mac.sh
#
# Without a terminal (e.g. run by an agent) it never prompts: it installs
# missing Rust, detects the Team ID from your Apple Development certificate,
# and defaults the bundle ID.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_XCCONFIG="$APP_DIR/Config/Local.xcconfig"
MIN_XCODE_MAJOR=26
RUST_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ask <prompt> <default>: prompt only when a person is at the terminal.
ask() {
  local reply=""
  if [[ -t 0 ]]; then
    read -r -p "$1" reply || true
  fi
  printf '%s\n' "${reply:-$2}"
}

# The OU field of the Apple Development certificate Xcode creates for your
# account is your Team ID.
detect_team_id() {
  security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -Eo 'OU ?= ?[A-Z0-9]{10}' | head -n1 | grep -Eo '[A-Z0-9]{10}$' || true
}

echo "Goose Mac setup"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must run on macOS. iOS apps can only be built with Xcode on a Mac."
fi

echo "1. Xcode"
if ! xcode_path="$(xcode-select -p 2>/dev/null)" || [[ "$xcode_path" != *Xcode*.app* ]]; then
  fail "Full Xcode is not selected. Install Xcode from the App Store, open it once, then run:
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  fail "xcodebuild cannot run. Accept the Xcode license first: sudo xcodebuild -license accept"
fi
xcode_version="$(xcodebuild -version | head -n1 | awk '{print $2}')"
if (( ${xcode_version%%.*} < MIN_XCODE_MAJOR )); then
  fail "Xcode $xcode_version found; Goose targets iOS 26 and needs Xcode $MIN_XCODE_MAJOR or newer."
fi
ok "Xcode $xcode_version at $xcode_path"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  if [[ -t 0 ]]; then
    warn "Xcode needs first-launch setup. Running: sudo xcodebuild -runFirstLaunch"
    sudo xcodebuild -runFirstLaunch
  else
    fail "Xcode needs first-launch setup. Run this in Terminal, then re-run: sudo xcodebuild -runFirstLaunch"
  fi
fi

echo
echo "2. Rust"
if ! command -v rustup >/dev/null 2>&1; then
  answer="$(ask "  rustup is not installed. Install it now from https://rustup.rs? [Y/n] " Y)"
  if [[ "$answer" =~ ^[Nn] ]]; then
    fail "Rust is required. Install it from https://rustup.rs and re-run this script."
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  export PATH="$HOME/.cargo/bin:$PATH"
fi
rustup update stable >/dev/null
ok "$(rustc --version)"
rustup target add "${RUST_TARGETS[@]}" >/dev/null
ok "iOS targets: ${RUST_TARGETS[*]}"

echo
echo "3. Signing"
if [[ -f "$LOCAL_XCCONFIG" ]]; then
  ok "Config/Local.xcconfig already exists:"
  sed 's/^/      /' "$LOCAL_XCCONFIG"
else
  echo "  You need an Apple ID signed in to Xcode (Xcode > Settings > Accounts)."
  echo "  A free Personal Team works; the app then expires after 7 days and must be reinstalled."
  echo
  echo "  Signing identities found in your keychain:"
  security find-identity -v -p codesigning 2>/dev/null | sed 's/^/      /' || true
  echo
  detected_team="$(detect_team_id)"
  if [[ -n "$detected_team" ]]; then
    echo "  Detected Team ID $detected_team from your Apple Development certificate."
  else
    echo "  No Apple Development certificate found. In Xcode > Settings > Accounts, select"
    echo "  your Apple ID > Manage Certificates > + > Apple Development, then re-run."
  fi
  team_id="${TEAM_ID:-$(ask "  Team ID [${detected_team:-blank = pick the team in Xcode}]: " "$detected_team")}"
  default_bundle="com.$(whoami | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]').goose"
  bundle_id="${BUNDLE_ID:-$(ask "  Bundle ID [$default_bundle]: " "$default_bundle")}"
  cat > "$LOCAL_XCCONFIG" <<EOF
// Personal signing settings. Gitignored; created by Scripts/setup_mac.sh.
DEVELOPMENT_TEAM = $team_id
GOOSE_BUNDLE_ID = $bundle_id
EOF
  ok "Wrote Config/Local.xcconfig"
fi

echo
echo "Setup complete. Next:"
echo "  1. Plug your iPhone in with a cable, unlock it, and tap 'Trust This Computer'."
echo "  2. On the iPhone: Settings > Privacy & Security > Developer Mode > On (restart required)."
echo "  3. Run: Scripts/deploy_to_iphone.sh"
