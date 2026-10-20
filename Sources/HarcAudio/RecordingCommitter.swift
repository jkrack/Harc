import Foundation
import HarcClient
import HarcCore

/// Publication policy for a completed, recoverable capture.
///
/// Standalone mode moves the accepted master into the local public library.
/// Client mode can instead durably enqueue the capture without changing the
/// capture coordinator itself.
public protocol RecordingCommitter: Sendable {
    func prepareCapture(at source: URL) throws
    func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome
}

extension RecordingCommitter {
    public func prepareCapture(at source: URL) throws {}
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

    public func prepareCapture(at source: URL) throws {
        try destination.persistBinding(for: source)
    }

    public func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
        let destination = try destination.restoringBinding(for: captured.localMasterURL)
        let wavURL = try RecordingPublication.load(for: captured.localMasterURL)?.destination
            ?? destination.publicPath(for: captured.startedAt)
        if captured.integrity.hasIssues { try captured.integrity.save(nextTo: captured.localMasterURL) }
        let publication = try destination.preparePublication(from: captured.localMasterURL, to: wavURL)
        try publication.verifyDestinationVolume()
        _ = try CaptureIntegrityReport.carry(from: captured.localMasterURL, to: wavURL)
        try publication.publish()

        try? FileManager.default.removeItem(at: CaptureIntegrityReport.sidecarURL(for: captured.localMasterURL))

        // Siblings describe the committed public master, never the temporary
        // capture path. Match the legacy best-effort behavior: a sibling write
        // failure is logged but does not turn an already-published WAV into a
        // failed recording.
        var txtURL: URL?
        var jsonURL: URL?
        if var transcript = captured.transcript {
            transcript.audioPath = wavURL.path
            do {
                try publication.verifyDestinationVolume()
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

}
