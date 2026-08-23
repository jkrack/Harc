#!/usr/bin/env bash
set -euo pipefail

# Run the HarcMobile UI qualification bundle against one explicit destination
# and retain enough provenance to reproduce or reject the result. Ordinary app
# storage is never copied or modified by this script; the UI tests themselves
# use Debug-only, UUID-scoped roots.
#
# Usage:
#   ./scripts/qualify-harcmobile-ui.sh \
#     --destination-id <UDID> \
#     --platform simulator|physical \
#     --output-dir <new-directory> \
#     [--development-team <10-character-team-id>] \
#     [--attempts 1-3] \
#     [--allow-dirty-diagnostic]

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION_ID=""
PLATFORM=""
OUTPUT_DIR=""
ALLOW_DIRTY=0
ATTEMPTS=0
DEVELOPMENT_TEAM="${HARC_DEVELOPMENT_TEAM:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination-id)
      [[ $# -ge 2 ]] || { echo "error: --destination-id requires a value" >&2; exit 64; }
      DESTINATION_ID="$2"
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || { echo "error: --platform requires a value" >&2; exit 64; }
      PLATFORM="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "error: --output-dir requires a value" >&2; exit 64; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --attempts)
      [[ $# -ge 2 ]] || { echo "error: --attempts requires a value" >&2; exit 64; }
      ATTEMPTS="$2"
      shift 2
      ;;
    --development-team)
      [[ $# -ge 2 ]] || { echo "error: --development-team requires a value" >&2; exit 64; }
      DEVELOPMENT_TEAM="$2"
      shift 2
      ;;
    --allow-dirty-diagnostic)
      ALLOW_DIRTY=1
      shift
      ;;
    *)
      echo "usage: $0 --destination-id <UDID> --platform simulator|physical --output-dir <new-directory> [--development-team <10-character-team-id>] [--attempts 1-3] [--allow-dirty-diagnostic]" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$DESTINATION_ID" || -z "$PLATFORM" || -z "$OUTPUT_DIR" ]]; then
  echo "error: --destination-id, --platform, and --output-dir are required" >&2
  exit 64
fi
if [[ "$PLATFORM" != "simulator" && "$PLATFORM" != "physical" ]]; then
  echo "error: --platform must be simulator or physical" >&2
  exit 64
fi
if [[ "$PLATFORM" == "physical" && ! "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: physical qualification requires --development-team with a 10-character Apple team ID" >&2
  exit 64
fi
if [[ ! "$ATTEMPTS" =~ ^[0-3]$ ]]; then
  echo "error: --attempts must be an integer from 1 through 3" >&2
  exit 64
fi
if [[ "$ATTEMPTS" -eq 0 ]]; then
  if [[ "$PLATFORM" == "physical" ]]; then
    ATTEMPTS=3
  else
    ATTEMPTS=1
  fi
fi
if [[ ! "$ATTEMPTS" =~ ^[1-3]$ ]]; then
  echo "error: --attempts must be an integer from 1 through 3" >&2
  exit 64
fi
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "error: output path already exists: $OUTPUT_DIR" >&2
  exit 1
fi

for TOOL in git xcodebuild xcrun shasum ditto; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "error: required tool is unavailable: $TOOL" >&2
    exit 1
  }
done

AVAILABLE_GIB="$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
if [[ "$AVAILABLE_GIB" -lt 8 ]]; then
  echo "error: free disk is ${AVAILABLE_GIB} GiB; qualification requires 8 GiB of starting headroom to preserve the 5 GiB operational floor" >&2
  exit 1
fi

cd "$REPO_ROOT"
SOURCE_HEAD="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain=v1 --untracked-files=all)"
SOURCE_FILE_LIST="$(git ls-files --cached --others --exclude-standard | LC_ALL=C sort)"
if [[ -n "$SOURCE_STATUS" && "$ALLOW_DIRTY" -ne 1 ]]; then
  echo "error: qualification requires a clean tree; use --allow-dirty-diagnostic only for non-release evidence" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
SOURCE_MANIFEST="$OUTPUT_DIR/source-files.sha256"
while IFS= read -r SOURCE_FILE; do
  [[ -n "$SOURCE_FILE" ]] || continue
  shasum -a 256 "$SOURCE_FILE"
done <<< "$SOURCE_FILE_LIST" > "$SOURCE_MANIFEST"
SOURCE_FINGERPRINT="$(shasum -a 256 "$SOURCE_MANIFEST" | awk '{ print $1 }')"

printf '%s\n' "$SOURCE_STATUS" > "$OUTPUT_DIR/source-status.txt"
{
  echo "head=$SOURCE_HEAD"
  echo "source_manifest_sha256=$SOURCE_FINGERPRINT"
  echo "tree_clean=$([[ -z "$SOURCE_STATUS" ]] && echo true || echo false)"
  echo "diagnostic_dirty_tree=$([[ "$ALLOW_DIRTY" -eq 1 ]] && echo true || echo false)"
} > "$OUTPUT_DIR/source-identity.txt"

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
XCODE_STATUS=1
SELECTED_ATTEMPT=0
RESULT_BUNDLE=""

# CoreDevice can fail before launching a single UI test while enabling physical
# automation. xcresulttool reports that runner-initialization failure as one
# failed "test", so classify it by its runner-only failure payload instead of
# trusting totalTestCount. It is infrastructure noise only when a bounded retry
# executes the actual suite. A runner-only result can never pass this script.
for ATTEMPT in $(seq 1 "$ATTEMPTS"); do
  ATTEMPT_BUNDLE="$OUTPUT_DIR/HarcMobileUITests-attempt-${ATTEMPT}.xcresult"
  ATTEMPT_LOG="$OUTPUT_DIR/xcodebuild-attempt-${ATTEMPT}.log"
  ATTEMPT_SUMMARY="$OUTPUT_DIR/test-summary-attempt-${ATTEMPT}.json"
  SIGNING_OPTIONS=()
  if [[ "$PLATFORM" == "physical" ]]; then
    SIGNING_OPTIONS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  fi
  set +e
  xcodebuild \
    -project Harc.xcodeproj \
    -scheme HarcMobile \
    -configuration Debug \
    -destination "id=$DESTINATION_ID" \
    -jobs 2 \
    -parallel-testing-enabled NO \
    SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
    HARC_BUILD_SHA="$SOURCE_HEAD" \
    "${SIGNING_OPTIONS[@]}" \
    -resultBundlePath "$ATTEMPT_BUNDLE" \
    -only-testing:HarcMobileUITests \
    test 2>&1 | tee "$ATTEMPT_LOG"
  ATTEMPT_STATUS="${PIPESTATUS[0]}"
  XCODE_STATUS="$ATTEMPT_STATUS"
  set -e

  if [[ -d "$ATTEMPT_BUNDLE" ]]; then
    xcrun xcresulttool get test-results summary \
      --path "$ATTEMPT_BUNDLE" \
      --compact > "$ATTEMPT_SUMMARY" \
      2> "$OUTPUT_DIR/test-summary-attempt-${ATTEMPT}-error.txt" \
      || true
  fi
  TOTAL_TESTS="$(/usr/bin/python3 -c '
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    print(int(json.loads(path.read_text()).get("totalTestCount", 0)))
except Exception:
    print(0)
' "$ATTEMPT_SUMMARY")"
  FAILED_TESTS="$(/usr/bin/python3 -c '
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    print(int(json.loads(path.read_text()).get("failedTests", 0)))
except Exception:
    print(0)
' "$ATTEMPT_SUMMARY")"
  PASSED_TESTS="$(/usr/bin/python3 -c '
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    print(int(json.loads(path.read_text()).get("passedTests", 0)))
except Exception:
    print(0)
' "$ATTEMPT_SUMMARY")"
  {
    echo "attempt=$ATTEMPT"
    echo "xcode_status=$ATTEMPT_STATUS"
    echo "total_tests=$TOTAL_TESTS"
    echo "passed_tests=$PASSED_TESTS"
    echo "failed_tests=$FAILED_TESTS"
  } > "$OUTPUT_DIR/attempt-${ATTEMPT}.txt"

  if [[ "$ATTEMPT_STATUS" -eq 0 && "$TOTAL_TESTS" -gt 0 && "$PASSED_TESTS" -gt 0 && "$FAILED_TESTS" -eq 0 ]]; then
    XCODE_STATUS=0
    SELECTED_ATTEMPT="$ATTEMPT"
    RESULT_BUNDLE="$ATTEMPT_BUNDLE"
    cp -p "$ATTEMPT_SUMMARY" "$OUTPUT_DIR/test-summary.json"
    break
  fi

  RETRYABLE_AUTOMATION_STARTUP=0
  RUNNER_STARTUP_ONLY="$(/usr/bin/python3 -c '
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    summary = json.loads(path.read_text())
    failures = summary.get("testFailures", [])
    runner_only = (
        int(summary.get("passedTests", 0)) == 0
        and int(summary.get("skippedTests", 0)) == 0
        and len(failures) > 0
        and all(
            "HarcMobileUITests-Runner" in str(failure.get("testName", ""))
            and "Timed out while enabling automation mode" in str(failure.get("failureText", ""))
            for failure in failures
        )
    )
    print(1 if runner_only else 0)
except Exception:
    print(0)
' "$ATTEMPT_SUMMARY")"
  if [[ "$PLATFORM" == "physical" && "$RUNNER_STARTUP_ONLY" -eq 1 ]] && \
    grep -Fqi 'Timed out while enabling automation mode' "$ATTEMPT_LOG"; then
    RETRYABLE_AUTOMATION_STARTUP=1
  fi
  echo "runner_startup_only=$RUNNER_STARTUP_ONLY" \
    >> "$OUTPUT_DIR/attempt-${ATTEMPT}.txt"
  echo "retryable_automation_startup=$RETRYABLE_AUTOMATION_STARTUP" \
    >> "$OUTPUT_DIR/attempt-${ATTEMPT}.txt"
  if [[ "$RETRYABLE_AUTOMATION_STARTUP" -ne 1 ]]; then
    break
  fi
done

ENDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ "$SELECTED_ATTEMPT" -gt 0 && -d "$RESULT_BUNDLE" ]]; then
  ditto -c -k --sequesterRsrc --keepParent \
    "$RESULT_BUNDLE" "$OUTPUT_DIR/HarcMobileUITests.xcresult.zip"
  shasum -a 256 "$OUTPUT_DIR/HarcMobileUITests.xcresult.zip" \
    > "$OUTPUT_DIR/HarcMobileUITests.xcresult.zip.sha256"
fi

if [[ "$PLATFORM" == "physical" ]]; then
  xcrun devicectl device info details --device "$DESTINATION_ID" \
    > "$OUTPUT_DIR/device-info.txt" 2>&1 || true
else
  {
    echo "udid=$DESTINATION_ID"
    echo "model_identifier=$(xcrun simctl getenv "$DESTINATION_ID" SIMULATOR_MODEL_IDENTIFIER 2>/dev/null || true)"
    echo "runtime_version=$(xcrun simctl getenv "$DESTINATION_ID" SIMULATOR_RUNTIME_VERSION 2>/dev/null || true)"
    echo "runtime_build=$(xcrun simctl getenv "$DESTINATION_ID" SIMULATOR_RUNTIME_BUILD_VERSION 2>/dev/null || true)"
  } > "$OUTPUT_DIR/device-info.txt"
fi

{
  echo "started_at=$STARTED_AT"
  echo "ended_at=$ENDED_AT"
  echo "platform=$PLATFORM"
  echo "destination_id=$DESTINATION_ID"
  echo "development_team=$DEVELOPMENT_TEAM"
  echo "maximum_attempts=$ATTEMPTS"
  echo "selected_attempt=$SELECTED_ATTEMPT"
  echo "xcode_status=$XCODE_STATUS"
  echo "result_bundle=$RESULT_BUNDLE"
  echo "source_head=$SOURCE_HEAD"
  echo "source_manifest_sha256=$SOURCE_FINGERPRINT"
} > "$OUTPUT_DIR/qualification.txt"

echo ""
echo "Evidence: $OUTPUT_DIR"
echo "Source manifest SHA-256: $SOURCE_FINGERPRINT"
echo "xcodebuild status: $XCODE_STATUS"
exit "$XCODE_STATUS"
