import Foundation
import HarcCore

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
    public private(set) var idleUnloadDelay: TimeInterval?
    private var container: (any ContainerLike)?
    private var idleUnloadTask: Task<Void, Never>?

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func setIdleUnloadDelay(_ delay: TimeInterval?) {
        idleUnloadDelay = delay
        if container != nil {
            scheduleIdleUnload(reason: "policy-change")
        }
    }

    /// Drop the resident model so MLX can reclaim GPU/ANE memory.
    /// Implemented by nil-ing the container — `mlx-swift-lm` 3.x has
    /// no explicit unload method. Next `summarize(...)` pays the load
    /// cost again.
    public func unload(reason: String = "manual") {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard let currentModelID = loadedModelID else { return }
        ModelRuntimeLog.event("unload.begin", modelID: currentModelID, reason: reason)
        container = nil
        loadedModelID = nil
        ModelRuntimeLog.event("unload.end", modelID: currentModelID, reason: reason)
    }

    /// Testing seam: the memory-pressure handler, callable directly by
    /// tests. In production it's invoked by the `DispatchSource` set up
    /// in `startObservingMemoryPressure()`.
    public func handleMemoryPressure() {
        unload(reason: "memory-pressure")
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
        budgetWords: Int,
        onStats: (@Sendable (GenerationStats) -> Void)? = nil
    ) async throws -> SummaryParseResult {
        cancelIdleUnload()
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        defer { scheduleIdleUnload(reason: "idle") }
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
                maxTokens: SummaryPrompt.maxOutputTokens,
                onStats: onStats
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

    public func answer(
        question: String,
        contextMarkdown: String,
        modelID: String,
        modelDirectory: URL
    ) async throws -> String {
        cancelIdleUnload()
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        defer { scheduleIdleUnload(reason: "idle") }
        let promptBody = ConversationPrompt.build(
            question: question,
            contextMarkdown: contextMarkdown
        )

        do {
            return try await cont.generate(
                promptBody: promptBody,
                systemPrompt: ConversationPrompt.systemPrompt,
                maxTokens: ConversationPrompt.maxOutputTokens
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.generationFailed(error.localizedDescription)
        }
    }

    /// Transform `text` per a dictation mode's `instruction` and return the
    /// raw transformed string. Shares the resident container with
    /// `summarize`/`answer` via `getOrLoad`, so a mode using the active
    /// summarizer model pays no extra load cost.
    public func transform(
        text: String,
        instruction: String,
        systemPrompt: String? = nil,
        contextBlock: String? = nil,
        modelID: String,
        modelDirectory: URL,
        maxTokens: Int = ModeTransformPrompt.maxOutputTokens
    ) async throws -> String {
        cancelIdleUnload()
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        defer { scheduleIdleUnload(reason: "idle") }
        let hasContext = !(contextBlock?.isEmpty ?? true)
        let promptBody = ModeTransformPrompt.build(
            instruction: instruction,
            transcript: text,
            contextBlock: contextBlock
        )

        do {
            return try await cont.generate(
                promptBody: promptBody,
                systemPrompt: systemPrompt
                    ?? ModeTransformPrompt.systemPrompt(includesContext: hasContext),
                maxTokens: maxTokens
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.generationFailed(error.localizedDescription)
        }
    }

    /// Load the container for `modelID` without generating — lets callers
    /// (dictation's cold-load phase) attribute the multi-GB load to its own
    /// UI state instead of hiding it under generation time. No-op when the
    /// model is already resident.
    public func preload(modelID: String, modelDirectory: URL) async throws {
        cancelIdleUnload()
        _ = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        scheduleIdleUnload(reason: "idle")
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
            ModelRuntimeLog.event("load.begin", modelID: modelID, reason: "summarizer")
            newContainer = try await loader(directory)
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.loadFailed(error.localizedDescription)
        }
        container = newContainer
        loadedModelID = modelID
        ModelRuntimeLog.event("load.end", modelID: modelID, reason: "summarizer")
        return newContainer
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func scheduleIdleUnload(reason: String) {
        cancelIdleUnload()
        guard let idleUnloadDelay, let modelID = loadedModelID else { return }
        let nanoseconds = UInt64(max(0, idleUnloadDelay) * 1_000_000_000)
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.unloadIfStillLoaded(modelID: modelID, reason: reason)
        }
    }

    private func unloadIfStillLoaded(modelID: String, reason: String) {
        guard loadedModelID == modelID else { return }
        unload(reason: reason)
    }
}
