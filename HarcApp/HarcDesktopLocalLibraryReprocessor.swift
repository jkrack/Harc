import CryptoKit
import Darwin
import Foundation
import HarcAudio
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
import HarcStore
import HarcTransfer

enum HarcDesktopLocalLibraryQueueResult: Equatable {
    case queued
    case alreadyQueued
}

enum HarcDesktopLocalLibraryReprocessPlanner {
    private static let originNamespace = Data(
        "harc.desktop-client.local-library-reprocess.v1".utf8
    )

    /// One local canonical row always maps to one Client origin on this
    /// installation. This makes retries and repeated button presses harmless.
    static func originRecordingID(
        sourceCanonicalID: CanonicalRecordingID,
        deviceID: DeviceID
    ) -> OriginRecordingID {
        var input = originNamespace
        input.append(deviceID.rawBytes)
        var sourceUUID = sourceCanonicalID.rawValue.uuid
        withUnsafeBytes(of: &sourceUUID) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return OriginRecordingID(deviceID: deviceID, recordingUUID: uuid)
    }

    static func loadStructuredTranscript(for recording: Recording) -> SessionTranscript? {
        guard let path = recording.jsonPath,
              FileManager.default.fileExists(atPath: path),
              let data = try? Data(
                contentsOf: URL(fileURLWithPath: path),
                options: .mappedIfSafe
              ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionTranscript.self, from: data)
    }

    static func currentModelID(diarize: Bool, vad: Bool) -> String {
        "parakeet-\(HarcVersion.sttEngineVersion)\(diarize ? "+diar" : "")\(vad ? "+vad" : "")"
    }

    static func shouldTranscribe(
        recording: Recording,
        structuredTranscript: SessionTranscript?,
        currentModelID: String
    ) -> Bool {
        structuredTranscript?.processingCoverage == nil
            || recording.sttModelID != currentModelID
    }
}

extension HarcDesktopClientRuntime {
    /// Fast repeat-action check so a recording already represented by the
    /// durable outbox does not spend time running local inference again.
    func localLibraryRecordingIsQueued(_ recording: Recording) throws -> Bool {
        let origin = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: recording.canonicalID,
            deviceID: identity.deviceID
        )
        guard let existing = try transferStore.recordingOutbox(for: origin) else {
            return false
        }
        guard existing.finalizedCapture.capture.producingDeviceID
                == identity.deviceID else {
            throw HarcDesktopLocalLibraryReprocessError.identityMismatch
        }
        return true
    }

    /// Copy an existing On This Mac master into ClientState and atomically
    /// establish its durable outbox. The source library file is never moved or
    /// deleted; verified Host cleanup can affect only this private staging copy.
    func enqueueLocalLibraryRecording(
        _ recording: Recording,
        transcript sourceTranscript: SessionTranscript,
        speakerEmbeddings: [SpeakerEmbeddingRow]
    ) async throws -> HarcDesktopLocalLibraryQueueResult {
        let result = try await HarcDesktopLocalLibraryStager.enqueue(
            recording,
            transcript: sourceTranscript,
            speakerEmbeddings: speakerEmbeddings,
            deviceID: identity.deviceID,
            transferStore: transferStore,
            root: root
        )
        refreshStatus()
        return result
    }
}

enum HarcDesktopLocalLibraryStager {
    /// The filesystem and database half of Reprocess, split from the runtime so
    /// crash recovery, source preservation, and idempotence are testable with a
    /// temporary ClientState root.
    static func enqueue(
        _ recording: Recording,
        transcript sourceTranscript: SessionTranscript,
        speakerEmbeddings: [SpeakerEmbeddingRow],
        deviceID: DeviceID,
        transferStore: HarcTransferStore,
        root: URL
    ) async throws -> HarcDesktopLocalLibraryQueueResult {
        let origin = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: recording.canonicalID,
            deviceID: deviceID
        )
        if let existing = try transferStore.recordingOutbox(for: origin) {
            guard existing.finalizedCapture.capture.producingDeviceID
                    == deviceID else {
                throw HarcDesktopLocalLibraryReprocessError.identityMismatch
            }
            return .alreadyQueued
        }

        let directory = root.appendingPathComponent("Captures", isDirectory: true)
        try HarcDesktopClientFiles.requireDirectory(directory)
        let stem = origin.recordingUUID.uuidString.lowercased()
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        let sidecarURL = directory.appendingPathComponent("\(stem).capture.json")

        let prepared: HarcDesktopClientFiles.PreparedWAV
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let source = try HarcDesktopClientFiles.inspectCanonicalWAV(
                URL(fileURLWithPath: recording.wavPath)
            )
            let staged = try HarcDesktopClientFiles.inspectCanonicalWAV(finalURL)
            guard source.frames == staged.frames,
                  source.pcmSHA256 == staged.pcmSHA256 else {
                throw HarcDesktopLocalLibraryReprocessError.stagingConflict
            }
            prepared = staged
        } else {
            prepared = try await Task.detached(priority: .utility) {
                try HarcDesktopClientFiles.canonicalizeWAV(
                    source: URL(fileURLWithPath: recording.wavPath),
                    destination: finalURL
                )
            }.value
        }

        let durationNanoseconds = prepared.frames.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard !durationNanoseconds.overflow else {
            throw HarcDesktopLocalLibraryReprocessError.invalidDuration
        }
        let monotonicDuration = durationNanoseconds.partialValue / 16_000
        let audioDuration = Double(prepared.frames) / 16_000
        let endedAt = recording.endedAt.flatMap {
            $0 >= recording.startedAt ? $0 : nil
        } ?? recording.startedAt.addingTimeInterval(audioDuration)
        let integrity = recording.captureIntegrity.hasIssues ? recording.captureIntegrity
            : try CaptureIntegrityReport.load(nextTo: URL(fileURLWithPath: recording.wavPath))
        if integrity.hasIssues { try integrity.save(nextTo: finalURL) }
        let recoveredCapture = CapturedRecording(localMasterURL: finalURL,
            startedAt: recording.startedAt, endedAt: endedAt, integrity: integrity)
        let capture = try FinalizedCapture(
            producingDeviceID: deviceID,
            originRecordingID: origin,
            captureStartedAt: recording.startedAt,
            captureEndedAt: endedAt,
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: monotonicDuration,
            finalizationReason: .userStopped,
            totalCanonicalFrames: prepared.frames,
            totalCanonicalBytes: prepared.frames * 2,
            canonicalPCMSHA256: try CanonicalPCMHash(prepared.pcmSHA256),
            discontinuities: try recoveredCapture.boundDiscontinuities(to: origin, totalFrames: prepared.frames)
        )
        var transcript = sourceTranscript
        transcript.audioPath = finalURL.path

        let sidecar: HarcDesktopClientCaptureSidecar
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            sidecar = try JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: Data(contentsOf: sidecarURL, options: .mappedIfSafe)
            )
            guard sidecar.sourceLocalCanonicalID == recording.canonicalID,
                  sidecar.capture == capture else {
                throw HarcDesktopLocalLibraryReprocessError.stagingConflict
            }
        } else {
            sidecar = HarcDesktopClientCaptureSidecar(
                capture: capture,
                transcript: transcript,
                speakerEmbeddings: speakerEmbeddings,
                speakerProcessingStatus: .ready,
                persistedAt: Date(),
                sourceLocalCanonicalID: recording.canonicalID
            )
            try HarcDesktopClientFiles.writeSidecar(sidecar, to: sidecarURL)
        }

        _ = try transferStore.persistFinalizedCapture(
            sidecar.capture,
            masterFileURL: finalURL,
            persistedAt: sidecar.persistedAt
        )
        return .queued
    }
}

enum HarcDesktopLocalLibraryReprocessError: LocalizedError {
    case identityMismatch
    case stagingConflict
    case invalidDuration
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .identityMismatch:
            "This recording was staged by a different Client identity. Its files were left untouched."
        case .stagingConflict:
            "Harc found conflicting staged data for this recording. The local original was left untouched."
        case .invalidDuration:
            "This recording is too long to represent safely."
        case .missingAudio:
            "The local audio file could not be found."
        }
    }
}

/// One local diarization generation, prepared from a protected canonical master.
/// Publication must commit these exact bytes and snapshots together; preparing
/// this value does not enroll voices or authorize a mutable numeric speaker slot.
struct HarcStandaloneSpeakerGeneration: Sendable {
    let structuredTranscriptData: Data
    let canonicalPCMHash: CanonicalPCMHash
    let canonicalFrames: UInt64
    let snapshots: [SpeakerEvidenceSnapshot]

    /// Replace only diarization; preserve words, text and manual edit provenance.
    /// Chunk-local speaker guesses are superseded by the new full-master timeline.
    static func applying(_ result: DiarizeResult, to original: SessionTranscript) -> SessionTranscript {
        var transcript = original
        transcript.speakers = result.segments
        transcript.overlapRanges = result.overlapRanges
        if var utterances = transcript.attributedUtterances {
            for index in utterances.indices {
                utterances[index].speakerAttribution = nil
                for word in utterances[index].words.indices {
                    utterances[index].words[word].speakerAttribution = nil
                }
            }
            transcript.attributedUtterances = utterances
        }
        // Explicit word assignments are scoped to the replaced generation.
        for index in transcript.words.indices { transcript.words[index].speakerAttribution = nil }
        for index in transcript.chunks.indices {
            transcript.chunks[index].speakers = []
            for word in transcript.chunks[index].words.indices {
                transcript.chunks[index].words[word].speakerAttribution = nil
            }
        }
        return transcript
    }

    static func prepare(transcript: SessionTranscript, embeddings: [HarcCore.SpeakerEmbeddingRow],
                        canonicalID: CanonicalRecordingID, producerDeviceID: DeviceID,
                        expectedAudio: HarcStandaloneAudioIdentity? = nil) throws -> Self {
        let audio = try HarcStandaloneAudioIdentity.capture(URL(fileURLWithPath: transcript.audioPath))
        if let expectedAudio, expectedAudio != audio {
            throw invalid("The recording audio changed while inference was running")
        }
        return try build(transcript: transcript, embeddings: embeddings, canonicalID: canonicalID,
            producerDeviceID: producerDeviceID, canonicalPCMHash: audio.hash, canonicalFrames: audio.frames)
    }

    static func build(transcript: SessionTranscript, embeddings: [HarcCore.SpeakerEmbeddingRow],
                      canonicalID: CanonicalRecordingID, producerDeviceID: DeviceID,
                      canonicalPCMHash: CanonicalPCMHash, canonicalFrames: UInt64) throws -> Self {
        guard canonicalFrames > 0 else { throw invalid("Empty canonical audio") }
        var durations: [Int: UInt64] = [:]
        var ends: [Int: Int] = [:]
        for segment in transcript.speakers.sorted(by: { $0.startMs < $1.startMs }) {
            guard segment.speaker >= 0, segment.startMs >= 0, segment.endMs > segment.startMs,
                  let end = UInt64(exactly: segment.endMs), end <= canonicalFrames / 16,
                  (ends[segment.speaker] ?? 0) <= segment.startMs else {
                throw invalid("Invalid or overlapping local speaker timeline")
            }
            let duration = UInt64(segment.endMs - segment.startMs)
            let total = (durations[segment.speaker] ?? 0).addingReportingOverflow(duration)
            guard !total.overflow else { throw invalid("Speaker duration overflow") }
            durations[segment.speaker] = total.partialValue
            ends[segment.speaker] = segment.endMs
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transcript)
        let digest = Data(SHA256.hash(data: data))
        var seen = Set<Int>()
        let snapshots = try embeddings.map { embedding in
            guard seen.insert(embedding.speakerIndex).inserted,
                  let available = durations[embedding.speakerIndex],
                  let duration = UInt64(exactly: embedding.totalMs), duration <= available,
                  let count = UInt32(exactly: embedding.segmentCount) else {
                throw invalid("Voice evidence does not belong to the local speaker timeline")
            }
            return try SpeakerEvidenceSnapshot(canonicalRecordingID: canonicalID,
                canonicalPCMHash: canonicalPCMHash, producerDeviceID: producerDeviceID,
                processingArtifactSHA256: digest, localClusterID: "local-speaker-\(embedding.speakerIndex)",
                embedding: .quantizing(embedding.vector), modelID: embedding.modelID,
                speechDurationMs: duration, segmentCount: count)
        }
        return Self(structuredTranscriptData: data, canonicalPCMHash: canonicalPCMHash,
            canonicalFrames: canonicalFrames, snapshots: snapshots)
    }

    private static func invalid(_ reason: String) -> DomainValidationError {
        .invalidState(reason: reason)
    }
}

/// A bounded PCM hash plus filesystem change evidence. Retain before inference
/// and compare during preparation, including replacement with identical bytes.
struct HarcStandaloneAudioIdentity: Sendable, Equatable {
    let hash: CanonicalPCMHash
    let frames: UInt64
    private let file: Fingerprint

    static func capture(_ url: URL) throws -> Self {
        let before = try Fingerprint.read(url)
        let audio = try HarcDesktopClientFiles.inspectCanonicalWAV(url)
        guard try Fingerprint.read(url) == before else {
            throw DomainValidationError.invalidState(reason: "Recording audio changed during inspection")
        }
        return Self(hash: try CanonicalPCMHash(audio.pcmSHA256), frames: audio.frames, file: before)
    }

    private struct Fingerprint: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ url: URL) throws -> Self {
            var value = stat()
            guard url.isFileURL, lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
                throw DomainValidationError.invalidState(reason: "Recording master is unavailable or not a regular file")
            }
            return Self(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
    }
}
