import SwiftUI

/// "Stats for Nerds" — the inspector section that surfaces what Harc
/// actually computed for this recording: pipeline throughput, speech
/// dynamics, talk-time balance, voiceprints, and index state. Values are
/// monospaced; rows with nothing to say don't render.
struct NerdStatsSection: View {
    let stats: RecordingNerdStats
    /// Person-resolved labels by speaker index; falls back to "Speaker N".
    let speakerLabels: [Int: String]

    var body: some View {
        Section("Stats for Nerds") {
            pipelineRows
            speechRows
            voiceRows
            intelligenceRows
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var pipelineRows: some View {
        if let factor = stats.realtimeFactor {
            row("Transcription speed", String(format: "%.0f× realtime", factor))
                .help("Seconds of audio transcribed per second of compute, on the Neural Engine")
        }
        if stats.chunkCount > 0 {
            row("Chunks", "\(stats.chunkCount) · avg \(Self.ms(stats.totalProcessingMs / stats.chunkCount))")
                .help("The recording was transcribed in rolling chunks while capture continued")
        }
        if let model = stats.sttModelID {
            row("Speech model", model)
        }
        if stats.durationSeconds != nil {
            row("Audio", audioValue)
        }
    }

    private var audioValue: String {
        var parts = [Self.duration(stats.durationSeconds ?? 0)]
        if let bytes = stats.wavBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        parts.append("16 kHz mono")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var speechRows: some View {
        if stats.wordCount > 0 {
            row("Words", wordsValue)
        }
        if let coverage = stats.speechCoverage {
            row("Speech vs silence", String(format: "%.0f%% speech", coverage * 100))
                .help("Diarized speech over wall clock — voice-activity detection skips the rest")
        }
        if stats.speakerTurns > 1 {
            row("Speaker turns", "\(stats.speakerTurns) · longest monologue \(Self.duration(Double(stats.longestMonologueMs) / 1000))")
        }
    }

    @ViewBuilder
    private var voiceRows: some View {
        ForEach(stats.speakerShares) { share in
            row(
                speakerLabels[share.index] ?? "Speaker \(share.index + 1)",
                String(format: "%.0f%% · %@", share.share * 100, Self.duration(Double(share.talkMs) / 1000))
            )
        }
        if let print = stats.voiceprints.first {
            row(
                "Voiceprints",
                "\(stats.voiceprints.count) × \(print.dimensions)-dim \(print.embedderKind ?? "embedding")"
            )
            .help("Speaker embeddings used to recognize the same voice across recordings")
        }
    }

    private var wordsValue: String {
        var value = stats.wordCount.formatted()
        if let wpm = stats.wordsPerMinute {
            value += String(format: " · %.0f/min", wpm)
        }
        return value
    }

    private var summaryValue: String {
        var value = stats.summaryModelID ?? ""
        if let words = stats.summarySourceWordCount {
            value += " · from \(words.formatted()) words"
        }
        return value
    }

    @ViewBuilder
    private var intelligenceRows: some View {
        if stats.summaryModelID != nil {
            row("Summary", summaryValue)
        }
        if stats.semanticChunkCount > 0 {
            row(
                "Semantic index",
                "\(stats.semanticChunkCount) chunks · \(stats.semanticEmbedderID ?? "unindexed")"
            )
            .help("Passage embeddings behind hybrid search")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.harcMono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.harcLabel)
    }

    // MARK: - Formatting

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func ms(_ value: Int) -> String {
        value >= 1000
            ? String(format: "%.1fs", Double(value) / 1000)
            : "\(value)ms"
    }
}
