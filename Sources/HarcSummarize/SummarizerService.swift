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
/// The service serializes summary, answer, dictation and preload operations.
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
    private var loadedDirectory: URL?
    private var loadGeneration = UUID()
    private var operationActive = false
    private var operationWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Internal diagnostic for bounded concurrency tests.
    var pendingOperationCount: Int { operationWaiters.count }

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
        loadGeneration = UUID()
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        loadedDirectory = nil
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
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        cancelIdleUnload()
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        defer { scheduleIdleUnload(reason: "idle") }
        let inputWords = transcript.utterances.map(SummaryPrompt.line(for:)).reduce(0) {
            $0 + SummaryPrompt.wordCount(of: $1)
        }
        if inputWords > budgetWords {
            let generation = loadGeneration
            let result = try await LongSummary.run(transcript: transcript, budget: budgetWords) { prompt in
                try await self.generateSummaryPass(prompt, container: cont, generation: generation, onStats: onStats)
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            try SummaryTaskValidation.validate(result)
            return result
        }
        let rendered = SummaryPrompt.renderWithCoverage(
            transcript: transcript,
            budgetWords: budgetWords
        )

        let promptBody = SummaryPrompt.template.replacingOccurrences(of: "{TRANSCRIPT}", with: rendered.body)
        let generation = loadGeneration
        let raw = try await generateSummaryPass(promptBody, container: cont, generation: generation, onStats: onStats)
        let parsed = SummaryParser.parse(raw)
        try SummaryTaskValidation.validate(parsed)
        guard !parsed.parseWarning else { return parsed }
        let factsPrompt = SummaryPrompt.factsTemplate.replacingOccurrences(of: "{TRANSCRIPT}", with: rendered.body)
        let facts = try await generateSummaryPass(factsPrompt, container: cont, generation: generation, onStats: onStats)
        let trimmed = facts.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "## Summary\n"
        guard trimmed.hasPrefix(prefix), !trimmed.dropFirst(prefix.count).contains("##"),
              !trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.generationFailed("The factual summary pass was incomplete. No partial summary was saved.")
        }
        return SummaryParseResult(summary: String(trimmed.dropFirst(prefix.count)), actionItems: parsed.actionItems, parseWarning: false)

    }

    /// All summary passes share termination and authority checks. Markdown
    /// validity alone cannot establish that generation finished.
    private func generateSummaryPass(
        _ prompt: String, container: any ContainerLike, generation: UUID,
        onStats: (@Sendable (GenerationStats) -> Void)?
    ) async throws -> String {
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        let completion = SummaryCompletion()
        let raw: String
        do {
            raw = try await container.generateSummary(promptBody: prompt,
                maxTokens: SummaryPrompt.maxOutputTokens, onStats: { stats in
                    completion.observe(stats)
                    onStats?(stats)
                })
        } catch {
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            if error is CancellationError { throw CancellationError() }
            if let typed = error as? SummarizerError { throw typed }
            throw SummarizerError.generationFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        switch completion.reason {
        case .outputLimit:
            throw SummarizerError.generationFailed("The model reached its output limit before completing the summary. No incomplete summary was saved.")
        case .cancelled:
            // Caller cancellation/unload was checked above. A runtime stop
            // without either is a visible failure, not a user cancellation.
            throw SummarizerError.generationFailed("The model stopped before completing the summary. No incomplete summary was saved.")
        case .complete, nil:
            return raw
        }
    }

    public func answer(
        question: String,
        contextMarkdown: String,
        modelID: String,
        modelDirectory: URL
    ) async throws -> String {
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
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
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
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
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        cancelIdleUnload()
        _ = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        scheduleIdleUnload(reason: "idle")
    }

    /// Called only by the operation owner. Reuse requires both model identity
    /// and directory identity; a model switched to another location reloads.
    private func getOrLoad(modelID: String, directory: URL) async throws -> any ContainerLike {
        let normalizedDirectory = directory.standardizedFileURL
        if let container, loadedModelID == modelID, loadedDirectory == normalizedDirectory {
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

        let generation = loadGeneration
        let newContainer: any ContainerLike
        do {
            ModelRuntimeLog.event("load.begin", modelID: modelID, reason: "summarizer")
            newContainer = try await loader(directory)
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
        } catch {
            // A noncooperative loader can throw an ordinary error after its
            // request was cancelled or unloaded. Preserve the invalidation.
            if error is CancellationError || Task.isCancelled || generation != loadGeneration {
                throw CancellationError()
            }
            if let typed = error as? SummarizerError { throw typed }
            throw SummarizerError.loadFailed(error.localizedDescription)
        }
        container = newContainer
        loadedModelID = modelID
        loadedDirectory = normalizedDirectory
        ModelRuntimeLog.event("load.end", modelID: modelID, reason: "summarizer")
        return newContainer
    }

    private func acquireOperation() async throws {
        try Task.checkCancellation()
        if !operationActive {
            operationActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operationWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaitingOperation(id) }
        }
    }

    private func cancelWaitingOperation(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else { return }
        operationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationActive = false
        } else {
            operationWaiters.removeFirst().continuation.resume()
        }
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
        guard !operationActive, loadedModelID == modelID else { return }
        unload(reason: reason)
    }
}

/// Stats callbacks may run off the service actor. Only final metadata is
/// authoritative; interim chunk counts must not decide completion.
private final class SummaryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GenerationStats.StopReason?
    func observe(_ stats: GenerationStats) {
        guard stats.isFinal else { return }
        lock.withLock {
            guard value != .outputLimit, value != .cancelled else { return }
            if let reason = stats.stopReason { value = reason }
        }
    }
    var reason: GenerationStats.StopReason? { lock.withLock { value } }
}
