import Foundation
import CryptoKit
import Testing
@testable import HarcModels

@Suite struct SyntheticEvidenceSnapshotTests {
    private func setup() throws -> (URL, URL, URL, SyntheticEvidenceSnapshot.File) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let data = Data("synthetic model bytes".utf8)
        try data.write(to: source.appendingPathComponent("model.safetensors"))
        return (root, source, scratch, .init(name: "model.safetensors", bytes: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
    @Test func fakeLoaderGetsCopyAndScopeCleansOnlySnapshot() async throws {
        let (root, source, scratch, file) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { url in
            #expect(url != source)
            #expect(url.deletingLastPathComponent().path == scratch.path)
            return try Data(contentsOf: url.appendingPathComponent(file.name))
        }
        #expect(content == Data("synthetic model bytes".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(file.name).path))
    }
    @Test(arguments: ["extra", "symlink", "corrupt", "nested"])
    func refusesUnverifiedInputs(kind: String) async throws {
        let (root, source, scratch, file) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        switch kind {
        case "extra": try Data().write(to: source.appendingPathComponent("extra.safetensors"))
        case "nested": try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        case "symlink":
            let original = source.appendingPathComponent(file.name)
            let other = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: original, to: other)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: other)
        default: try Data(repeating: 32, count: file.bytes).write(to: source.appendingPathComponent(file.name))
        }
        await #expect(throws: (any Error).self) {
            try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { _ in
                Issue.record("Unverified input reached loader")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
    @Test func failedConsumerCleansSnapshot() async throws {
        let (root, source, scratch, file) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CancellationError.self) {
            try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { _ in
                throw CancellationError()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
    @Test func concurrentSnapshotsHaveDistinctPaths() async throws {
        let (root, source, scratch, file) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        async let first = SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { $0.path }
        async let second = SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { $0.path }
        let paths = try await (first, second)
        #expect(paths.0 != paths.1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func invalidManifestNeverCopies() async throws {
        let (root, source, scratch, file) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = SyntheticEvidenceSnapshot.File(name: "../escape", bytes: file.bytes, sha256: file.sha256)
        await #expect(throws: (any Error).self) {
            try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [bad]) { _ in
                Issue.record("Invalid manifest accepted")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
}
