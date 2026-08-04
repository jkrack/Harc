import HarcAudioMobile
import XCTest
@testable import HarcMobile

final class HarcMobileConfigurationTests: XCTestCase {
    func testBackgroundModesContainOnlyAudio() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
                as? [String]
        )
        XCTAssertEqual(modes, ["audio"])
    }

    func testRequiredPrivacyDescriptionsArePresent() {
        for key in [
            "NSMicrophoneUsageDescription",
            "NSCameraUsageDescription",
            "NSLocalNetworkUsageDescription",
        ] {
            XCTAssertFalse(
                (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                    .isEmpty ?? true
            )
        }
    }

    func testStorageExhaustionQualificationArgumentParsesDurableQuota() throws {
        let argument = HarcMobileCaptureQualificationConfiguration
            .storageExhaustionArgument
        let quota = HarcMobileDurableMasterWriter.checkpointFrames * 2

        XCTAssertEqual(
            try HarcMobileCaptureQualificationConfiguration
                .storageExhaustionAfterCanonicalBytes(
                    arguments: ["HarcMobile", argument, String(quota)]
                ),
            quota
        )
    }

    func testStorageExhaustionQualificationArgumentRejectsUnsafeValues() {
        let argument = HarcMobileCaptureQualificationConfiguration
            .storageExhaustionArgument
        let minimum = HarcMobileDurableMasterWriter.checkpointFrames * 2

        XCTAssertThrowsError(try HarcMobileCaptureQualificationConfiguration
            .storageExhaustionAfterCanonicalBytes(
                arguments: ["HarcMobile", argument]
            ))
        XCTAssertThrowsError(try HarcMobileCaptureQualificationConfiguration
            .storageExhaustionAfterCanonicalBytes(
                arguments: ["HarcMobile", argument, String(minimum - 2)]
            ))
        XCTAssertThrowsError(try HarcMobileCaptureQualificationConfiguration
            .storageExhaustionAfterCanonicalBytes(
                arguments: ["HarcMobile", argument, String(minimum + 1)]
            ))
        XCTAssertThrowsError(try HarcMobileCaptureQualificationConfiguration
            .storageExhaustionAfterCanonicalBytes(
                arguments: ["HarcMobile", argument, "not-a-number"]
            ))
        XCTAssertThrowsError(try HarcMobileCaptureQualificationConfiguration
            .storageExhaustionAfterCanonicalBytes(
                arguments: [
                    "HarcMobile", argument, String(minimum),
                    argument, String(minimum),
                ]
            ))
    }

    @MainActor
    func testStorageExhaustionFinalizationHasVisibleTerminalState() {
        let recordingUUID = UUID()

        XCTAssertEqual(
            HarcMobileCaptureCoordinator.terminalState(
                recordingUUID: recordingUUID,
                finalizationReason: .storageExhausted
            ),
            .storageExhausted(recordingUUID: recordingUUID)
        )
    }
}
