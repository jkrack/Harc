import Foundation
import CryptoKit

public enum EvidenceContextError: Error, Equatable {
    case unsupportedModel, invalidConfig, digestMismatch, changed
}

/// Config qualification only, not proof that resident weights/tokenizer match.
/// No public initializer. The inference adapter must separately bind load identity.
public struct QualifiedEvidenceContext: Sendable, Equatable {
    public let modelID: String
    public let revision: String
    public let directory: URL
    public let configSHA256: String
    public let modelContextTokens: Int
    public let operationalContextTokens: Int
    fileprivate init(modelID: String, revision: String, directory: URL, configSHA256: String,
                     modelContextTokens: Int) {
        self.modelID = modelID
        self.revision = revision
        self.directory = directory
        self.configSHA256 = configSHA256
        self.modelContextTokens = modelContextTokens
        self.operationalContextTokens = min(modelContextTokens, 32_768)
    }
}

public enum EvidenceContextQualification {
    /// Deliberately narrow allowlist, not every catalog entry or SDK default.
    public static func resolve(modelID: String, directory: URL) async throws -> QualifiedEvidenceContext {
        let read = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try resolveConfig(modelID: modelID, directory: directory)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await read.value
            try Task.checkCancellation()
            return result
        } onCancel: { read.cancel() }
    }

    // Internal synchronous core for bounded synthetic tests; production reads
    // always go through the detached utility task, never the main actor.
    static func resolveConfig(modelID: String, directory: URL) throws -> QualifiedEvidenceContext {
        guard modelID == "gemma-4-e2b-it-4bit",
              let descriptor = ModelCatalog.descriptor(for: modelID), descriptor.manifestVerified,
              let config = descriptor.files.first(where: { $0.path == "config.json" }),
              config.bytes > 0, config.bytes <= 65_536 else { throw EvidenceContextError.unsupportedModel }
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let handle = try FileHandle(forReadingFrom: canonical.appendingPathComponent("config.json"))
        defer { try? handle.close() }
        // Bounded read also rejects growth after a filesystem size check.
        let data = try handle.read(upToCount: Int(config.bytes) + 1) ?? Data()
        guard data.count == config.bytes else { throw EvidenceContextError.invalidConfig }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == config.sha256.lowercased() else { throw EvidenceContextError.digestMismatch }
        let limit = try explicitGemmaContext(data)
        return QualifiedEvidenceContext(modelID: modelID, revision: descriptor.revision,
            directory: canonical, configSHA256: digest, modelContextTokens: limit)
    }

    /// Re-read immediately around model binding; this is a point-in-time check,
    /// not filesystem locking or proof of the identity of an already loaded model.
    public static func revalidate(_ qualified: QualifiedEvidenceContext) async throws {
        guard try await resolve(modelID: qualified.modelID, directory: qualified.directory) == qualified else {
            throw EvidenceContextError.changed
        }
    }

    static func explicitGemmaContext(_ data: Data) throws -> Int {
        // Parsing follows successful catalog digest validation in production.
        // Decodable Int rejects booleans, fractions, missing and string values.
        struct Text: Decodable {
            let model_type: String
            let max_position_embeddings: Int
        }
        struct Config: Decodable { let model_type: String; let text_config: Text }
        guard let config = try? JSONDecoder().decode(Config.self, from: data),
              config.model_type == "gemma4", config.text_config.model_type == "gemma4_text",
              config.text_config.max_position_embeddings > 0,
              config.text_config.max_position_embeddings <= 1_048_576 else {
            throw EvidenceContextError.invalidConfig
        }
        return config.text_config.max_position_embeddings
    }
}
