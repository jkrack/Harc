#!/usr/bin/env bash
set -euo pipefail

# Verify the exact notarized and stapled DMG bytes that will be signed for
# Sparkle and uploaded to the GitHub release.
#
# Usage:
#   ./scripts/verify-release.sh <marketing-version> <build-number> <dmg>

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <marketing-version> <build-number> <dmg>" >&2
  exit 1
fi

EXPECTED_VERSION="$1"
EXPECTED_BUILD="$2"
DMG_INPUT="$3"

if [[ ! -f "$DMG_INPUT" ]]; then
  echo "error: no such DMG: $DMG_INPUT" >&2
  exit 1
fi

DMG_DIRECTORY="$(cd "$(dirname "$DMG_INPUT")" && pwd)"
DMG="$DMG_DIRECTORY/$(basename "$DMG_INPUT")"
MOUNT_POINT="$(mktemp -d /private/tmp/harc-release-verify.XXXXXX)"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Verifying signed and stapled DMG"
codesign --verify --verbose=4 "$DMG"
/usr/bin/hdiutil verify "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open -vvv --context context:primary-signature "$DMG"

echo "==> Verifying embedded notarized app"
/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DMG" >/dev/null
MOUNTED=1

APP="$MOUNT_POINT/Harc.app"
if [[ ! -d "$APP" ]]; then
  echo "error: packaged DMG does not contain Harc.app at its root" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=4 "$APP"
spctl -a -t execute -vvv "$APP"

INFO_PLIST="$APP/Contents/Info.plist"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "error: expected version $EXPECTED_VERSION, got $ACTUAL_VERSION" >&2
  exit 1
fi
if [[ "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "error: expected build $EXPECTED_BUILD, got $ACTUAL_BUILD" >&2
  exit 1
fi
if [[ "$ACTUAL_BUNDLE_ID" != "com.harc.Harc" ]]; then
  echo "error: expected bundle ID com.harc.Harc, got $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi

for BINARY in Harc harc-stt harc-mcp; do
  ARCHITECTURES="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$BINARY")"
  if [[ "$ARCHITECTURES" != "arm64" ]]; then
    echo "error: expected arm64-only $BINARY, got $ARCHITECTURES" >&2
    exit 1
  fi
done

SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
BYTE_COUNT="$(stat -f '%z' "$DMG")"

echo ""
echo "Release candidate verified:"
echo "  Version: $ACTUAL_VERSION ($ACTUAL_BUILD)"
echo "  Bundle:  $ACTUAL_BUNDLE_ID"
echo "  Arch:    arm64"
echo "  Bytes:   $BYTE_COUNT"
echo "  SHA-256: $SHA256"
