import CryptoKit
import Foundation
import HarcDomain
import Testing
@testable import HarcAudioMobile

@Suite("Mobile durable canonical master")
struct HarcMobileDurableMasterWriterTests {
    @Test("finalization publishes an exact protected canonical WAV")
    func finalize() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = Data((0 ..< 32_000).map { UInt8(truncatingIfNeeded: $0) })
        let writer = try fixture.writer()
        try writer.appendCanonicalPCM(
            bytes,
            endedAt: fixture.started.addingTimeInterval(1),
            endedMonotonicNanoseconds: 2_000_000_000
        )
        let result = try writer.finalize(reason: .userStopped)

        #expect(result.totalCanonicalFrames == 16_000)
        #expect(result.totalCanonicalBytes == UInt64(bytes.count))
        let expectedHash = try CanonicalPCMHash(
            Data(SHA256.hash(data: bytes))
        )
        #expect(result.canonicalPCMSHA256 == expectedHash)
        let wav = try Data(contentsOf: result.masterFileURL)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8 ..< 12], encoding: .ascii) == "WAVE")
        #expect(String(data: wav[36 ..< 40], encoding: .ascii) == "data")
        #expect(wav.dropFirst(44) == bytes)
    }

    @Test("recovery truncates unsynchronized tail to the durable checkpoint")
    func recovery() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let durable = Data(
            repeating: 0x4a,
            count: Int(HarcMobileDurableMasterWriter.checkpointFrames * 2)
        )
        let tail = Data(repeating: 0x7b, count: 64)
        let writer = try fixture.writer()
        try writer.appendCanonicalPCM(
            durable,
            endedAt: fixture.started.addingTimeInterval(5),
            endedMonotonicNanoseconds: 6_000_000_000
        )
        try writer.appendCanonicalPCM(
            tail,
            endedAt: fixture.started.addingTimeInterval(5.002),
            endedMonotonicNanoseconds: 6_002_000_000
        )
        try writer.simulateProcessTerminationForTesting()

        let results = try HarcMobileCaptureRecovery.recoverDurablePrefixes(
            locations: fixture.locations,
            attributes: NoopStorageAttributes()
        )
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.totalCanonicalFrames
            == HarcMobileDurableMasterWriter.checkpointFrames)
        #expect(result.finalizationReason == .recoveredDurablePrefix)
        #expect(result.discontinuities.last?.reason == .recovery)
        let expectedHash = try CanonicalPCMHash(
            Data(SHA256.hash(data: durable))
        )
        #expect(result.canonicalPCMSHA256 == expectedHash)
        #expect(try Data(contentsOf: result.masterFileURL).dropFirst(44) == durable)
    }

    @Test("a process death before the first frame never publishes zero-byte success")
    func emptyRecovery() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try fixture.writer()
        try writer.simulateProcessTerminationForTesting()
        #expect(try HarcMobileCaptureRecovery.recoverDurablePrefixes(
            locations: fixture.locations,
            attributes: NoopStorageAttributes()
        ).isEmpty)
    }
}

private struct NoopStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying
{
    func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws {}
}

private struct Fixture {
    let root: URL
    let locations: HarcMobileCaptureLocations
    let started = Date(timeIntervalSince1970: 1_900_000_000)
    let deviceID: DeviceID

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: root
        )
        deviceID = try DeviceID(Data(repeating: 0x42, count: 32))
    }

    func writer() throws -> HarcMobileDurableMasterWriter {
        try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: deviceID,
            captureStartedAt: started,
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            attributes: NoopStorageAttributes()
        )
    }
}
