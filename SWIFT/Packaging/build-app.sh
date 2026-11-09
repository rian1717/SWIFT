#!/usr/bin/env bash
# Build SWIFT.app — a proper macOS bundle so the OS grants local-network
# access (Bonjour/mDNS) that a bare `swift run` binary can't get.
#
# Usage: SWIFT/Packaging/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"                 # .../SWIFT package
ROOT_DIR="$(dirname "$APP_DIR")"
OUT="$APP_DIR/build/SWIFT.app"
PRODUCTS="$APP_DIR/.build/xcode-products"
OBJECTS="$APP_DIR/.build/xcode-objects"
XCODE_CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"

mkdir -p "$APP_DIR/.build"
LOG="$APP_DIR/.build/xcodebuild.log"
echo "▶︎ Building ($CONFIG)…"
xcodebuild \
  -project "$ROOT_DIR/SWIFT.xcodeproj" \
  -target SWIFT \
  -configuration "$XCODE_CONFIG" \
  SYMROOT="$PRODUCTS" \
  OBJROOT="$OBJECTS" \
  CODE_SIGNING_ALLOWED=NO \
  clean build >"$LOG" 2>&1 || {
    echo "✗ The build failed. Last lines of the log ($LOG):" >&2
    tail -25 "$LOG" >&2
    exit 1
  }
BUILT_APP="$PRODUCTS/$XCODE_CONFIG/SWIFT.app"

# --- build identity -----------------------------------------------------
# A monotonic counter so it's obvious at a glance which build is running, plus
# the commit and timestamp, which are what actually pin it down. The counter
# lives outside git (it would conflict on every branch); the commit does not.
COUNTER_FILE="$HERE/.build-number"
BUILD_NUMBER=$(( $(cat "$COUNTER_FILE" 2>/dev/null || echo 34000) + 1 ))
echo "$BUILD_NUMBER" > "$COUNTER_FILE"

if GIT_COMMIT="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null)"; then
  if ! git -C "$APP_DIR" diff --quiet HEAD 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT+dirty"
  fi
else
  GIT_COMMIT="uncommitted"
fi
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

echo "▶︎ Assembling ${OUT}…"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$BUILT_APP" "$OUT"
mkdir -p "$OUT/Contents/Resources"
cp "$HERE/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

PLIST="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SWIFTGitCommit $GIT_COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SWIFTBuildDate $BUILD_DATE" "$PLIST"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
EXTENSION_PLIST="$OUT/Contents/PlugIns/SWIFTShareExtension.appex/Contents/Info.plist"
if [[ -f "$EXTENSION_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$EXTENSION_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$EXTENSION_PLIST"
fi

# Sign the sandboxed extension first, preserving its required entitlements, then
# the containing app. `--deep` would replace the nested signature without the
# extension's sandbox entitlements and PlugInKit would reject it.
if [[ -d "$OUT/Contents/PlugIns/SWIFTShareExtension.appex" ]]; then
  codesign --force --sign - \
    -r='designated => identifier "app.swift.mac.share"' \
    --entitlements "$ROOT_DIR/SWIFTShareExtension/SWIFTShareExtension.entitlements" \
    "$OUT/Contents/PlugIns/SWIFTShareExtension.appex" >/dev/null
fi
# The signature is "ad hoc", and by default macOS pins it to this one build, so
# every new build asked again for Bluetooth and Local Network. Tying it to the
# app's identifier instead lets those answers survive an update.
codesign --force --sign - -r='designated => identifier "app.swift.mac"' "$OUT" >/dev/null 2>&1 || \
  echo "  (codesign skipped — app will still run, may re-prompt for network)"

echo "✓ Built $OUT"
echo "  BUILD $BUILD_NUMBER · $GIT_COMMIT · $BUILD_DATE"
echo "  Run it:  open \"$OUT\""
