import Foundation
import Testing
@testable import HarcModels

@Suite struct EvidenceContextQualificationTests {
    @Test func pinnedFixtureQualifiesAndMutationFailsRevalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try #require(Bundle.module.url(forResource: "evidence-gemma4-config", withExtension: "json"))
        let target = directory.appendingPathComponent("config.json")
        try FileManager.default.copyItem(at: fixture, to: target)
        let result = try EvidenceContextQualification.resolveConfig(modelID: "gemma-4-e2b-it-4bit", directory: directory)
        #expect(result.modelContextTokens == 131_072)
        #expect(result.operationalContextTokens == 32_768)
        try await EvidenceContextQualification.revalidate(result)
        var data = try Data(contentsOf: target)
        data[0] = 32
        try data.write(to: target)
        await #expect(throws: EvidenceContextError.digestMismatch) { try await EvidenceContextQualification.revalidate(result) }
    }

    @Test func directorySymlinkRetargetCannotRebindReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let link = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try #require(Bundle.module.url(forResource: "evidence-gemma4-config", withExtension: "json"))
        try FileManager.default.copyItem(at: fixture, to: first.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let receipt = try await EvidenceContextQualification.resolve(modelID: "gemma-4-e2b-it-4bit", directory: link)
        #expect(receipt.directory == first.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        // Revalidation remains bound to the original resolved directory, never
        // silently authorizes the replacement target at the old alias.
        try await EvidenceContextQualification.revalidate(receipt)
        await #expect(throws: (any Error).self) {
            try await EvidenceContextQualification.resolve(modelID: "gemma-4-e2b-it-4bit", directory: link)
        }
    }

    @Test func explicitKnownSchemaOnly() throws {
        let data = Data(#"{"model_type":"gemma4","text_config":{"model_type":"gemma4_text","max_position_embeddings":131072}}"#.utf8)
        #expect(try EvidenceContextQualification.explicitGemmaContext(data) == 131072)
    }
    @Test(arguments: ["0", "-1", "true", "1.5", "\"131072\"", "1048577", "null"])
    func invalidLimits(value: String) {
        let data = Data("{\"model_type\":\"gemma4\",\"text_config\":{\"model_type\":\"gemma4_text\",\"max_position_embeddings\":\(value)}}".utf8)
        #expect(throws: EvidenceContextError.invalidConfig) { try EvidenceContextQualification.explicitGemmaContext(data) }
    }
    @Test(arguments: ["{}", #"{"model_type":"gemma4","text_config":{"model_type":"gemma4_text"}}"#,
        #"{"model_type":"unknown","text_config":{"model_type":"gemma4_text","max_position_embeddings":100}}"#])
    func missingOrUnknownSchema(json: String) {
        #expect(throws: EvidenceContextError.invalidConfig) { try EvidenceContextQualification.explicitGemmaContext(Data(json.utf8)) }
    }
    @Test func unknownModelCannotSupplyOwnConfig() {
        #expect(throws: EvidenceContextError.unsupportedModel) {
            try EvidenceContextQualification.resolveConfig(modelID: "unknown", directory: .temporaryDirectory)
        }
    }
    @Test func sizeAndDigestRejectUntrustedConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data(repeating: 32, count: 5997).write(to: file)
        #expect(throws: EvidenceContextError.invalidConfig) {
            try EvidenceContextQualification.resolveConfig(modelID: "gemma-4-e2b-it-4bit", directory: directory)
        }
        try Data(repeating: 32, count: 5996).write(to: file)
        #expect(throws: EvidenceContextError.digestMismatch) {
            try EvidenceContextQualification.resolveConfig(modelID: "gemma-4-e2b-it-4bit", directory: directory)
        }
    }
}
