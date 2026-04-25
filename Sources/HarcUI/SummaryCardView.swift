import SwiftUI
import AppKit
import HarcStore
import HarcModels
import HarcSummarize

/// Renders one of six states above the transcript in `TranscriptionDetailView`.
/// All state resolution lives in the pure `SummaryCardState.resolve(...)` helper;
/// this view's only job is to translate its observed environment into that
/// helper's primitive inputs and lay out each case.
public struct SummaryCardView: View {
    let recording: Recording
    let activeSummarizerID: String
    let onClearSummary: (Int64) -> Void

    @EnvironmentObject private var queueStore: SummarizationQueueStore
    @EnvironmentObject private var modelStore: ModelManagerStore

    public init(
        recording: Recording,
        activeSummarizerID: String,
        onClearSummary: @escaping (Int64) -> Void
    ) {
        self.recording = recording
        self.activeSummarizerID = activeSummarizerID
        self.onClearSummary = onClearSummary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            if case .summary = state, SummaryCardState.isStale(recording: recording) {
                stalenessBanner
            }
            card
        }
    }

    private var state: SummaryCardState {
        SummaryCardState.resolve(
            recording: recording,
            isInFlight: queueStore.current == recording.id,
            isQueued: recording.id.map { queueStore.isQueued($0) && queueStore.current != $0 } ?? false,
            position: recording.id.flatMap { queueStore.position($0) },
            totalInFlight: queueStore.totalInFlight,
            isSummarizerInstalled: modelStore.state(of: activeSummarizerID).isInstalled,
            lastFailure: recording.id.flatMap { queueStore.lastFailures[$0] }
        )
    }

    @ViewBuilder private var card: some View {
        switch state {
        case .empty:
            emptyCard
        case .installRequired:
            installRequiredCard
        case .queued(let position, let totalInFlight):
            queuedCard(position: position, totalInFlight: totalInFlight)
        case .inFlight:
            inFlightCard
        case .failed(let message):
            failedCard(message: message)
        case .summary:
            summaryCard
        }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        tintedContainer {
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.harcAccent)
                Text("No summary yet.")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
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
                    descriptor: descriptor,
                    reason: "Generate summaries and action items from your meeting transcripts."
                )
            } else {
                tintedContainer {
                    Text("Active summarizer model is unknown.")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcError)
                }
            }
        }
    }

    private func queuedCard(position: Int, totalInFlight: Int) -> some View {
        tintedContainer {
            HStack(spacing: HarcDesign.Space.sm) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.harcInkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summarization queued")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcInkPrimary)
                    Text("Queued · #\(position) of \(totalInFlight)")
                        .font(HarcDesign.Font.meta)
                        .foregroundStyle(Color.harcInkTertiary)
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
            HStack(spacing: HarcDesign.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Summarizing with \(currentTierDisplay)…")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkPrimary)
                Spacer()
                Button("Cancel") { cancelSelf() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func failedCard(message: String) -> some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                HStack(spacing: HarcDesign.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.harcWarning)
                    Text("Summarization failed")
                        .font(HarcDesign.Font.body)
                        .foregroundStyle(Color.harcInkPrimary)
                    Spacer()
                }
                Text(message)
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HarcDesign.Space.xs) {
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

    private var summaryCard: some View {
        tintedContainer {
            VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
                summaryHeader
                Text(markdown: recording.summaryMarkdown ?? "")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkPrimary)
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
                            .font(HarcDesign.Font.bodySm)
                            .italic()
                            .foregroundStyle(Color.harcInkTertiary)
                    } else {
                        // Parser couldn't extract structured items but the
                        // column has content — render the raw markdown so the
                        // user sees what the model produced rather than a
                        // silently-dropped section.
                        Text(markdown: raw)
                            .font(HarcDesign.Font.body)
                            .foregroundStyle(Color.harcInkPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.harcAccent)
            Text("Summary")
                .font(HarcDesign.Font.subtitle)
                .foregroundStyle(Color.harcInkPrimary)
            Text("· generated with \(persistedTierDisplay)")
                .font(HarcDesign.Font.meta)
                .foregroundStyle(Color.harcInkTertiary)
            if let when = recording.summaryGeneratedAt {
                Text("· \(when, format: .relative(presentation: .named))")
                    .font(HarcDesign.Font.meta)
                    .foregroundStyle(Color.harcInkTertiary)
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
            .font(HarcDesign.Font.label)
            .foregroundStyle(Color.harcInkSecondary)
    }

    private func actionItemsList(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                actionItemRow(item)
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcDesign.Space.xs) {
            Text("•").foregroundStyle(Color.harcInkTertiary)
            HStack(spacing: 0) {
                if let actor = item.actor {
                    Text("\(actor): ").bold().foregroundStyle(Color.harcInkPrimary)
                }
                Text(item.text).foregroundStyle(Color.harcInkPrimary)
                if let due = item.due {
                    Text(" (\(due))").italic().foregroundStyle(Color.harcInkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(HarcDesign.Font.body)
    }

    private var stalenessBanner: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harcWarning)
            Text("Summary is based on an older transcript.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcWarning)
            Spacer(minLength: 0)
            Button("Regenerate") { enqueueSelf() }
                .buttonStyle(.plain)
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcWarning)
        }
        .padding(.horizontal, HarcDesign.Space.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .fill(Color.harcWarning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                .strokeBorder(Color.harcWarning.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tintedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, HarcDesign.Space.md)
            .padding(.vertical, HarcDesign.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                    .fill(Color.harcAccent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg)
                    .strokeBorder(Color.harcAccent.opacity(0.3), lineWidth: 1)
            )
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

    private var currentTierDisplay: String {
        guard let d = ModelCatalog.descriptor(for: activeSummarizerID) else {
            return activeSummarizerID
        }
        return tierName(d.tier, fallback: d.displayName)
    }

    private func tierName(_ tier: ModelTier, fallback: String) -> String {
        switch tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .max:      return "Max"
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
