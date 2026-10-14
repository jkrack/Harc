import AVFoundation
import Foundation
import HarcClientStore
import HarcDomain
import HarcTransfer
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileLocalLibraryTests: XCTestCase {
    func testLocalMasterIsVisibleAndDecodableWithoutHost() throws {
        try withRecording { store, url in
            XCTAssertNil(try store.activeAdoption())
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
        }
    }

    func testOfflineHostAndPendingOrFailedSyncDoNotHideLocalMaster() throws {
        try withRecording { store, url in
            try adopt(store)
            // There is deliberately no Host route or live transport in this fixture.
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
            _ = try store.updateRecordingOutbox(for: ClientStoreFixtures.origin()) {
                try $0.queue()
            }
            try assertLocalPlaybackSource(store, url: url, state: .transferring)
            _ = try store.updateRecordingOutbox(for: ClientStoreFixtures.origin()) {
                try $0.failRecoverably(TransferFailure(code: "host_unavailable"))
            }
            try assertLocalPlaybackSource(store, url: url, state: .retryNeeded)
        }
    }

    func testSecurityBlockedSyncDoesNotPreventLocalPlayback() throws {
        try withRecording { store, url in
            try adopt(store)
            _ = try store.updateRecordingOutbox(for: ClientStoreFixtures.origin()) {
                try $0.queue()
                try $0.beginAuthorization()
                try $0.blockForSecurity(.grantRevoked)
            }
            try assertLocalPlaybackSource(store, url: url, state: .securityBlocked)
        }
    }

    func testForgettingHostPreservesLocalPlaybackAcrossStoreReopen() throws {
        try withRecording { store, url in
            try adopt(store)
            XCTAssertTrue(try store.forgetActiveHost())
            XCTAssertNil(try store.activeAdoption())
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
            let reopened = try HarcTransferStore(
                rootDirectory: url.deletingLastPathComponent(),
                installationDeviceID: ClientStoreFixtures.device(),
                storageAttributes: RecordingStorageAttributes()
            )
            try assertLocalPlaybackSource(reopened, url: url, state: .localOnly)
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

    private func adopt(_ store: HarcTransferStore) throws {
        _ = try store.adopt(ClientStoreFixtures.adoption(
            tuple: ClientStoreFixtures.tuple(library: 90, authorityByte: 90),
            keyByte: 90, transportEpoch: 1, transportByte: 1,
            grantEpoch: 1, grantByte: 1
        ))
    }

    private func withRecording(
        _ body: (HarcTransferStore, URL) throws -> Void
    ) throws {
        let root = temporaryClientStoreDirectory()
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
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(), masterFileURL: url
        )
        try body(store, url)
    }
}
