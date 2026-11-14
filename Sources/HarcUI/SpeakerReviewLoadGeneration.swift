import Foundation
import HarcStore

/// Coordinates inspector reads without granting or refreshing mutation authority.
/// Store-bound reviews still validate the exact evidence at mutation time.
struct SpeakerReviewLoadGeneration {
    private var latest: UUID?

    mutating func begin(recording: Recording, selectedRecording: Recording?,
                        isCancelled: Bool) -> UUID? {
        // A post-mutation callback may still carry the old row. It must not
        // invalidate an admissible refresh already loading the new row.
        guard !isCancelled, selectedRecording == recording else { return nil }
        let generation = UUID()
        latest = generation
        return generation
    }

    func isCurrent(_ generation: UUID, recording: Recording,
                   selectedRecording: Recording?, isCancelled: Bool) -> Bool {
        !isCancelled && latest == generation && selectedRecording == recording
    }
}
