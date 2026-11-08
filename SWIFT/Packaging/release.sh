#!/usr/bin/env bash
# Build, Developer ID sign, notarize, staple, and checksum a release DMG.
#
# Required:
#   SWIFT_SIGN_IDENTITY="Developer ID Application: …"
#   SWIFT_NOTARY_PROFILE="notarytool-keychain-profile"
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"
APP="$APP_DIR/build/SWIFT.app"
DMG="$APP_DIR/build/SWIFT-macOS.dmg"

: "${SWIFT_SIGN_IDENTITY:?Set SWIFT_SIGN_IDENTITY to a Developer ID Application identity}"
: "${SWIFT_NOTARY_PROFILE:?Set SWIFT_NOTARY_PROFILE to a notarytool keychain profile}"

"$HERE/build-app.sh" release

echo "▶︎ Signing app with hardened runtime…"
codesign --force --options runtime --timestamp \
  --entitlements "$APP_DIR/../SWIFTShareExtension/SWIFTShareExtension.entitlements" \
  --sign "$SWIFT_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/SWIFTShareExtension.appex"
codesign --force --options runtime --timestamp \
  --sign "$SWIFT_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Creating DMG…"
SWIFT_SKIP_BUILD=1 "$HERE/make-dmg.sh" release

echo "▶︎ Signing DMG…"
codesign --force --timestamp --sign "$SWIFT_SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "▶︎ Submitting to Apple notarization…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$SWIFT_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG" > "$DMG.sha256"
echo "✓ Release ready:"
echo "  $DMG"
echo "  $DMG.sha256"
