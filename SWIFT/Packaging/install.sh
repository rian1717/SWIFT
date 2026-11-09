#!/bin/bash
# Builds SWIFT from source and installs it, in one command:
#
#   git clone https://github.com/rian1717/SWIFT.git
#   cd SWIFT
#   SWIFT/Packaging/install.sh
#
# INSTALL_DIR=<folder>  installs somewhere other than /Applications
# NO_OPEN=1             does not open the app afterwards
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILT="$(dirname "$HERE")/build/SWIFT.app"
DEST_DIR="${INSTALL_DIR:-/Applications}"

fail() { echo "✗ $1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "SWIFT is a Mac app. Run this on a Mac."
VERSION="$(sw_vers -productVersion)"
(( ${VERSION%%.*} >= 26 )) || fail "SWIFT needs macOS 26 or newer. This Mac has macOS $VERSION."
command -v xcodebuild >/dev/null ||
  fail "Xcode is not installed. Install Xcode 26 or newer from the App Store, open it once, then run this again."
xcodebuild -version >/dev/null 2>&1 ||
  fail "Xcode is installed but not ready. Run: sudo xcodebuild -license accept
   and, if it still fails: sudo xcode-select -s /Applications/Xcode.app"

"$HERE/build-app.sh" release

mkdir -p "$DEST_DIR" 2>/dev/null || true
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "  /Applications is not writable here, so SWIFT goes to $DEST_DIR."
fi

# Replace a running copy cleanly, but only when installing over the normal one.
if [[ -d "$DEST_DIR/SWIFT.app" && "$DEST_DIR" == "/Applications" ]]; then
  osascript -e 'tell application id "app.swift.mac" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$DEST_DIR/SWIFT.app"
cp -R "$BUILT" "$DEST_DIR/SWIFT.app"
xattr -dr com.apple.quarantine "$DEST_DIR/SWIFT.app" 2>/dev/null || true

echo "✓ Installed $DEST_DIR/SWIFT.app"
echo "  When macOS asks about Local Network, choose Allow."
[[ "${NO_OPEN:-0}" == "1" ]] || open "$DEST_DIR/SWIFT.app"
