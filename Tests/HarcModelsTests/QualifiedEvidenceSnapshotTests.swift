import Foundation
import Testing
import CryptoKit
@testable import HarcModels

@Suite struct QualifiedEvidenceSnapshotTests {
    @Test(arguments: [false, true])
    func fixedTinyManifestSucceedsAndCleansAfterConsumer(fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try #require(Bundle.module.url(forResource: "evidence-gemma4-config", withExtension: "json"))
        try FileManager.default.copyItem(at: fixture, to: source.appendingPathComponent("config.json"))
        let tiny = Data("fixed synthetic weights, not a model".utf8)
        try tiny.write(to: source.appendingPathComponent("model.safetensors"))
        let catalog = try #require(ModelCatalog.descriptor(for: "gemma-4-e2b-it-4bit"))
        let config = try #require(catalog.files.first { $0.path == "config.json" })
        let weights = ModelFile(path: "model.safetensors", bytes: Int64(tiny.count),
            sha256: SHA256.hash(data: tiny).map { String(format: "%02x", $0) }.joined(), url: URL(fileURLWithPath: "/unused"))
        let fixed = ModelDescriptor(id: catalog.id, displayName: "fixture", summary: "fixture", task: .summarizer,
            tier: .standard, repoID: "fixture", revision: "fixed-test-revision", files: [config, weights],
            minRAMGB: 1, recommendedRAMGB: 1, contextTokens: 1024, manifestVerified: false)
        do {
            try await QualifiedEvidenceSnapshotFactory.withSnapshotCore(descriptor: fixed,
                installedDirectory: source, scratchDirectory: scratch) { snapshot in
                #expect(snapshot.context.modelContextTokens == 131072)
                #expect(snapshot.manifestDigest.count == 64)
                #expect(try Data(contentsOf: snapshot.directory.appendingPathComponent("model.safetensors")) == tiny)
                if fails { throw CancellationError() }
            }
            #expect(!fails)
        } catch is CancellationError { #expect(fails) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent("model.safetensors")) == tiny)
    }

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
