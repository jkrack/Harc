#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || exit 2
cd "$(dirname "$0")/.."
OUTPUT=.build/mobile-seek-phase
mkdir -p "$OUTPUT"
case "${1:-}" in
  build) python3 scripts/select-ios-configuration-simulator.py "$OUTPUT/destination.json" ;;
  test) test -f "$OUTPUT/destination.json" ;;
  *) exit 2 ;;
esac
DESTINATION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["destination"])' "$OUTPUT/destination.json")
OPTIONS=(-project Harc.xcodeproj -scheme HarcMobile -configuration Debug
  -destination "$DESTINATION" -derivedDataPath "$OUTPUT/derived"
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
  -only-testing:HarcMobileUITests/HarcMobileRecordingDetailUITests/testLocalDetailSeekPreservesPausedPlayback
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "HARC_BUILD_SHA=$(git rev-parse HEAD)")
# Retain plugin/macro trust enforcement. Never add skip-validation overrides.
if [[ "$1" == build ]]; then
  xcodebuild "${OPTIONS[@]}" build-for-testing
else
  xcodebuild "${OPTIONS[@]}" -resultBundlePath "$OUTPUT/result.xcresult" test-without-building
  xcrun xcresulttool get test-results summary --path "$OUTPUT/result.xcresult" > "$OUTPUT/summary.json"
  xcrun xcresulttool get test-results tests --path "$OUTPUT/result.xcresult" > "$OUTPUT/tests.json"
  python3 scripts/check-xcode-test-results.py --summary "$OUTPUT/summary.json" --tests "$OUTPUT/tests.json" --require-bundle HarcMobileUITests --output "$OUTPUT/execution-gate.json" \
    --require-test HarcMobileUITests/HarcMobileRecordingDetailUITests/testLocalDetailSeekPreservesPausedPlayback
fi
