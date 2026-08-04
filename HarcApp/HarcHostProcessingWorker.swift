import Foundation
import HarcClient
import HarcCore
import HarcDomain
import HarcHost
import HarcStore

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

            try await store.updateProcessing(
                id: recordingID,
                descriptor: try ProcessingDescriptor(state: .transcribing)
            )
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

            try await store.updateProcessing(
                id: recordingID,
                descriptor: try ProcessingDescriptor(state: .projecting)
            )
            try await store.updateProjection(
                id: recordingID,
                descriptor: try ProjectionDescriptor(state: .projecting)
            )
            try await store.applyReprocessedTranscript(
                recordingID: recordingID,
                text: result.text,
                modelID: HarcVersion.sttEngineVersion
            )
            guard let refreshed = try await store.fetch(id: recordingID),
                  OKFProjection.write(recording: refreshed) != nil else {
                throw HostProcessingWorkerError.projectionFailed
            }
            try await store.updateProjection(
                id: recordingID,
                descriptor: .readyV1
            )
            try await store.updateProcessing(
                id: recordingID,
                descriptor: .ready
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
        if recording.projection.state == .projecting, let failure {
            try? await store.updateProjection(
                id: recordingID,
                descriptor: try ProjectionDescriptor(
                    state: .failedRecoverable,
                    failure: failure
                )
            )
        }
        if let failure {
            try? await store.updateProcessing(
                id: recordingID,
                descriptor: try ProcessingDescriptor(
                    state: .failedRecoverable,
                    failure: failure
                )
            )
        }
    }
}

private enum HostProcessingWorkerError: LocalizedError {
    case canonicalBindingChanged
    case projectionFailed

    var errorDescription: String? {
        switch self {
        case .canonicalBindingChanged:
            "The canonical recording binding changed before processing."
        case .projectionFailed:
            "The OKF projection could not be written."
        }
    }
}
