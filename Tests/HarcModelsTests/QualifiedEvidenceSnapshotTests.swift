import Foundation
import Testing
@testable import HarcModels

@Suite struct QualifiedEvidenceSnapshotTests {
    @Test func matchingConfigAloneCannotAuthorizeBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try #require(Bundle.module.url(forResource: "evidence-gemma4-config", withExtension: "json"))
        try FileManager.default.copyItem(at: fixture, to: source.appendingPathComponent("config.json"))
        await #expect(throws: (any Error).self) {
            try await QualifiedEvidenceSnapshotFactory.withSnapshot(modelID: "gemma-4-e2b-it-4bit",
                installedDirectory: source, scratchDirectory: scratch) { _ in
                    Issue.record("Config-only directory authorized as full bundle")
                }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path))
    }
    @Test func unsupportedModelFailsBeforeFilesystemAccess() async {
        await #expect(throws: EvidenceContextError.unsupportedModel) {
            try await QualifiedEvidenceSnapshotFactory.withSnapshot(modelID: "unknown",
                installedDirectory: URL(fileURLWithPath: "/missing"), scratchDirectory: URL(fileURLWithPath: "/missing")) { _ in
                    Issue.record("Unknown bundle authorized")
                }
        }
    }
}
