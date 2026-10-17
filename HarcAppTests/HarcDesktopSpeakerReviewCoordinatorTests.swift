import CryptoKit
import Foundation
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcTransfer
import Testing
@testable import Harc

@Suite("Desktop speaker review coordinator", .serialized)
struct HarcDesktopSpeakerReviewCoordinatorTests {
    @Test @MainActor func persistedDeadlineWakesInventoryAndRespectsCancellationAndBackoff() async throws {
        for mode in ["review", "cancel", "backoff", "host-review", "host-missing-master", "host-missing-both"] {
            let cancel = mode == "cancel", backoff = mode == "backoff", hostReview = mode.hasPrefix("host-")
            let root = temporaryClientStoreDirectory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let deviceKey = SoftwareP256SigningKey()
            let evidence = try ClientStoreValidatedEvidenceFixture(deviceKey: deviceKey)
            let identity = InstallationSigningIdentity(key: InstallationSigningKey(keychainSoftware: deviceKey))
            let store = try HarcTransferStore(rootDirectory: root, installationDeviceID: identity.deviceID,
                storageAttributes: RecordingStorageAttributes())
            _ = try store.adopt(evidence.adoption)
            let master = root.appendingPathComponent("master.wav")
            try Data([1,2,3]).write(to: master)
            _ = try store.persistFinalizedCapture(evidence.capture, masterFileURL: master)
            _ = try store.updateRecordingOutbox(for: evidence.origin) { machine in
                try machine.queue(); try machine.beginAuthorization()
                try machine.beginActiveUpload(); try machine.awaitHostCommit()
            }
            var attempt = evidence.attempt
            _ = try attempt.bindFinalManifest(using: evidence.manifestEvidence,
                generation: attempt.generation, at: attempt.generationBeganAt)
            try store.persistUploadAttempt(attempt, for: evidence.tuple)
            if mode.hasPrefix("host-missing") {
                let pending = try #require(try store.recordingOutbox(for: evidence.origin))
                #expect(try !HarcDesktopClientTransferCoordinator.hasVerifiedHostCopy(pending,
                    store: store, expectedTrust: evidence.tuple))
            }
            _ = try store.persistVerifiedRecordingReceipt(HarcAuthenticatedRecordingReceiptV1(evidence: evidence.receiptEvidence))
            let cache = try HarcLibraryCache(rootDirectory: root, storageAttributes: RecordingStorageAttributes())
            let log = try HarcDiagnosticLogStore(fileURL: root.appendingPathComponent("diagnostics.jsonl"))
            if backoff {
                var schedule = HarcDesktopRetrySchedule()
                for _ in 0..<8 { _ = schedule.recordFailure(now: Date(), jitterMultiplier: 1) }
                try JSONEncoder().encode(schedule).write(to: root.appendingPathComponent("host-retry.json"))
            }
            let coordinator = try HarcDesktopClientTransferCoordinator(identity: identity, store: store,
                libraryCache: cache, clientRoot: root, routeURL: root.appendingPathComponent("absent-route.json"),
                diagnosticLog: log)
            defer { coordinator.shutdown() }
            let captures = root.appendingPathComponent("Captures", isDirectory: true)
            try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
            let prefix = evidence.origin.recordingUUID.uuidString.lowercased()
            let sidecar = HarcDesktopClientCaptureSidecar(capture: evidence.capture, transcript: nil,
                speakerEmbeddings: hostReview ? [] : [SpeakerEmbeddingRow(speakerIndex: 0, vector: [1,0], totalMs: 50, segmentCount: 1)],
                persistedAt: Date())
            let sidecarData = try JSONEncoder().encode(sidecar)
            try sidecarData.write(to: captures.appendingPathComponent(prefix + ".capture.json"))
            let digest = Data(SHA256.hash(data: sidecarData)), artifact = Data(repeating: 4, count: 32)
            let host = HarcDesktopHostEvidenceBinding(trust: evidence.tuple)
            let processing = HarcDesktopProcessingMarker(exactSignedMetadataSHA256: Data(repeating: 5, count: 32),
                disposition: 1, sidecarSHA256: digest, acceptedAt: Date(), hostBinding: host,
                selectedEdgeBundleSHA256: artifact)
            try JSONEncoder().encode(processing).write(to: captures.appendingPathComponent(prefix + ".edge-accepted.json"))
            let deadline = Date().addingTimeInterval(1)
            let outcome = try HostSpeakerProcessingOutcome(canonicalRecordingID: evidence.receiptEvidence.canonicalRecordingID,
                canonicalPCMHash: evidence.capture.canonicalPCMSHA256,
                producerDeviceID: DeviceID(evidence.tuple.hostAuthorityID.rawBytes),
                processingArtifactSHA256: artifact, diarization: .completed,
                clusters: [HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0)])
            let marker = HarcDesktopSpeakerObservationMarker(canonicalRecordingID: evidence.receiptEvidence.canonicalRecordingID,
                sourcePackRevision: nil, decisions: hostReview ? nil : [], acceptedAt: Date(), nextReviewAt: deadline,
                hostBinding: host, sidecarSHA256: digest, processingArtifactSHA256: hostReview ? nil : artifact,
                hostOutcome: hostReview ? outcome : nil)
            try JSONEncoder().encode(marker).write(to: captures.appendingPathComponent(prefix + ".speakers-accepted.json"))
            if mode.hasPrefix("host-missing") {
                try FileManager.default.removeItem(at: master)
                _ = try store.reconcileLocalArtifacts()
                let outbox = try #require(try store.recordingOutbox(for: evidence.origin))
                #expect(outbox.finalizedCapture.masterFileState == .missing)
                #expect(try HarcDesktopClientTransferCoordinator.hasVerifiedHostCopy(outbox,
                    store: store, expectedTrust: evidence.tuple))
                #expect(try !HarcDesktopClientTransferCoordinator.hasVerifiedHostCopy(outbox,
                    store: store, expectedTrust: nil))
                #expect(try !HarcDesktopClientTransferCoordinator.hasVerifiedHostCopy(outbox,
                    store: store, expectedTrust: AdoptedTrustTuple(libraryID: .random(),
                        hostAuthorityID: evidence.tuple.hostAuthorityID)))
                let recovery = try HarcDesktopClientRecovery.reconcile(root: root, store: store, deviceID: identity.deviceID)
                #expect(recovery.blockedOrigins.isEmpty)
                #expect(recovery.report.alreadyOnHost == 1)
                #expect(recovery.localCandidates.isEmpty)
                let sidecarURL = captures.appendingPathComponent(prefix + ".capture.json")
                try Data("invalid sidecar".utf8).write(to: sidecarURL)
                let corrupted = try HarcDesktopClientRecovery.reconcile(root: root, store: store, deviceID: identity.deviceID)
                #expect(corrupted.blockedOrigins.contains(evidence.origin))
                try sidecarData.write(to: sidecarURL)
                if mode == "host-missing-both" {
                    try FileManager.default.removeItem(at: sidecarURL)
                    let rebuilt = try HarcDesktopClientRecovery.reconcile(root: root, store: store, deviceID: identity.deviceID)
                    #expect(rebuilt.blockedOrigins.isEmpty)
                    #expect(rebuilt.report.sidecarsRebuilt == 1)
                    #expect(rebuilt.localCandidates.isEmpty)
                    #expect(!FileManager.default.fileExists(atPath: master.path))
                    let reconstructedData = try Data(contentsOf: sidecarURL)
                    let reconstructed = try JSONDecoder().decode(HarcDesktopClientCaptureSidecar.self, from: reconstructedData)
                    #expect(reconstructed.capture == evidence.capture)
                    #expect(reconstructed.transcript == nil && reconstructed.speakerEmbeddings == nil)
                    let resumedMarker = HarcDesktopSpeakerObservationMarker(
                        canonicalRecordingID: evidence.receiptEvidence.canonicalRecordingID,
                        sourcePackRevision: nil, decisions: nil, acceptedAt: Date(), nextReviewAt: deadline,
                        hostBinding: host, sidecarSHA256: Data(SHA256.hash(data: reconstructedData)), hostOutcome: outcome)
                    try JSONEncoder().encode(resumedMarker).write(to: captures.appendingPathComponent(prefix + ".speakers-accepted.json"))
                }
                coordinator.setRecoveryBlockedOrigins(recovery.blockedOrigins)
            }
            coordinator.resumePending()
            func inventories() -> Int { log.entries.filter { $0.stage == "queue-inventory" }.count }
            #expect(inventories() == (backoff ? 0 : 1))
            #expect(coordinator.pendingSpeakerCount == 0)
            #expect(!log.entries.contains { $0.stage == "encode" })
            #expect(coordinator.speakerReviewCount == (hostReview && !backoff ? 1 : 0))
            if cancel { coordinator.shutdown() }
            let limit = Date().addingTimeInterval(5)
            while Date() < ((cancel || backoff) ? deadline.addingTimeInterval(0.2) : limit) {
                if !cancel && !backoff && inventories() > 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if backoff {
                #expect(inventories() == 0)
                #expect(log.entries.contains { $0.stage == "retry-restored" })
                #expect(try #require(coordinator.nextAutomaticRetryAt) > deadline)
            } else if cancel {
                #expect(inventories() == 1)
            } else {
                #expect(inventories() > 1)
                #expect(coordinator.pendingSpeakerCount == 1)
                #expect(coordinator.pendingProcessingCount == 0)
            }
        }
    }
}
