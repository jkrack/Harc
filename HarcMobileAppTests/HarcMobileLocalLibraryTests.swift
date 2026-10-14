import AVFoundation
import Foundation
import HarcClientStore
import HarcDomain
import HarcTransfer
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileLocalLibraryTests: XCTestCase {
    private var origin: OriginRecordingID {
        OriginRecordingID(
            deviceID: try! DeviceID(Data(repeating: 1, count: 32)),
            recordingUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    func testLocalMasterIsVisibleAndDecodableWithoutHost() throws {
        try withRecording { store, url in
            XCTAssertNil(try store.activeAdoption())
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
        }
    }

    func testOfflineHostAndPendingOrFailedSyncDoNotHideLocalMaster() throws {
        try withRecording { store, url in
            // There is deliberately no Host route or live transport in this fixture.
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
            _ = try store.updateRecordingOutbox(for: origin) {
                try $0.queue()
            }
            try assertLocalPlaybackSource(store, url: url, state: .transferring)
            _ = try store.updateRecordingOutbox(for: origin) {
                try $0.failRecoverably(TransferFailure(code: "host_unavailable"))
            }
            try assertLocalPlaybackSource(store, url: url, state: .retryNeeded)
        }
    }

    func testSecurityBlockedSyncDoesNotPreventLocalPlayback() throws {
        try withRecording { store, url in
            _ = try store.updateRecordingOutbox(for: origin) {
                try $0.queue()
                try $0.beginAuthorization()
                try $0.blockForSecurity(.grantRevoked)
            }
            try assertLocalPlaybackSource(store, url: url, state: .securityBlocked)
        }
    }

    func testMissingMasterIsNotAdvertisedAsPlayable() throws {
        try withRecording { store, url in
            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(try HarcMobileLocalRecording.load(from: store).isEmpty)
        }
    }

    private func assertLocalPlaybackSource(
        _ store: HarcTransferStore,
        url: URL,
        state: HarcMobileLocalRecording.TransferState
    ) throws {
        let recordings = try HarcMobileLocalRecording.load(from: store)
        XCTAssertEqual(recordings.count, 1)
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertEqual(recording.masterFileURL, url)
        XCTAssertEqual(recording.transferState, state)
        // Decode synthetic fixture metadata, without activating an audio session.
        XCTAssertEqual(try AVAudioFile(forReading: recording.masterFileURL).length, 1_000)
    }

    private func withRecording(
        _ body: (HarcTransferStore, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("synthetic.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
        buffer.frameLength = 1_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1_000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: LocalLibraryStorageAttributes()
        )
        _ = try store.persistFinalizedCapture(
            FinalizedCapture(
                producingDeviceID: origin.deviceID,
                originRecordingID: origin,
                captureStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
                captureEndedAt: Date(timeIntervalSince1970: 1_700_000_010),
                captureStartedMonotonicNanoseconds: 1_000,
                captureEndedMonotonicNanoseconds: 10_000_001_000,
                finalizationReason: .userStopped,
                totalCanonicalFrames: 1_000,
                totalCanonicalBytes: 2_000,
                canonicalPCMSHA256: CanonicalPCMHash(Data(repeating: 9, count: 32)),
                discontinuities: []
            ), masterFileURL: url
        )
        try body(store, url)
    }
}

private struct LocalLibraryStorageAttributes: ClientStoreStorageAttributeApplying {
    func isProtectedDataAvailable(for _: ClientStoreStoragePolicy) -> Bool { true }
    func applyAndVerify(
        _: ClientStoreStoragePolicy, to _: ClientStoreStorageArtifact
    ) throws {}
}
