import CryptoKit
import Foundation
import HarcAudioMobile
import HarcDomain
import XCTest

final class HarcMobileALACPhysicalRegressionTests: XCTestCase {
    func testPhysicalEOFDoesNotRejectBitExactALAC() throws {
        try verifyRoundTrip(frames: 20_000)
    }

    func testPhysicalPacketAlignedEOFIsBitExact() throws {
        try verifyRoundTrip(frames: 50 * 4_096)
    }

    func testPhysicalFullChunkIsBitExactAndRestartable() throws {
        try verifyRoundTrip(frames: 60 * 16_000)
    }

    private func verifyRoundTrip(frames: Int) throws {
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
        var canonical = Data(capacity: frames * 2)
        for frame in 0..<frames {
            var sample = Int16(truncatingIfNeeded: frame &* 97).littleEndian
            withUnsafeBytes(of: &sample) {
                canonical.append(contentsOf: $0)
            }
        }
        let writer = try HarcMobileDurableMasterWriter(
            locations: locations,
            producingDeviceID: DeviceID(Data(repeating: 0x61, count: 32)),
            captureStartedAt: Date(timeIntervalSince1970: 1_900_000_000),
            captureStartedMonotonicNanoseconds: 1_000_000_000
        )
        try writer.appendCanonicalPCM(
            canonical,
            endedAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(frames) / 16_000),
            endedMonotonicNanoseconds: 1_000_000_000 + UInt64(frames) * 62_500
        )
        let master = try writer.finalize(reason: .userStopped)

        let artifacts = try HarcMobileALACChunkEncoder().encode(
            master,
            locations: locations
        )
        let artifact = try XCTUnwrap(artifacts.first)

        let retried = try HarcMobileALACChunkEncoder().encode(master, locations: locations)
        XCTAssertEqual(retried, artifacts)
        XCTAssertEqual(artifact.canonicalDecodedByteLength, UInt64(canonical.count))
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifact.canonicalFrameCount, UInt64(frames))
        XCTAssertEqual(
            artifact.canonicalDecodedSHA256,
            Data(SHA256.hash(data: canonical))
        )
    }
}
