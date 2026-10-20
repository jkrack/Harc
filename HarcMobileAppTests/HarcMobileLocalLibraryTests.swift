import AVFoundation
import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcClientTransport
import HarcTransfer
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileLocalLibraryTests: XCTestCase {
    private let deviceKey = SoftwareP256SigningKey()

    private var origin: OriginRecordingID {
        OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    }

    func testLocalMasterIsVisibleAndDecodableWithoutHost() throws {
        try withRecording { store, url in
            XCTAssertNil(try store.activeAdoption())
            try assertLocalPlaybackSource(store, url: url, state: .localOnly)
        }
    }

    func testOfflineHostAndPendingOrFailedSyncDoNotHideLocalMaster() async throws {
        let adoption = try await validatedOfflineAdoption()
        try withRecording { store, url in
            // Adoption is persisted, but there is no Host route or live transport.
            _ = try store.adopt(adoption)
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

    func testSecurityBlockedSyncDoesNotPreventLocalPlayback() async throws {
        let adoption = try await validatedOfflineAdoption()
        try withRecording { store, url in
            _ = try store.adopt(adoption)
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

    private func validatedOfflineAdoption() async throws -> ValidatedClientAdoptionEvidence {
        let fixture = try BootstrapClientFixture(deviceKey: deviceKey)
        let rpc = BootstrapClientFakeRPC(fixture: fixture)
        let client = try fixture.client(rpc: rpc)
        _ = try await client.beginPairing(
            ticket: fixture.ticket, deviceSigner: deviceKey,
            requestedScopes: fixture.scopes, deviceLabel: "Synthetic local library fixture"
        )
        let result = try await client.getPairingStatus()
        guard case .approved(let adoption, _) = result else {
            throw BootstrapClientFakeError.invalidRequest
        }
        let proofVerified = await rpc.proofWasVerified()
        XCTAssertTrue(proofVerified)
        XCTAssertEqual(adoption.grant.deviceID, origin.deviceID)
        XCTAssertTrue(adoption.grant.scopes.contains(.recordingUploadOwn))
        await rpc.disconnect()
        let disconnected = await rpc.isDisconnected()
        XCTAssertTrue(disconnected)
        var request = Harc_V1_GetHostInfoRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        do {
            _ = try await rpc.getHostInfo(request)
            XCTFail("Disconnected fixture transport must reject requests")
        } catch {
            XCTAssertEqual(error as? BootstrapClientFakeError, .disconnected)
        }
        return adoption
    }

    private func assertLocalPlaybackSource(
        _ store: HarcTransferStore,
        url: URL,
        state: HarcMobileLocalRecording.TransferState
    ) throws {
        let recordings = try HarcMobileLocalRecording.load(from: store)
        XCTAssertEqual(recordings.count, 1)
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertEqual(
            recording.masterFileURL.resolvingSymlinksInPath(),
            url.resolvingSymlinksInPath()
        )
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
            storageAttributes: LocalLibraryStorageAttributes(),
            now: { Date(timeIntervalSince1970: Double(TransportTrustFixtures.nowMilliseconds) / 1_000) }
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
