import CryptoKit
import Foundation
import HarcClient
import HarcCore
import HarcDomain
import HarcHost
import HarcStore
import HarcVoiceprint

/// Serial daemon-backed worker for canonical recordings received by Host.
/// Its queue of record IDs is the canonical database; this actor only retains
/// validated artifact requests while the current process is alive.
actor HarcHostProcessingWorker {
    private let store: RecordingStore
    private let launcher: DaemonLauncher
    private let diarize: Bool
    private let vad: Bool

    private var pending: [CanonicalRecordingID: HostDurableProcessingRequest] = [:]
    private var wakeGeneration: UInt64 = 0
    private var drainTask: Task<Void, Never>?

    init(
        store: RecordingStore,
        launcher: DaemonLauncher,
        diarize: Bool,
        vad: Bool
    ) {
        self.store = store
        self.launcher = launcher
        self.diarize = diarize
        self.vad = vad
    }

    func signal(_ request: HostDurableProcessingRequest) {
        pending[request.canonicalRecordingID] = request
        wakeGeneration &+= 1
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    private func drain() async {
        while !Task.isCancelled {
            let observedGeneration = wakeGeneration
            let batch = pending.values.sorted {
                $0.canonicalRecordingID < $1.canonicalRecordingID
            }
            pending.removeAll(keepingCapacity: true)
            for request in batch where !Task.isCancelled {
                await process(request)
            }
            if pending.isEmpty, wakeGeneration == observedGeneration { break }
        }
        drainTask = nil
        if !pending.isEmpty, !Task.isCancelled {
            drainTask = Task { await self.drain() }
        }
    }

    private func process(_ request: HostDurableProcessingRequest) async {
        do {
            guard let recording = try await store.fetch(
                canonicalID: request.canonicalRecordingID
            ), let recordingID = recording.id,
               recording.deletedAt == nil,
               recording.originID != nil,
               recording.wavPath == request.canonicalWAVURL.path,
               recording.canonicalPCMHash == request.canonicalPCMHash,
               recording.canonicalPCMFrames == request.canonicalPCMFrames
            else { throw HostProcessingWorkerError.canonicalBindingChanged }

            try request.artifactIdentity.validatePathBinding(
                at: request.canonicalWAVURL
            )
            if recording.processing.state == .ready { return }

            guard try await store.beginHostProcessingIfNotReady(
                id: recordingID
            ) else { return }
            _ = try await launcher.ensureRunning()

            // Revalidate immediately before the daemon opens the path. This is
            // the final same-UID path-swap boundary for derived processing.
            try request.artifactIdentity.validatePathBinding(
                at: request.canonicalWAVURL
            )
            let result = try await HarcSTTClient().transcribe(
                audioPath: request.canonicalWAVURL.path,
                diarize: diarize,
                vad: vad
            )

            let transcript = SessionTranscript(
                startedAt: recording.startedAt,
                endedAt: recording.endedAt ?? recording.startedAt,
                audioPath: recording.wavPath,
                joinedText: result.text,
                words: result.words,
                speakers: result.speakers,
                chunks: []
            )
            let renderedText = TranscriptPlainTextRenderer.render(transcript)

            guard try await store.stageHostProcessedTranscriptIfNotReady(
                recordingID: recordingID,
                text: renderedText,
                modelID: HarcVersion.sttEngineVersion
            ) else { return }

            if !result.speakerEmbeddings.isEmpty {
                let rows = result.speakerEmbeddings.map {
                    RecordingStore.SpeakerEmbeddingRow(
                        recordingID: recordingID,
                        speakerIndex: $0.speakerIndex,
                        embedding: EmbeddingBlob.encode($0.vector),
                        segmentCount: $0.segmentCount,
                        totalMs: $0.totalMs,
                        embedderKind: EmbedderKind.wespeakerV2
                    )
                }
                try await store.upsertSpeakerEmbeddings(
                    recordingID: recordingID,
                    rows: rows
                )
            }
            if let sourceDeviceID = recording.originID?.deviceID {
                for embedding in result.speakerEmbeddings {
                    guard embedding.speakerIndex >= 0,
                          embedding.totalMs > 0,
                          embedding.segmentCount > 0 else { continue }
                    let observation = try SpeakerEmbeddingObservation(
                        operationID: Self.observationOperationID(
                            canonicalID: request.canonicalRecordingID,
                            speakerIndex: embedding.speakerIndex
                        ),
                        canonicalRecordingID: request.canonicalRecordingID,
                        speakerIndex: UInt32(embedding.speakerIndex),
                        embedding: try .quantizing(embedding.vector),
                        modelID: EmbedderKind.wespeakerV2,
                        speechDurationMs: UInt64(embedding.totalMs),
                        segmentCount: UInt32(embedding.segmentCount)
                    )
                    _ = try await store.submitSpeakerObservation(
                        observation,
                        from: sourceDeviceID
                    )
                }
            }
            _ = try await store.publishHostProcessedProjectionIfNotReady(
                recordingID: recordingID
            )
        } catch {
            await persistRecoverableFailure(
                canonicalRecordingID: request.canonicalRecordingID,
                underlyingError: error
            )
        }
    }

    private func persistRecoverableFailure(
        canonicalRecordingID: CanonicalRecordingID,
        underlyingError: Error
    ) async {
        FileHandle.standardError.write(Data(
            "harc-host: canonical processing failed for \(canonicalRecordingID): \(underlyingError.localizedDescription)\n".utf8
        ))
        guard let recording = try? await store.fetch(
            canonicalID: canonicalRecordingID
        ), let recordingID = recording.id else { return }

        let failure = try? ProcessingFailure(
            code: "host.processing_retry",
            message: "Local processing did not finish and can be retried."
        )
        if let failure {
            _ = try? await store.markHostProcessingFailureIfNotReady(
                recordingID: recordingID,
                failure: failure
            )
        }
    }

    private static func observationOperationID(
        canonicalID: CanonicalRecordingID,
        speakerIndex: Int
    ) -> OperationID {
        let material = Data(
            "host-speaker-observation-v1:\(canonicalID.description):\(speakerIndex)".utf8
        )
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return OperationID(uuid)
    }
}

private enum HostProcessingWorkerError: LocalizedError {
    case canonicalBindingChanged

    var errorDescription: String? {
        switch self {
        case .canonicalBindingChanged:
            "The canonical recording binding changed before processing."
        }
    }
}
