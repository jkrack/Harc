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

    /// Testing seam: the memory-pressure handler, callable directly by
    /// tests. In production it's invoked by the `DispatchSource` set up
    /// in `startObservingMemoryPressure()`.
    public func handleMemoryPressure() {
        unload()
    }

    /// Begin observing OS-level memory pressure warnings and nil-out
    /// the resident container on warning/critical events. Safe to call
    /// multiple times; only the first call installs the source. Caller
    /// owns the returned handle — retain it for the lifetime of the
    /// service; dropping it cancels observation.
    ///
    /// Not called from `init` because actor isolation combined with
    /// `DispatchSource` event handlers would require a Task hop on
    /// every invocation. The caller (AppDelegate in Stage 3) calls
    /// this explicitly after construction.
    public nonisolated func startObservingMemoryPressure() -> MemoryPressureObservation {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }
        source.resume()
        return MemoryPressureObservation(source: source)
    }

    /// Handle returned from `startObservingMemoryPressure`. Drops the
    /// underlying DispatchSource when deallocated, which stops event
    /// delivery.
    public final class MemoryPressureObservation: @unchecked Sendable {
        private let source: DispatchSourceMemoryPressure
        init(source: DispatchSourceMemoryPressure) { self.source = source }
        deinit { source.cancel() }
    }

    /// Render the prompt for `transcript` (clamped to `budgetWords`),
    /// generate via the lazily-loaded container for `modelID` (loaded
    /// from `modelDirectory` on first use), and return the parsed
    /// two-section result.
    ///
    /// Throws `SummarizerError.modelDirectoryMissing` if the directory
    /// doesn't exist on disk, `.loadFailed` if the underlying loader
    /// throws, `.generationFailed` if generation throws a non-typed
    /// error. `CancellationError` from `Task` cancellation propagates
    /// unwrapped so callers can `catch is CancellationError` cleanly.
    public func summarize(
        transcript: PromptTranscript,
        modelID: String,
        modelDirectory: URL,
        budgetWords: Int
    ) async throws -> SummaryParseResult {
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        let promptBody = SummaryPrompt.build(
            transcript: transcript,
            budgetWords: budgetWords
        )

        let raw: String
        do {
            // The template already carries the instructions — no
            // separate system prompt in v1. See the §5.1 template.
            raw = try await cont.generate(
                promptBody: promptBody,
                systemPrompt: nil,
                maxTokens: SummaryPrompt.maxOutputTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.generationFailed(error.localizedDescription)
        }

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
