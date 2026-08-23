import CryptoKit
import Darwin
import Foundation
import HarcClient
import HarcCore
import HarcDomain
import HarcHost
import HarcStore
import HarcVoiceprint

struct HarcHostWorkAdmissionSnapshot: Equatable, Sendable {
    enum ThermalPressure: Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    let thermalPressure: ThermalPressure
    let lowPowerModeEnabled: Bool
    let oneMinuteLoad: Double
    let activeProcessorCount: Int
    let harcCaptureActive: Bool

    static func current(
        harcCaptureActive: Bool = false
    ) -> HarcHostWorkAdmissionSnapshot {
        let process = ProcessInfo.processInfo
        let pressure: ThermalPressure = switch process.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        var loadAverages = [Double](repeating: 0, count: 3)
        let loaded = loadAverages.withUnsafeMutableBufferPointer {
            getloadavg($0.baseAddress, Int32($0.count))
        }
        return HarcHostWorkAdmissionSnapshot(
            thermalPressure: pressure,
            lowPowerModeEnabled: process.isLowPowerModeEnabled,
            oneMinuteLoad: loaded > 0 ? loadAverages[0] : 0,
            activeProcessorCount: max(1, process.activeProcessorCount),
            harcCaptureActive: harcCaptureActive
        )
    }
}

enum HarcHostWorkAdmissionDecision: Equatable, Sendable {
    case run
    case deferFor(TimeInterval, reason: String)
}

struct HarcHostWorkAdmissionPolicy {
    static func decide(
        _ snapshot: HarcHostWorkAdmissionSnapshot
    ) -> HarcHostWorkAdmissionDecision {
        switch snapshot.thermalPressure {
        case .serious, .critical:
            return .deferFor(60, reason: "thermal-pressure")
        case .nominal, .fair:
            break
        }
        if snapshot.lowPowerModeEnabled {
            return .deferFor(60, reason: "low-power-mode")
        }
        if snapshot.harcCaptureActive {
            return .deferFor(30, reason: "active-recording")
        }
        let normalizedLoad = snapshot.oneMinuteLoad
            / Double(max(1, snapshot.activeProcessorCount))
        if normalizedLoad >= 0.75 {
            return .deferFor(30, reason: "host-load")
        }
        return .run
    }
}

struct HarcHostProcessingRetryPolicy {
    private static let delays: [TimeInterval] = [
        5, 15, 30, 60, 300, 900, 3_600,
    ]

    nonisolated static func delay(afterFailureCount count: Int) -> TimeInterval {
        delays[min(max(1, count), delays.count) - 1]
    }
}

/// Serial daemon-backed worker for canonical recordings received by Host.
/// Its queue of record IDs is the canonical database; this actor only retains
/// validated artifact requests while the current process is alive.
actor HarcHostProcessingWorker {
    typealias AdmissionSnapshot = @Sendable () async
        -> HarcHostWorkAdmissionSnapshot

    private let store: RecordingStore
    private let launcher: DaemonLauncher
    private let diarize: Bool
    private let vad: Bool
    private let clientArtifactGrace: TimeInterval
    private let admissionSnapshot: AdmissionSnapshot

    private var pending: [CanonicalRecordingID: HostDurableProcessingRequest] = [:]
    private var eligibleAt: [CanonicalRecordingID: Date] = [:]
    private var failureCounts: [CanonicalRecordingID: Int] = [:]
    private var wakeGeneration: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var delayTask: Task<Void, Error>?

    init(
        store: RecordingStore,
        launcher: DaemonLauncher,
        diarize: Bool,
        vad: Bool,
        clientArtifactGrace: TimeInterval = 15,
        admissionSnapshot: @escaping AdmissionSnapshot = {
            HarcHostWorkAdmissionSnapshot.current()
        }
    ) {
        self.store = store
        self.launcher = launcher
        self.diarize = diarize
        self.vad = vad
        self.clientArtifactGrace = max(0, clientArtifactGrace)
        self.admissionSnapshot = admissionSnapshot
    }

    func signal(_ request: HostDurableProcessingRequest) {
        pending[request.canonicalRecordingID] = request
        if eligibleAt[request.canonicalRecordingID] == nil {
            eligibleAt[request.canonicalRecordingID] = Date()
                .addingTimeInterval(clientArtifactGrace)
        }
        wakeGeneration &+= 1
        // Wake a drain that may be waiting behind a longer admission or retry
        // deadline. New Client work must not inherit another recording's sleep.
        delayTask?.cancel()
        delayTask = nil
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    /// Cancels only in-memory execution. Every request remains reconstructible
    /// from the Host processing journal on the next launch.
    func shutdown() async {
        let task = drainTask
        delayTask?.cancel()
        delayTask = nil
        drainTask?.cancel()
        if let task { await task.value }
        drainTask = nil
        pending.removeAll()
        eligibleAt.removeAll()
        failureCounts.removeAll()
    }

    private func drain() async {
        while !Task.isCancelled {
            let observedGeneration = wakeGeneration
            let now = Date()
            let eligibleIDs = pending.keys.filter {
                (eligibleAt[$0] ?? .distantPast) <= now
            }
            if eligibleIDs.isEmpty, let next = eligibleAt.values.min() {
                let delay = max(0.05, next.timeIntervalSince(now))
                let sleeper = Task {
                    try await Task.sleep(for: .seconds(delay))
                }
                delayTask = sleeper
                do {
                    try await sleeper.value
                } catch {
                    // `signal` cancels only this delay so the actor can
                    // immediately recalculate the earliest eligible work.
                }
                delayTask = nil
                continue
            }
            let batch = eligibleIDs.compactMap { pending[$0] }.sorted {
                $0.canonicalRecordingID < $1.canonicalRecordingID
            }
            for request in batch {
                pending.removeValue(forKey: request.canonicalRecordingID)
                eligibleAt.removeValue(forKey: request.canonicalRecordingID)
            }
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

            switch HarcHostWorkAdmissionPolicy.decide(
                await admissionSnapshot()
            ) {
            case .run:
                break
            case .deferFor(let delay, let reason):
                pending[request.canonicalRecordingID] = request
                eligibleAt[request.canonicalRecordingID] = Date()
                    .addingTimeInterval(delay)
                FileHandle.standardError.write(Data(
                    "harc-host: deferred canonical processing (\(reason))\n".utf8
                ))
                return
            }

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
            failureCounts.removeValue(forKey: request.canonicalRecordingID)
        } catch {
            let remainsPending = await persistRecoverableFailure(
                canonicalRecordingID: request.canonicalRecordingID,
                underlyingError: error
            )
            guard remainsPending,
                  Self.isAutomaticallyRetryable(error) else { return }
            let count = min(
                (failureCounts[request.canonicalRecordingID] ?? 0) + 1,
                7
            )
            failureCounts[request.canonicalRecordingID] = count
            pending[request.canonicalRecordingID] = request
            eligibleAt[request.canonicalRecordingID] = Date()
                .addingTimeInterval(
                    HarcHostProcessingRetryPolicy.delay(
                        afterFailureCount: count
                    )
                )
        }
    }

    private func persistRecoverableFailure(
        canonicalRecordingID: CanonicalRecordingID,
        underlyingError: Error
    ) async -> Bool {
        FileHandle.standardError.write(Data(
            "harc-host: canonical processing failed for \(canonicalRecordingID): \(underlyingError.localizedDescription)\n".utf8
        ))
        guard let recording = try? await store.fetch(
            canonicalID: canonicalRecordingID
        ), let recordingID = recording.id else { return false }

        let failure = try? ProcessingFailure(
            code: "host.processing_retry",
            message: "Local processing did not finish and can be retried."
        )
        if let failure {
            return (try? await store.markHostProcessingFailureIfNotReady(
                recordingID: recordingID,
                failure: failure
            )) == true
        }
        return false
    }

    private nonisolated static func isAutomaticallyRetryable(
        _ error: Error
    ) -> Bool {
        if let workerError = error as? HostProcessingWorkerError {
            if case .canonicalBindingChanged = workerError { return false }
        }
        if let storeError = error as? StoreError,
           storeError == .canonicalArtifactIdentityMismatch {
            return false
        }
        return true
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
