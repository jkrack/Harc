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

# Established by scripts/build-release.sh; do not accept an arbitrary trusted signer.
EXPECTED_TEAM_ID="63TNU5M7P4"

verify_signing_identity() {
  local target="$1" expected_identifier="${2:-}" signing_info actual_team actual_identifier
  if ! signing_info="$(codesign -d --verbose=4 "$target" 2>&1)"; then
    echo "error: cannot read signing identity: $target" >&2
    return 1
  fi
  actual_team="$(printf '%s\n' "$signing_info" | sed -n 's/^TeamIdentifier=//p')"
  if [[ "$actual_team" != "$EXPECTED_TEAM_ID" ]]; then
    echo "error: $target: expected TeamIdentifier $EXPECTED_TEAM_ID, got ${actual_team:-<missing>}" >&2
    return 1
  fi
  if [[ -n "$expected_identifier" ]]; then
    actual_identifier="$(printf '%s\n' "$signing_info" | sed -n 's/^Identifier=//p')"
    if [[ "$actual_identifier" != "$expected_identifier" ]]; then
      echo "error: $target: expected signing Identifier $expected_identifier, got ${actual_identifier:-<missing>}" >&2
      return 1
    fi
  fi
}

EXPECTED_VERSION="$1"
EXPECTED_BUILD="$2"
DMG_INPUT="$3"
EXPECTED_SOURCE_SHA="${HARC_EXPECTED_BUILD_SHA:-$(git rev-parse HEAD)}"

if [[ ! "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: expected source commit must be a full 40-character SHA" >&2
  exit 1
fi

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
verify_signing_identity "$DMG"
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
verify_signing_identity "$APP" com.harc.Harc
# Verify helpers independently as well as through the app's deep verification.
for HELPER in harc-stt harc-mcp; do
  codesign --verify --strict --verbose=4 "$APP/Contents/MacOS/$HELPER"
  if [[ "$HELPER" == "harc-mcp" ]]; then
    verify_signing_identity "$APP/Contents/MacOS/$HELPER" com.harc.Harc.mcp
  else
    verify_signing_identity "$APP/Contents/MacOS/$HELPER"
  fi
done
spctl -a -t execute -vvv "$APP"

INFO_PLIST="$APP/Contents/Info.plist"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
ACTUAL_RELAY_ORIGIN="$(plutil -extract HarcRemoteRelayOrigin raw -o - "$INFO_PLIST")"
ACTUAL_SOURCE_SHA="$(plutil -extract HarcBuildSHA raw -o - "$INFO_PLIST")"

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
if [[ "$ACTUAL_RELAY_ORIGIN" != "https://relay.adaptcontext.com" ]]; then
  echo "error: expected relay origin https://relay.adaptcontext.com, got $ACTUAL_RELAY_ORIGIN" >&2
  exit 1
fi
if [[ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA" ]]; then
  echo "error: expected source commit $EXPECTED_SOURCE_SHA, got $ACTUAL_SOURCE_SHA" >&2
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
echo "  Relay:   $ACTUAL_RELAY_ORIGIN"
echo "  Source:  $ACTUAL_SOURCE_SHA"
echo "  Arch:    arm64"
echo "  Bytes:   $BYTE_COUNT"
echo "  SHA-256: $SHA256"
