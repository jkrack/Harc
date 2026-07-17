import Foundation
import HarcCore

/// Honest, testable mapping from observable daemon facts to the speech-model
/// readiness shown in the menu-bar panel and onboarding. Pure function — the
/// poller in AppDelegate stays a thin loop around it.
public enum STTReadiness: Equatable, Sendable {
    /// The daemon answered `status()` and the ASR model is resident.
    case ready
    /// The daemon reports an active model download (first run). Progress is
    /// in [0, 1] when the daemon knows it, nil when it doesn't.
    case downloading(progress: Double?)
    /// The daemon is reachable but the model isn't loaded yet. On a first
    /// run this is the one-time ~460 MB Hugging Face download; on later
    /// launches it's a short local load.
    case preparing(firstRun: Bool)
    /// The daemon reports a model load failure (offline first run, corrupt
    /// cache). Recording now would produce transcript holes; surface it.
    case failed(message: String)
    /// The daemon isn't reachable, but the model has been verified on this
    /// Mac before — it relaunches on demand, so capture isn't blocked.
    case idle
    /// The daemon isn't reachable and no model has ever been verified here.
    /// Recording during this state would produce transcript holes.
    case waitingForFirstModel

    public struct Facts: Equatable, Sendable {
        /// The daemon's Unix socket exists on disk.
        public var socketExists: Bool
        /// `status().modelLoaded`; nil when `status()` failed or was skipped.
        public var statusModelLoaded: Bool?
        /// The model has loaded successfully at least once on this Mac
        /// (persisted flag or FluidAudio's cache present on disk).
        public var modelVerifiedBefore: Bool
        /// `status().modelState`; nil from an older daemon or a failed call.
        public var modelState: DaemonStatus.ModelState?
        /// `status().downloadProgress` while the model is downloading.
        public var downloadProgress: Double?
        /// `status().errorMessage` when the model load failed.
        public var errorMessage: String?

        public init(
            socketExists: Bool,
            statusModelLoaded: Bool?,
            modelVerifiedBefore: Bool,
            modelState: DaemonStatus.ModelState? = nil,
            downloadProgress: Double? = nil,
            errorMessage: String? = nil
        ) {
            self.socketExists = socketExists
            self.statusModelLoaded = statusModelLoaded
            self.modelVerifiedBefore = modelVerifiedBefore
            self.modelState = modelState
            self.downloadProgress = downloadProgress
            self.errorMessage = errorMessage
        }
    }

    public static func from(_ facts: Facts) -> STTReadiness {
        // Rich states from a newer daemon win over the coarse bool.
        switch facts.modelState {
        case .downloading:
            return .downloading(progress: facts.downloadProgress)
        case .failed:
            return .failed(message: facts.errorMessage ?? "the model failed to load")
        default:
            break
        }
        switch facts.statusModelLoaded {
        case .some(true):
            return .ready
        case .some(false):
            return .preparing(firstRun: !facts.modelVerifiedBefore)
        case .none:
            return facts.modelVerifiedBefore ? .idle : .waitingForFirstModel
        }
    }

    /// True when capture can proceed without a blocked banner. `.idle`
    /// counts — the daemon relaunches on demand once the model exists.
    public var isReady: Bool {
        switch self {
        case .ready, .idle: return true
        case .downloading, .preparing, .failed, .waitingForFirstModel: return false
        }
    }

    /// Download progress when known — drives determinate progress bars.
    public var progress: Double? {
        if case .downloading(let p) = self { return p }
        return nil
    }

    public var displayText: String {
        switch self {
        case .ready:
            return "Local STT ready"
        case .idle:
            return "Speech engine starts on demand"
        case .downloading(let progress):
            if let progress {
                return "Downloading speech model — \(Int((progress * 100).rounded()))% of ~460 MB"
            }
            return "Downloading speech model (one-time, ~460 MB)…"
        case .preparing(firstRun: true):
            return "Downloading speech model (one-time, ~460 MB)…"
        case .preparing(firstRun: false):
            return "Loading speech model…"
        case .failed(let message):
            return "Speech model unavailable — \(message)"
        case .waitingForFirstModel:
            return "Waiting for the speech model — starting the engine"
        }
    }
}

/// Disk probe for FluidAudio's model cache, used to seed
/// `Facts.modelVerifiedBefore` for installs that predate the persisted flag.
public enum STTModelDiskProbe {
    /// FluidAudio caches models under
    /// `~/Library/Application Support/FluidAudio/Models/<repo>/…`.
    public static func modelPresent(
        under base: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
    ) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return false }
        return entries.contains { $0.lastPathComponent.localizedCaseInsensitiveContains("parakeet") }
    }
}
