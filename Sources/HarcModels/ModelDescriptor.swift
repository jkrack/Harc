import Foundation

/// What role a model plays in the app.
public enum ModelTask: String, Codable, Sendable {
    case summarizer
}

/// Quality / resource tier. `standard`, `quality`, `pro`, `max`, `ultra` are
/// ordered; models in the same task share a tier ordering so the Settings UI
/// can render an ascending quality/resource picker. `singleton` is the escape
/// hatch for tasks that ship exactly one model (e.g. the embedder).
public enum ModelTier: String, Codable, Sendable, Comparable {
    case standard
    case quality
    case pro
    case max
    case ultra
    case singleton

    private var ordinal: Int {
        switch self {
        case .standard: return 0
        case .quality:  return 1
        case .pro:      return 2
        case .max:      return 3
        case .ultra:    return 4
        case .singleton: return -1
        }
    }

    public static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// One file inside a model bundle. `path` is relative to the model directory
/// (e.g. `"config.json"`, `"model.safetensors"`, `"tokenizer.json"`).
/// `url` is the fully-resolved download URL (HuggingFace `resolve/<revision>`).
public struct ModelFile: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL

    public init(path: String, bytes: Int64, sha256: String, url: URL) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
    }
}

/// Everything needed to present, download, verify, and install a model.
/// Hardcoded into the binary in `ModelCatalog.v1`. A descriptor is immutable
/// within a release; changing any field requires a code change.
public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// Stable id, used as the directory name and the preferences value.
    /// Example: `"gemma-4-e2b-it-4bit"`.
    public let id: String
    /// Shown in Settings. Example: `"Gemma 4 · Standard"`.
    public let displayName: String
    /// One-line sell used in Settings rows.
    public let summary: String
    public let task: ModelTask
    public let tier: ModelTier
    /// The HuggingFace repo id, for display + the refresh script.
    /// Example: `"mlx-community/gemma-4-e2b-it-4bit"`.
    public let repoID: String
    /// Pinned git revision (a full SHA). All file URLs reference this.
    public let revision: String
    public let files: [ModelFile]
    /// Sum of `files[].bytes`, pre-computed so the UI doesn't have to.
    public let totalBytes: Int64
    public let minMacOS: String
    public let minRAMGB: Int
    public let recommendedRAMGB: Int
    /// Prompt-context budget in tokens (for summarizer). Ignored for embedder.
    public let contextTokens: Int
    /// True when this descriptor's `files` list (URLs + byte counts) has been
    /// cross-checked against the real HuggingFace repo. False means the
    /// entry is a placeholder — downloads are blocked by `ModelManager` and
    /// the Settings row shows a "Manifest pending" chip. Flip to `true` when
    /// the manifest-refresh script runs (or the URLs are hand-verified).
    public let manifestVerified: Bool

    public init(
        id: String,
        displayName: String,
        summary: String,
        task: ModelTask,
        tier: ModelTier,
        repoID: String,
        revision: String,
        files: [ModelFile],
        minMacOS: String = "14.0",
        minRAMGB: Int,
        recommendedRAMGB: Int,
        contextTokens: Int,
        manifestVerified: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.task = task
        self.tier = tier
        self.repoID = repoID
        self.revision = revision
        self.files = files
        self.totalBytes = files.map(\.bytes).reduce(0, +)
        self.minMacOS = minMacOS
        self.minRAMGB = minRAMGB
        self.recommendedRAMGB = recommendedRAMGB
        self.contextTokens = contextTokens
        self.manifestVerified = manifestVerified
    }
}

public extension ModelDescriptor {
    /// Display string for the descriptor's tier, falling back to the
    /// descriptor's own `displayName` for `singleton` tiers (which don't
    /// have a meaningful "Standard/Quality/Max" label).
    var tierDisplayName: String {
        switch tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .pro:      return "Pro"
        case .max:      return "Max"
        case .ultra:    return "Ultra"
        case .singleton: return displayName
        }
    }
}
