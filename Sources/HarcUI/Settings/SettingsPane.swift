import SwiftUI

/// The Settings sidebar's panes. Ordering here is the sidebar's order:
/// everyday configuration first, reference and troubleshooting last.
public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case recording
    case transcription
    case dictation
    case modes
    case ai
    case about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .dictation: return "Dictation"
        case .modes: return "Modes"
        case .ai: return "AI Models"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .transcription: return "text.quote"
        case .dictation: return "mic"
        case .modes: return "sparkles"
        case .ai: return "brain"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Search

/// One searchable setting. `keywords` carries the words a user is likely to
/// type that don't appear in the visible label — "diarization" for Speakers,
/// "quarantine" for the permission reset — so search finds settings by the
/// name the user knows them by, not only the name Harc prints.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    let pane: SettingsPane
    let label: String
    let keywords: [String]

    var id: String { "\(pane.rawValue).\(label)" }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        if label.lowercased().contains(needle) { return true }
        if pane.title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }
}

enum SettingsSearchIndex {
    static func results(for query: String) -> [SettingsSearchEntry] {
        entries.filter { $0.matches(query) }
    }

    static let entries: [SettingsSearchEntry] = [
        // General
        .init(pane: .general, label: "Appearance",
              keywords: ["theme", "dark mode", "light", "system"]),
        .init(pane: .general, label: "Launch at login",
              keywords: ["startup", "start", "boot", "login item"]),

        // Recording
        .init(pane: .recording, label: "Destination folder",
              keywords: ["save", "where", "location", "path", "documents", "output"]),
        .init(pane: .recording, label: "Recording hotkey",
              keywords: ["shortcut", "key", "toggle", "global"]),
        .init(pane: .recording, label: "Auto-stop when silent",
              keywords: ["silence", "timeout", "idle", "stop"]),
        .init(pane: .recording, label: "Capture before you press record",
              keywords: ["retroactive", "pre-roll", "preroll", "rewind", "buffer",
                         "before", "missed", "back in time", "always on"]),
        .init(pane: .recording, label: "Hard duration cap",
              keywords: ["maximum", "length", "limit", "cap"]),
        .init(pane: .recording, label: "Auto-paste on stop",
              keywords: ["clipboard", "insert", "paste", "deny", "block", "excluded apps"]),
        .init(pane: .recording, label: "Post-stop notification",
              keywords: ["notify", "banner", "alert"]),
        .init(pane: .recording, label: "Meeting detection",
              keywords: ["zoom", "teams", "slack", "meet", "monitored apps", "auto start"]),

        // Transcription
        .init(pane: .transcription, label: "Speakers",
              keywords: ["diarization", "diarize", "who", "labels", "speaker 1"]),
        .init(pane: .transcription, label: "Voice-activity detection",
              keywords: ["vad", "silence", "skip", "battery"]),
        .init(pane: .transcription, label: "Chunk duration",
              keywords: ["slice", "interval", "window", "60", "background"]),
        .init(pane: .transcription, label: "Vocabulary",
              keywords: ["replace", "spelling", "acronym", "jargon", "names", "corrections"]),
        .init(pane: .transcription, label: "Blend meaning into search",
              keywords: ["semantic", "vector", "embedding", "similarity", "hybrid", "search"]),
        .init(pane: .transcription, label: "Search index",
              keywords: ["index", "reindex", "rebuild", "embeddings", "chunks", "search"]),
        .init(pane: .transcription, label: "Re-transcribe archive",
              keywords: ["reprocess", "redo", "again", "upgrade", "backfill", "old recordings", "model"]),

        // Dictation
        .init(pane: .dictation, label: "Dictation hotkey",
              keywords: ["shortcut", "push to talk", "key"]),
        .init(pane: .dictation, label: "Trigger style",
              keywords: ["push to talk", "toggle", "hold"]),
        .init(pane: .dictation, label: "Dictated text",
              keywords: ["cursor", "insert", "clipboard", "copy"]),
        .init(pane: .dictation, label: "Restore clipboard after inserting",
              keywords: ["clipboard", "pasteboard", "restore"]),
        .init(pane: .dictation, label: "Sounds",
              keywords: ["audio", "chime", "beep", "feedback"]),
        .init(pane: .dictation, label: "Keep the dictation pill on screen",
              keywords: ["hud", "pill", "overlay", "persistent"]),
        .init(pane: .dictation, label: "Keep dictation ready",
              keywords: ["warm", "fast", "latency", "preload", "memory"]),
        .init(pane: .dictation, label: "Keep dictation history",
              keywords: ["history", "privacy", "log", "recent"]),

        // Modes
        .init(pane: .modes, label: "Dictation modes",
              keywords: ["clean-up", "email", "message", "answer", "prompt", "rewrite"]),
        .init(pane: .modes, label: "Per-app mode rules",
              keywords: ["activate", "apps", "automatic", "frontmost"]),

        // AI Models
        .init(pane: .ai, label: "Active summarizer",
              keywords: ["model", "gemma", "qwen", "tier", "summary"]),
        .init(pane: .ai, label: "Download models",
              keywords: ["install", "remove", "disk", "gb", "hugging face"]),
        .init(pane: .ai, label: "Performance",
              keywords: ["speed", "quality", "tokens", "throughput"]),
        .init(pane: .ai, label: "Automatically summarize after recording",
              keywords: ["auto", "summary", "battery"]),
        .init(pane: .ai, label: "Include summary in exports",
              keywords: ["prompt", "copy", "export", "markdown", "docx"]),

        // About
        .init(pane: .about, label: "Check for updates",
              keywords: ["sparkle", "version", "upgrade", "release"]),
        .init(pane: .about, label: "Storage",
              keywords: ["disk", "space", "uninstall", "size", "caches", "reveal"]),
        .init(pane: .about, label: "Recording permissions",
              keywords: ["privacy", "microphone", "screen", "reset", "repair", "access", "tcc"]),
    ]
}
