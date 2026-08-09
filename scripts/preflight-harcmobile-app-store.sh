#!/usr/bin/env bash
set -u

# Validate repository-side inputs for a HarcMobile App Store candidate and,
# when supplied, the resulting Xcode archive or locally exported distribution
# app. Xcode may repackage and distribution-sign an archive during export or
# upload, so archive signing and distribution signing are deliberately checked
# as separate stages.
#
# Usage:
#   ./scripts/preflight-harcmobile-app-store.sh [--archive <path.xcarchive>] \
#     [--distribution-app <path/Harc.app>] [--screenshots-dir <path>] \
#     [--check-public-urls] [--report-only]
#
# This command intentionally does not claim external qualification. Physical
# device matrices, secondary-Mac evidence, relay staging/deployment evidence,
# and App Store Connect decisions remain in the evidence matrix.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE=""
DISTRIBUTION_APP=""
SCREENSHOTS_DIR=""
CHECK_PUBLIC_URLS=0
REPORT_ONLY=0
FAILURES=0
EXPECTED_TEAM_ID="63TNU5M7P4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      if [[ $# -lt 2 ]]; then
        echo "error: --archive requires a path" >&2
        exit 64
      fi
      ARCHIVE="$2"
      shift 2
      ;;
    --distribution-app)
      if [[ $# -lt 2 ]]; then
        echo "error: --distribution-app requires a path" >&2
        exit 64
      fi
      DISTRIBUTION_APP="$2"
      shift 2
      ;;
    --screenshots-dir)
      if [[ $# -lt 2 ]]; then
        echo "error: --screenshots-dir requires a path" >&2
        exit 64
      fi
      SCREENSHOTS_DIR="$2"
      shift 2
      ;;
    --check-public-urls)
      CHECK_PUBLIC_URLS=1
      shift
      ;;
    --report-only)
      REPORT_ONLY=1
      shift
      ;;
    *)
      echo "usage: $0 [--archive <path.xcarchive>] [--distribution-app <path/Harc.app>] [--screenshots-dir <path>] [--check-public-urls] [--report-only]" >&2
      exit 64
      ;;
  esac
done

pass() {
  echo "PASS  $1"
}

evidence() {
  echo "EVID  $1"
}

fail() {
  echo "OPEN  $1"
  FAILURES=$((FAILURES + 1))
}

require_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', found '$actual')"
  fi
}

require_nonempty() {
  local actual="$1"
  local label="$2"
  if [[ -n "$actual" ]]; then
    pass "$label"
  else
    fail "$label is missing"
  fi
}

require_contains() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label (expected to contain '$expected', found '${actual:-missing}')"
  fi
}

codesign_entitlement() {
  local app="$1"
  local key="$2"
  local escaped_key="${key//./\\.}"
  codesign -d --entitlements :- "$app" 2>/dev/null \
    | plutil -extract "$escaped_key" raw -o - - 2>/dev/null \
    || true
}

profile_value() {
  local profile="$1"
  local key="$2"
  security cms -D -i "$profile" 2>/dev/null \
    | plutil -extract "$key" raw -o - - 2>/dev/null \
    || true
}

require_future_profile_date() {
  local actual="$1"
  local label="$2"
  local expiration_epoch
  local now_epoch
  expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$actual" '+%s' 2>/dev/null || true)"
  now_epoch="$(date -u '+%s')"
  if [[ -n "$expiration_epoch" && "$expiration_epoch" -gt "$now_epoch" ]]; then
    pass "$label ($actual)"
  else
    fail "$label must be a future UTC date (found '${actual:-missing}')"
  fi
}

metadata_single_line() {
  local marker="$1"
  awk -v marker="$marker" '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == marker { found = 1; next }
    found && NF { print; exit }
  ' "$REPO_ROOT/docs/app-store/harcmobile-metadata.md"
}

metadata_block() {
  local start="$1"
  local finish="$2"
  awk -v start="$start" -v finish="$finish" '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == start { found = 1; next }
    found && line == finish { exit }
    found { print }
  ' "$REPO_ROOT/docs/app-store/harcmobile-metadata.md"
}

character_count() {
  LC_ALL=en_US.UTF-8 wc -m | tr -d ' '
}

echo "==> HarcMobile repository preflight"

EXPECTED_VERSION="$(awk -F': ' '
  /^    MARKETING_VERSION:/ {
    gsub(/"/, "", $2)
    print $2
    exit
  }
' "$REPO_ROOT/project.yml")"
EXPECTED_BUILD="$(awk -F': ' '
  /^    CURRENT_PROJECT_VERSION:/ {
    gsub(/"/, "", $2)
    print $2
    exit
  }
' "$REPO_ROOT/project.yml")"
require_nonempty "$EXPECTED_VERSION" "source marketing version"
require_nonempty "$EXPECTED_BUILD" "source project build number"

READINESS_EVIDENCE="$REPO_ROOT/docs/evidence/2026-08-09-harcmobile-app-store-readiness.md"
EXPECTED_CANDIDATE_LINE="**Candidate configuration:** HarcMobile $EXPECTED_VERSION ($EXPECTED_BUILD), iOS 18+, iPhone only"
if [[ -f "$READINESS_EVIDENCE" ]] && grep -Fxq "$EXPECTED_CANDIDATE_LINE" "$READINESS_EVIDENCE"; then
  pass "App Store evidence candidate matches source version/build"
else
  fail "App Store evidence candidate must match HarcMobile $EXPECTED_VERSION ($EXPECTED_BUILD)"
fi

AVAILABLE_GIB="$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
if [[ "$AVAILABLE_GIB" -ge 5 ]]; then
  pass "free disk is ${AVAILABLE_GIB} GiB (5 GiB operational floor)"
else
  fail "free disk is ${AVAILABLE_GIB} GiB (stop below the 5 GiB operational floor)"
fi

for PLIST in \
  "$REPO_ROOT/HarcMobileApp/Info.plist" \
  "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" \
  "$REPO_ROOT/HarcMobileApp/HarcMobile.entitlements"; do
  if plutil -lint "$PLIST" >/dev/null; then
    pass "$(basename "$PLIST") is structurally valid"
  else
    fail "$(basename "$PLIST") is not structurally valid"
  fi
done

require_equal \
  "$(plutil -extract HarcPrivacyPolicyURL raw -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  "https://github.com/jkrack/Harc/blob/main/docs/privacy/harc-mobile-privacy-policy.md" \
  "packaged privacy-policy URL"
require_equal \
  "$(plutil -extract HarcRemoteRelayOrigin raw -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  "https://relay.adaptcontext.com" \
  "packaged relay origin"
require_equal \
  "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  "false" \
  "non-exempt encryption declaration"
require_equal \
  "$(plutil -extract UIBackgroundModes json -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  '["audio"]' \
  "background mode is explicit user-started audio only"
require_equal \
  "$(plutil -extract NSBonjourServices json -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  '["_harc._tcp"]' \
  "Bonjour service allowlist"
require_equal \
  "$(plutil -extract UISupportedInterfaceOrientations json -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  '["UIInterfaceOrientationPortrait"]' \
  "iPhone orientation declaration"
require_equal \
  "$(plutil -extract UIRequiresFullScreen raw -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
  "true" \
  "full-screen iPhone declaration"
for USAGE_KEY in NSMicrophoneUsageDescription NSCameraUsageDescription NSLocalNetworkUsageDescription; do
  require_nonempty \
    "$(plutil -extract "$USAGE_KEY" raw -o - "$REPO_ROOT/HarcMobileApp/Info.plist" 2>/dev/null || true)" \
    "$USAGE_KEY"
done
require_equal \
  "$(plutil -extract NSPrivacyTracking raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "false" \
  "privacy manifest tracking declaration"
require_equal \
  "$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "0" \
  "privacy manifest collected-data list is empty"
SOURCE_TRACKING_DOMAIN_COUNT="$(plutil -extract NSPrivacyTrackingDomains raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)"
if [[ -z "$SOURCE_TRACKING_DOMAIN_COUNT" || "$SOURCE_TRACKING_DOMAIN_COUNT" == "0" ]]; then
  pass "privacy manifest tracking-domain list is absent or empty"
else
  fail "privacy manifest tracking-domain list must be absent or empty"
fi
require_equal \
  "$(plutil -extract NSPrivacyAccessedAPITypes raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "1" \
  "privacy manifest contains one required-reason API declaration"
require_equal \
  "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "NSPrivacyAccessedAPICategoryFileTimestamp" \
  "privacy manifest file-timestamp category"
require_equal \
  "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "1" \
  "privacy manifest file-timestamp reason count"
require_equal \
  "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$REPO_ROOT/HarcMobileApp/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
  "C617.1" \
  "privacy manifest file-timestamp reason"
require_equal \
  "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.default-data-protection' "$REPO_ROOT/HarcMobileApp/HarcMobile.entitlements" 2>/dev/null || true)" \
  "NSFileProtectionComplete" \
  "complete Data Protection entitlement"

MOBILE_TARGET="$(awk '
  /^  HarcMobile:$/ { found = 1 }
  found && /^  HarcMobileAppTests:$/ { exit }
  found { print }
' "$REPO_ROOT/project.yml")"
if [[ "$MOBILE_TARGET" == *'deploymentTarget: "18.0"'* ]] && \
  [[ "$MOBILE_TARGET" == *'PRODUCT_BUNDLE_IDENTIFIER: com.harc.HarcMobile'* ]] && \
  [[ "$MOBILE_TARGET" == *'TARGETED_DEVICE_FAMILY: 1'* ]] && \
  [[ "$MOBILE_TARGET" == *'SUPPORTS_MACCATALYST: NO'* ]] && \
  [[ "$MOBILE_TARGET" == *'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO'* ]] && \
  [[ "$MOBILE_TARGET" != *'SKIP_INSTALL: YES'* ]]; then
  pass "iOS 18, iPhone-only, installable Release source settings"
else
  fail "expected iOS 18, iPhone-only, installable settings are incomplete in project.yml"
fi

ICON_SET="$REPO_ROOT/HarcMobileApp/Assets.xcassets/AppIcon.appiconset"
ICON_CONTENTS="$ICON_SET/Contents.json"
if [[ ! -f "$ICON_CONTENTS" ]]; then
  fail "final AppIcon asset is missing at HarcMobileApp/Assets.xcassets/AppIcon.appiconset"
else
  ICON_FILE="$(/usr/bin/python3 -c '
import json, pathlib, sys
contents = pathlib.Path(sys.argv[1])
data = json.loads(contents.read_text())
for image in data.get("images", []):
    if image.get("size") == "1024x1024" and image.get("filename"):
        print(image["filename"])
        break
' "$ICON_CONTENTS")"
  if [[ -z "$ICON_FILE" || ! -f "$ICON_SET/$ICON_FILE" ]]; then
    fail "AppIcon does not contain a referenced 1024x1024 source image"
  else
    ICON_WIDTH="$(sips -g pixelWidth "$ICON_SET/$ICON_FILE" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
    ICON_HEIGHT="$(sips -g pixelHeight "$ICON_SET/$ICON_FILE" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"
    ICON_ALPHA="$(sips -g hasAlpha "$ICON_SET/$ICON_FILE" 2>/dev/null | awk '/hasAlpha/ { print $2 }')"
    if [[ "$ICON_WIDTH" == "1024" && "$ICON_HEIGHT" == "1024" ]]; then
      pass "AppIcon source is 1024x1024"
    else
      fail "AppIcon source must be 1024x1024 (found ${ICON_WIDTH:-unknown}x${ICON_HEIGHT:-unknown})"
    fi
    if [[ "$ICON_ALPHA" == "no" ]]; then
      pass "AppIcon source has no alpha channel"
    else
      fail "AppIcon source must not contain an alpha channel (found ${ICON_ALPHA:-unknown})"
    fi
  fi
fi

METADATA="$REPO_ROOT/docs/app-store/harcmobile-metadata.md"
if [[ -f "$METADATA" ]]; then
  NAME="$(metadata_single_line '**Name**')"
  SUBTITLE="$(metadata_single_line '**Subtitle**')"
  PROMOTIONAL_TEXT="$(metadata_block '**Promotional text**' '**Description**' | awk 'NF { if (text) text = text " "; text = text $0 } END { print text }')"
  DESCRIPTION="$(metadata_block '**Description**' '**Keywords**')"
  KEYWORDS="$(metadata_single_line '**Keywords**')"
  REVIEW_NOTES="$(metadata_block '**Review notes**' '## Account-holder decisions still required')"

  NAME_COUNT="$(printf '%s' "$NAME" | character_count)"
  SUBTITLE_COUNT="$(printf '%s' "$SUBTITLE" | character_count)"
  PROMOTIONAL_COUNT="$(printf '%s' "$PROMOTIONAL_TEXT" | character_count)"
  DESCRIPTION_COUNT="$(printf '%s' "$DESCRIPTION" | character_count)"
  KEYWORD_BYTES="$(printf '%s' "$KEYWORDS" | wc -c | tr -d ' ')"
  REVIEW_NOTES_BYTES="$(printf '%s' "$REVIEW_NOTES" | wc -c | tr -d ' ')"

  if [[ "$NAME_COUNT" -le 30 && "$SUBTITLE_COUNT" -le 30 && \
        "$PROMOTIONAL_COUNT" -le 170 && "$DESCRIPTION_COUNT" -le 4000 && \
        "$KEYWORD_BYTES" -le 100 ]]; then
    pass "metadata limits (name $NAME_COUNT/30, subtitle $SUBTITLE_COUNT/30, promotional $PROMOTIONAL_COUNT/170, description $DESCRIPTION_COUNT/4000, keywords $KEYWORD_BYTES/100 bytes)"
  else
    fail "metadata exceeds a product-page limit (name $NAME_COUNT/30, subtitle $SUBTITLE_COUNT/30, promotional $PROMOTIONAL_COUNT/170, description $DESCRIPTION_COUNT/4000, keywords $KEYWORD_BYTES/100 bytes)"
  fi
  if [[ "$REVIEW_NOTES_BYTES" -le 4000 && "$REVIEW_NOTES_BYTES" -gt 0 ]]; then
    pass "App Review notes limit ($REVIEW_NOTES_BYTES/4000 bytes)"
  else
    fail "App Review notes must contain 1-4000 bytes (found $REVIEW_NOTES_BYTES)"
  fi

  SUPPORT_LINE="$(awk '/^- Support URL:/ { print; exit }' "$METADATA")"
  SUPPORT_PAGE="$REPO_ROOT/docs/support/harcmobile-support.md"
  if [[ "$SUPPORT_LINE" == *"https://github.com/jkrack/Harc/blob/main/docs/support/harcmobile-support.md"* ]] && \
    [[ -f "$SUPPORT_PAGE" ]]; then
    pass "stable public support-page URL is recorded"
  else
    fail "stable public HTTPS support page and metadata URL are not aligned"
  fi
  if [[ -f "$SUPPORT_PAGE" ]] && \
    grep -Fq 'mailto:' "$SUPPORT_PAGE" && \
    ! grep -Fq 'ACCOUNT_HOLDER_MONITORED_SUPPORT_EMAIL' "$SUPPORT_PAGE"; then
    pass "support page contains monitored email contact information"
  else
    fail "replace the support page's monitored-email placeholder"
  fi
else
  fail "App Store metadata deck is missing"
fi

if [[ -n "$SCREENSHOTS_DIR" ]]; then
  echo ""
  echo "==> App Store screenshot preflight"
  if [[ ! -d "$SCREENSHOTS_DIR" ]]; then
    fail "screenshot directory does not exist: $SCREENSHOTS_DIR"
  else
    SCREENSHOT_NAMES=(
      "01-record"
      "02-recording"
      "03-review-sample"
      "04-library"
      "05-privacy-host"
    )
    for SCREENSHOT_NAME in "${SCREENSHOT_NAMES[@]}"; do
      SCREENSHOT="$SCREENSHOTS_DIR/harcmobile-${EXPECTED_VERSION}-${EXPECTED_BUILD}-${SCREENSHOT_NAME}-1290x2796.png"
      if [[ ! -f "$SCREENSHOT" ]]; then
        fail "required screenshot is missing: $(basename "$SCREENSHOT")"
        continue
      fi
      SCREENSHOT_WIDTH="$(sips -g pixelWidth "$SCREENSHOT" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
      SCREENSHOT_HEIGHT="$(sips -g pixelHeight "$SCREENSHOT" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"
      SCREENSHOT_ALPHA="$(sips -g hasAlpha "$SCREENSHOT" 2>/dev/null | awk '/hasAlpha/ { print $2 }')"
      if [[ "$SCREENSHOT_WIDTH" == "1290" && "$SCREENSHOT_HEIGHT" == "2796" ]]; then
        pass "$(basename "$SCREENSHOT") is 1290x2796"
      else
        fail "$(basename "$SCREENSHOT") must be 1290x2796 (found ${SCREENSHOT_WIDTH:-unknown}x${SCREENSHOT_HEIGHT:-unknown})"
      fi
      if [[ "$SCREENSHOT_ALPHA" == "no" ]]; then
        pass "$(basename "$SCREENSHOT") has no alpha channel"
      else
        fail "$(basename "$SCREENSHOT") must not contain an alpha channel (found ${SCREENSHOT_ALPHA:-unknown})"
      fi
      evidence "$(basename "$SCREENSHOT") SHA-256: $(shasum -a 256 "$SCREENSHOT" | awk '{ print $1 }')"
    done
  fi
fi

if [[ "$CHECK_PUBLIC_URLS" -eq 1 ]]; then
  echo ""
  echo "==> Public App Store URL preflight"
  PUBLIC_PRIVACY_URL="https://github.com/jkrack/Harc/blob/main/docs/privacy/harc-mobile-privacy-policy.md"
  PUBLIC_SUPPORT_URL="https://github.com/jkrack/Harc/blob/main/docs/support/harcmobile-support.md"
  for URL_LABEL in privacy-policy support; do
    if [[ "$URL_LABEL" == "privacy-policy" ]]; then
      PUBLIC_URL="$PUBLIC_PRIVACY_URL"
    else
      PUBLIC_URL="$PUBLIC_SUPPORT_URL"
    fi
    PUBLIC_STATUS="$(curl -L -sS -o /dev/null -w '%{http_code}' "$PUBLIC_URL" 2>/dev/null || true)"
    if [[ "$PUBLIC_STATUS" == "200" ]]; then
      pass "public $URL_LABEL URL resolves with HTTP 200"
    else
      fail "public $URL_LABEL URL must resolve with HTTP 200 (found ${PUBLIC_STATUS:-unreachable})"
    fi
  done
fi

if [[ -n "$ARCHIVE" ]]; then
  echo ""
  echo "==> Xcode archive preflight"
  if [[ ! -d "$ARCHIVE" ]]; then
    fail "archive does not exist: $ARCHIVE"
  else
    ARCHIVE_INFO="$ARCHIVE/Info.plist"
    APP="$ARCHIVE/Products/Applications/Harc.app"
    APP_INFO="$APP/Info.plist"
    if [[ ! -f "$ARCHIVE_INFO" ]]; then
      fail "archive metadata Info.plist is missing"
    else
      require_equal \
        "$(plutil -extract ApplicationProperties.ApplicationPath raw -o - "$ARCHIVE_INFO" 2>/dev/null || true)" \
        "Applications/Harc.app" \
        "archive application path"
      require_equal \
        "$(plutil -extract ApplicationProperties.CFBundleIdentifier raw -o - "$ARCHIVE_INFO" 2>/dev/null || true)" \
        "com.harc.HarcMobile" \
        "archive metadata bundle identifier"
      require_equal \
        "$(plutil -extract ApplicationProperties.Architectures json -o - "$ARCHIVE_INFO" 2>/dev/null || true)" \
        '["arm64"]' \
        "archive metadata architecture"
      require_nonempty \
        "$(plutil -extract ApplicationProperties.SigningIdentity raw -o - "$ARCHIVE_INFO" 2>/dev/null || true)" \
        "archive signing identity"
      require_equal \
        "$(plutil -extract ApplicationProperties.Team raw -o - "$ARCHIVE_INFO" 2>/dev/null || true)" \
        "$EXPECTED_TEAM_ID" \
        "archive signing team"
    fi
    if [[ ! -f "$APP_INFO" ]]; then
      fail "archive does not contain Products/Applications/Harc.app"
    else
      require_equal \
        "$(plutil -extract CFBundleIdentifier raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "com.harc.HarcMobile" \
        "archived bundle identifier"
      require_equal \
        "$(plutil -extract MinimumOSVersion raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "18.0" \
        "archived minimum iOS version"
      require_equal \
        "$(plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "$EXPECTED_VERSION" \
        "archived marketing version"
      require_equal \
        "$(plutil -extract CFBundleVersion raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "$EXPECTED_BUILD" \
        "archived build number"
      require_equal \
        "$(plutil -extract CFBundleSupportedPlatforms json -o - "$APP_INFO" 2>/dev/null || true)" \
        '["iPhoneOS"]' \
        "archived platform is iPhoneOS only"
      require_equal \
        "$(plutil -extract UIDeviceFamily json -o - "$APP_INFO" 2>/dev/null || true)" \
        '[1]' \
        "archived device family is iPhone only"
      require_equal \
        "$(plutil -extract HarcPrivacyPolicyURL raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "https://github.com/jkrack/Harc/blob/main/docs/privacy/harc-mobile-privacy-policy.md" \
        "archived privacy-policy URL"
      require_equal \
        "$(plutil -extract HarcRemoteRelayOrigin raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "https://relay.adaptcontext.com" \
        "archived relay origin"
      require_equal \
        "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "false" \
        "archived non-exempt encryption declaration"
      require_equal \
        "$(plutil -extract UIBackgroundModes json -o - "$APP_INFO" 2>/dev/null || true)" \
        '["audio"]' \
        "archived background mode is audio only"
      require_equal \
        "$(plutil -extract NSBonjourServices json -o - "$APP_INFO" 2>/dev/null || true)" \
        '["_harc._tcp"]' \
        "archived Bonjour service allowlist"
      for USAGE_KEY in NSMicrophoneUsageDescription NSCameraUsageDescription NSLocalNetworkUsageDescription; do
        require_nonempty \
          "$(plutil -extract "$USAGE_KEY" raw -o - "$APP_INFO" 2>/dev/null || true)" \
          "archived $USAGE_KEY"
      done
      require_equal \
        "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$APP_INFO" 2>/dev/null || true)" \
        "AppIcon" \
        "archived primary icon name"

      if [[ -f "$APP/PrivacyInfo.xcprivacy" ]]; then
        pass "privacy manifest is bundled in the archive"
        require_equal \
          "$(plutil -extract NSPrivacyTracking raw -o - "$APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "false" \
          "archived privacy manifest tracking declaration"
        require_equal \
          "$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "0" \
          "archived privacy manifest collected-data list is empty"
        ARCHIVE_TRACKING_DOMAIN_COUNT="$(plutil -extract NSPrivacyTrackingDomains raw -o - "$APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)"
        if [[ -z "$ARCHIVE_TRACKING_DOMAIN_COUNT" || "$ARCHIVE_TRACKING_DOMAIN_COUNT" == "0" ]]; then
          pass "archived privacy manifest tracking-domain list is absent or empty"
        else
          fail "archived privacy manifest tracking-domain list must be absent or empty"
        fi
        require_equal \
          "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "NSPrivacyAccessedAPICategoryFileTimestamp" \
          "archived privacy manifest file-timestamp category"
        require_equal \
          "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "C617.1" \
          "archived privacy manifest file-timestamp reason"
      else
        fail "privacy manifest is missing from the archived app"
      fi
      if [[ -f "$APP/Assets.car" ]]; then
        pass "compiled asset catalog is bundled in the archive"
      else
        fail "compiled asset catalog is missing from the archived app"
      fi
      if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
        pass "archived app signature verifies"
      else
        fail "archived app signature does not verify"
      fi
      SIGNING_AUTHORITY="$(
        codesign -dvvv "$APP" 2>&1 \
          | awk -F= '/^Authority=/ { print substr($0, index($0, "=") + 1); exit }'
      )"
      require_nonempty "$SIGNING_AUTHORITY" "archived app signing authority"
      ARCHIVE_CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ { print $2; exit }')"
      require_nonempty "$ARCHIVE_CDHASH" "archived app signature CDHash"
      if [[ -n "$ARCHIVE_CDHASH" ]]; then
        evidence "archived app signature CDHash: $ARCHIVE_CDHASH"
      fi
      require_equal \
        "$(codesign_entitlement "$APP" "com.apple.developer.default-data-protection")" \
        "NSFileProtectionComplete" \
        "archived complete Data Protection entitlement"
      require_equal \
        "$(codesign_entitlement "$APP" "application-identifier")" \
        "$EXPECTED_TEAM_ID.com.harc.HarcMobile" \
        "archived application identifier entitlement"
      require_equal \
        "$(codesign_entitlement "$APP" "com.apple.developer.team-identifier")" \
        "$EXPECTED_TEAM_ID" \
        "archived team identifier entitlement"

      PROFILE="$APP/embedded.mobileprovision"
      if [[ -f "$PROFILE" ]]; then
        pass "archived provisioning profile is embedded"
        require_equal \
          "$(profile_value "$PROFILE" "Entitlements.application-identifier")" \
          "$EXPECTED_TEAM_ID.com.harc.HarcMobile" \
          "archived profile application identifier"
        require_equal \
          "$(profile_value "$PROFILE" "TeamIdentifier.0")" \
          "$EXPECTED_TEAM_ID" \
          "archived provisioning profile team"
        require_nonempty \
          "$(profile_value "$PROFILE" "UUID")" \
          "archived provisioning profile UUID"
        require_future_profile_date \
          "$(profile_value "$PROFILE" "ExpirationDate")" \
          "archived provisioning profile expiration"
      else
        fail "archived provisioning profile is missing"
      fi
      APP_BINARY="$APP/Harc"
      if [[ -f "$APP_BINARY" ]]; then
        require_equal "$(lipo -archs "$APP_BINARY")" "arm64" "archived application architecture"
        evidence "archived executable SHA-256: $(shasum -a 256 "$APP_BINARY" | awk '{ print $1 }')"
      else
        fail "archived application binary is missing"
      fi
    fi
  fi
fi

if [[ -n "$DISTRIBUTION_APP" ]]; then
  echo ""
  echo "==> Exported distribution-app preflight"
  if [[ ! -d "$DISTRIBUTION_APP" ]]; then
    fail "distribution app does not exist: $DISTRIBUTION_APP"
  else
    DISTRIBUTION_INFO="$DISTRIBUTION_APP/Info.plist"
    if [[ ! -f "$DISTRIBUTION_INFO" ]]; then
      fail "distribution app Info.plist is missing"
    else
      require_equal \
        "$(plutil -extract CFBundleIdentifier raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "com.harc.HarcMobile" \
        "distribution bundle identifier"
      require_equal \
        "$(plutil -extract CFBundleShortVersionString raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "$EXPECTED_VERSION" \
        "distribution marketing version"
      require_equal \
        "$(plutil -extract CFBundleVersion raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "$EXPECTED_BUILD" \
        "distribution build number"
      require_equal \
        "$(plutil -extract MinimumOSVersion raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "18.0" \
        "distribution minimum iOS version"
      require_equal \
        "$(plutil -extract CFBundleSupportedPlatforms json -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        '["iPhoneOS"]' \
        "distribution platform is iPhoneOS only"
      require_equal \
        "$(plutil -extract UIDeviceFamily json -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        '[1]' \
        "distribution device family is iPhone only"
      require_equal \
        "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "AppIcon" \
        "distribution primary icon name"
      require_equal \
        "$(plutil -extract HarcPrivacyPolicyURL raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "https://github.com/jkrack/Harc/blob/main/docs/privacy/harc-mobile-privacy-policy.md" \
        "distribution privacy-policy URL"
      require_equal \
        "$(plutil -extract HarcRemoteRelayOrigin raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "https://relay.adaptcontext.com" \
        "distribution relay origin"
      require_equal \
        "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        "false" \
        "distribution non-exempt encryption declaration"
      require_equal \
        "$(plutil -extract UIBackgroundModes json -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        '["audio"]' \
        "distribution background mode is audio only"
      require_equal \
        "$(plutil -extract NSBonjourServices json -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
        '["_harc._tcp"]' \
        "distribution Bonjour service allowlist"
      for USAGE_KEY in NSMicrophoneUsageDescription NSCameraUsageDescription NSLocalNetworkUsageDescription; do
        require_nonempty \
          "$(plutil -extract "$USAGE_KEY" raw -o - "$DISTRIBUTION_INFO" 2>/dev/null || true)" \
          "distribution $USAGE_KEY"
      done

      if [[ -f "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" ]]; then
        pass "privacy manifest is bundled in the distribution app"
        require_equal \
          "$(plutil -extract NSPrivacyTracking raw -o - "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "false" \
          "distribution privacy manifest tracking declaration"
        require_equal \
          "$(plutil -extract NSPrivacyCollectedDataTypes raw -o - "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "0" \
          "distribution privacy manifest collected-data list is empty"
        DISTRIBUTION_TRACKING_DOMAIN_COUNT="$(plutil -extract NSPrivacyTrackingDomains raw -o - "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)"
        if [[ -z "$DISTRIBUTION_TRACKING_DOMAIN_COUNT" || "$DISTRIBUTION_TRACKING_DOMAIN_COUNT" == "0" ]]; then
          pass "distribution privacy manifest tracking-domain list is absent or empty"
        else
          fail "distribution privacy manifest tracking-domain list must be absent or empty"
        fi
        require_equal \
          "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "NSPrivacyAccessedAPICategoryFileTimestamp" \
          "distribution privacy manifest file-timestamp category"
        require_equal \
          "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$DISTRIBUTION_APP/PrivacyInfo.xcprivacy" 2>/dev/null || true)" \
          "C617.1" \
          "distribution privacy manifest file-timestamp reason"
      else
        fail "privacy manifest is missing from the distribution app"
      fi
      if [[ -f "$DISTRIBUTION_APP/Assets.car" ]]; then
        pass "compiled asset catalog is bundled in the distribution app"
      else
        fail "compiled asset catalog is missing from the distribution app"
      fi

      if codesign --verify --deep --strict "$DISTRIBUTION_APP" >/dev/null 2>&1; then
        pass "distribution app signature verifies"
      else
        fail "distribution app signature does not verify"
      fi
      DISTRIBUTION_AUTHORITY="$(
        codesign -dvvv "$DISTRIBUTION_APP" 2>&1 \
          | awk -F= '/^Authority=/ { print substr($0, index($0, "=") + 1); exit }'
      )"
      require_contains \
        "$DISTRIBUTION_AUTHORITY" \
        "Apple Distribution" \
        "distribution app certificate"
      DISTRIBUTION_CDHASH="$(codesign -dvvv "$DISTRIBUTION_APP" 2>&1 | awk -F= '/^CDHash=/ { print $2; exit }')"
      require_nonempty "$DISTRIBUTION_CDHASH" "distribution app signature CDHash"
      if [[ -n "$DISTRIBUTION_CDHASH" ]]; then
        evidence "distribution app signature CDHash: $DISTRIBUTION_CDHASH"
      fi

      DISTRIBUTION_GET_TASK_ALLOW="$(codesign_entitlement "$DISTRIBUTION_APP" "get-task-allow")"
      if [[ -z "$DISTRIBUTION_GET_TASK_ALLOW" || "$DISTRIBUTION_GET_TASK_ALLOW" == "false" ]]; then
        pass "distribution app is not debugger-entitled"
      else
        fail "distribution app must not contain get-task-allow=true"
      fi
      require_equal \
        "$(codesign_entitlement "$DISTRIBUTION_APP" "com.apple.developer.default-data-protection")" \
        "NSFileProtectionComplete" \
        "distribution complete Data Protection entitlement"
      require_equal \
        "$(codesign_entitlement "$DISTRIBUTION_APP" "application-identifier")" \
        "$EXPECTED_TEAM_ID.com.harc.HarcMobile" \
        "distribution application identifier entitlement"
      require_equal \
        "$(codesign_entitlement "$DISTRIBUTION_APP" "com.apple.developer.team-identifier")" \
        "$EXPECTED_TEAM_ID" \
        "distribution team identifier entitlement"

      DISTRIBUTION_PROFILE="$DISTRIBUTION_APP/embedded.mobileprovision"
      if [[ -f "$DISTRIBUTION_PROFILE" ]]; then
        pass "distribution provisioning profile is embedded"
        require_equal \
          "$(profile_value "$DISTRIBUTION_PROFILE" "Entitlements.application-identifier")" \
          "$EXPECTED_TEAM_ID.com.harc.HarcMobile" \
          "distribution profile application identifier"
        require_equal \
          "$(profile_value "$DISTRIBUTION_PROFILE" "TeamIdentifier.0")" \
          "$EXPECTED_TEAM_ID" \
          "distribution provisioning profile team"
        require_equal \
          "$(profile_value "$DISTRIBUTION_PROFILE" "Entitlements.get-task-allow")" \
          "false" \
          "distribution profile disables debugger attachment"
        require_nonempty \
          "$(profile_value "$DISTRIBUTION_PROFILE" "UUID")" \
          "distribution provisioning profile UUID"
        require_future_profile_date \
          "$(profile_value "$DISTRIBUTION_PROFILE" "ExpirationDate")" \
          "distribution provisioning profile expiration"
        DISTRIBUTION_DEVICE_COUNT="$(profile_value "$DISTRIBUTION_PROFILE" "ProvisionedDevices")"
        DISTRIBUTION_ALL_DEVICES="$(profile_value "$DISTRIBUTION_PROFILE" "ProvisionsAllDevices")"
        if [[ -z "$DISTRIBUTION_DEVICE_COUNT" && "$DISTRIBUTION_ALL_DEVICES" != "true" ]]; then
          pass "distribution provisioning profile is App Store scoped rather than device or enterprise scoped"
        else
          fail "distribution provisioning profile must not be device-bound or enterprise-wide"
        fi
      else
        fail "distribution provisioning profile is missing"
      fi

      DISTRIBUTION_BINARY="$DISTRIBUTION_APP/Harc"
      if [[ -f "$DISTRIBUTION_BINARY" ]]; then
        require_equal "$(lipo -archs "$DISTRIBUTION_BINARY")" "arm64" "distribution application architecture"
        evidence "distribution executable SHA-256: $(shasum -a 256 "$DISTRIBUTION_BINARY" | awk '{ print $1 }')"
      else
        fail "distribution application binary is missing"
      fi
    fi
  fi
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "Local HarcMobile App Store preflight passed."
else
  echo "Local HarcMobile App Store preflight has $FAILURES open item(s)."
fi
echo "External release evidence remains authoritative in:"
echo "  docs/evidence/2026-08-09-harcmobile-app-store-readiness.md"

if [[ "$FAILURES" -ne 0 && "$REPORT_ONLY" -ne 1 ]]; then
  exit 1
fi
