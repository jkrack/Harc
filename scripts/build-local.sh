#!/usr/bin/env bash
set -euo pipefail

# Build a locally-signed (ad-hoc) Harc.app for personal use.
# No Apple Developer account required. The resulting app is NOT notarized,
# so first launch on another Mac will need: right-click → Open → Open anyway,
# or: xattr -dr com.apple.quarantine /Applications/Harc.app

cd "$(dirname "$0")/.."

SCHEME="Harc"
CONFIG="Release"
DERIVED="build/local-derived"
DIST="build/local-dist"
APP_NAME="Harc.app"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building $SCHEME ($CONFIG, ad-hoc signed)"
xcodebuild \
  -project Harc.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build

APP_SRC="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
APP_DST="$DIST/$APP_NAME"

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build succeeded but $APP_SRC is missing" >&2
  exit 1
fi

APP_ARCHS="$(/usr/bin/lipo -archs "$APP_SRC/Contents/MacOS/Harc")"
if [[ "$APP_ARCHS" != "arm64" ]]; then
  echo "error: expected arm64-only Harc binary, got: $APP_ARCHS" >&2
  exit 1
fi

DAEMON_ARCHS="$(/usr/bin/lipo -archs "$APP_SRC/Contents/MacOS/harc-stt")"
if [[ "$DAEMON_ARCHS" != "arm64" ]]; then
  echo "error: expected arm64-only harc-stt binary, got: $DAEMON_ARCHS" >&2
  exit 1
fi

cp -R "$APP_SRC" "$APP_DST"

echo "==> Re-signing bundle (deep)"
# Identity selection:
#   1. If a self-signed "Harc Local Dev" identity exists in the user's
#      keychain (created by scripts/setup-local-signing.sh), use it. A stable
#      named identity helps TCC persist Microphone / Screen Recording grants
#      across rebuilds — better than re-granting after every cdhash change.
#   2. Otherwise fall back to ad-hoc (`-`).
#
# NOT passing --options runtime: hardened runtime + ad-hoc/self-signed makes
# TCC unable to verify a stable signing identity reliably. Hardened runtime
# is only required for notarization; not in scope for local builds.
LOCAL_IDENTITY="Harc Local Dev"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "${LOCAL_IDENTITY}"; then
  SIGN_ID="${LOCAL_IDENTITY}"
  echo "    using stable identity: ${LOCAL_IDENTITY}"
else
  SIGN_ID="-"
  echo "    using ad-hoc identity (run scripts/setup-local-signing.sh once for stable TCC grants)"
fi

codesign --force --deep --sign "${SIGN_ID}" \
  --entitlements HarcApp/Harc.entitlements \
  "$APP_DST"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DST"

echo "==> Building DMG"
DMG_PATH="$DIST/Harc-local.dmg"
# UDZO = zlib-compressed read-only. The .app is ad-hoc signed; the DMG itself
# is unsigned (fine for local/personal distribution — the user will need to
# strip the quarantine attribute on the destination Mac).
/usr/bin/hdiutil create \
  -volname "Harc" \
  -srcfolder "$APP_DST" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Zipping DMG"
# Zipping the DMG makes it safer to move across Slack / email / iCloud Drive,
# which can otherwise strip attributes or flag .dmg attachments. ditto keeps
# the macOS metadata intact.
ZIP_PATH="$DIST/Harc-local-dmg.zip"
/usr/bin/ditto -c -k --sequesterRsrc "$DMG_PATH" "$ZIP_PATH"

echo ""
echo "Built: $APP_DST"
echo "DMG:   $DMG_PATH"
echo "Zip:   $ZIP_PATH  (contains the DMG)"
echo ""
echo "On the target Mac:"
echo "  1. Unzip, double-click Harc-local.dmg, drag Harc.app to /Applications"
echo "  2. xattr -dr com.apple.quarantine /Applications/Harc.app"
echo "  3. Launch. Approve mic + screen recording prompts in System Settings."
