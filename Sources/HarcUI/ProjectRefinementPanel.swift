import SwiftUI
import HarcStore
import HarcDomain

/// Reusable local-only screen. Not installed in Library until the caller supplies
/// canonical writer authority; never attach it to a secondary-client mirror.
public struct ProjectRefinementPanel: View {
    @StateObject private var model: ProjectRefinementViewModel
    @FocusState private var focusedReview: UUID?
    @AccessibilityFocusState private var feedbackFocused: Bool
    private let onOpenRecording: (CanonicalRecordingID) -> Void

    public init(store: RecordingStore, expectedHost: LibraryMetadata, canWrite: @escaping @MainActor () -> Bool, onOpenRecording: @escaping (CanonicalRecordingID) -> Void) {
        _model = StateObject(wrappedValue: ProjectRefinementViewModel(store: store, expectedHost: expectedHost, canWrite: canWrite))
        self.onOpenRecording = onOpenRecording
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcSpacing.lg) {
                Text("A few connections to review").font(.harcTitle)
                Text("Help connect recordings to knowledge projects. These are separate from Library folders. Your answers stay on this Mac.")
                    .font(.harcBody)
                if let feedback = model.errorMessage ?? model.statusMessage {
                    Text(feedback).font(.harcBody).accessibilityFocused($feedbackFocused)
                }
                if model.isLoading { ProgressView("Loading connections…") }
                ForEach(model.cards) { card in
                    VStack(alignment: .leading, spacing: HarcSpacing.md) {
                        Text("Does this recording belong to \(card.projectName)?").font(.harcTitle)
                        Text(card.recordingTitle).font(.harcLabel)
                        Text("Knowledge project · \(card.review.project.id.uuidString.prefix(8))").font(.harcCaption)
                        Text(card.evidenceIsCurrent ? "Source excerpt" : "Original supporting excerpt").font(.harcCaption)
                        Text(card.review.quote).font(.harcBody).textSelection(.enabled)
                        if let context = card.sourceContext {
                            DisclosureGroup("Current surrounding context") {
                                Text(context).font(.harcBody).textSelection(.enabled)
                            }
                        }
                        DisclosureGroup("Why this connection?") {
                            Text("Suggested by \(card.review.generatorID). This excerpt is evidence to inspect, not proof of a relationship.")
                                .font(.harcCaption)
                        }
                        Button("Open recording") { onOpenRecording(card.review.canonicalID) }
                            .focused($focusedReview, equals: card.id)
                            .accessibilityLabel("Open recording: \(card.recordingTitle)")
                        if !card.evidenceIsCurrent {
                            Text("The source or project changed. Yes is unavailable until you review refreshed evidence.")
                                .font(.harcBody)
                            if card.review.decision == .pending || card.review.decision == .unsure {
                                Button("Refresh evidence") { Task { await model.refresh(card) } }
                            }
                        }
                        HStack(spacing: HarcSpacing.md) {
                            Button("Yes") { Task { await model.decide(card, decision: .accepted) } }
                                .disabled(!card.evidenceIsCurrent)
                                .accessibilityLabel("Yes, assign \(card.recordingTitle) to \(card.projectName)")
                            Button("No") { Task { await model.decide(card, decision: .rejected) } }
                                .accessibilityLabel("No, dismiss \(card.recordingTitle) connection to \(card.projectName)")
                            Button("Not sure") { Task { await model.decide(card, decision: .unsure) } }
                                .accessibilityLabel("Set aside \(card.recordingTitle) connection to \(card.projectName)")
                        }
                        .disabled(model.isSaving)
                    }
                    .padding(HarcSpacing.lg)
                    .overlay(RoundedRectangle(cornerRadius: HarcSpacing.md).stroke(.secondary.opacity(0.25)))
                }
                if !model.isLoading && model.cards.isEmpty && model.errorMessage == nil {
                    if model.completedBatch {
                        Text("This batch is complete. There may be more connections to review.").font(.harcBody)
                        Button("Review next 3") { Task { await model.load(deferred: model.reviewingDeferred, nextBatch: true) } }
                    } else {
                        Text("No more connections in this batch sequence. Refresh to start again.").font(.harcBody)
                    }
                }
                if model.isSaving { ProgressView("Saving…") }
                if !model.confirmations.isEmpty { Text("Recent answers").font(.harcLabel) }
                ForEach(model.confirmations) { confirmation in
                    HStack {
                        Text(confirmation.undone ? "Answer undone." : confirmation.message).font(.harcBody)
                        Spacer()
                        Button("Undo") { Task { await model.undo(confirmation) } }
                            .disabled(confirmation.undone || !confirmation.canUndo || model.isSaving)
                            .accessibilityLabel("Undo answer for \(confirmation.context)")
                    }
                }
                HStack {
                    Button("Refresh") { Task { await model.load() } }
                    Button("Review set-aside connections") { Task { await model.load(deferred: true) } }
                }.disabled(model.isSaving)
            }
            .padding(HarcSpacing.xl)
        }
        .task { await model.load() }
        .onDisappear { model.deactivate() }
        .onChange(of: model.cards.map(\.id)) { _, ids in focusedReview = ids.first }
        .onChange(of: model.errorMessage) { _, message in if message != nil { feedbackFocused = true } }
        .onChange(of: model.statusMessage) { _, message in if message != nil { feedbackFocused = true } }
    }
}
