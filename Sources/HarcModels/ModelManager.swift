import Foundation
import Combine
import CryptoKit

/// Single source of truth for model install state, downloads, and removal.
/// Owns an `AsyncStream<ModelInstallState>` per model id so SwiftUI views
/// can render progress without polling.
///
/// Thread model: it's an actor; UI views talk to it via `MainActor.run` or
/// through a shared `@MainActor` observer object (`ModelManagerStore`, below)
/// that bridges the async streams into `@Published` properties.
public actor ModelManager {

    public enum Failure: Error, LocalizedError {
        case unknownModel(String)
        case insufficientDisk(required: Int64, free: Int64)
        case otherDownloadRunning(current: String)
        case notInstalled(String)
        case filesystem(String)
        case verification(String)
        case manifestUnverified(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "Model \"\(id)\" isn't in the catalog."
            case .insufficientDisk(let req, let free):
                let f = ByteCountFormatter.string(fromByteCount: req, countStyle: .file)
                let g = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                return "Not enough disk space: need \(f), only \(g) free."
            case .otherDownloadRunning(let id):
                return "Another model is currently downloading: \(id)."
            case .notInstalled(let id): return "Model \"\(id)\" isn't installed yet."
            case .filesystem(let s): return s
            case .verification(let s): return s
            case .manifestUnverified(let id):
                return "Manifest for \"\(id)\" is not fully verified. Downloads require a pinned revision and SHA256 for every file."
            }
        }
    }

    private let storage: ModelStorage
    private let diskGuard: DiskSpaceGuard
    private let engine: DownloadEngine
    private let catalog: [ModelDescriptor]
    private let clock: () -> Date

    /// In-memory view of state per model id. Starts as `.absent`; seeded
    /// from disk on `bootstrap()`.
    private var states: [String: ModelInstallState] = [:]
    /// Per-id continuations for state change streams. Keyed by id.
    private var subscribers: [String: [UUID: AsyncStream<ModelInstallState>.Continuation]] = [:]
    /// The currently-running download id, if any. Serialized per §4.1.
    private var activeDownload: String?
    /// Cancellation tokens for the active download's Task chain.
    private var activeTask: Task<Void, Never>?

    public init(
        storage: ModelStorage = ModelStorage(baseDirectory: ModelStorage.defaultBase()),
        diskGuard: DiskSpaceGuard = DiskSpaceGuard(),
        engine: DownloadEngine = URLSessionDownloadEngine(),
        catalog: [ModelDescriptor] = ModelCatalog.v1,
        clock: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.diskGuard = diskGuard
        self.engine = engine
        self.catalog = catalog
        self.clock = clock
    }

    // MARK: - Bootstrap

    /// Read on-disk install markers and seed `states`. Safe to call more than
    /// once; later calls re-check disk so an externally-modified Models/
    /// directory is picked up.
    ///
    /// Goes through `transition` so subscribers (SwiftUI stores observing
    /// `stateChanges`) actually see the result. A direct `states[id] = ...`
    /// assignment used to silently leave subscribers stuck on `.absent`.
    public func bootstrap() {
        for d in catalog {
            let previous = states[d.id] ?? .absent
            let next = storage.persistedState(for: d.id)
            if previous != next {
                transition(d.id, to: next)
            } else if states[d.id] == nil {
                // First-ever read for this id: seed the dict and notify any
                // subscriber that attached at .absent default.
                transition(d.id, to: next)
            }
        }
    }

    // MARK: - Public API

    public func state(of id: String) -> ModelInstallState {
        states[id] ?? .absent
    }

    public func descriptor(for id: String) -> ModelDescriptor? {
        catalog.first { $0.id == id }
    }

    /// URL to the model's directory — only valid if the model is installed.
    public func requireInstalled(_ id: String) throws -> URL {
        guard case .installed = state(of: id) else {
            throw Failure.notInstalled(id)
        }
        return storage.modelDirectory(for: id)
    }

    /// Start downloading the given model. Enters `.downloading(progress: 0)`
    /// immediately; moves through `.verifying` → `.installed`, or `.failed`.
    public func startDownload(_ id: String) throws {
        guard let descriptor = descriptor(for: id) else {
            throw Failure.unknownModel(id)
        }
        guard Self.isDownloadManifestTrusted(descriptor) else {
            throw Failure.manifestUnverified(id)
        }
        if case .installed = state(of: id) {
            return   // already done
        }
        if let active = activeDownload, active != id {
            throw Failure.otherDownloadRunning(current: active)
        }
        let check = diskGuard.check(
            requiredBytes: descriptor.totalBytes,
            at: storage.baseDirectory
        )
        if !check.hasSpace {
            throw Failure.insufficientDisk(required: check.withHeadroom, free: check.free)
        }

        // Teardown any prior install record — we're re-downloading.
        try? storage.clearInstallRecord(for: id)

        activeDownload = id
        transition(id, to: .downloading(progress: 0))

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(descriptor)
        }
        activeTask = task
    }

    /// Cancel the active download for `id`. No-op if the id isn't running.
    public func cancel(_ id: String) {
        guard activeDownload == id, let task = activeTask else { return }
        task.cancel()
    }

    /// Remove a model's on-disk footprint. Errors surface but don't throw —
    /// the caller's state is always `.absent` after this returns.
    public func remove(_ id: String) {
        guard descriptor(for: id) != nil else { return }
        if activeDownload == id {
            activeTask?.cancel()
            activeDownload = nil
        }
        try? storage.removeModelDirectory(for: id)
        transition(id, to: .absent)
    }

    /// Stream of state transitions for a specific id. Each subscription
    /// receives the current state first, then future transitions.
    public nonisolated func stateChanges(id: String) -> AsyncStream<ModelInstallState> {
        AsyncStream { continuation in
            let token = UUID()
            Task { await self.attachSubscriber(id: id, token: token, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id: id, token: token) }
            }
        }
    }

    // MARK: - Internals

    private func attachSubscriber(id: String, token: UUID,
                                  continuation: AsyncStream<ModelInstallState>.Continuation) {
        var list = subscribers[id] ?? [:]
        list[token] = continuation
        subscribers[id] = list
        continuation.yield(state(of: id))
    }

    private func removeSubscriber(id: String, token: UUID) {
        subscribers[id]?.removeValue(forKey: token)
    }

    private func transition(_ id: String, to new: ModelInstallState) {
        states[id] = new
        for (_, cont) in subscribers[id] ?? [:] {
            cont.yield(new)
        }
    }

    private func runDownload(_ descriptor: ModelDescriptor) async {
        defer {
            if activeDownload == descriptor.id {
                activeDownload = nil
                activeTask = nil
            }
        }

        let totalBytes = max(1, descriptor.totalBytes)
        var bytesDone: Int64 = 0
        // Update progress in transitions as we finish each file.
        do {
            try storage.ensureModelDirectory(for: descriptor.id)

            for file in descriptor.files {
                if Task.isCancelled { throw DownloadError.cancelled }

                let destination = storage.fileURL(forDescriptor: descriptor, file: file)

                // A prior attempt may have fully downloaded + verified this
                // file — skip it so a network blip at file N of a multi-GB
                // model doesn't restart from file 1. SHA is the gate; any
                // partial or corrupt leftover fails the check and is
                // re-downloaded below.
                if FileManager.default.fileExists(atPath: destination.path),
                   let existing = try? await Self.sha256Hex(of: destination),
                   existing.lowercased() == file.sha256.lowercased() {
                    bytesDone += file.bytes
                    tickProgress(descriptor.id, progress: Double(bytesDone) / Double(totalBytes))
                    continue
                }

                let perFileBase = bytesDone
                let totalForClosure = totalBytes

                let result = try await engine.download(
                    from: file.url,
                    to: destination,
                    expectedBytes: file.bytes,
                    resumeData: nil,
                    onProgress: { [weak self] written in
                        let fraction = Double(perFileBase + written) / Double(totalForClosure)
                        Task { await self?.tickProgress(descriptor.id, progress: fraction) }
                    }
                )

                do {
                    try await verifyFile(at: destination, against: file)
                } catch {
                    // Remove the corrupt file so the model directory only
                    // ever holds verified files; earlier verified files stay
                    // for the SHA-skip resume on retry.
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                bytesDone += max(result.bytesWritten, file.bytes)
                tickProgress(descriptor.id, progress: Double(bytesDone) / Double(totalBytes))
            }

            // All files in; write the install marker.
            transition(descriptor.id, to: .verifying)
            let record = ModelStorage.InstallRecord(
                modelID: descriptor.id,
                revision: descriptor.revision,
                installedAt: clock(),
                bytes: bytesDone,
                skippedSHAVerification: false
            )
            try storage.writeInstallRecord(record)
            try? storage.clearPartialRecord(for: descriptor.id)
            transition(descriptor.id, to: .installed)
        } catch is CancellationError {
            // Keep the partial on disk for resume, but drop the install marker.
            try? storage.clearInstallRecord(for: descriptor.id)
            transition(descriptor.id, to: .absent)
        } catch let e as DownloadError {
            // Keep completed files on disk — the per-file SHA check above
            // skips them on retry, so a failure at 15 GB doesn't restart
            // from zero. Only the install marker is dropped.
            try? storage.clearInstallRecord(for: descriptor.id)
            transition(descriptor.id, to: .failed(reason: e.errorDescription ?? "Download failed"))
        } catch {
            try? storage.clearInstallRecord(for: descriptor.id)
            transition(descriptor.id, to: .failed(reason: error.localizedDescription))
        }
    }

    private func tickProgress(_ id: String, progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        transition(id, to: .downloading(progress: clamped))
    }

    // MARK: - Verification

    /// SHA-verify a downloaded file against its manifest entry.
    private func verifyFile(at url: URL, against file: ModelFile) async throws {
        guard !file.sha256.isEmpty else {
            throw Failure.verification("Missing SHA256 for \(file.path).")
        }
        let actual = try await Self.sha256Hex(of: url)
        if actual.lowercased() != file.sha256.lowercased() {
            throw DownloadError.sha256Mismatch(expected: file.sha256, actual: actual)
        }
    }

    static func isDownloadManifestTrusted(_ descriptor: ModelDescriptor) -> Bool {
        descriptor.manifestVerified
            && descriptor.revision != "main"
            && !descriptor.revision.isEmpty
            && descriptor.files.allSatisfy { file in
                file.sha256.count == 64
                    && file.sha256.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
            }
    }

    static func sha256Hex(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while autoreleasepool(invoking: {
                        let chunk = handle.readData(ofLength: 1 << 20)  // 1 MiB
                        if chunk.isEmpty { return false }
                        hasher.update(data: chunk)
                        return true
                    }) {}
                    let digest = hasher.finalize()
                    let hex = digest.map { String(format: "%02x", $0) }.joined()
                    cont.resume(returning: hex)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - SwiftUI-friendly observer

/// MainActor-bound bridge from `ModelManager`'s async streams to Combine
/// `@Published` so SwiftUI views can `@EnvironmentObject` and render row
/// state + progress without managing their own tasks.
@MainActor
public final class ModelManagerStore: ObservableObject {
    @Published public private(set) var states: [String: ModelInstallState] = [:]

    public let manager: ModelManager
    public let catalog: [ModelDescriptor]
    private var observers: [String: Task<Void, Never>] = [:]

    public init(manager: ModelManager, catalog: [ModelDescriptor] = ModelCatalog.v1) {
        self.manager = manager
        self.catalog = catalog
        for d in catalog {
            states[d.id] = .absent
            observers[d.id] = Task { [weak self] in
                let stream = manager.stateChanges(id: d.id)
                for await s in stream {
                    await MainActor.run { self?.states[d.id] = s }
                }
            }
        }
    }

    deinit {
        observers.values.forEach { $0.cancel() }
    }

    public func bootstrap() async {
        await manager.bootstrap()
    }

    public func state(of id: String) -> ModelInstallState {
        states[id] ?? .absent
    }

    public func download(_ id: String) async throws {
        try await manager.startDownload(id)
    }

    public func cancel(_ id: String) async {
        await manager.cancel(id)
    }

    public func remove(_ id: String) async {
        await manager.remove(id)
    }
}
