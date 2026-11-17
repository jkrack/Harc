#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64
df -Pk "$PWD" | awk 'NR == 2 { exit ($4 < 5242880) }'
OUTPUT="${HARC_MOBILE_CONFIGURATION_OUTPUT:-.build/mobile-query-diagnostic}"
DERIVED="${HARC_MOBILE_CONFIGURATION_DERIVED:-$OUTPUT/derived}"
source scripts/build-concurrency.sh
harc_configure_build_jobs
XCODE_OPTIONS=(-skipMacroValidation -skipPackagePluginValidation)
if [[ -n "$HARC_BUILD_JOB_COUNT" ]]; then
  XCODE_OPTIONS+=(-jobs "$HARC_BUILD_JOB_COUNT")
fi
if [[ -n "${HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE:-}" ]]; then
  mkdir -p "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE"
  XCODE_OPTIONS+=(-packageCachePath "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE")
fi
mkdir -p "$OUTPUT"
python3 scripts/select-ios-configuration-simulator.py "$OUTPUT/destination.json"
DESTINATION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["destination"])' "$OUTPUT/destination.json")
SOURCE_SHA=$(git rev-parse HEAD)
# Build and execute the same selection, destination and products in separate budgets.
# Cold compilation must not consume the time needed to run tests and seal xcresult.
# Diagnostic only; original tests/assertions remain unchanged.
SIMULATOR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$OUTPUT/destination.json")
collect_trace() {
  xcrun simctl spawn "$SIMULATOR" log show --last 1h --style json --predicate 'subsystem == "com.harc.mobile.uidiagnostic"' > "$OUTPUT/setup-trace.json" 2> "$OUTPUT/setup-trace-error.txt" || true
}
trap collect_trace EXIT
TEST_OPTIONS=("${XCODE_OPTIONS[@]}" -project Harc.xcodeproj -scheme HarcMobile -configuration Debug
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" -parallel-testing-enabled NO
  -only-testing:HarcMobileUITests/HarcMobileRecordingDetailUITests/testStorageWarningSurvivesDoneRecentAndLibrary
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLongHostNameKeepsRecordAndToolbarsUsable
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "HARC_BUILD_SHA=$SOURCE_SHA")
python3 scripts/run-package-tests.py --timeout-seconds 1800 --diagnostics-dir "$OUTPUT/build-diagnostics" -- xcodebuild "${TEST_OPTIONS[@]}" build-for-testing
python3 scripts/run-package-tests.py --timeout-seconds 900 --diagnostics-dir "$OUTPUT/diagnostics" -- xcodebuild "${TEST_OPTIONS[@]}" -resultBundlePath "$OUTPUT/configuration.xcresult" test-without-building
xcrun xcresulttool get test-results summary --path "$OUTPUT/configuration.xcresult" > "$OUTPUT/summary.json"
xcrun xcresulttool get test-results tests --path "$OUTPUT/configuration.xcresult" > "$OUTPUT/tests.json"
python3 scripts/check-xcode-test-results.py --summary "$OUTPUT/summary.json" --tests "$OUTPUT/tests.json" --require-bundle HarcMobileUITests --output "$OUTPUT/execution-gate.json" \
  --require-test HarcMobileUITests/HarcMobileRecordingDetailUITests/testStorageWarningSurvivesDoneRecentAndLibrary \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLongHostNameKeepsRecordAndToolbarsUsable
