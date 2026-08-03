import CryptoKit
import Foundation
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("File-backed HARCAB1 decoding")
struct AudioBatchFileTests {
    @Test("scanner validates and emits bounded chunks without whole-body Data")
    func scansExactFile() throws {
        let fixture = try Fixture()
        var consumed: [HarcAudioBatchFileChunkV1] = []
        let scan = try fixture.scan { consumed.append($0) }

        #expect(scan.exactHeaderPayload == fixture.batch.exactHeaderPayload)
        #expect(scan.header == fixture.batch.header)
        #expect(scan.descriptor.batchID.rawValue == Fixture.batchID)
        #expect(scan.descriptor.uploadID.rawValue == Fixture.uploadID)
        #expect(scan.descriptor.generation == .initial)
        #expect(scan.descriptor.exactBodyByteLength == UInt64(fixture.batch.exactBytes.count))
        #expect(scan.descriptor.exactBodySHA256.rawBytes == fixture.batch.exactSHA256)
        #expect(consumed.map(\.encodedBytes) == fixture.chunks)
        #expect(consumed.map(\.descriptor) == scan.descriptor.chunks)
        #expect(consumed.allSatisfy {
            $0.encodedBytes.count <= HarcAudioBatchV1.maximumEntryBytes
        })
    }

    @Test("whole-body capability hash mismatch fails after bounded parsing")
    func rejectsWrongCapabilityHash() throws {
        let fixture = try Fixture()
        let wrongHash = try ImmutableBatchSHA256(Data(repeating: 0xfe, count: 32))
        #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            try HarcAudioBatchFileV1.scan(
                at: fixture.url,
                expectedGeneration: .initial,
                expectedExactBodyByteLength: UInt64(fixture.batch.exactBytes.count),
                expectedExactBodySHA256: wrongHash,
                consume: { _ in }
            )
        }
    }

    @Test("capability length mismatch fails before any chunk callback")
    func rejectsWrongCapabilityLengthBeforeConsume() throws {
        let fixture = try Fixture()
        var callbackCount = 0
        #expect(throws: HarcProtocolCodecError.lengthMismatch(
            field: "audioBatch.exactBytes",
            expected: UInt64(fixture.batch.exactBytes.count + 1),
            actual: UInt64(fixture.batch.exactBytes.count)
        )) {
            try HarcAudioBatchFileV1.scan(
                at: fixture.url,
                expectedGeneration: .initial,
                expectedExactBodyByteLength: UInt64(fixture.batch.exactBytes.count + 1),
                expectedExactBodySHA256: fixture.bodyHash,
                consume: { _ in callbackCount += 1 }
            )
        }
        #expect(callbackCount == 0)
    }

    @Test("per-chunk corruption is rejected before that chunk is emitted")
    func rejectsCorruptChunkBeforeConsume() throws {
        let fixture = try Fixture()
        var corrupted = fixture.batch.exactBytes
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
        try corrupted.write(to: fixture.url, options: [])
        let corruptedHash = try ImmutableBatchSHA256(Data(SHA256.hash(data: corrupted)))
        var callbackCount = 0

        #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            try HarcAudioBatchFileV1.scan(
                at: fixture.url,
                expectedGeneration: .initial,
                expectedExactBodyByteLength: UInt64(corrupted.count),
                expectedExactBodySHA256: corruptedHash,
                consume: { _ in callbackCount += 1 }
            )
        }
        #expect(callbackCount == fixture.chunks.count - 1)
    }

    #if canImport(Darwin)
    @Test("scanner rejects a non-regular input descriptor")
    func rejectsNonRegularFile() throws {
        #expect(throws: HarcAudioBatchFileError.notRegularFile) {
            try HarcAudioBatchFileV1.scan(
                at: URL(fileURLWithPath: "/dev/null"),
                expectedGeneration: .initial,
                expectedExactBodyByteLength: 1,
                expectedExactBodySHA256: ImmutableBatchSHA256(
                    Data(repeating: 0, count: 32)
                ),
                consume: { _ in }
            )
        }
    }
    #endif
}

private struct Fixture {
    static let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
    static let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000009002")!

    let chunks = [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
    let batch: HarcAudioBatchV1
    let url: URL

    init() throws {
        var header = Harc_V1_AudioBatchHeaderV1()
        header.protocol.major = 1
        header.protocol.minor = 0
        header.batchID.value = Self.uuidBytes(Self.batchID)
        header.uploadID.value = Self.uuidBytes(Self.uploadID)
        header.uploadProfileSha256.value = Self.digest(0x03)
        header.originRecordingID.deviceID.sha256 = Self.digest(0x04)
        header.originRecordingID.recordingUuid = Self.uuidBytes(
            UUID(uuidString: "00000000-0000-0000-0000-000000009003")!
        )
        header.deviceID.sha256 = Self.digest(0x04)
        header.entries = chunks.enumerated().map { index, chunk in
            var entry = Harc_V1_AudioBatchEntryV1()
            entry.chunkID.value = Self.uuidBytes(
                UUID(uuidString: String(format:
                    "00000000-0000-0000-0000-%012d",
                    9_100 + index
                ))!
            )
            entry.chunkIndex = UInt32(index)
            entry.encodedLength = UInt32(chunk.count)
            entry.encodedSha256.value = Data(SHA256.hash(data: chunk))
            entry.canonicalStartFrame = UInt64(index * 2)
            entry.canonicalFrameCount = 2
            entry.canonicalDecodedSha256.value = Data(SHA256.hash(data: chunk))
            entry.encoding.codec = .losslessAudioCodecRawCanonicalPcmFixture
            entry.encoding.container = .losslessAudioContainerRawCanonicalPcmFixture
            return entry
        }
        batch = try HarcAudioBatchV1.create(header: header, encodedChunks: chunks)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-file-batch-\(UUID().uuidString).harcab1")
        try batch.exactBytes.write(to: url, options: [])
    }

    var bodyHash: ImmutableBatchSHA256 {
        try! ImmutableBatchSHA256(batch.exactSHA256)
    }

    func scan(
        consume: (HarcAudioBatchFileChunkV1) throws -> Void
    ) throws -> HarcAudioBatchFileScanV1 {
        defer { try? FileManager.default.removeItem(at: url) }
        return try HarcAudioBatchFileV1.scan(
            at: url,
            expectedGeneration: .initial,
            expectedExactBodyByteLength: UInt64(batch.exactBytes.count),
            expectedExactBodySHA256: bodyHash,
            consume: consume
        )
    }

    private static func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }
}
