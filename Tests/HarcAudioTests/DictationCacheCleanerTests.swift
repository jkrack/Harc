import Testing
import Foundation
@testable import HarcAudio

@Suite("DictationCacheCleaner")
struct DictationCacheCleanerTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/harc-dictation-clean-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(in dir: URL, name: String, ageSeconds: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("stub".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
        return url
    }

    @Test("deletes WAVs older than the cutoff, keeps fresh ones")
    func deletesOldKeepsFresh() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = try makeFile(in: dir, name: "old.wav", ageSeconds: 2 * 60 * 60)
        let fresh = try makeFile(in: dir, name: "fresh.wav", ageSeconds: 60)

        let deleted = DictationCacheCleaner.cleanOrphans(directory: dir, olderThan: 60 * 60)

        #expect(deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("ignores non-WAV files even when old")
    func ignoresNonWav() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stray = try makeFile(in: dir, name: "notes.txt", ageSeconds: 2 * 60 * 60)

        let deleted = DictationCacheCleaner.cleanOrphans(directory: dir, olderThan: 60 * 60)

        #expect(deleted == 0)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test("missing directory is a no-op")
    func missingDirectory() {
        let missing = URL(fileURLWithPath: "/tmp/harc-dictation-clean-missing-\(UUID().uuidString)")
        let deleted = DictationCacheCleaner.cleanOrphans(directory: missing, olderThan: 60 * 60)
        #expect(deleted == 0)
    }

    @Test("matches WAV extension case-insensitively")
    func caseInsensitiveExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let upper = try makeFile(in: dir, name: "OLD.WAV", ageSeconds: 2 * 60 * 60)

        let deleted = DictationCacheCleaner.cleanOrphans(directory: dir, olderThan: 60 * 60)

        #expect(deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: upper.path))
    }
}
