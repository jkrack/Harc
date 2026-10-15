import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcDomain
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileFinalizationRecoveryTests: XCTestCase {
    func testRelaunchRegistersFinalizedMasterAfterCallbackWasNeverRunExactlyOnce() throws {
        try withFinalized { root, locations, master in
            let store = try self.openStore(root, device: master.producingDeviceID)
            XCTAssertTrue(try store.recordingOutboxes().isEmpty)
            XCTAssertEqual(try HarcMobileAppModel.recoverCaptures(
                store: store, locations: locations, attributes: SyntheticStorageAttributes()
            ), [master])
            let reopened = try self.openStore(root, device: master.producingDeviceID)
            XCTAssertTrue(try HarcMobileAppModel.recoverCaptures(
                store: reopened, locations: locations, attributes: SyntheticStorageAttributes()
            ).isEmpty)
            XCTAssertEqual(try reopened.recordingOutboxes().count, 1)
            let local = try HarcMobileLocalRecording.load(from: reopened)
            XCTAssertEqual(local.count, 1)
            XCTAssertEqual(local.first?.masterFileURL, master.masterFileURL)
            XCTAssertEqual(local.first?.transferState, .localOnly)
        }
    }

    func testFailedOutboxCallbackStillDeactivatesAndRelaunchRecoversMaster() throws {
        try withFinalized { root, locations, master in
            let store = try self.openStore(root, device: master.producingDeviceID)
            var deactivated = false
            XCTAssertThrowsError(try HarcMobileCaptureCoordinator.persistBeforeDeactivating(
                master, persist: { _ in throw Failure.store },
                deactivate: { deactivated = true }
            ))
            XCTAssertTrue(deactivated)
            XCTAssertTrue(try store.recordingOutboxes().isEmpty)
            _ = try HarcMobileAppModel.recoverCaptures(
                store: store, locations: locations, attributes: SyntheticStorageAttributes()
            )
            XCTAssertEqual(try HarcMobileLocalRecording.load(from: store).count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: master.masterFileURL.path))
            XCTAssertNil(try store.verifiedRecordingReceipt(for: master.originRecordingID))
            XCTAssertNil(try store.cleanupIntent(for: master.originRecordingID))
        }
    }

    func testDeactivationFailureCannotPreventDurableOutboxRegistration() throws {
        try withFinalized { root, locations, master in
            let store = try self.openStore(root, device: master.producingDeviceID)
            XCTAssertThrowsError(try HarcMobileCaptureCoordinator.persistBeforeDeactivating(
                master,
                persist: {
                    _ = try store.persistFinalizedCapture(
                        try HarcMobileAppModel.finalizedCapture($0), masterFileURL: $0.masterFileURL
                    )
                },
                deactivate: {
                    XCTAssertEqual(try store.recordingOutboxes().count, 1)
                    throw Failure.audioSession
                }
            ))
            XCTAssertTrue(try HarcMobileAppModel.recoverCaptures(
                store: store, locations: locations, attributes: SyntheticStorageAttributes()
            ).isEmpty)
            XCTAssertEqual(try HarcMobileLocalRecording.load(from: store).count, 1)
            XCTAssertNil(try store.verifiedRecordingReceipt(for: master.originRecordingID))
        }
    }

    func testMixedOrphansPreserveHealthyLibraryAndCaptureReadiness() throws {
        try withFinalized { root, locations, healthy in
            let store = try self.openStore(root, device: healthy.producingDeviceID)
            _ = try store.persistFinalizedCapture(
                try HarcMobileAppModel.finalizedCapture(healthy), masterFileURL: healthy.masterFileURL
            )
            let orphan = try self.finalize(locations, device: healthy.producingDeviceID)
            var rejected: [URL] = []
            // Each invalid artifact is preserved and excluded independently.
            for mutation in 0 ..< 4 {
                let device = mutation == 3
                    ? try DeviceID(Data(repeating: 0x52, count: 32))
                    : healthy.producingDeviceID
                let bad = try self.finalize(locations, device: device)
                let metadata = locations.finalized.appendingPathComponent(
                    bad.originRecordingID.recordingUUID.uuidString.lowercased() + ".capture.json"
                )
                if mutation == 0 {
                    try Data("malformed".utf8).write(to: metadata)
                } else if mutation == 1 {
                    try FileManager.default.removeItem(at: bad.masterFileURL)
                } else if mutation == 2 {
                    var bytes = try Data(contentsOf: bad.masterFileURL)
                    bytes[44] ^= 1
                    try bytes.write(to: bad.masterFileURL)
                }
                rejected.append(metadata)
            }
            let filesBefore = try self.captureFileBytes(locations)
            let model = HarcMobileAppModel()
            let recovered = try model.prepareLocalCapture(
                store: store, locations: locations, attributes: SyntheticStorageAttributes()
            )
            XCTAssertTrue(recovered.contains(orphan))
            XCTAssertEqual(Set(model.rejectedCaptureMetadataFiles.map { $0.resolvingSymlinksInPath() }),
                           Set(rejected.map { $0.resolvingSymlinksInPath() }))
            XCTAssertEqual(model.captureCoordinator?.state, .idle)
            let local = try HarcMobileLocalRecording.load(from: store)
            XCTAssertTrue(local.contains { $0.masterFileURL == healthy.masterFileURL })
            XCTAssertTrue(local.contains { $0.masterFileURL == orphan.masterFileURL })
            XCTAssertEqual(local.count, 2)
            XCTAssertEqual(try self.captureFileBytes(locations), filesBefore)
            for metadata in rejected {
                XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
            }
            let before = try store.recordingOutboxes().count
            XCTAssertTrue(try model.prepareLocalCapture(
                store: store, locations: locations, attributes: SyntheticStorageAttributes()
            ).isEmpty)
            XCTAssertEqual(try store.recordingOutboxes().count, before)
            XCTAssertEqual(model.captureCoordinator?.state, .idle)
        }
    }

    private func captureFileBytes(_ locations: HarcMobileCaptureLocations) throws -> [URL: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: locations.finalized, includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
    }

    private func finalize(
        _ locations: HarcMobileCaptureLocations, device: DeviceID
    ) throws -> HarcMobileFinalizedMaster {
        let started = Date(timeIntervalSince1970: 1_900_000_000)
        let writer = try HarcMobileDurableMasterWriter(
            locations: locations, producingDeviceID: device,
            captureStartedAt: started, captureStartedMonotonicNanoseconds: 1_000,
            attributes: SyntheticStorageAttributes()
        )
        try writer.appendCanonicalPCM(Data([1, 2, 3, 4, 5, 6, 7, 8]),
                                      endedAt: started.addingTimeInterval(1),
                                      endedMonotonicNanoseconds: 2_000)
        return try writer.finalize(reason: .userStopped)
    }

    private enum Failure: Error { case store, audioSession }

    private func openStore(_ root: URL, device: DeviceID) throws -> HarcTransferStore {
        try HarcTransferStore(rootDirectory: root, installationDeviceID: device,
                              storageAttributes: SyntheticStorageAttributes())
    }

    private func withFinalized(
        _ body: (URL, HarcMobileCaptureLocations, HarcMobileFinalizedMaster) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = try HarcMobileCaptureLocations(applicationSupportRoot: root)
        let started = Date(timeIntervalSince1970: 1_900_000_000)
        let writer = try HarcMobileDurableMasterWriter(
            locations: locations, producingDeviceID: DeviceID(Data(repeating: 0x51, count: 32)),
            captureStartedAt: started, captureStartedMonotonicNanoseconds: 1_000,
            attributes: SyntheticStorageAttributes()
        )
        try writer.appendCanonicalPCM(Data([1, 2, 3, 4, 5, 6, 7, 8]),
                                      endedAt: started.addingTimeInterval(1),
                                      endedMonotonicNanoseconds: 2_000)
        try body(root, locations, writer.finalize(reason: .userStopped))
    }
}

private struct SyntheticStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying, ClientStoreStorageAttributeApplying
{
    func applyAndVerify(_: HarcMobileCaptureStoragePolicy, to _: URL) throws {}
    func isProtectedDataAvailable(for _: ClientStoreStoragePolicy) -> Bool { true }
    func applyAndVerify(_: ClientStoreStoragePolicy, to _: ClientStoreStorageArtifact) throws {}
}
