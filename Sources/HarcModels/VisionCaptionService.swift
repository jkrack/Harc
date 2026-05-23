import Foundation
import CoreGraphics
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

public enum VisionCaptionError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)
    case captionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let modelID):
            return "Vision caption model \"\(modelID)\" is not installed."
        case .captionFailed(let reason):
            return "Image caption failed: \(reason)"
        }
    }
}

public struct VisionCaptionRequest: Equatable, Sendable {
    public static let defaultPrompt = "Describe this meeting screenshot or slide for later retrieval. Capture visible title, key bullets, chart/table meaning, and any action-relevant context. Do not invent hidden details."

    public let imageURL: URL
    public let modelID: String
    public let modelDirectory: URL
    public let prompt: String

    public init(
        imageURL: URL,
        modelID: String,
        modelDirectory: URL,
        prompt: String = Self.defaultPrompt
    ) {
        self.imageURL = imageURL
        self.modelID = modelID
        self.modelDirectory = modelDirectory
        self.prompt = prompt
    }
}

public actor VisionCaptionService {
    public typealias Generator = @Sendable (VisionCaptionRequest) async throws -> String

    private let generator: Generator

    public init(generator: @escaping Generator = VisionCaptionService.defaultMLXVLMGenerator) {
        self.generator = generator
    }

    public func caption(_ request: VisionCaptionRequest) async throws -> String {
        guard FileManager.default.fileExists(atPath: request.modelDirectory.path) else {
            throw VisionCaptionError.modelUnavailable(request.modelID)
        }
        do {
            return try await generator(request).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VisionCaptionError {
            throw error
        } catch {
            throw VisionCaptionError.captionFailed(error.localizedDescription)
        }
    }

    public static func defaultMLXVLMGenerator(_ request: VisionCaptionRequest) async throws -> String {
        var parameters = GenerateParameters()
        parameters.maxTokens = 220

        let container = try await VLMModelFactory.shared.loadContainer(
            from: request.modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        let session = ChatSession(
            container,
            generateParameters: parameters,
            processing: .init(resize: CGSize(width: 1024, height: 1024))
        )
        return try await session.respond(
            to: request.prompt,
            image: .url(request.imageURL)
        )
    }
}
