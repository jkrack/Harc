import AVFoundation
import HarcAudioMobile
import HarcDomain
import UIKit
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

    @MainActor
    func testPairingCameraPreviewTracksSheetLayoutBounds() {
        let controller = HarcPairingPreviewViewController(
            session: AVCaptureSession()
        )
        controller.loadViewIfNeeded()

        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.previewLayer.frame, controller.view.bounds)

        controller.view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.previewLayer.frame, controller.view.bounds)
    }

    func testPackagedPrivacyManifestMatchesMobileDataAndFileUsage() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "PrivacyInfo",
                withExtension: "xcprivacy"
            )
        )
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        ).isEmpty)
        let accessedAPIs = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        XCTAssertEqual(accessedAPIs.count, 1)
        let fileMetadata = try XCTUnwrap(accessedAPIs.first)
        XCTAssertEqual(
            fileMetadata["NSPrivacyAccessedAPIType"] as? String,
            "NSPrivacyAccessedAPICategoryFileTimestamp"
        )
        XCTAssertEqual(
            fileMetadata["NSPrivacyAccessedAPITypeReasons"] as? [String],
            ["C617.1"]
        )
    }

    func testReleaseMetadataIsIPhoneOnlyAndMatchesExportDeclaration() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.harc.HarcMobile")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily")
                as? [Int],
            [1]
        )
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption"
            ) as? Bool,
            false
        )
    }

#if targetEnvironment(simulator)
    func testSimulatorCaptureStorageStillEnforcesBackupExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-mobile-simulator-storage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FoundationHarcMobileCaptureStorageAttributes().applyAndVerify(
            .transferArtifact,
            to: root
        )
        XCTAssertEqual(
            try root.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            true
        )
    }
#endif

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

    func testUITestRootArgumentRequiresOneCanonicalUUID() throws {
        let argument = HarcMobileUITestConfiguration.rootArgument
        let rootID = UUID()

        XCTAssertEqual(
            try HarcMobileUITestConfiguration.rootID(
                arguments: ["HarcMobile", argument, rootID.uuidString]
            ),
            rootID
        )
        XCTAssertNil(try HarcMobileUITestConfiguration.rootID(
            arguments: ["HarcMobile"]
        ))
        XCTAssertThrowsError(try HarcMobileUITestConfiguration.rootID(
            arguments: ["HarcMobile", argument]
        ))
        XCTAssertThrowsError(try HarcMobileUITestConfiguration.rootID(
            arguments: ["HarcMobile", argument, "not-a-uuid"]
        ))
        XCTAssertThrowsError(try HarcMobileUITestConfiguration.rootID(
            arguments: [
                "HarcMobile", argument, rootID.uuidString,
                argument, rootID.uuidString,
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

    func testHandoffCapacityCoversHardwareSizedInputSlices() {
        XCTAssertEqual(
            HarcMobileCaptureCoordinator.handoffFrameCapacity(
                inputSampleRate: 48_000
            ),
            48_000
        )
        XCTAssertEqual(
            HarcMobileCaptureCoordinator.handoffFrameCapacity(
                inputSampleRate: 44_100
            ),
            44_100
        )
    }

    func testHandoffCapacityPreservesFloorAndMemoryBound() {
        XCTAssertEqual(
            HarcMobileCaptureCoordinator.handoffFrameCapacity(
                inputSampleRate: 2_000
            ),
            4_096
        )
        XCTAssertEqual(
            HarcMobileCaptureCoordinator.handoffFrameCapacity(
                inputSampleRate: 384_000
            ),
            192_000
        )
        XCTAssertEqual(
            HarcMobileCaptureCoordinator.handoffFrameCapacity(
                inputSampleRate: .nan
            ),
            4_096
        )
    }

    func testCapturePathIgnoresUnchangedRouteNotifications() throws {
        let builtIn = try CaptureRouteDescriptor(
            identifier: "Built-In Microphone",
            name: "iPhone Microphone",
            sampleRateHz: 48_000,
            channelCount: 1
        )
        let headset = try CaptureRouteDescriptor(
            identifier: "Headset Microphone",
            name: "Headset Microphone",
            sampleRateHz: 48_000,
            channelCount: 1
        )

        XCTAssertFalse(HarcMobileCaptureCoordinator.capturePathRequiresRebuild(
            activeRoute: builtIn,
            currentRoute: builtIn
        ))
        XCTAssertTrue(HarcMobileCaptureCoordinator.capturePathRequiresRebuild(
            activeRoute: builtIn,
            currentRoute: headset
        ))
        XCTAssertTrue(HarcMobileCaptureCoordinator.capturePathRequiresRebuild(
            activeRoute: builtIn,
            currentRoute: nil
        ))
    }
}
