import CryptoKit
import Foundation
import HarcDomain
import Testing
@testable import HarcHost

@Suite("Host canonical audio download")
struct HarcHostCanonicalAudioDownloadTests {
    @Test("reader verifies representation and supports bounded resume")
    func verifiedReadAndResume() async throws {
        let fixture = try AudioDownloadFixture()
        defer { fixture.remove() }
        let reader = try HarcHostCanonicalAudioReader(
            canonicalID: fixture.canonicalID,
            revision: .initial,
            fileURL: fixture.url,
            canonicalPCMSHA256: fixture.pcmHash,
            totalCanonicalFrames: fixture.totalFrames
        )

        #expect(reader.descriptor.totalByteLength == UInt64(fixture.wav.count))
        #expect(
            reader.descriptor.contentSHA256
                == Data(SHA256.hash(data: fixture.wav))
        )
        let prefix = try #require(
            try await reader.read(at: 0, maximumBytes: 10)
        )
        let suffix = try #require(
            try await reader.read(
                at: UInt64(prefix.count),
                maximumBytes: fixture.wav.count
            )
        )
        #expect(prefix + suffix == fixture.wav)
        #expect(
            try await reader.read(
                at: UInt64(fixture.wav.count),
                maximumBytes: 1
            ) == nil
        )
    }

    @Test("in-place mutation fails the retained stream")
    func mutationFailsClosed() async throws {
        let fixture = try AudioDownloadFixture()
        defer { fixture.remove() }
        let reader = try HarcHostCanonicalAudioReader(
            canonicalID: fixture.canonicalID,
            revision: .initial,
            fileURL: fixture.url,
            canonicalPCMSHA256: fixture.pcmHash,
            totalCanonicalFrames: fixture.totalFrames
        )
        let handle = try FileHandle(forUpdating: fixture.url)
        try handle.seek(toOffset: 44)
        try handle.write(contentsOf: Data([0xff]))
        try handle.synchronize()
        try handle.close()

        await #expect(throws: HarcHostLibraryError.canonicalAudioChanged) {
            _ = try await reader.read(at: 0, maximumBytes: 1)
        }
    }
}

private struct AudioDownloadFixture {
    let directory: URL
    let url: URL
    let canonicalID = CanonicalRecordingID.random()
    let pcm = Data([0x01, 0x02, 0x03, 0x04])
    let totalFrames: UInt64 = 2
    let wav: Data
    let pcmHash: CanonicalPCMHash

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-audio-download-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        url = directory.appendingPathComponent("canonical.wav")
        pcmHash = try CanonicalPCMHash(Data(SHA256.hash(data: pcm)))
        var value = Data()
        value.append(Data("RIFF".utf8))
        value.appendLE(UInt32(40))
        value.append(Data("WAVEfmt ".utf8))
        value.appendLE(UInt32(16))
        value.appendLE(UInt16(1))
        value.appendLE(UInt16(1))
        value.appendLE(UInt32(16_000))
        value.appendLE(UInt32(32_000))
        value.appendLE(UInt16(2))
        value.appendLE(UInt16(16))
        value.append(Data("data".utf8))
        value.appendLE(UInt32(pcm.count))
        value.append(pcm)
        wav = value
        try wav.write(to: url, options: .withoutOverwriting)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
