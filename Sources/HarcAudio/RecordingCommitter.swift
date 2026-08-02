import Foundation
import HarcClient

/// Publication policy for a completed, recoverable capture.
///
/// Standalone mode moves the accepted master into the local public library.
/// Client mode can instead durably enqueue the capture without changing the
/// capture coordinator itself.
public protocol RecordingCommitter: Sendable {
    func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome
}

/// A mode-neutral acceptance result. Only standalone publication produces the
/// legacy public-file result; a future client outbox can accept responsibility
/// for the durable local master without pretending that it is canonical.
public enum RecordingCommitOutcome: Sendable {
    case standalonePublished(capture: CapturedRecording, result: RecordingResult)
    case acceptedForDeferredPublication(localMasterURL: URL)
}

/// Preserves Harc's existing standalone publication behavior behind the new
/// capture/commit boundary.
public struct StandaloneRecordingCommitter: RecordingCommitter, Sendable {
    public let destination: RecordingDestination

    public init(destination: RecordingDestination) {
        self.destination = destination
    }

    public func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
        let wavURL = try destination.publicPath(for: captured.startedAt)
        try publishMasterPreservingSourceOnFailure(
            from: captured.localMasterURL,
            to: wavURL
        )

        // Siblings describe the committed public master, never the temporary
        // capture path. Match the legacy best-effort behavior: a sibling write
        // failure is logged but does not turn an already-published WAV into a
        // failed recording.
        var txtURL: URL?
        var jsonURL: URL?
        if var transcript = captured.transcript {
            transcript.audioPath = wavURL.path
            do {
                try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)
                let stem = wavURL.deletingPathExtension().lastPathComponent
                let parent = wavURL.deletingLastPathComponent()
                txtURL = parent.appendingPathComponent("\(stem).md")
                jsonURL = parent.appendingPathComponent("\(stem).json")
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: transcript sibling write failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        let result = RecordingResult(
            wavURL: wavURL,
            txtURL: txtURL,
            jsonURL: jsonURL,
            speakerEmbeddings: captured.speakerEmbeddings,
            diarizationError: captured.diarizationError
        )
        return .standalonePublished(capture: captured, result: result)
    }

    /// Preserve the legacy publication primitive. On the normal same-volume
    /// cache-to-Documents path this is one O(1) rename: success removes the
    /// cache identity atomically, while a thrown rename leaves it recoverable.
    /// `FileManager.moveItem` also owns the platform's cross-volume behavior;
    /// adding an unjournaled two-file staging protocol here would create crash
    /// windows that the current recovery scanner cannot safely reconcile.
    private func publishMasterPreservingSourceOnFailure(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try RecordingDestination.atomicMove(from: source, to: destination)
    }
}
