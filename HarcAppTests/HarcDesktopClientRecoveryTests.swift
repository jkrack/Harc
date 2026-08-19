import Foundation
import HarcClientStore
import HarcDomain
import HarcTransfer
import HarcUI
import Testing
@testable import Harc

@Suite("Desktop Client Recover & Sync")
struct HarcDesktopClientRecoveryTests {
    @Test("sidecar repairs a missing outbox and repeat runs are idempotent")
    func repairsMissingOutbox() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recording = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        try fixture.writeCapture(recording: recording, deviceID: fixture.deviceID)

        let first = try fixture.reconcile()
        #expect(first.mastersFound == 1)
        #expect(first.sidecarsFound == 1)
        #expect(first.outboxesRepaired == 1)
        #expect(first.retryRequested == 1)
        #expect(first.issues.isEmpty)
        #expect(try fixture.store.recordingOutboxes().count == 1)

        let repeatRun = try fixture.reconcile()
        #expect(repeatRun.outboxesRepaired == 0)
        #expect(repeatRun.alreadyTracked == 1)
        #expect(repeatRun.retryRequested == 1)
        #expect(repeatRun.issues.isEmpty)
    }

    @Test("owned canonical WAV rebuilds a missing sidecar and outbox")
    func rebuildsOrphanedMaster() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recording = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let master = fixture.masterURL(recording)
        try fixture.makeWAV().write(to: master)

        let report = try fixture.reconcile()

        #expect(report.mastersFound == 1)
        #expect(report.sidecarsFound == 0)
        #expect(report.sidecarsRebuilt == 1)
        #expect(report.outboxesRepaired == 1)
        #expect(report.retryRequested == 1)
        #expect(report.issues.isEmpty)
        let sidecar = try fixture.readSidecar(recording)
        #expect(sidecar.capture.finalizationReason == .recoveredDurablePrefix)
        #expect(sidecar.capture.producingDeviceID == fixture.deviceID)
    }

    @Test("bad metadata does not prevent another recording from being repaired")
    func isolatesInvalidSidecar() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let invalid = UUID(uuidString: "deadbeef-0000-4000-8000-000000000001")!
        try fixture.makeWAV().write(to: fixture.masterURL(invalid))
        try Data("not-json".utf8).write(to: fixture.sidecarURL(invalid))
        let recoverable = UUID(uuidString: "deadbeef-0000-4000-8000-000000000002")!
        try fixture.makeWAV().write(to: fixture.masterURL(recoverable))

        let report = try fixture.reconcile()

        #expect(report.mastersFound == 2)
        #expect(report.outboxesRepaired == 1)
        #expect(report.retryRequested == 1)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].recording == "deadbeef")
        #expect(try fixture.store.recordingOutboxes().count == 1)
    }

    @Test("foreign Client identity stays fail-closed")
    func blocksForeignIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let foreign = try DeviceID(Data(repeating: 0x77, count: 32))
        let recording = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        try fixture.writeCapture(recording: recording, deviceID: foreign)

        let report = try fixture.reconcile()

        #expect(report.securityBlocked == 1)
        #expect(report.retryRequested == 0)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].message.contains("different Client identity"))
        #expect(try fixture.store.recordingOutboxes().isEmpty)
    }

    @Test("conflicting metadata excludes an existing outbox from retry")
    func excludesConflictingExistingOutbox() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recording = UUID(uuidString: "88888888-2222-4333-8444-555555555555")!
        try fixture.writeCapture(recording: recording, deviceID: fixture.deviceID)
        _ = try fixture.reconcile()
        try FileManager.default.removeItem(at: fixture.sidecarURL(recording))
        let foreign = try DeviceID(Data(repeating: 0x66, count: 32))
        try fixture.writeCapture(recording: recording, deviceID: foreign)

        let outcome = try fixture.recoveryOutcome()

        let currentOrigin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: recording
        )
        #expect(outcome.blockedOrigins.contains(currentOrigin))
        #expect(outcome.report.securityBlocked == 1)
        #expect(outcome.report.retryRequested == 0)
    }
}

private final class Fixture {
    let root: URL
    let captures: URL
    let deviceID: DeviceID
    let store: HarcTransferStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-client-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captures,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        deviceID = try DeviceID(Data(repeating: 0x22, count: 32))
        store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: deviceID
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func reconcile() throws -> ClientRecoverSyncReport {
        try recoveryOutcome().report
    }

    func recoveryOutcome() throws -> HarcDesktopClientRecovery.Outcome {
        try HarcDesktopClientRecovery.reconcile(
            root: root,
            store: store,
            deviceID: deviceID
        )
    }

    func masterURL(_ recording: UUID) -> URL {
        captures.appendingPathComponent(
            "\(recording.uuidString.lowercased()).wav"
        )
    }

    func sidecarURL(_ recording: UUID) -> URL {
        captures.appendingPathComponent(
            "\(recording.uuidString.lowercased()).capture.json"
        )
    }

    func writeCapture(recording: UUID, deviceID: DeviceID) throws {
        let master = masterURL(recording)
        try makeWAV().write(to: master)
        let prepared = try HarcDesktopClientFiles.inspectCanonicalWAV(master)
        let origin = OriginRecordingID(deviceID: deviceID, recordingUUID: recording)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let capture = try FinalizedCapture(
            producingDeviceID: deviceID,
            originRecordingID: origin,
            captureStartedAt: startedAt,
            captureEndedAt: startedAt.addingTimeInterval(1),
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: 1_000_000_000,
            finalizationReason: .userStopped,
            totalCanonicalFrames: prepared.frames,
            totalCanonicalBytes: prepared.frames * 2,
            canonicalPCMSHA256: try CanonicalPCMHash(prepared.pcmSHA256),
            discontinuities: []
        )
        let sidecar = HarcDesktopClientCaptureSidecar(
            capture: capture,
            transcript: nil,
            speakerEmbeddings: nil,
            persistedAt: startedAt
        )
        try HarcDesktopClientFiles.writeSidecar(sidecar, to: sidecarURL(recording))
    }

    func readSidecar(_ recording: UUID) throws -> HarcDesktopClientCaptureSidecar {
        try JSONDecoder().decode(
            HarcDesktopClientCaptureSidecar.self,
            from: Data(contentsOf: sidecarURL(recording))
        )
    }

    func makeWAV() -> Data {
        let pcm = Data(repeating: 0x12, count: 32_000)
        var wav = Data("RIFF".utf8)
        appendLittleEndian(UInt32(pcm.count + 36), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(16_000), to: &wav)
        appendLittleEndian(UInt32(32_000), to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
