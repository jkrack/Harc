#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64
df -Pk "$PWD" | awk 'NR == 2 { exit ($4 < 5242880) }'
OUTPUT="${HARC_MOBILE_CONFIGURATION_OUTPUT:-.build/mobile-configuration}"
DERIVED="${HARC_MOBILE_CONFIGURATION_DERIVED:-$OUTPUT/derived}"
XCODE_OPTIONS=(-skipMacroValidation -skipPackagePluginValidation -jobs 2)
if [[ -n "${HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE:-}" ]]; then
  mkdir -p "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE"
  XCODE_OPTIONS+=(-packageCachePath "$HARC_MOBILE_CONFIGURATION_PACKAGE_CACHE")
fi
mkdir -p "$OUTPUT"
python3 scripts/select-ios-configuration-simulator.py "$OUTPUT/destination.json"
DESTINATION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["destination"])' "$OUTPUT/destination.json")
SOURCE_SHA=$(git rev-parse HEAD)
# Preserve owned-process diagnostics and xcresult on failure or timeout.
python3 scripts/run-package-tests.py --timeout-seconds 1800 --diagnostics-dir "$OUTPUT/diagnostics" -- \
  xcodebuild "${XCODE_OPTIONS[@]}" \
  -project Harc.xcodeproj -scheme HarcMobile -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$OUTPUT/configuration.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:HarcMobileAppTests/HarcMobileConfigurationTests \
  -only-testing:HarcMobileAppTests/HarcMobileCaptureExperienceTests \
  -only-testing:HarcMobileAppTests/HarcMobileCapturePipelineTests \
  -only-testing:HarcMobileAppTests/HarcMobileSyncStatusPresentationTests \
  -only-testing:HarcMobileAppTests/HarcMobileLocalLibraryTests \
  -only-testing:HarcMobileAppTests/HarcMobileLibraryRefreshPresentationTests \
  -only-testing:HarcMobileAppTests/HarcMobilePlaybackSessionTests \
  -only-testing:HarcMobileAppTests/HarcMobileFinalizationRecoveryTests \
  -only-testing:HarcMobileAppTests/HarcMobileUploadPreparationTests \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLocalLibraryIsReachableWithoutHost \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testSyncDetailsAreDiscoverableWithoutHostOrRecording \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testHostTabFromLibraryRootControl \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testHostTabFromSyncControl \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testHostTabFromEmptyLocalRecordings \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testRepeatedOfflineNavigationPreservesEachTabStack \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testRecordEmptyTodayRemainsNavigableAtLargestText \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLibraryDaySummaryRemainsReadableAtLargestText \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLibraryTextActionsHaveAccessibleContrast \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLongHostNameKeepsRecordAndToolbarsUsable \
  -only-testing:HarcMobileUITests/HarcMobileReleaseReadinessUITests/testSetupMacCardRemainsUsableAtNormalAndLargestText \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "HARC_BUILD_SHA=$SOURCE_SHA" test

# A successful xcodebuild exit alone does not prove the selected tests ran.
xcrun xcresulttool get test-results summary --path "$OUTPUT/configuration.xcresult" \
  > "$OUTPUT/configuration-summary.json"
xcrun xcresulttool get test-results tests --path "$OUTPUT/configuration.xcresult" \
  > "$OUTPUT/configuration-test-tree.json"
python3 scripts/check-xcode-test-results.py \
  --summary "$OUTPUT/configuration-summary.json" \
  --tests "$OUTPUT/configuration-test-tree.json" \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLibraryTextActionsHaveAccessibleContrast \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLongHostNameKeepsRecordAndToolbarsUsable \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testSetupMacCardRemainsUsableAtNormalAndLargestText \
  --require-test HarcMobileAppTests/HarcMobileCaptureExperienceTests/testSetupMacIconInkStaysInsideItsTileAtEveryTextSize \
  --require-test HarcMobileAppTests/HarcMobileCaptureExperienceTests/testTimelineAccessibilityDescribesOnlyVisibleIntervalsInChronologicalOrder \
  --require-bundle HarcMobileAppTests \
  --require-bundle HarcMobileUITests \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testRecordEmptyTodayRemainsNavigableAtLargestText \
  --require-test HarcMobileUITests/HarcMobileReleaseReadinessUITests/testLibraryDaySummaryRemainsReadableAtLargestText \
  --require-test HarcMobileAppTests/HarcMobileCapturePipelineTests/testDequeuedReconfigurationCheckpointFailureReleasesEveryCaller \
  --require-test HarcMobileAppTests/HarcMobileCapturePipelineTests/testCancelledReconfigurationCheckpointFailureReleasesEveryCaller \
  --require-test HarcMobileAppTests/HarcMobileCapturePipelineTests/testReconfigurationAfterWriterFailureFailsInsteadOfWaiting \
  --require-test HarcMobileAppTests/HarcMobileCapturePipelineTests/testFormatChangingRouteRebuildsConverterWithoutSplittingMaster \
  --output "$OUTPUT/configuration-execution-gate.json"
