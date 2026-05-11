import Foundation
import HarcModels
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import HuggingFace
import Tokenizers

public enum MLXTextEmbedderError: Error, LocalizedError, Sendable {
    case modelDirectoryMissing(URL)
    case noTexts

    public var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let url):
            return "Semantic search model is not installed at \(url.path)."
        case .noTexts:
            return "No text was provided for embedding."
        }
    }
}

/// Production local text embedder backed by MLXEmbedders.
///
/// BGE-small emits 384-dimensional L2-normalized vectors. The returned Data is
/// a packed little-endian Float32 BLOB, which is the format SQLite vec1 expects.
public actor MLXTextEmbedder: LocalTextEmbedder {
    public let modelID: String

    private let modelDirectory: URL
    private var container: EmbedderModelContainer?

    public init(
        modelID: String = "bge-small-en-v1.5",
        modelDirectory: URL = ModelStorage.defaultBase()
            .appendingPathComponent("bge-small-en-v1.5", isDirectory: true)
    ) {
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    public func embed(texts: [String]) async throws -> [Data] {
        let cleaned = texts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw MLXTextEmbedderError.noTexts }

        let container = try await getOrLoad()
        let vectors: [[Float]] = await container.perform(nonSendable: cleaned) { context, inputTexts in
            let encoded = inputTexts.map {
                context.tokenizer.encode(text: $0.isEmpty ? " " : $0, addSpecialTokens: true)
            }
            let padID = context.tokenizer.eosTokenId ?? 0
            let maxLength = min(512, max(1, encoded.map(\.count).max() ?? 1))

            let padded = encoded.map { tokens in
                let clipped = Array(tokens.prefix(maxLength))
                return clipped + Array(repeating: padID, count: maxLength - clipped.count)
            }
            let input = stacked(padded.map { MLXArray($0) })
            let mask = input .!= padID
            let tokenTypes = MLXArray.zeros(like: input)
            let output = context.model(
                input,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let pooled = context.pooling(
                output,
                mask: mask,
                normalize: true,
                applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
        return vectors.map(EmbeddingVectorCodec.encode)
    }

    private func getOrLoad() async throws -> EmbedderModelContainer {
        if let container { return container }
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw MLXTextEmbedderError.modelDirectoryMissing(modelDirectory)
        }
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        return loaded
    }
}
