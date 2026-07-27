import SwiftUI
import AppKit
import HarcStore
import HarcModels
import HarcSummarize

/// Renders one of six states above the transcript in the recording detail panel.
/// All state resolution lives in the pure `SummaryCardState.resolve(...)` helper;
/// this view's only job is to translate its observed environment into that
/// helper's primitive inputs and lay out each case.
public struct SummaryCardView: View {
    let recording: Recording
    let store: RecordingStore?
    let activeSummarizerID: String
    let hasTranscript: Bool
    let onClearSummary: (Int64) -> Void

    @EnvironmentObject private var queueStore: SummarizationQueueStore
    @EnvironmentObject private var modelStore: ModelManagerStore

    public init(
        recording: Recording,
        store: RecordingStore? = nil,
        activeSummarizerID: String,
        hasTranscript: Bool = true,
        onClearSummary: @escaping (Int64) -> Void
    ) {
        self.recording = recording
        self.store = store
        self.activeSummarizerID = activeSummarizerID
        self.hasTranscript = hasTranscript
        self.onClearSummary = onClearSummary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            if case .summary = state, SummaryCardState.isStale(recording: recording) {
                stalenessBanner
            }
            card
        }
    }

    private var state: SummaryCardState {
        SummaryCardState.resolve(
            recording: recording,
            isInFlight: recording.id.map { queueStore.current == $0 } ?? false,
            isQueued: recording.id.map { queueStore.isQueued($0) && queueStore.current != $0 } ?? false,
            position: recording.id.flatMap { queueStore.position($0) },
            totalInFlight: queueStore.totalInFlight,
            isSummarizerInstalled: modelStore.state(of: activeSummarizerID).isInstalled,
            hasTranscript: hasTranscript,
            lastFailure: recording.id.flatMap { queueStore.lastFailures[$0] }
        )
    }

    @ViewBuilder private var card: some View {
        switch state {
        case .empty:
            emptyCard
        case .installRequired:
            installRequiredCard
        case .transcriptRequired:
            transcriptRequiredCard
        case .queued(let position, let totalInFlight):
            queuedCard(position: position, totalInFlight: totalInFlight)
        case .inFlight:
            inFlightCard
        case .failed(let message):
            failedCard(message: message)
        case .skipped(let message):
            skippedCard(message: message)
        case .summary:
            summaryCard
        }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        tintedContainer {
            HStack(spacing: HarcSpacing.md) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("No summary yet.")
                    .font(.harcBody)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("Generate") { enqueueSelf() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var installRequiredCard: some View {
        Group {
            if let descriptor = ModelCatalog.descriptor(for: activeSummarizerID) {
                ModelRequirementView(
                    title: "Needs \(descriptor.displayName)",
                    description: "Generate summaries and action items from your meeting transcripts.",
                    actionTitle: "Open Models Settings",
                    action: {
                        NSApp.sendAction(Selector(("harcShowSettingsWindow:")), to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )
            } else {
                tintedContainer {
                    Text("Active summarizer model is unknown.")
                        .font(.harcBody)
                        .foregroundStyle(Color.harc(.failure))
                }
            }
        }
    }

    private var transcriptRequiredCard: some View {
        tintedContainer {
            HStack(spacing: HarcSpacing.md) {
                Image(systemName: "text.badge.xmark")
                    .foregroundStyle(Color.harc(.attention))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No transcript available")
                        .font(.harcBody)
                        .foregroundStyle(Color.primary)
                    Text("Summaries need transcript text. Re-transcribe this audio before generating a summary.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func queuedCard(position: Int, totalInFlight: Int) -> some View {
        tintedContainer {
            HStack(spacing: HarcSpacing.md) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summarization queued")
                        .font(.harcBody)
                        .foregroundStyle(Color.primary)
                    Text("Queued · #\(position) of \(totalInFlight)")
                        .font(.harcLabel)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Spacer()
                Button("Cancel") { cancelSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var inFlightCard: some View {
        tintedContainer {
            HStack(alignment: .top, spacing: HarcSpacing.md) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summarizing with \(currentModelDisplay)…")
                        .font(.harcBody)
                        .foregroundStyle(Color.primary)
                    Text(liveThroughputText ?? currentModelResourceHint)
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Cancel") { cancelSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func failedCard(message: String) -> some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                HStack(spacing: HarcSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.harc(.attention))
                    Text("Summarization failed")
                        .font(.harcBody)
                        .foregroundStyle(Color.primary)
                    Spacer()
                }
                Text(message)
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcSpacing.sm) {
                    Button("Retry") { enqueueSelf() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Dismiss") { dismissFailureOnSelf() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func skippedCard(message: String) -> some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                HStack(spacing: HarcSpacing.sm) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(Color.harc(.attention))
                    Text("Summarization skipped")
                        .font(.harcBody)
                        .foregroundStyle(Color.primary)
                    Spacer()
                }
                Text(message)
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcSpacing.sm) {
                    Button("Generate") { enqueueSelf() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Dismiss") { dismissFailureOnSelf() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var summaryCard: some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                summaryHeader
                Text(markdown: recording.summaryMarkdown ?? "")
                    .font(.harcBody)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let items = parsedActionItems, !items.isEmpty {
                    actionItemsLabel
                    actionItemsList(items)
                } else if let raw = recording.actionItemsMarkdown?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty {
                    actionItemsLabel
                    if raw.lowercased() == "_none identified._" {
                        Text("No action items identified.")
                            .font(.harcLabel)
                            .italic()
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    } else {
                        // Parser couldn't extract structured items but the
                        // column has content — render the raw markdown so the
                        // user sees what the model produced rather than a
                        // silently-dropped section.
                        Text(markdown: raw)
                            .font(.harcBody)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("Summary")
                .font(.harcTitle)
                .foregroundStyle(Color.primary)
            Text("· generated with \(persistedTierDisplay)")
                .font(.harcLabel)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            if let when = recording.summaryGeneratedAt {
                Text("· \(RelativeTimeFormatter.relativeOrDated(when))")
                    .font(.harcLabel)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            Spacer()
            Button(action: enqueueSelf) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Regenerate with the active summarizer")

            Menu {
                Button("Copy summary") {
                    if let s = recording.summaryMarkdown { copyToPasteboard(s) }
                }
                Button("Copy action items") {
                    if let a = recording.actionItemsMarkdown { copyToPasteboard(a) }
                }
                Divider()
                Button("Clear summary", role: .destructive) {
                    if let id = recording.id { onClearSummary(id) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var actionItemsLabel: some View {
        Text("ACTION ITEMS")
            .font(.harcCaption)
            .foregroundStyle(Color.secondary)
    }

    private func actionItemsList(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                actionItemRow(item)
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
            Text("•").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            HStack(spacing: 0) {
                if let actor = item.actor {
                    Text("\(actor): ").bold().foregroundStyle(Color.primary)
                }
                Text(item.text).foregroundStyle(Color.primary)
                if let due = item.due {
                    Text(" (\(due))").italic().foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.harcBody)
    }

    private var stalenessBanner: some View {
        NativeStatusCallout(intent: .warning) {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.harc(.attention))
                Text("Summary is based on an older transcript.")
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Regenerate") { enqueueSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tintedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content()
                .padding(.vertical, 2)
        }
    }

    private var parsedActionItems: [ActionItem]? {
        guard let body = recording.actionItemsMarkdown else { return nil }
        return SummaryParser.parseActionItems(body)
    }

    private var persistedTierDisplay: String {
        guard let id = recording.summaryModelID,
              let d = ModelCatalog.descriptor(for: id) else {
            return recording.summaryModelID ?? "unknown"
        }
        return tierName(d.tier, fallback: d.displayName)
    }

    private var currentModelDisplay: String {
        guard let d = ModelCatalog.descriptor(for: activeSummarizerID) else {
            return activeSummarizerID
        }
        return "\(d.displayName) (\(d.id))"
    }

    /// Live on-device throughput while THIS recording's job is generating.
    /// Nil before the first snapshot (model load, prompt processing) — the
    /// static resource hint shows instead.
    private var liveThroughputText: String? {
        guard let id = recording.id, queueStore.current == id,
              let stats = queueStore.liveStats else { return nil }
        return "\(stats.generatedTokens) tokens · \(Int(stats.tokensPerSecond.rounded())) tok/s on-device"
    }

    private var currentModelResourceHint: String {
        guard let d = ModelCatalog.descriptor(for: activeSummarizerID) else {
            return "Model identity unavailable."
        }
        let size = ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file)
        return "\(size) on disk · recommends \(d.recommendedRAMGB) GB RAM"
    }

    private func tierName(_ tier: ModelTier, fallback: String) -> String {
        switch tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .pro:      return "Pro"
        case .max:      return "Max"
        case .ultra:    return "Ultra"
        case .singleton: return fallback
        }
    }

    private func enqueueSelf() {
        guard let id = recording.id else { return }
        Task { await queueStore.queue.enqueue(id) }
    }

    private func cancelSelf() {
        guard let id = recording.id else { return }
        Task { await queueStore.queue.cancel(id) }
    }

    private func dismissFailureOnSelf() {
        guard let id = recording.id else { return }
        queueStore.dismissFailure(id)
        Task { try? await recordingStoreClearSummaryStatus(id: id) }
    }

    private func recordingStoreClearSummaryStatus(id: Int64) async throws {
        guard let store else { return }
        try await store.clearSummaryStatus(id: id)
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

// Tiny helper so `Text(markdown:)` reads clearly at call site. Uses
// AttributedString rather than LocalizedStringKey because the input is
// model-generated content — LocalizedStringKey would reinterpret `%@`-style
// substrings as format specifiers and run the string through Bundle
// localization lookup. AttributedString.init(markdown:) parses inline
// markdown safely; the verbatim fallback covers any parse failure.
private extension Text {
    init(markdown: String) {
        if let attr = try? AttributedString(markdown: markdown) {
            self.init(attr)
        } else {
            self.init(verbatim: markdown)
        }
    }
}
