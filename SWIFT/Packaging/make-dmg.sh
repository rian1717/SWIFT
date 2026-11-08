#!/usr/bin/env bash
# Package SWIFT.app into a distributable .dmg.
#
# A disk image rather than a .pkg installer: SWIFT is a single self-contained
# .app with no privileged components, no LaunchDaemon and nothing to write
# outside its own bundle, so there is nothing for an installer to do that
# dragging to /Applications doesn't already do. `hdiutil` ships with macOS,
# which keeps this dependency-free like the rest of the project.
#
# Usage: SWIFT/Packaging/make-dmg.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$HERE")"
APP="$APP_DIR/build/SWIFT.app"
OUT="$APP_DIR/build/SWIFT-macOS.dmg"

# Always package what the current source produces. Reusing whatever happens to
# be sitting in build/ is how a release ends up shipping a binary that doesn't
# match the commit it claims.
if [[ "${SWIFT_SKIP_BUILD:-0}" != "1" ]]; then
  "$HERE/build-app.sh" "$CONFIG"
fi

PLIST="$APP/Contents/Info.plist"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
GIT_COMMIT="$(/usr/libexec/PlistBuddy -c "Print :SWIFTGitCommit" "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

echo "▶︎ Staging disk image contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The drag-to-install target. A symlink costs nothing in the compressed image
# and is what makes the window self-explanatory without a background graphic.
ln -s /Applications "$STAGE/Applications"

echo "▶︎ Building ${OUT}…"
rm -f "$OUT"
# UDZO = zlib-compressed, read-only: the standard for distribution.
hdiutil create \
    -volname "SWIFT" \
    -srcfolder "$STAGE" \
    -format UDZO \
    -ov -quiet \
    "$OUT"

SIZE="$(du -h "$OUT" | cut -f1 | tr -d ' ')"
echo "✓ Built $OUT"
echo "  VERSION $VERSION · BUILD $BUILD_NUMBER · $GIT_COMMIT · $SIZE"
if [[ "${SWIFT_SKIP_BUILD:-0}" != "1" ]]; then
  echo
  echo "  Development DMG: ad-hoc signed and not notarized."
  echo "  Use Packaging/release.sh for a public Developer ID release."
fi
