import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcProtocol
import HarcTransfer
import Network
import XCTest
@testable import HarcMobile

final class HarcMobileBackgroundBatchPreparerTests: XCTestCase {
    func testResolvedBonjourRouteRequiresConcreteHostAndPort() throws {
        let route = try HarcMobileBonjourHostRouteResolver.route(
            fromResolvedEndpoint: .hostPort(
                host: "harc-host.local",
                port: 7_443
            )
        )

        XCTAssertEqual(route.host, "harc-host.local")
        XCTAssertEqual(route.port, 7_443)
        XCTAssertEqual(route.serverHostname, "harc-host.local")
        XCTAssertThrowsError(
            try HarcMobileBonjourHostRouteResolver.route(
                fromResolvedEndpoint: .service(
                    name: "Harc",
                    type: "_harc._tcp",
                    domain: "local.",
                    interface: nil
                )
            )
        )
    }

    func testLocalExportDisclosureNamesTrustBoundaryAndSynchronization() {
        XCTAssertTrue(
            HarcMobileLocalRecording.exportDisclosure.contains(
                "outside your adopted Harc Host trust boundary"
            )
        )
        XCTAssertTrue(
            HarcMobileLocalRecording.exportDisclosure.contains(
                "does not treat this export as synchronization"
            )
        )
    }

    func testBuildsDeterministicBoundedHARCAB1File() async throws {
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
        let deviceID = try DeviceID(Data(repeating: 0x41, count: 32))
        let origin = OriginRecordingID(
            deviceID: deviceID,
            recordingUUID: UUID(
                uuidString: "ac111111-2222-3333-4444-555555555555"
            )!
        )
        let profile = try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .rawPCMFixture,
            requiredCapabilities: [],
            negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                Data(repeating: 0x42, count: 32)
            ),
            profileSHA256: UploadProfileSHA256(
                Data(repeating: 0x43, count: 32)
            ),
            purpose: .fixtureLoopback
        )
        let chunks = try [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
            .enumerated().map { index, bytes in
                let hash = Data(SHA256.hash(data: bytes))
                let descriptor = try LogicalChunkDescriptor(
                    originRecordingID: origin,
                    chunkID: ChunkID(
                        UUID(uuidString: String(format:
                            "ac222222-3333-4444-5555-%012d",
                            index + 1
                        ))!
                    ),
                    chunkIndex: UInt32(index),
                    canonicalStartFrame: UInt64(index * 2),
                    canonicalFrameCount: 2,
                    encoding: .rawPCMFixture,
                    encodedByteLength: UInt64(bytes.count),
                    encodedSHA256: EncodedChunkSHA256(hash),
                    canonicalDecodedByteLength: UInt64(bytes.count),
                    canonicalDecodedSHA256: CanonicalPCMHash(hash)
                )
                let url = root.appendingPathComponent("chunk-\(index).pcm")
                    .standardizedFileURL
                try bytes.write(to: url)
                return try HarcForegroundEncodedChunk(
                    descriptor: descriptor,
                    encodedFileURL: url
                )
            }
        let plan = try HarcForegroundRecordingUploadPlan(
            trustTuple: AdoptedTrustTuple(
                libraryID: LibraryID(
                    UUID(uuidString:
                        "ac333333-4444-5555-6666-777777777777")!
                ),
                hostAuthorityID: HostAuthorityID(
                    Data(repeating: 0x44, count: 32)
                )
            ),
            uploadID: UploadID(
                UUID(uuidString: "ac444444-5555-6666-7777-888888888888")!
            ),
            originRecordingID: origin,
            frozenProfile: profile,
            chunks: chunks
        )
        let preparer = HarcMobileBackgroundBatchPreparer(
            locations: locations,
            attributes: HarcMobileBatchNoopStorageAttributes()
        )

        let first = try await preparer.prepareBatches(
            plan: plan,
            generation: .initial,
            chunks: chunks
        )
        let replay = try await preparer.prepareBatches(
            plan: plan,
            generation: .initial,
            chunks: chunks
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(replay.count, 1)
        let batch = try XCTUnwrap(first.first)
        XCTAssertEqual(replay.first?.descriptor, batch.descriptor)
        XCTAssertEqual(replay.first?.bodyFileURL, batch.bodyFileURL)
        XCTAssertLessThanOrEqual(
            batch.descriptor.exactBodyByteLength,
            UInt64(8 * 1_024 * 1_024)
        )
        var consumed: [Data] = []
        let scan = try HarcAudioBatchFileV1.scan(
            at: batch.bodyFileURL,
            expectedGeneration: .initial,
            expectedExactBodyByteLength:
                batch.descriptor.exactBodyByteLength,
            expectedExactBodySHA256: batch.descriptor.exactBodySHA256,
            consume: { consumed.append($0.encodedBytes) }
        )
        XCTAssertEqual(scan.descriptor, batch.descriptor)
        XCTAssertEqual(consumed, [
            Data([1, 2, 3, 4]),
            Data([5, 6, 7, 8]),
        ])
    }
}

private struct HarcMobileBatchNoopStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying
{
    func applyAndVerify(
        _: HarcMobileCaptureStoragePolicy,
        to _: URL
    ) throws {}
}
