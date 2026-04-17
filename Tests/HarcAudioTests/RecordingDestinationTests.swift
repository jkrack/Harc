import Testing
import Foundation
@testable import HarcAudio

@Suite("RecordingDestination")
struct RecordingDestinationTests {
    private func makeTempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-dest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("publicPath yields YYYY/YYYY-MM-DD/HH-mm-ss.wav under base")
    func publicPathShape() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // 2026-04-17T13:14:15 local time
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 13; comps.minute = 14; comps.second = 15
        comps.timeZone = TimeZone.current
        let date = Calendar.current.date(from: comps)!

        let dest = RecordingDestination(baseDirectory: base)
        let url = try dest.publicPath(for: date)
        let components = url.pathComponents
        #expect(components.contains("2026"))
        #expect(components.contains("2026-04-17"))
        #expect(url.lastPathComponent == "13-14-15.wav")
        #expect(url.path.hasPrefix(base.path))
    }

    @Test("publicPath appends -1, -2 on collision")
    func publicPathCollisionSuffix() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let date = Date()
        let dest = RecordingDestination(baseDirectory: base)

        let first = try dest.publicPath(for: date)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: first.path, contents: Data([0x00]))

        let second = try dest.publicPath(for: date)
        #expect(second.lastPathComponent.hasSuffix("-1.wav"))
        FileManager.default.createFile(atPath: second.path, contents: Data([0x00]))

        let third = try dest.publicPath(for: date)
        #expect(third.lastPathComponent.hasSuffix("-2.wav"))
    }

    @Test("cachePath is under ~/Library/Caches/Harc/recordings and ends with .wav")
    func cachePathShape() {
        let cache = RecordingDestination.cachePath()
        #expect(cache.pathExtension == "wav")
        #expect(cache.path.contains("/Library/Caches/Harc/recordings/"))
    }

    @Test("atomicMove relocates a file and removes the source")
    func atomicMoveRelocates() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let src = base.appendingPathComponent("src.wav")
        let dst = base.appendingPathComponent("a/b/dst.wav")
        FileManager.default.createFile(atPath: src.path, contents: Data([1, 2, 3]))

        try RecordingDestination.atomicMove(from: src, to: dst)

        #expect(FileManager.default.fileExists(atPath: dst.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let data = try Data(contentsOf: dst)
        #expect(data == Data([1, 2, 3]))
    }
}
