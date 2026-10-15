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
