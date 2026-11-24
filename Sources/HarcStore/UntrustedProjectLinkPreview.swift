import Foundation

/// Inert review context, NOT a verified relationship or extracted factual claim.
/// No Codable/persistence, actions, titles, timestamps or assignment capability.
public struct UntrustedProjectLinkPreview: Sendable {
    public let fullSourceText: String
    public let projectName: String
    public let projectBrief: String
    public let quote: String
    public let startUTF8: Int
    public let endUTF8: Int
    /// Supplied by the caller; explicitly NOT authenticated generation provenance.
    public let unverifiedModelLabel: String
    public var requiresHumanReview: Bool { true }
    fileprivate init(snapshot: ProjectEvidenceSnapshot, evidence: VerifiedProjectEvidence, modelLabel: String) {
        fullSourceText = snapshot.transcript
        projectName = snapshot.project.name
        projectBrief = snapshot.project.brief ?? ""
        quote = evidence.quote
        startUTF8 = evidence.startUTF8
        endUTF8 = evidence.endUTF8
        unverifiedModelLabel = modelLabel
    }
}

public enum ProjectPreviewError: Error, Equatable { case invalidated }
public enum ProjectPreviewOutcome: Sendable { case suggestionReady, abstained }
public struct ProjectPreviewTicket: Equatable, Sendable {
    fileprivate let id: UUID
}

/// Memory-only holder for a future selected-source review controller. Has no
/// RecordingStore reference, write API, model call, logger or background task.
/// Callers must invalidate on selection/Host changes and drop their own copies
/// on dismissal. This releases our references, not secure erasure of Strings.
/// No production/UI caller exists in this slice.
public actor UntrustedProjectPreviewSession {
    private struct Active {
        let ticket: ProjectPreviewTicket
        let snapshot: ProjectEvidenceSnapshot
        var preview: UntrustedProjectLinkPreview?
        var completed = false
    }
    private var active: Active?
    public init() { }

    public func begin(snapshot: ProjectEvidenceSnapshot) -> ProjectPreviewTicket {
        let ticket = ProjectPreviewTicket(id: UUID())
        active = Active(ticket: ticket, snapshot: snapshot)
        return ticket
    }

    /// Late or duplicate responses cannot replace a newer review. Invalid output
    /// ends this request and retains no raw response or rendered preview.
    public func finish(rawResponse: String, unverifiedModelLabel: String,
                       ticket: ProjectPreviewTicket) throws -> ProjectPreviewOutcome {
        guard var current = active, current.ticket == ticket, !current.completed else {
            throw ProjectPreviewError.invalidated
        }
        do {
            let result = try RecordingStore.validateProjectEvidenceResponse(rawResponse,
                snapshot: current.snapshot, modelID: unverifiedModelLabel)
            switch result {
            case .abstain:
                active = nil
                return .abstained
            case .candidate(let evidence):
                current.preview = UntrustedProjectLinkPreview(snapshot: current.snapshot,
                    evidence: evidence, modelLabel: unverifiedModelLabel)
                current.completed = true
                active = current
                return .suggestionReady
            }
        } catch {
            active = nil
            throw error
        }
    }

    /// The controller supplies the key for its CURRENT selection, preferably
    /// from a fresh Store snapshot. This comparison is not live DB validation.
    public func preview(for currentSelection: ProjectPreviewSelectionKey) -> UntrustedProjectLinkPreview? {
        guard let current = active else { return nil }
        guard current.snapshot.previewSelectionKey == currentSelection else {
            active = nil
            return nil
        }
        return current.preview
    }

    public func invalidate() { active = nil }
    public func dismiss() { active = nil }
}
