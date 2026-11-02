import Foundation
import HarcCore
import HarcStore
import HarcExport

/// All file-backed detail data is prepared together, away from the UI actor.
/// Speaker lists reuse the export projection so overlap and legacy fallback
/// rules stay the same without decoding a sidecar during SwiftUI rendering.
struct RecordingDetailSnapshot: Sendable {
    let recording: Recording
    var wavPath: String { recording.wavPath }
    let document: TranscriptDocument
    let turnSpeakerIndices: [Int]
    let speakerIndices: [Int]
    let transcriptText: String
    let transcriptLoadError: String?

    /// Summary/title edits do not invalidate transcript data; new processing,
    /// artifact bindings or text do. This keeps a selected reprocess fresh.
    func matchesSource(recording other: Recording) -> Bool {
        recording.wavPath == other.wavPath && recording.jsonPath == other.jsonPath &&
        recording.txtPath == other.txtPath && recording.transcribedAt == other.transcribedAt &&
        recording.transcriptText == other.transcriptText && recording.processing == other.processing &&
        recording.projection == other.projection && recording.canonicalID == other.canonicalID &&
        recording.originID == other.originID && recording.canonicalPCMHash == other.canonicalPCMHash &&
        recording.canonicalPCMFrames == other.canonicalPCMFrames
    }

    static func load(
        recording: Recording,
        readDocument: @escaping @Sendable (Recording) -> TranscriptDocument = { TranscriptDocument.load(recording: $0) }
    ) async -> Self {
        let worker = Task.detached(priority: .userInitiated) {
            let document = readDocument(recording)
            let turns = ExportInputBuilder.build(
                from: recording, transcript: document.structuredTranscript
            ).segments.compactMap(\.speaker)
            let text: String
            let loadError: String?
            if let cached = recording.transcriptText, !cached.isEmpty {
                text = cached
                loadError = nil
            } else if let path = recording.txtPath {
                do {
                    let raw = try String(contentsOfFile: path, encoding: .utf8)
                    text = OKFMarkdown.extractTranscript(from: raw) ?? raw
                    loadError = nil
                } catch {
                    text = ""
                    loadError = "Could not load transcript: \(error.localizedDescription)"
                }
            } else {
                text = ""
                loadError = "No transcript file — recording may not have been transcribed."
            }
            return Self(recording: recording, document: document,
                        turnSpeakerIndices: turns, speakerIndices: Array(Set(turns)).sorted(),
                        transcriptText: text, transcriptLoadError: loadError)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// A later selection (including A -> B -> A) invalidates every earlier load.
/// File I/O may finish after cancellation; its result must not reach the editor.
@MainActor
final class RecordingDetailLoader {
    typealias Read = @Sendable (Recording) async -> RecordingDetailSnapshot
    private let read: Read
    private var requestID = UUID()

    init(read: @escaping Read = { await RecordingDetailSnapshot.load(recording: $0) }) {
        self.read = read
    }

    func cancel() { requestID = UUID() }

    func load(recording: Recording) async -> RecordingDetailSnapshot? {
        let request = UUID()
        requestID = request
        let snapshot = await read(recording)
        guard !Task.isCancelled, requestID == request else { return nil }
        return snapshot
    }
}
