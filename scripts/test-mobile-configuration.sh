#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64
df -Pk "$PWD" | awk 'NR == 2 { exit ($4 < 5242880) }'
OUTPUT="${HARC_MOBILE_CONFIGURATION_OUTPUT:-.build/mobile-configuration}"
DERIVED="${HARC_MOBILE_CONFIGURATION_DERIVED:-$OUTPUT/derived}"
mkdir -p "$OUTPUT"
python3 scripts/select-ios-configuration-simulator.py "$OUTPUT/destination.json"
DESTINATION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["destination"])' "$OUTPUT/destination.json")
SOURCE_SHA=$(git rev-parse HEAD)
# Preserve owned-process diagnostics and xcresult on failure or timeout.
python3 scripts/run-package-tests.py --timeout-seconds 1800 --diagnostics-dir "$OUTPUT/diagnostics" -- \
  xcodebuild -skipMacroValidation -skipPackagePluginValidation -jobs 2 \
  -project Harc.xcodeproj -scheme HarcMobile -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$OUTPUT/configuration.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:HarcMobileAppTests/HarcMobileConfigurationTests \
  -only-testing:HarcMobileAppTests/HarcMobileLocalLibraryTests \
  -only-testing:HarcMobileAppTests/HarcMobilePlaybackSessionTests \
  -only-testing:HarcMobileAppTests/HarcMobileFinalizationRecoveryTests \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLocalLibraryIsReachableWithoutHost \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "HARC_BUILD_SHA=$SOURCE_SHA" test
