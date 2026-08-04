import CryptoKit
import Foundation
import Testing
@testable import Harc

@Suite("Desktop Client durable capture files")
struct HarcDesktopClientFilesTests {
    @Test("Canonical WAV is copied, normalized, and hashed")
    func canonicalizesWAV() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        try makeWAV(pcm: pcm).write(to: fixture.source)

        let prepared = try HarcDesktopClientFiles.canonicalizeWAV(
            source: fixture.source,
            destination: fixture.destination
        )

        #expect(prepared.frames == 3)
        #expect(prepared.pcmSHA256 == Data(SHA256.hash(data: pcm)))
        let output = try Data(contentsOf: fixture.destination)
        #expect(output.count == 44 + pcm.count)
        #expect(output.prefix(4) == Data("RIFF".utf8))
        #expect(output[8 ..< 12] == Data("WAVE".utf8))
        #expect(output.suffix(pcm.count) == pcm)
    }

    @Test("Noncanonical WAV is rejected without publishing a destination")
    func rejectsNoncanonicalWAV() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not a wave file".utf8).write(to: fixture.source)

        do {
            _ = try HarcDesktopClientFiles.canonicalizeWAV(
                source: fixture.source,
                destination: fixture.destination
            )
            Issue.record("Expected invalid WAV rejection")
        } catch HarcDesktopClientError.invalidWAV {
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        }
    }

    @Test("An existing durable destination is never overwritten")
    func refusesOverwrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWAV(pcm: Data([0, 0])).write(to: fixture.source)
        let sentinel = Data("owned".utf8)
        try sentinel.write(to: fixture.destination)

        do {
            _ = try HarcDesktopClientFiles.canonicalizeWAV(
                source: fixture.source,
                destination: fixture.destination
            )
            Issue.record("Expected exclusive-create rejection")
        } catch HarcDesktopClientError.destinationExists {
            #expect(try Data(contentsOf: fixture.destination) == sentinel)
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "harc-desktop-client-files-\(UUID().uuidString)",
                isDirectory: true
            )
            source = root.appendingPathComponent("source.wav")
            destination = root.appendingPathComponent("destination.wav")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeWAV(pcm: Data) -> Data {
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
