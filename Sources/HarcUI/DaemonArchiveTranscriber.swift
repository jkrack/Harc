import Foundation
import HarcClient
import HarcStore

/// Adapts the STT daemon to `ArchiveTranscriber` so the archive reprocessor can
/// drive it without `HarcStore` knowing the client exists.
///
/// `modelID` is the provenance stamp written onto every recording this
/// transcribes, and it is what makes a future engine's output count as newer.
/// It must therefore change whenever the transcription result would change —
/// engine version, diarization, or vocabulary — otherwise recordings look
/// current when they are not.
public struct DaemonArchiveTranscriber: ArchiveTranscriber {
    public let modelID: String
    private let diarize: Bool
    private let vad: Bool

    public init(engineVersion: String, diarize: Bool, vad: Bool) {
        self.diarize = diarize
        self.vad = vad
        self.modelID = "parakeet-\(engineVersion)\(diarize ? "+diar" : "")\(vad ? "+vad" : "")"
    }

    public func retranscribe(wavPath: String) async throws -> String {
        let result = try await HarcSTTClient().transcribe(
            audioPath: wavPath,
            diarize: diarize,
            vad: vad
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // An empty transcript would overwrite a good one with nothing.
            // Fail the item so the run counts it and the original survives.
            throw ArchiveTranscriptionError.emptyResult(wavPath)
        }
        return text
    }
}

public enum ArchiveTranscriptionError: Error, LocalizedError {
    case emptyResult(String)

    public var errorDescription: String? {
        switch self {
        case .emptyResult(let path):
            return "Re-transcribing \(URL(fileURLWithPath: path).lastPathComponent) produced no text."
        }
    }
}

/// The resident app owns local identity and structured publication. Keep those
/// dependencies out of the transport-free archive orchestration layer.
public struct PublishingArchiveTranscriber: ArchiveTranscriber {
    public let modelID: String
    private let publish: @Sendable (Recording, RecordingStore) async throws -> Void

    public init(modelID: String, publish: @escaping @Sendable (Recording, RecordingStore) async throws -> Void) {
        self.modelID = modelID
        self.publish = publish
    }

    public func retranscribe(wavPath: String) async throws -> String {
        throw StoreError.invalidData("Structured archive processing requires a recording and publication transaction")
    }

    public func reprocess(recording: Recording, store: RecordingStore) async throws {
        try Task.checkCancellation()
        try await publish(recording, store)
    }
}
