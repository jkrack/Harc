import Foundation

/// Recoverable errors surfaced by `SummarizerService`. Non-recoverable
/// bugs (contract violations) trap as usual.
public enum SummarizerError: Error, LocalizedError {
    case loadFailed(String)
    case generationFailed(String)
    case modelDirectoryMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            return "Couldn't load the summarization model: \(reason)"
        case .generationFailed(let reason):
            return "Summarization generation failed: \(reason)"
        case .modelDirectoryMissing(let url):
            return "Model directory not present at \(url.path). Download the model in Settings first."
        }
    }
}

/// Actor that owns a lazily-loaded LLM container and serves
/// summarization requests. Single-tenant by design — one in-flight
/// summarize at a time — because the underlying Gemma model has a
/// multi-GB resident footprint and concurrent generation blows RAM.
/// The caller (Stage 3's queue) enforces serial scheduling.
///
/// Thread model: actor. All state mutation is serialized. Callers
/// interact via `await`. Cancellation is structured-concurrency
/// native: cancel the calling `Task` and the generation terminates
/// at the next stream iteration.
public actor SummarizerService {

    /// Factory signature for loading a `ContainerLike` from a model
    /// directory on disk. Injected at init so tests can substitute a
    /// stub that doesn't require Metal.
    public typealias Loader = @Sendable (URL) async throws -> any ContainerLike

    private let loader: Loader
    public private(set) var loadedModelID: String?
    private var container: (any ContainerLike)?

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    /// Drop the resident model so MLX can reclaim GPU/ANE memory.
    /// Implemented by nil-ing the container — `mlx-swift-lm` 3.x has
    /// no explicit unload method. Next `summarize(...)` pays the load
    /// cost again.
    public func unload() {
        container = nil
        loadedModelID = nil
    }

    /// Placeholder for Task 3. Full implementation lands in Task 5.
    public func summarize(
        transcript: PromptTranscript,
        modelID: String,
        modelDirectory: URL,
        budgetWords: Int
    ) async throws -> SummaryParseResult {
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        // Minimal body for Task 2: just prove the container is reachable.
        // Task 5 replaces this with the real prompt / parse pipeline.
        let raw = try await cont.generate(
            promptBody: "(stage-2 task-2 placeholder)",
            systemPrompt: nil,
            maxTokens: 16
        )
        return SummaryParser.parse(raw)
    }

    /// Load or reuse the container for `modelID`. Reloads when the id
    /// changes. Validates that the directory exists before calling the
    /// loader — the loader itself is free to assume the directory is
    /// present.
    ///
    /// Not a coalescing cache: concurrent `summarize` calls for the
    /// same id during a cold-load window would each re-enter here and
    /// load independently. The Stage 3 queue enforces serial
    /// scheduling upstream so this is never exercised in practice.
    private func getOrLoad(modelID: String, directory: URL) async throws -> any ContainerLike {
        if let container, loadedModelID == modelID {
            return container
        }
        // Different id (or first call) — drop any stale container
        // before loading so a mid-load failure doesn't leave the
        // service in a half-initialised state.
        container = nil
        loadedModelID = nil

        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SummarizerError.modelDirectoryMissing(directory)
        }

        let newContainer: any ContainerLike
        do {
            newContainer = try await loader(directory)
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.loadFailed(error.localizedDescription)
        }
        container = newContainer
        loadedModelID = modelID
        return newContainer
    }
}
