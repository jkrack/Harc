import Darwin
import Foundation
import Testing
@testable import HarcCore

@Suite("Journaled recording publication")
struct RecordingPublicationTests {
    @Test("unbound legacy publication intent is preserved rather than silently adopting a volume")
    func unboundIntentFailsClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("final.wav")
        try Data([1, 2]).write(to: source)
        _ = try RecordingPublication.prepare(source: source, destination: destination)
        let journal = RecordingPublication.journalURL(for: source)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object["version"] = 1
        object.removeValue(forKey: "destinationVolumeIdentity")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        try legacy.write(to: journal)
        #expect(throws: (any Error).self) { try RecordingPublication.prepare(source: source, destination: destination) }
        #expect(try Data(contentsOf: journal) == legacy)
        #expect(try Data(contentsOf: source) == Data([1, 2]))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("partial staging resumes and completed publication is repeat-safe after source removal")
    func resumesPartialAndCompletedPublication() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("public/final.wav")
        let bytes = Data(repeating: 0x5a, count: 100_000)
        try bytes.write(to: source)
        let intent = try RecordingPublication.prepare(source: source, destination: destination)
        try DurableFileIO.createDirectory(at: destination.deletingLastPathComponent())
        try Data(bytes.prefix(200)).write(to: intent.stagingURL)
        try intent.publish(removingSource: false)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: destination) == bytes)
        try intent.publish()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let loaded = try RecordingPublication.load(for: source)
        let resumed = try #require(loaded)
        #expect(resumed == intent)
        try resumed.publish()
        #expect(try Data(contentsOf: destination) == bytes)
        try resumed.finishLibraryCommit()
        #expect(try RecordingPublication.load(for: source) == nil)
    }

    @Test("failed destination barrier keeps the source and intent for an exact retry")
    func barrierFailurePreservesSource() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("final.wav")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        let intent = try RecordingPublication.prepare(source: source, destination: destination)
        #expect(throws: (any Error).self) {
            try intent.publish(removingSource: true, synchronizeDestination: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try RecordingPublication.load(for: source) == intent)
        try intent.publish()
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("destination conflicts and source mutations preserve both files")
    func contentConflicts() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("final.wav")
        try Data([1]).write(to: source)
        let intent = try RecordingPublication.prepare(source: source, destination: destination)
        try Data([2]).write(to: destination)
        #expect(throws: RecordingPublication.PublicationError.self) { try intent.publish() }
        #expect(try Data(contentsOf: source) == Data([1]))
        #expect(try Data(contentsOf: destination) == Data([2]))
        try FileManager.default.removeItem(at: destination)
        try Data([3]).write(to: source)
        #expect(throws: RecordingPublication.PublicationError.self) { try intent.publish() }
        #expect(try Data(contentsOf: source) == Data([3]))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("invalid existing publication metadata is never replaced")
    func corruptIntentIsPreserved() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let journal = RecordingPublication.journalURL(for: source)
        try Data([1, 2]).write(to: source)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: journal)
        #expect(throws: (any Error).self) {
            try RecordingPublication.prepare(source: source, destination: root.appendingPathComponent("final.wav"))
        }
        #expect(try Data(contentsOf: journal) == corrupt)
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test("publication crosses a separately mounted volume without losing the original bytes",
          .enabled(if: ProcessInfo.processInfo.environment["HARC_CROSS_VOLUME_DESTINATION"] != nil,
                   "Run the disposable cross-volume qualification wrapper"))
    func crossVolumePublication() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let mount = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HARC_CROSS_VOLUME_DESTINATION"]))
        let destination = mount.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        var sourceStat = stat()
        var destinationStat = stat()
        #expect(lstat(root.path, &sourceStat) == 0)
        #expect(lstat(mount.path, &destinationStat) == 0)
        #expect(sourceStat.st_dev != destinationStat.st_dev)
        let source = root.appendingPathComponent("source.wav")
        let bytes = Data((0..<2_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let intent = try RecordingPublication.prepare(source: source, destination: destination)
        try intent.publish()
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try intent.publish()
        try intent.finishLibraryCommit()
    }
}
