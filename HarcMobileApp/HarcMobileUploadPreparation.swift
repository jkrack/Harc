import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcTransfer

/// Application composition of a new attempt or a durable Begin replay.
enum HarcMobileUploadPreparation {
    @MainActor
    static func artifacts<Artifact>(
        origin: OriginRecordingID, store: HarcTransferStore,
        encode: @MainActor () async throws -> [Artifact]
    ) async throws -> [Artifact]? {
        guard try store.uploadBeginIntent(for: origin) == nil else { return nil }
        return try await encode()
    }

    static func plan(
        origin: OriginRecordingID, store: HarcTransferStore,
        currentTrustTuple: AdoptedTrustTuple,
        freshProfile: () throws -> FrozenUploadProfile,
        freshChunks: () throws -> [HarcForegroundEncodedChunk]
    ) throws -> HarcForegroundRecordingUploadPlan {
        // A fresh authenticated session is still required by the caller and
        // the uploader validates it again before any recording RPC.
        _ = try store.authorizingAdoption(for: currentTrustTuple, requiredScope: .recordingUploadOwn)
        if let stored = try store.uploadBeginIntent(for: origin) {
            let intent = stored.intent
            guard intent.originRecordingID == origin,
                  intent.trustTuple == currentTrustTuple else {
                throw HarcForegroundRecordingOutboxError.securityBindingMismatch(field: "uploadBeginIntentTrust")
            }
            return try HarcForegroundRecordingUploadPlan(
                trustTuple: intent.trustTuple, uploadID: intent.uploadID,
                originRecordingID: intent.originRecordingID, frozenProfile: intent.frozenProfile,
                chunks: intent.chunks.map {
                    try HarcForegroundEncodedChunk(descriptor: $0.descriptor, encodedFileURL: $0.encodedFileURL)
                }
            )
        }
        let outbox = try store.recordingOutbox(for: origin)
        return try HarcForegroundRecordingUploadPlan(
            trustTuple: currentTrustTuple, uploadID: outbox?.uploadID ?? .random(),
            originRecordingID: origin, frozenProfile: freshProfile(), chunks: freshChunks()
        )
    }

    static func canAttempt(origin: OriginRecordingID, store: HarcTransferStore) throws -> Bool {
        guard let outbox = try store.recordingOutbox(for: origin) else {
            throw ClientStoreError.missingRow(entity: "recording outbox")
        }
        guard outbox.stateMachine.state != .committed,
              outbox.stateMachine.state != .securityBlocked,
              outbox.integrityBlock == nil,
              outbox.finalizedCapture.masterFileState == .present else { return false }
        let boundTuple: AdoptedTrustTuple
        if let intent = try store.uploadBeginIntent(for: origin) {
            boundTuple = intent.intent.trustTuple
        } else if let uploadID = outbox.uploadID {
            guard let attempt = try store.uploadAttempt(id: uploadID) else {
                throw ClientStoreError.missingRow(entity: "upload attempt")
            }
            boundTuple = attempt.trustTuple
        } else {
            // A new local capture has no frozen Host binding yet. The normal
            // connector/uploader still requires an authorizing adoption.
            return true
        }
        guard let active = try store.activeAdoption() else { return false }
        return active.tuple == boundTuple && active.hasActiveGrantStatus
    }
}

/// One bounded pass. A failed recording remains durable for a later wake.
@MainActor
enum HarcMobileTransferWorkQueue {
    static func drain<Work, ID: Hashable>(
        identity: (Work) -> ID,
        next: () -> Work?,
        shouldAttempt: (Work) throws -> Bool,
        process: (Work) async throws -> Void,
        skipped: (Work) -> Void,
        failed: (Work, any Error) throws -> Void
    ) async throws {
        var attempted = Set<ID>()
        while !Task.isCancelled, let work = next() {
            guard attempted.insert(identity(work)).inserted else { skipped(work); continue }
            do {
                guard try shouldAttempt(work) else { skipped(work); continue }
                try await process(work)
            } catch {
                // The failure callback may throw for a true global stop.
                // Otherwise continue this bounded pass with the next job.
                try failed(work, error)
            }
        }
    }
}
