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
  build

APP_SRC="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
APP_DST="$DIST/$APP_NAME"

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build succeeded but $APP_SRC is missing" >&2
  exit 1
fi

cp -R "$APP_SRC" "$APP_DST"

echo "==> Re-signing bundle ad-hoc (deep)"
codesign --force --deep --sign - --options runtime \
  --entitlements HarcApp/Harc.entitlements \
  "$APP_DST"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DST"

echo "==> Zipping"
ZIP_PATH="$DIST/Harc-local.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DST" "$ZIP_PATH"

echo ""
echo "Built: $APP_DST"
echo "Zip:   $ZIP_PATH"
echo ""
echo "On the target Mac:"
echo "  1. Unzip, drag Harc.app to /Applications"
echo "  2. xattr -dr com.apple.quarantine /Applications/Harc.app"
echo "  3. Launch. Approve mic + screen recording prompts in System Settings."
