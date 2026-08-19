import CryptoKit
import Foundation
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
        structuredTranscript == nil || recording.sttModelID != currentModelID
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
            discontinuities: []
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
