import Foundation

/// Read-only presentation. A saved name is never evidence of confirmation.
enum SpeakerReviewPresentation {
    static func assignmentTitle(_ name: String?, speakerIndex: Int) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "Speaker \(speakerIndex + 1)" ? "Assign person…" : trimmed
    }

    static func statusText(_ isUserConfirmed: Bool?) -> String {
        switch isUserConfirmed {
        case true?: return "Confirmed"
        case false?: return "Auto-matched"
        case nil: return "Confirmation unknown"
        }
    }

    static func similarityText(_ score: Double) -> String {
        guard score.isFinite, (-1...1).contains(score) else { return "Voice similarity unavailable" }
        return "Voice similarity: \(String(format: "%.2f", score))"
    }
}
