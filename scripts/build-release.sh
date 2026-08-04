#!/usr/bin/env bash
set -euo pipefail

# Build a notarizable Harc.app + DMG signed with the Developer ID identity.
# Counterpart to build-local.sh (which is ad-hoc signed and NOT notarizable).
#
# Produces: build/release-dist/Harc-<version>.dmg, ready for
#   xcrun notarytool submit <dmg> --keychain-profile harc-notary --wait
#   xcrun stapler staple <dmg>
#
# Requirements: "Developer ID Application" cert in the login keychain,
# network access (secure timestamps come from Apple's timestamp server).

cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: JAMES ELLIS LANE (63TNU5M7P4)"
TEAM_ID="63TNU5M7P4"
SCHEME="Harc"
CONFIG="Release"
DERIVED="build/release-derived"
DIST="build/release-dist"
APP_NAME="Harc.app"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building $SCHEME $VERSION ($CONFIG, Developer ID)"
xcodebuild \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project Harc.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
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

for BIN in Harc harc-stt harc-mcp; do
  ARCHS_FOUND="$(/usr/bin/lipo -archs "$APP_SRC/Contents/MacOS/$BIN")"
  if [[ "$ARCHS_FOUND" != "arm64" ]]; then
    echo "error: expected arm64-only $BIN binary, got: $ARCHS_FOUND" >&2
    exit 1
  fi
done

cp -R "$APP_SRC" "$APP_DST"

# Notarization requires hardened runtime AND a secure timestamp on every
# nested Mach-O. Xcode's incremental build signing and build-daemon.sh both
# omit --timestamp, so re-sign everything here, inside-out (nested code must
# be sealed before its container).
echo "==> Re-signing inside-out (hardened runtime + secure timestamps)"

SPARKLE="$APP_DST/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for NESTED in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app"; do
    if [[ -e "$NESTED" ]]; then
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$NESTED"
    fi
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
fi

# Any other embedded frameworks/dylibs/XPCs (deepest first).
find "$APP_DST/Contents/Frameworks" -depth \
  \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \) -print0 2>/dev/null |
  while IFS= read -r -d '' ITEM; do
    [[ "$ITEM" == "$SPARKLE"* ]] && continue
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$ITEM"
  done

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$APP_DST/Contents/MacOS/harc-stt"

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --identifier com.harc.Harc.mcp \
  "$APP_DST/Contents/MacOS/harc-mcp"

codesign --force --options runtime --timestamp \
  --entitlements HarcApp/Harc.entitlements \
  --sign "$IDENTITY" \
  "$APP_DST"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DST"

MCP_SIGNING_INFO="$(codesign -d --verbose=4 \
  "$APP_DST/Contents/MacOS/harc-mcp" 2>&1)"
if [[ "$MCP_SIGNING_INFO" != *$'Identifier=com.harc.Harc.mcp\n'* ]]; then
  echo "error: embedded harc-mcp does not have its required identifier" >&2
  exit 1
fi
APP_TEAM="$(codesign -d --verbose=4 "$APP_DST" 2>&1 | \
  sed -n 's/^TeamIdentifier=//p')"
MCP_TEAM="$(printf '%s\n' "$MCP_SIGNING_INFO" | \
  sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$APP_TEAM" || "$MCP_TEAM" != "$APP_TEAM" ]]; then
  echo "error: Harc and harc-mcp must share one non-empty Team Identifier" >&2
  exit 1
fi

echo "==> Building DMG"
DMG_PATH="$DIST/Harc-$VERSION.dmg"
/usr/bin/hdiutil create \
  -volname "Harc" \
  -srcfolder "$APP_DST" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"

echo ""
echo "Built: $APP_DST"
echo "DMG:   $DMG_PATH"
echo ""
echo "Next:"
echo "  xcrun notarytool submit $DMG_PATH --keychain-profile harc-notary --wait"
echo "  xcrun stapler staple $DMG_PATH"
