import Foundation
import SwiftUI
import HarcStore

/// Presentation for an explicitly authorized local canonical Store. The app
/// must not construct this for a secondary-client mirror; no RPC exists yet.
@MainActor
public final class ProjectRefinementViewModel: ObservableObject {
    @Published public private(set) var cards: [ProjectReviewCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var confirmations: [Confirmation] = []
    @Published public private(set) var reviewingDeferred = false

    public struct Confirmation: Identifiable {
        public var id: UUID { receipt.operationID }
        public let receipt: ProjectReviewReceipt
        public let message: String
        public var undone = false
        public var canUndo = true
        public var context = ""
    }

    private struct Intent {
        let version: UUID
        let decision: ProjectReviewDecision
        let operationID: UUID
    }
    private let store: RecordingStore
    private var intents: [UUID: Intent] = [:]
    private var generation = UUID()
    private var active = true
    private let onCommitted: () -> Void
    private let beforeApply: @MainActor () async -> Void
    private var reloadAfterSave = false
    var reloadTask: Task<Void, Never>?

    public init(store: RecordingStore, onCommitted: @escaping () -> Void = {}, beforeApply: @escaping @MainActor () async -> Void = {}) {
        self.store = store
        self.onCommitted = onCommitted
        self.beforeApply = beforeApply
    }

    public func deactivate() {
        active = false
        reloadTask?.cancel()
        reloadTask = nil
        generation = UUID()
        isLoading = false
    }

    public func load(deferred: Bool = false) async {
        active = true
        reviewingDeferred = deferred
        guard !isSaving else { reloadAfterSave = true; return }
        let token = UUID()
        generation = token
        reviewingDeferred = deferred
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        do {
            let loaded = try await store.pendingProjectReviewCards(deferred: deferred)
            let history = try await store.recentProjectReviewHistory()
            guard active, generation == token else { return }
            cards = loaded
            confirmations = history.map { item in
                Confirmation(receipt: item.receipt, message: Self.confirmationMessage(item.receipt, projectName: item.projectName),
                    undone: item.undone, canUndo: item.canUndo, context: "\(item.recordingTitle), \(item.projectName)")
            }
            isLoading = false
        } catch {
            guard active, generation == token else { return }
            isLoading = false
            errorMessage = "Connections could not be loaded. Try again."
        }
    }

    public func decide(_ card: ProjectReviewCard, decision: ProjectReviewDecision) async {
        guard active, !isLoading, !isSaving, cards.contains(where: { $0.id == card.id }),
              decision != .pending, decision != .accepted || card.evidenceIsCurrent else { return }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        let token = generation
        let intent: Intent
        if let previous = intents[card.id], previous.version == card.review.version, previous.decision == decision {
            intent = previous
        } else {
            intent = Intent(version: card.review.version, decision: decision, operationID: UUID())
            intents[card.id] = intent
        }
        defer { finishSaving() }
        do {
            await beforeApply()
            let result = try await store.applyProjectMatchDecision(id: card.id, expectedVersion: intent.version,
                decision: decision, operationID: intent.operationID)
            // Retain undo even if this panel disappeared while commit completed.
            if !confirmations.contains(where: { $0.id == result.receipt.operationID }) {
                let message: String
                if !result.didApply { message = "This answer was already processed. No new changes." }
                else if decision == .accepted {
                    message = result.receipt.newlyLinkedRecordings == 1
                        ? "Added 1 recording to \(card.projectName)." : "Already assigned to \(card.projectName)."
                } else { message = decision == .rejected ? "Connection dismissed." : "Connection set aside." }
                confirmations.insert(Confirmation(receipt: result.receipt, message: message,
                    context: "\(card.recordingTitle), \(card.projectName)"), at: 0)
            }
            guard active, generation == token else { return }
            cards.removeAll { $0.id == card.id }
            statusMessage = result.didApply
                ? Self.confirmationMessage(result.receipt, projectName: card.projectName)
                : "This answer was already processed. No new changes."
            if result.didApply { onCommitted() }
        } catch {
            guard active, generation == token else { return }
            errorMessage = Self.message(for: error)
        }
    }

    public func refresh(_ card: ProjectReviewCard) async {
        guard active, !isSaving else { return }
        isSaving = true
        let token = generation
        errorMessage = nil
        defer { finishSaving() }
        do {
            try await store.refreshPendingProjectReview(id: card.id, expectedVersion: card.review.version)
            guard active, generation == token else { return }
            isSaving = false
            await load(deferred: false)
        } catch {
            isSaving = false
            guard active, generation == token else { return }
            errorMessage = "The original evidence cannot be refreshed. Open the recording, dismiss this connection or set it aside."
        }
    }

    public func undo(_ confirmation: Confirmation) async {
        guard active, !isSaving, !confirmation.undone, confirmation.canUndo else { return }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        let token = generation
        defer { finishSaving() }
        do {
            _ = try await store.undoProjectMatch(operationID: confirmation.id)
            if let index = confirmations.firstIndex(where: { $0.id == confirmation.id }) { confirmations[index].undone = true }
            guard active, generation == token else { return }
            let refreshed = try await store.pendingProjectReviewCards(deferred: reviewingDeferred)
            guard active, generation == token else { return }
            cards = refreshed
            statusMessage = "Answer undone."
        } catch {
            guard active, generation == token else { return }
            errorMessage = Self.message(for: error)
        }
    }

    private func finishSaving() {
        isSaving = false
        if active && reloadAfterSave {
            reloadAfterSave = false
            let deferred = reviewingDeferred
            let token = generation
            reloadTask = Task {
                guard active, generation == token, !Task.isCancelled else { return }
                await load(deferred: deferred)
            }
        }
    }

    private static func confirmationMessage(_ receipt: ProjectReviewReceipt, projectName: String) -> String {
        switch receipt.decision {
        case .accepted: return receipt.newlyLinkedRecordings == 1 ? "Added 1 recording to \(projectName)." : "Already assigned to \(projectName)."
        case .rejected: return "Connection dismissed."
        case .unsure: return "Connection set aside."
        case .pending: return "Connection awaiting review."
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ProjectRefinementError.conflict:
            return "This connection changed since your answer. Refresh to see the current state."
        case ProjectRefinementError.staleEvidence:
            return "The source changed. Review fresh evidence before saying Yes."
        case ProjectRefinementError.missing:
            return "This recording or project is no longer available. Refresh the list."
        default:
            return "Your answer could not be saved. Try again; no success has been assumed."
        }
    }
}
