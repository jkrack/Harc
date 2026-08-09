import CryptoKit
import Foundation
import HarcDomain
import Testing
@testable import HarcAudioMobile

@Suite("Mobile ALAC transfer chunks")
struct HarcMobileALACChunkEncoderTests {
    @Test("CAF ALAC round trips canonical PCM and is restart idempotent")
    func roundTripAndRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: root
        )
        let frames = 20_000
        var canonical = Data(capacity: frames * 2)
        for frame in 0..<frames {
            var sample = Int16(truncatingIfNeeded: frame &* 97).littleEndian
            withUnsafeBytes(of: &sample) { canonical.append(contentsOf: $0) }
        }
        let writer = try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: DeviceID(Data(repeating: 0x52, count: 32)),
            captureStartedAt: Date(timeIntervalSince1970: 1_900_000_000),
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            attributes: ALACNoopStorageAttributes()
        )
        try writer.appendCanonicalPCM(
            canonical,
            endedAt: Date(timeIntervalSince1970: 1_900_000_001.25),
            endedMonotonicNanoseconds: 2_250_000_000
        )
        let master = try writer.finalize(reason: .userStopped)
        let encoder = HarcMobileALACChunkEncoder()

        let first: [HarcMobileEncodedChunkArtifact]
        do {
            first = try encoder.encode(
                master,
                locations: locations,
                attributes: ALACNoopStorageAttributes()
            )
        } catch let error as HarcMobileALACEncodingError {
            guard case .encodingFailed = error else { throw error }
            // The release decision is intentionally a physical-iPhone gate.
            // macOS and simulator codec availability is diagnostic only.
            #if os(macOS) || targetEnvironment(simulator)
            return
            #else
            throw error
            #endif
        }
        let second = try encoder.encode(
            master,
            locations: locations,
            attributes: ALACNoopStorageAttributes()
        )

        let artifact = try #require(first.first)
        #expect(first.count == 1)
        #expect(second == first)
        #expect(artifact.canonicalFrameCount == UInt64(frames))
        #expect(artifact.canonicalDecodedByteLength == UInt64(canonical.count))
        #expect(artifact.canonicalDecodedSHA256 == Data(SHA256.hash(data: canonical)))
        #expect(artifact.encodedByteLength > 0)
        #expect(artifact.encodedByteLength <= HarcMobileALACChunkEncoder.maximumEncodedBytes)
        #expect(FileManager.default.fileExists(atPath: artifact.encodedFileURL.path))
    }

    @Test(
        "Packet-aligned ALAC retry terminates and stays bit exact",
        .timeLimit(.minutes(1))
    )
    func packetAlignedRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: root
        )
        // The physical iPhone artifact that exposed the retry hang contained
        // exactly 50 ALAC packets of canonical audio plus codec remainder.
        let frames = 50 * 4_096
        var canonical = Data(capacity: frames * 2)
        for frame in 0..<frames {
            var sample = Int16(truncatingIfNeeded: frame &* 97).littleEndian
            withUnsafeBytes(of: &sample) { canonical.append(contentsOf: $0) }
        }
        let writer = try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: DeviceID(Data(repeating: 0x53, count: 32)),
            captureStartedAt: Date(timeIntervalSince1970: 1_900_000_000),
            captureStartedMonotonicNanoseconds: 1_000_000_000,
            attributes: ALACNoopStorageAttributes()
        )
        try writer.appendCanonicalPCM(
            canonical,
            endedAt: Date(timeIntervalSince1970: 1_900_000_012.8),
            endedMonotonicNanoseconds: 13_800_000_000
        )
        let master = try writer.finalize(reason: .userStopped)
        let encoder = HarcMobileALACChunkEncoder()

        let first: [HarcMobileEncodedChunkArtifact]
        do {
            first = try encoder.encode(
                master,
                locations: locations,
                attributes: ALACNoopStorageAttributes()
            )
        } catch let error as HarcMobileALACEncodingError {
            guard case .encodingFailed = error else { throw error }
            #if os(macOS) || targetEnvironment(simulator)
            return
            #else
            throw error
            #endif
        }
        let resumed = try encoder.encode(
            master,
            locations: locations,
            attributes: ALACNoopStorageAttributes()
        )

        let artifact = try #require(resumed.first)
        #expect(resumed == first)
        #expect(artifact.canonicalFrameCount == UInt64(frames))
        #expect(artifact.canonicalDecodedByteLength == UInt64(canonical.count))
        #expect(
            artifact.canonicalDecodedSHA256
                == Data(SHA256.hash(data: canonical))
        )
    }
}

private struct ALACNoopStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying
{
    func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws {}
}
