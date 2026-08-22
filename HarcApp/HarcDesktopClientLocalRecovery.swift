import Foundation
import HarcClient
import HarcCore
import HarcStore
import HarcUI

struct HarcDesktopClientLocalTranscription: Sendable {
    let transcript: SessionTranscript
    let speakerEmbeddings: [SpeakerEmbeddingRow]
}

enum HarcDesktopClientLocalRecovery {
    struct Outcome: Sendable {
        var added = 0
        var alreadyVisible = 0
        var transcribed = 0
        var transcriptReused = 0
        var failed = 0
        var issues: [ClientRecoverSyncIssue] = []
    }

    /// Reconcile every verified ClientState master into the local Library
    /// before Host delivery is attempted. Each recording is isolated so a bad
    /// file or failed inference cannot stop the rest of the archive.
    @MainActor
    static func reconcile(
        _ candidates: [HarcDesktopClientRecovery.LocalCandidate],
        store: RecordingStore,
        currentModelID: String,
        onLibraryChange: @MainActor () async -> Void = {},
        transcribe: @MainActor (HarcDesktopClientRecovery.LocalCandidate) async throws
            -> HarcDesktopClientLocalTranscription
    ) async -> Outcome {
        var outcome = Outcome()

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let capture = candidate.sidecar.capture
            let shortID = String(
                capture.originRecordingID.recordingUUID.uuidString
                    .lowercased().prefix(8)
            )
            do {
                if let sourceID = candidate.sidecar.sourceLocalCanonicalID,
                   let source = try await store.fetch(canonicalID: sourceID) {
                    outcome.alreadyVisible += 1
                    try await completeExistingSourceIfNeeded(
                        source,
                        candidate: candidate,
                        store: store,
                        currentModelID: currentModelID,
                        transcribe: transcribe,
                        outcome: &outcome
                    )
                    await onLibraryChange()
                    continue
                }

                var sidecar = candidate.sidecar
                let initial = try await reconcilePersistedCapture(
                    candidate,
                    store: store,
                    currentModelID: currentModelID
                )
                if initial.inserted {
                    outcome.added += 1
                } else {
                    outcome.alreadyVisible += 1
                }
                // The row is useful immediately, even when this master still
                // needs local STT. Do not make the Library wait for every
                // older archive item to finish transcribing.
                await onLibraryChange()

                if sidecar.transcript != nil {
                    outcome.transcriptReused += 1
                    continue
                }

                let generated = try await transcribe(candidate)
                var transcript = generated.transcript
                transcript.audioPath = candidate.masterURL.path
                let generatedArtifacts = try writeTranscript(
                    transcript,
                    nextTo: candidate.masterURL
                )
                let completed = try await store.reconcileClientCapture(
                    originID: capture.originRecordingID,
                    canonicalPCMHash: capture.canonicalPCMSHA256,
                    canonicalPCMFrames: capture.totalCanonicalFrames,
                    masterURL: candidate.masterURL,
                    startedAt: capture.captureStartedAt,
                    endedAt: capture.captureEndedAt,
                    transcriptText: persistedTranscriptText(transcript),
                    transcriptJSONURL: generatedArtifacts.json,
                    transcriptMarkdownURL: generatedArtifacts.markdown,
                    sttModelID: currentModelID,
                    transcribedAt: Date()
                )
                try await persistEmbeddings(
                    generated.speakerEmbeddings,
                    recording: completed.recording,
                    store: store
                )
                sidecar = HarcDesktopClientCaptureSidecar(
                    capture: sidecar.capture,
                    transcript: transcript,
                    speakerEmbeddings: generated.speakerEmbeddings,
                    persistedAt: sidecar.persistedAt,
                    sourceLocalCanonicalID: sidecar.sourceLocalCanonicalID
                )
                try HarcDesktopClientFiles.replaceSidecar(
                    sidecar,
                    at: candidate.sidecarURL
                )
                outcome.transcribed += 1
                await onLibraryChange()
            } catch {
                outcome.failed += 1
                outcome.issues.append(ClientRecoverSyncIssue(
                    id: "\(shortID):local:\(String(reflecting: type(of: error)))",
                    recording: shortID,
                    message: "The master remains protected, but local Library recovery did not finish: \(error.localizedDescription)"
                ))
            }
        }

        return outcome
    }

    /// Mirror a capture whose protected master and sidecar are already
    /// durable. This is the fast path used directly by tray recording commit:
    /// it never waits for an archive scan or Host connectivity.
    static func reconcilePersistedCapture(
        _ candidate: HarcDesktopClientRecovery.LocalCandidate,
        store: RecordingStore,
        currentModelID: String
    ) async throws -> ClientCaptureLibraryResult {
        let sidecar = candidate.sidecar
        let capture = sidecar.capture
        let artifacts = try sidecar.transcript.map {
            try writeTranscript($0, nextTo: candidate.masterURL)
        }
        var result = try await store.reconcileClientCapture(
            originID: capture.originRecordingID,
            canonicalPCMHash: capture.canonicalPCMSHA256,
            canonicalPCMFrames: capture.totalCanonicalFrames,
            masterURL: candidate.masterURL,
            startedAt: capture.captureStartedAt,
            endedAt: capture.captureEndedAt,
            transcriptText: sidecar.transcript.map {
                persistedTranscriptText($0)
            },
            transcriptJSONURL: artifacts?.json,
            transcriptMarkdownURL: artifacts?.markdown,
            sttModelID: sidecar.transcript == nil ? nil : currentModelID,
            transcribedAt: sidecar.transcript == nil ? nil : sidecar.persistedAt
        )
        // v0.14.9 and earlier mirrored SessionTranscript.joinedText into the
        // DB even though TranscriptWriter had produced a speaker-labeled
        // Markdown sibling. Repair only that exact untouched flat value. A
        // divergent DB transcript or a manually edited sidecar is user data
        // and must never be replaced automatically.
        if let transcript = sidecar.transcript,
           transcript.manualEditAt == nil {
            let rendered = persistedTranscriptText(transcript)
            if rendered != transcript.joinedText,
               result.recording.transcriptText == transcript.joinedText,
               let recordingID = result.recording.id {
                try await store.applyReprocessedTranscript(
                    recordingID: recordingID,
                    text: rendered,
                    modelID: currentModelID,
                    now: sidecar.persistedAt
                )
                if let refreshed = try await store.fetch(id: recordingID) {
                    result = ClientCaptureLibraryResult(
                        recording: refreshed,
                        inserted: result.inserted
                    )
                }
            }
        }
        try await persistEmbeddings(
            sidecar.speakerEmbeddings ?? [],
            recording: result.recording,
            store: store
        )
        return result
    }

    @MainActor
    private static func completeExistingSourceIfNeeded(
        _ source: Recording,
        candidate: HarcDesktopClientRecovery.LocalCandidate,
        store: RecordingStore,
        currentModelID: String,
        transcribe: @MainActor (HarcDesktopClientRecovery.LocalCandidate) async throws
            -> HarcDesktopClientLocalTranscription,
        outcome: inout Outcome
    ) async throws {
        guard source.deletedAt == nil else { return }
        if let existing = candidate.sidecar.transcript {
            let rendered = persistedTranscriptText(existing)
            let isRepairableLegacyFlatText = existing.manualEditAt == nil
                && source.transcriptText == existing.joinedText
                && rendered != existing.joinedText
            if source.transcriptText == nil || isRepairableLegacyFlatText,
               let id = source.id {
                try await store.applyReprocessedTranscript(
                    recordingID: id,
                    text: rendered,
                    modelID: currentModelID,
                    now: candidate.sidecar.persistedAt
                )
            }
            try await persistEmbeddings(
                candidate.sidecar.speakerEmbeddings ?? [],
                recording: source,
                store: store
            )
            outcome.transcriptReused += 1
            return
        }

        let generated = try await transcribe(candidate)
        guard let recordingID = source.id else {
            throw StoreError.invalidData(
                "The source local recording has no identifier"
            )
        }
        try await store.applyReprocessedTranscript(
            recordingID: recordingID,
            text: persistedTranscriptText(generated.transcript),
            modelID: currentModelID
        )
        try await persistEmbeddings(
            generated.speakerEmbeddings,
            recording: source,
            store: store
        )
        var transcript = generated.transcript
        transcript.audioPath = candidate.masterURL.path
        let updated = HarcDesktopClientCaptureSidecar(
            capture: candidate.sidecar.capture,
            transcript: transcript,
            speakerEmbeddings: generated.speakerEmbeddings,
            persistedAt: candidate.sidecar.persistedAt,
            sourceLocalCanonicalID: candidate.sidecar.sourceLocalCanonicalID
        )
        try HarcDesktopClientFiles.replaceSidecar(
            updated,
            at: candidate.sidecarURL
        )
        outcome.transcribed += 1
    }

    private static func writeTranscript(
        _ source: SessionTranscript,
        nextTo masterURL: URL
    ) throws -> (json: URL, markdown: URL) {
        var transcript = source
        transcript.audioPath = masterURL.path
        try TranscriptWriter.writeSiblings(
            transcript: transcript,
            nextTo: masterURL
        )
        let stem = masterURL.deletingPathExtension().lastPathComponent
        let parent = masterURL.deletingLastPathComponent()
        return (
            parent.appendingPathComponent("\(stem).json"),
            parent.appendingPathComponent("\(stem).md")
        )
    }

    /// Structured word/speaker timing is the source for generated display
    /// text. Once a user has edited joinedText, preserve that exact text: word
    /// offsets and diarization turns no longer describe its structure safely.
    private static func persistedTranscriptText(
        _ transcript: SessionTranscript
    ) -> String {
        guard transcript.manualEditAt == nil else { return transcript.joinedText }
        return TranscriptPlainTextRenderer.render(transcript)
    }

    private static func persistEmbeddings(
        _ embeddings: [SpeakerEmbeddingRow],
        recording: Recording,
        store: RecordingStore
    ) async throws {
        guard let recordingID = recording.id, !embeddings.isEmpty else {
            return
        }
        try await store.upsertSpeakerEmbeddings(
            recordingID: recordingID,
            rows: embeddings.map {
                RecordingStore.SpeakerEmbeddingRow(
                    recordingID: recordingID,
                    speakerIndex: $0.speakerIndex,
                    embedding: HarcStore.EmbeddingBlob.pack($0.vector),
                    segmentCount: $0.segmentCount,
                    totalMs: $0.totalMs,
                    embedderKind: "wespeaker_v2"
                )
            }
        )
    }
}
