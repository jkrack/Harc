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

/// Queue entries are bindings to refresh, not authority to reuse a stale ctime.
enum HarcHostProcessingRequestValidation {
    typealias Refresh = @Sendable (CanonicalRecordingID) async throws -> HostDurableProcessingRequest

    static func refresh(_ queued: HostDurableProcessingRequest, using validator: Refresh) async throws -> HostDurableProcessingRequest {
        for attempt in 0 ..< 2 {
            let fresh: HostDurableProcessingRequest
            do {
                fresh = try await validator(queued.canonicalRecordingID)
            } catch let error as HostCanonicalResourceDeferred {
                throw error
            } catch let error as StoreError where error == .canonicalArtifactIdentityMismatch {
                // A descriptor/path race during full evidence validation must
                // restart that validation, never reuse partially checked bytes.
                // Stable-field and content failures use HarcHostError instead.
                guard attempt == 0 else { throw error }
                continue
            } catch {
                throw HostProcessingWorkerError.canonicalRevalidationFailed
            }
            try requireSameBinding(queued, fresh)
            do {
                try fresh.artifactIdentity.validatePathBinding(at: fresh.canonicalWAVURL)
                return fresh
            } catch {
                guard attempt == 0 else { throw error }
            }
        }
        throw HostProcessingWorkerError.canonicalBindingChanged
    }

    static func requireSameBinding(_ queued: HostDurableProcessingRequest, _ fresh: HostDurableProcessingRequest) throws {
        let old = queued.artifactIdentity
        let new = fresh.artifactIdentity
        guard queued.canonicalRecordingID == fresh.canonicalRecordingID,
              queued.canonicalWAVURL == fresh.canonicalWAVURL,
              queued.canonicalPCMHash == fresh.canonicalPCMHash,
              queued.canonicalPCMFrames == fresh.canonicalPCMFrames,
              old.deviceNumber == new.deviceNumber,
              old.inodeNumber == new.inodeNumber,
              old.ownerUserID == new.ownerUserID,
              old.posixMode == new.posixMode,
              old.linkCount == new.linkCount,
              old.fileByteCount == new.fileByteCount else {
            throw HostProcessingWorkerError.canonicalBindingChanged
        }
    }
}

/// Serial daemon-backed worker for canonical recordings received by Host.
/// Its queue of record IDs is the canonical database; this actor only retains
/// validated artifact requests while the current process is alive.
actor HarcHostProcessingWorker {
    typealias AdmissionSnapshot = @Sendable () async
        -> HarcHostWorkAdmissionSnapshot

    private let store: RecordingStore
    // Internal dependency seam keeps tests off the real daemon and model.
    struct Transcription: Sendable {
        let prepare: @Sendable () async throws -> String
        let run: @Sendable (String, String, Bool, Bool) async throws -> TranscribeResult
    }
    private let transcription: Transcription
    private let producerDeviceID: DeviceID
    private let diarize: Bool
    private let vad: Bool
    private let clientArtifactGrace: TimeInterval
    typealias ResourceAdmission = @Sendable (HostDurableProcessingRequest) async throws -> Void
    private let admissionSnapshot: AdmissionSnapshot
    private let resourceAdmission: ResourceAdmission
    private let resourceDeferralDelay: TimeInterval
    private var recoveryRequests: Set<CanonicalRecordingID> = []

    private var requestValidator: HarcHostProcessingRequestValidation.Refresh?
    private var metadataRetryCounts: [CanonicalRecordingID: Int] = [:]

    private var pending: [CanonicalRecordingID: HostDurableProcessingRequest] = [:]
    private var eligibleAt: [CanonicalRecordingID: Date] = [:]
    private var failureCounts: [CanonicalRecordingID: Int] = [:]
    private var wakeGeneration: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var delayTask: Task<Void, Error>?

    init(
        store: RecordingStore,
        launcher: DaemonLauncher,
        producerDeviceID: DeviceID,
        diarize: Bool,
        vad: Bool,
        clientArtifactGrace: TimeInterval = 15,
        transcription: Transcription? = nil,
        resourceAdmission: @escaping ResourceAdmission = { request in
            try HostCanonicalResourceAdmission.requireResidentAudio(
                at: request.canonicalWAVURL, expectedByteCount: request.artifactIdentity.fileByteCount)
        },
        resourceDeferralDelay: TimeInterval = 60,
        admissionSnapshot: @escaping AdmissionSnapshot = {
            HarcHostWorkAdmissionSnapshot.current()
        }
    ) {
        self.store = store
        self.transcription = transcription ?? Transcription(
            prepare: { try await launcher.ensureRunning() },
            run: { socketPath, audioPath, diarize, vad in
                let client = HarcSTTClient(socketPath: socketPath)
                if diarize {
                    return try await client.transcribeRequiringDiarization(
                        audioPath: audioPath, vad: vad, diarizer: client)
                }
                return try await client.transcribe(audioPath: audioPath, diarize: false, vad: vad)
            }
        )
        self.producerDeviceID = producerDeviceID
        self.diarize = diarize
        self.vad = vad
        self.clientArtifactGrace = max(0, clientArtifactGrace)
        self.admissionSnapshot = admissionSnapshot
        self.resourceAdmission = resourceAdmission
        self.resourceDeferralDelay = max(0.05, resourceDeferralDelay)
    }

    func installRequestValidator(_ validator: @escaping HarcHostProcessingRequestValidation.Refresh) {
        requestValidator = validator
        guard drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { await self.drain() }
    }

    func signal(_ request: HostDurableProcessingRequest, isRecovery: Bool = false) {
        if isRecovery {
            if pending[request.canonicalRecordingID] == nil { recoveryRequests.insert(request.canonicalRecordingID) }
        } else {
            recoveryRequests.remove(request.canonicalRecordingID)
        }
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
        guard requestValidator != nil, drainTask == nil else { return }
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
        metadataRetryCounts.removeAll()
        recoveryRequests.removeAll()
        requestValidator = nil
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
            // Reconsider live signals between recordings, rather than retaining
            // a startup-sized batch across every expensive validation/transcription.
            let nextID = eligibleIDs.sorted {
                let leftRecovery = recoveryRequests.contains($0)
                let rightRecovery = recoveryRequests.contains($1)
                if leftRecovery != rightRecovery { return !leftRecovery }
                let leftDate = eligibleAt[$0] ?? .distantPast
                let rightDate = eligibleAt[$1] ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return $0 < $1
            }.first
            if let nextID, let request = pending.removeValue(forKey: nextID) {
                eligibleAt.removeValue(forKey: nextID)
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

            guard let requestValidator else {
                pending[request.canonicalRecordingID] = request
                return
            }
            // Admission is a resource gate only, never evidence of audio integrity.
            try await resourceAdmission(request)
            let socketPath = try await transcription.prepare()

            // Grace/admission and daemon startup can outlive metadata updates.
            // Refresh through signed receipt + exact WAV validation, never merely stat.
            let request = try await HarcHostProcessingRequestValidation.refresh(request, using: requestValidator)
            try Task.checkCancellation()
            guard try await store.beginHostProcessingIfNotReady(id: recordingID) else { return }
            try Task.checkCancellation()
            // No suspension between this strict check and the daemon request.
            try request.artifactIdentity.validatePathBinding(
                at: request.canonicalWAVURL
            )
            let result = try await transcription.run(
                socketPath, request.canonicalWAVURL.path, diarize, vad)

            try request.artifactIdentity.validatePathBinding(at: request.canonicalWAVURL)
            try Task.checkCancellation()
            let transcript = SessionTranscript(
                startedAt: recording.startedAt,
                endedAt: recording.endedAt ?? recording.startedAt,
                audioPath: recording.wavPath,
                result: result
            )
            let renderedText = TranscriptPlainTextRenderer.render(transcript)
            let transcriptEncoder = JSONEncoder()
            transcriptEncoder.dateEncodingStrategy = .secondsSince1970
            transcriptEncoder.outputFormatting = [.sortedKeys]
            let structuredTranscriptData = try transcriptEncoder.encode(transcript)

            guard try await store.stageHostProcessedTranscriptIfNotReady(
                recordingID: recordingID,
                text: renderedText,
                modelID: HarcVersion.sttEngineVersion,
                structuredTranscriptData: structuredTranscriptData
            ) else { return }

            // Bind every retained voice to the exact Host-produced JSON bytes,
            // canonical audio and this Host's public producer identity. Retention
            // alone grants neither enrollment nor a current review assignment.
            var publishedSpeakerEvidence: [Int: Data] = [:]
            for evidence in try Self.speakerEvidenceSnapshots(result,
                canonicalID: request.canonicalRecordingID, canonicalPCMHash: request.canonicalPCMHash,
                producerDeviceID: producerDeviceID, structuredTranscriptData: structuredTranscriptData) {
                let digest = try await store.retainSpeakerEvidence(evidence)
                guard let index = Int(evidence.localClusterID.dropFirst("host-speaker-".count)),
                      publishedSpeakerEvidence.updateValue(digest, forKey: index) == nil else {
                    throw DomainValidationError.invalidState(reason: "Duplicate Host speaker evidence")
                }
            }

            guard try await store.stageHostSpeakerEvidenceIfNotReady(recordingID: recordingID,
                expectedArtifactSHA256: Data(SHA256.hash(data: structuredTranscriptData)),
                speakerEvidence: publishedSpeakerEvidence) else { return }

            if !result.speakerEmbeddings.isEmpty {
                let rows = result.speakerEmbeddings.map {
                    RecordingStore.SpeakerEmbeddingRow(
                        recordingID: recordingID,
                        speakerIndex: $0.speakerIndex,
                        embedding: EmbeddingBlob.encode($0.vector),
                        segmentCount: $0.segmentCount,
                        totalMs: $0.totalMs,
                        embedderKind: $0.modelID
                    )
                }
                try await store.upsertSpeakerEmbeddings(
                    recordingID: recordingID,
                    rows: rows
                )
            }
            var speakerDecisions: [Int: SpeakerObservationDecision] = [:]
            if let sourceDeviceID = recording.originID?.deviceID {
                let recognitionRevision = try await store.publishedSpeakerRecognitionPack().revision
                for embedding in result.speakerEmbeddings {
                    guard embedding.speakerIndex >= 0,
                          embedding.totalMs > 0,
                          embedding.segmentCount > 0 else { continue }
                    guard let evidenceSHA256 = publishedSpeakerEvidence[embedding.speakerIndex] else {
                        throw DomainValidationError.invalidState(reason: "Host speaker evidence is missing")
                    }
                    let observation = try Self.speakerObservation(
                        embedding, canonicalID: request.canonicalRecordingID,
                        evidenceSHA256: evidenceSHA256, packRevision: recognitionRevision
                    )
                    let decision = try await store.submitSpeakerObservation(
                        observation,
                        from: sourceDeviceID, expectedEvidenceSHA256: evidenceSHA256
                    )
                    speakerDecisions[embedding.speakerIndex] = decision
                }
            }
            let clusters = try Set(result.speakers.map(\.speaker)).map { index in
                guard let boundedIndex = UInt32(exactly: index) else {
                    throw DomainValidationError.invalidState(reason: "Host transcript has an invalid speaker index")
                }
                return try HostSpeakerProcessingOutcome.Cluster(speakerIndex: boundedIndex,
                    evidenceSHA256: publishedSpeakerEvidence[index], decisionOperationID: speakerDecisions[index]?.operationID,
                    disposition: speakerDecisions[index]?.disposition,
                    recognitionPackRevision: speakerDecisions[index]?.recognitionPackRevision)
            }
            let speakerOutcome = try HostSpeakerProcessingOutcome(
                canonicalRecordingID: request.canonicalRecordingID, canonicalPCMHash: request.canonicalPCMHash,
                producerDeviceID: producerDeviceID,
                processingArtifactSHA256: Data(SHA256.hash(data: structuredTranscriptData)),
                diarization: diarize ? .completed : .disabled, clusters: clusters)
            try request.artifactIdentity.validatePathBinding(at: request.canonicalWAVURL)
            try Task.checkCancellation()
            _ = try await store.publishHostProcessedProjectionIfNotReady(
                recordingID: recordingID, speakerEvidence: publishedSpeakerEvidence,
                speakerOutcome: speakerOutcome, structuredTranscriptData: structuredTranscriptData
            )
            failureCounts.removeValue(forKey: request.canonicalRecordingID)
            metadataRetryCounts.removeValue(forKey: request.canonicalRecordingID)
            recoveryRequests.remove(request.canonicalRecordingID)
        } catch is HostCanonicalResourceDeferred {
            // Deferral neither marks an integrity failure nor spends retry budget.
            // Every future attempt starts with admission and complete validation.
            guard !Task.isCancelled else { return }
            pending[request.canonicalRecordingID] = request
            eligibleAt[request.canonicalRecordingID] = Date().addingTimeInterval(resourceDeferralDelay)
        } catch {
            let remainsPending = await persistRecoverableFailure(
                canonicalRecordingID: request.canonicalRecordingID,
                underlyingError: error
            )
            guard remainsPending, !Task.isCancelled else { return }
            if let storeError = error as? StoreError,
               storeError == .canonicalArtifactIdentityMismatch,
               (metadataRetryCounts[request.canonicalRecordingID] ?? 0) < 2 {
                // Discard this result and requeue only the expected binding. The
                // next pass must obtain resource admission before full validation;
                // never hash eagerly in the failure path or reuse derived results.
                metadataRetryCounts[request.canonicalRecordingID, default: 0] += 1
                pending[request.canonicalRecordingID] = request
                eligibleAt[request.canonicalRecordingID] = Date().addingTimeInterval(5)
                return
            }
            guard Self.isAutomaticallyRetryable(error) else { return }
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
            switch workerError {
            case .canonicalBindingChanged, .canonicalRevalidationFailed: return false
            }
        }
        if let storeError = error as? StoreError,
           storeError == .canonicalArtifactIdentityMismatch {
            return false
        }
        return true
    }

    nonisolated static func speakerEvidenceSnapshots(
        _ result: TranscribeResult, canonicalID: CanonicalRecordingID,
        canonicalPCMHash: CanonicalPCMHash, producerDeviceID: DeviceID,
        structuredTranscriptData: Data
    ) throws -> [SpeakerEvidenceSnapshot] {
        let indices = Set(result.speakers.map(\.speaker))
        let artifactDigest = Data(SHA256.hash(data: structuredTranscriptData))
        return try result.speakerEmbeddings.map { embedding in
            guard embedding.speakerIndex >= 0, indices.contains(embedding.speakerIndex),
                  let duration = UInt64(exactly: embedding.totalMs),
                  let count = UInt32(exactly: embedding.segmentCount) else {
                throw DomainValidationError.invalidState(reason: "Host voice evidence has no matching transcript cluster")
            }
            return try SpeakerEvidenceSnapshot(canonicalRecordingID: canonicalID,
                canonicalPCMHash: canonicalPCMHash, producerDeviceID: producerDeviceID,
                processingArtifactSHA256: artifactDigest,
                localClusterID: "host-speaker-\(embedding.speakerIndex)",
                embedding: .quantizing(embedding.vector), modelID: embedding.modelID,
                speechDurationMs: duration, segmentCount: count)
        }
    }

    nonisolated static func speakerObservation(
        _ embedding: HarcCore.SpeakerEmbeddingRow,
        canonicalID: CanonicalRecordingID,
        evidenceSHA256: Data? = nil,
        packRevision: EntityRevision? = nil
    ) throws -> SpeakerEmbeddingObservation {
        guard let index = UInt32(exactly: embedding.speakerIndex),
              let duration = UInt64(exactly: embedding.totalMs), duration > 0,
              let count = UInt32(exactly: embedding.segmentCount), count > 0 else {
            throw DomainValidationError.invalidState(reason: "A speaker observation requires bounded positive speech evidence")
        }
        let generation: Data?
        if let evidenceSHA256, let packRevision {
            guard evidenceSHA256.count == 32 else {
                throw DomainValidationError.invalidState(reason: "Host speaker evidence digest is invalid")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var material = Data("host-speaker-generation-v3".utf8)
            material.append(evidenceSHA256)
            var revision = packRevision.rawValue.bigEndian
            withUnsafeBytes(of: &revision) { material.append(contentsOf: $0) }
            material.append(try encoder.encode(embedding))
            generation = Data(SHA256.hash(data: material))
        } else {
            guard evidenceSHA256 == nil, packRevision == nil else {
                throw DomainValidationError.invalidState(reason: "Host speaker generation binding is incomplete")
            }
            generation = nil
        }
        return try SpeakerEmbeddingObservation(
            operationID: observationOperationID(canonicalID: canonicalID,
                speakerIndex: embedding.speakerIndex, modelID: embedding.modelID, generation: generation),
            canonicalRecordingID: canonicalID, speakerIndex: index,
            embedding: .quantizing(embedding.vector), modelID: embedding.modelID,
            speechDurationMs: duration, segmentCount: count, sourcePackRevision: packRevision)
    }

    nonisolated static func observationOperationID(
        canonicalID: CanonicalRecordingID,
        speakerIndex: Int,
        modelID: String,
        generation: Data? = nil
    ) -> OperationID {
        var material = Data(
            "host-speaker-observation-v1:\(canonicalID.description):\(speakerIndex)".utf8
        )
        // Retain existing WeSpeaker replay IDs. A different model must receive
        // its own decision rather than replaying another embedding space.
        if modelID != HarcCore.SpeakerEmbeddingRow.legacyModelID {
            material.append(Data("\0speaker-model\0".utf8))
            material.append(Data(modelID.utf8))
        }
        if let generation {
            material.append(Data("\0generation\0".utf8))
            material.append(generation)
        }
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
    case canonicalRevalidationFailed

    var errorDescription: String? {
        switch self {
        case .canonicalBindingChanged:
            "The canonical recording binding changed before processing."
        case .canonicalRevalidationFailed:
            "The canonical recording could not be cryptographically revalidated."
        }
    }
}
