import Foundation
import HarcCore

public extension TranscribingClient {
    /// For jobs that cannot be marked complete without speaker processing.
    /// The daemon's combined transcribe request is deliberately best-effort;
    /// use the explicit diarization endpoint so failures reach the job owner.
    func transcribeRequiringDiarization(
        audioPath: String, vad: Bool, diarizer: any DiarizingClient
    ) async throws -> TranscribeResult {
        var result = try await transcribe(audioPath: audioPath, diarize: false, vad: vad)
        try Task.checkCancellation()
        let speakers = try await diarizer.diarize(audioPath: audioPath)
        try Task.checkCancellation()
        result.speakers = speakers.segments
        result.speakerEmbeddings = speakers.speakers
        result.overlapRanges = speakers.overlapRanges
        return result
    }
}
