#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || { echo "Hosted-only synthetic diagnostic; refusing local collection" >&2; exit 2; }
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64
df -Pk "$PWD" | awk 'NR == 2 { exit ($4 < 5242880) }'
OUTPUT="${HARC_MOBILE_CONFIGURATION_OUTPUT:-.build/mobile-playback-trace}"
DERIVED="${HARC_MOBILE_CONFIGURATION_DERIVED:-$OUTPUT/derived}"
source scripts/build-concurrency.sh
harc_configure_build_jobs
XCODE_OPTIONS=()
if [[ -n "$HARC_BUILD_JOB_COUNT" ]]; then
  XCODE_OPTIONS+=(-jobs "$HARC_BUILD_JOB_COUNT")
fi
if [[ -n "${HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE:-}" ]]; then
  mkdir -p "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE"
  XCODE_OPTIONS+=(-packageCachePath "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE")
fi
mkdir -p "$OUTPUT"
xcrun simctl list devices available --json > "$OUTPUT/available-simulators.json"
python3 - "$OUTPUT/available-simulators.json" "$OUTPUT/destination.json" <<'PYSIM'
import json,sys
x=json.load(open(sys.argv[1]))
choices=[d for runtime,ds in x['devices'].items() if runtime.endswith('iOS-26-5') for d in ds if d.get('isAvailable') and d['name']=='iPhone 17']
if not choices: raise SystemExit('Required iPhone 17 iOS26.5 simulator unavailable; refusing substitute')
json.dump({'destination':'platform=iOS Simulator,id='+choices[0]['udid']},open(sys.argv[2],'w'))
PYSIM
DESTINATION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["destination"])' "$OUTPUT/destination.json")
SOURCE_SHA=$(git rev-parse HEAD)
# Build and execute the same selection, destination and products in separate budgets.
# Cold compilation must not consume the time needed to run tests and seal xcresult.
# Diagnostic only; original tests/assertions remain unchanged.
collect_trace() {
  # XCTest can execute in a booted clone while the selected template stays off.
  # Dedicated hosted job runs exactly one destination. Its XCTest clone is
  # restricted to the same runtime/model; do not persist unrelated inventory.
  xcrun simctl list devices --json | python3 -c 'import json,re,sys; print("\n".join(d["udid"] for runtime,ds in json.load(sys.stdin)["devices"].items() if runtime.endswith("iOS-26-5") for d in ds if d.get("state")=="Booted" and re.fullmatch(r"(?:Clone [0-9]+ of )?iPhone 17",d["name"])))' > "$OUTPUT/booted-simulators.txt" || return 0
  while IFS= read -r simulator; do
    [[ -n "$simulator" ]] || continue
    xcrun simctl spawn "$simulator" log show --last 1h --style json --predicate 'subsystem == "com.harc.mobile.syntheticplayback"' > "$OUTPUT/setup-trace-$simulator.json" 2> "$OUTPUT/setup-trace-$simulator-error.txt" || true
  done < "$OUTPUT/booted-simulators.txt"
}
trap collect_trace EXIT
TEST_OPTIONS=("${XCODE_OPTIONS[@]}" -project Harc.xcodeproj -scheme HarcMobile -configuration Debug
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" -parallel-testing-enabled NO
  -only-testing:HarcMobileUITests/HarcMobileRecordingDetailUITests/testLocalDetailRemainsUsableAtLargestDynamicType
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "HARC_BUILD_SHA=$SOURCE_SHA")
python3 scripts/run-package-tests.py --timeout-seconds 1800 --diagnostics-dir "$OUTPUT/build-diagnostics" -- xcodebuild "${TEST_OPTIONS[@]}" build-for-testing
python3 scripts/run-package-tests.py --timeout-seconds 900 --diagnostics-dir "$OUTPUT/diagnostics" -- xcodebuild "${TEST_OPTIONS[@]}" -resultBundlePath "$OUTPUT/configuration.xcresult" test-without-building
xcrun xcresulttool get test-results summary --path "$OUTPUT/configuration.xcresult" > "$OUTPUT/summary.json"
xcrun xcresulttool get test-results tests --path "$OUTPUT/configuration.xcresult" > "$OUTPUT/tests.json"
python3 scripts/check-xcode-test-results.py --summary "$OUTPUT/summary.json" --tests "$OUTPUT/tests.json" --require-bundle HarcMobileUITests --output "$OUTPUT/execution-gate.json" \
  --require-test HarcMobileUITests/HarcMobileRecordingDetailUITests/testLocalDetailRemainsUsableAtLargestDynamicType
