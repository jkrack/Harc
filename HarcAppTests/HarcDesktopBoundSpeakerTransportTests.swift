import CryptoKit
import Foundation
import GRDB
import HarcClient
import HarcClientStore
import HarcClientTransport
import HarcCore
import HarcDomain
import HarcIdentity
import HarcProtocol
@testable import HarcStore
import HarcTransfer
import Testing
@testable import Harc

@Suite("Desktop bound speaker sender over pinned TLS", .serialized)
struct HarcDesktopBoundSpeakerTransportTests {
    @Test func actualSenderRetainsExactBatchAcrossReplyFailureAndRecreation() async throws {
        try await PairingLifecycleLoopbackFixture().run { context in
            try await Self.exercise(context)
        }
    }

    @MainActor private static func exercise(_ context: BoundSpeakerLoopbackContext) async throws {
        let root = context.root.appendingPathComponent("desktop-sender", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let store = try HarcTransferStore(rootDirectory: root, installationDeviceID: context.identity.deviceID)
        _ = try store.adopt(context.adoption)
        let cache = try HarcLibraryCache(rootDirectory: root)
        let log = try HarcDiagnosticLogStore(fileURL: root.appendingPathComponent("diagnostics.jsonl"))
        let coordinator = try HarcDesktopClientTransferCoordinator(identity: context.identity,
            store: store, libraryCache: cache, clientRoot: root,
            routeURL: root.appendingPathComponent("unused-route.json"), diagnosticLog: log)
        defer { coordinator.shutdown() }
        let opened = HarcDesktopOpenedHostConnection(connection: context.connection,
            path: ProcessInfo.processInfo.environment["HARC_RELAY_EMULATOR_ORIGIN"] == nil ? .direct : .encryptedRelay,
            adoption: context.adoption, session: context.session, negotiated: context.session.negotiatedCapabilities)
        let now = Date()
        let capture = try FinalizedCapture(producingDeviceID: context.identity.deviceID, originRecordingID: context.origin,
            captureStartedAt: now, captureEndedAt: now.addingTimeInterval(0.5),
            captureStartedMonotonicNanoseconds: 0, captureEndedMonotonicNanoseconds: 500_000_000,
            finalizationReason: .userStopped, totalCanonicalFrames: 8000, totalCanonicalBytes: 16000,
            canonicalPCMSHA256: context.canonicalPCMHash, discontinuities: [])
        let transcript = SessionTranscript(startedAt: now, endedAt: now.addingTimeInterval(0.5),
            audioPath: root.appendingPathComponent("fixture.wav").path, joinedText: "mixed words", words: [],
            speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 100),
                SpeakerSegment(speaker: 1, startMs: 400, endMs: 500)], chunks: [])
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let prefix = context.origin.recordingUUID.uuidString.lowercased()
        let sidecarURL = captures.appendingPathComponent(prefix + ".capture.json")
        let markerURL = captures.appendingPathComponent(prefix + ".speakers-accepted.json")
        func persist(_ rows: [SpeakerEmbeddingRow]) throws {
            let sidecar = HarcDesktopClientCaptureSidecar(capture: capture, transcript: transcript,
                speakerEmbeddings: rows, persistedAt: now)
            let data = try JSONEncoder().encode(sidecar), digest = Data(SHA256.hash(data: data))
            try data.write(to: sidecarURL)
            let submission = HarcDesktopProcessingSubmission(exactSignedMetadata: context.exactSignedMetadata,
                exactBundle: context.exactBundle, sidecarSHA256: digest)
            let url = HarcDesktopClientTransferCoordinator.processingSubmissionURL(origin: context.origin,
                grantID: context.adoption.grant.grantID, grantEpoch: context.adoption.grant.registryEpoch,
                sidecarSHA256: digest, clientRoot: root)
            try JSONEncoder().encode(submission).write(to: url)
        }
        let row = SpeakerEmbeddingRow(speakerIndex: 0, vector: [1,0,0], totalMs: 100, segmentCount: 1)
        try persist([row])
        let database = await context.recordingStore.uncoordinatedDB
        func decisionCount() async throws -> Int {
            try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bound_speaker_observation_provenance") ?? 0 }
        }
        let before = try await decisionCount()
        let failure = try await coordinator.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: opened)
        try #require(failure == nil)
        let first = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: Data(contentsOf: markerURL))
        try #require(first.processingArtifactSHA256 == Data(SHA256.hash(data: context.exactBundle)))
        try #require(first.decisions?.count == 1)
        try #require(try await decisionCount() == before + 1)
        // Loss of the local completion marker must replay the existing Host
        // operation, rather than admit a second observation with a new identity.
        try FileManager.default.removeItem(at: markerURL)
        try #require(try await coordinator.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: opened) == nil)
        let replayData = try Data(contentsOf: markerURL)
        let replay = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: replayData)
        try #require(replay.decisions?.map(\.decision.operationID) == first.decisions?.map(\.decision.operationID))
        let refreshedPack = try #require(try cache.speakerRecognitionPack(libraryID: context.adoption.hostTrust.libraryID))
        let originalPackRevision = try #require(first.sourcePackRevision)
        try #require(refreshedPack.revision > originalPackRevision)
        try #require(try await decisionCount() == before + 1)
        try persist([row, SpeakerEmbeddingRow(speakerIndex: 99, vector: [1,0,0], totalMs: 100, segmentCount: 1)])
        try #require(try await coordinator.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: opened) != nil)
        try #require(try await decisionCount() == before + 1)
        try #require(try Data(contentsOf: markerURL) == replayData)
        try persist([row])
        try await context.recordingStore.updateProcessing(id: context.recordingID, descriptor: .pending)
        var statusRequest = Harc_V1_GetProcessingStatusRequestV1()
        statusRequest.protocol = HarcProtocolVersion.v1.protobufV1()
        statusRequest.originRecordingID = Harc_V1_OriginRecordingIDV1(context.origin)
        let status = try await context.connection.getProcessingStatus(statusRequest,
            authorization: HarcProcessingAuthorization(openedSession: context.session))
        try #require(!status.status.hasSelectedEdgeBundleSha256)
        try #require(!status.status.hasHostSpeakerOutcome)
        try #require(try await coordinator.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: opened) != nil)
        try #require(try await decisionCount() == before + 1)
        try #require(try Data(contentsOf: markerURL) == replayData)
        try await context.recordingStore.updateProcessing(id: context.recordingID, descriptor: .ready)
        let secondRow = SpeakerEmbeddingRow(speakerIndex: 1, vector: [0,1,0], totalMs: 100, segmentCount: 1)
        try persist([row, secondRow])
        let countBeforeInterruption = try await decisionCount()
        await context.replyFailureGate.arm()
        let interrupted = try await coordinator.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: opened)
        try #require(interrupted != nil)
        try #require(await context.replyFailureGate.failureCount == 1)
        try #require(try await decisionCount() == countBeforeInterruption + 1)
        try #require(try Data(contentsOf: markerURL) == replayData)
        let currentSidecarDigest = Data(SHA256.hash(data: try Data(contentsOf: sidecarURL)))
        let bundleDigest = SHA256.hash(data: context.exactBundle).map { String(format: "%02x", $0) }.joined()
        let journalURL = HarcDesktopClientTransferCoordinator.processingSubmissionURL(origin: context.origin,
            grantID: context.adoption.grant.grantID, grantEpoch: context.adoption.grant.registryEpoch,
            sidecarSHA256: currentSidecarDigest, clientRoot: root).appendingPathExtension("speakers-" + bundleDigest)
        let pending = try JSONDecoder().decode(HarcDesktopBoundSpeakerBatch.self, from: Data(contentsOf: journalURL))
        try #require(pending.completedAt == nil)
        try #require(pending.observations.count == 2)
        coordinator.shutdown()
        try await context.connection.shutdownGracefully()
        try #require(await context.connection.status() == .stoppedGracefully)
        let fresh = try await context.openFreshConnection()
        do {
        try #require(fresh.connection !== context.connection)
        try #require(fresh.session.credential != context.session.credential)
        let freshOpened = HarcDesktopOpenedHostConnection(connection: fresh.connection, path: opened.path,
            adoption: context.adoption, session: fresh.session, negotiated: fresh.session.negotiatedCapabilities)
        let reopenedStore = try HarcTransferStore(rootDirectory: root, installationDeviceID: context.identity.deviceID)
        let reopenedCache = try HarcLibraryCache(rootDirectory: root)
        let resumed = try HarcDesktopClientTransferCoordinator(identity: context.identity, store: reopenedStore,
            libraryCache: reopenedCache, clientRoot: root, routeURL: root.appendingPathComponent("unused-route.json"),
            diagnosticLog: log)
        defer { resumed.shutdown() }
        try #require(try await resumed.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: freshOpened) == nil)
        try #require(try await decisionCount() == countBeforeInterruption + 2)
        let completed = try JSONDecoder().decode(HarcDesktopBoundSpeakerBatch.self, from: Data(contentsOf: journalURL))
        try #require(completed.completedAt != nil)
        try #require(completed.observations == pending.observations)
        let completion = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: Data(contentsOf: markerURL))
        try #require(completion.decisions?.map(\.decision.operationID) == pending.observations.map(\.observation.operationID))
        // An actual authenticated status response must preserve a Host-owned
        // missing-voice outcome after replacing the previously selected edge.
        try await context.recordingStore.updateProcessing(id: context.recordingID, descriptor: .pending)
        let hostData = Data(#"{"words":[],"speakers":[{"speaker":0,"startMs":0,"endMs":100}]}"#.utf8)
        _ = try await context.recordingStore.stageHostProcessedTranscriptIfNotReady(recordingID: context.recordingID,
            text: "Host voice", modelID: "fixture-host", structuredTranscriptData: hostData)
        let hostProducer = try DeviceID(context.adoption.hostTrust.hostAuthorityID.rawBytes)
        let hostOutcome = try HostSpeakerProcessingOutcome(canonicalRecordingID: context.canonicalID,
            canonicalPCMHash: context.canonicalPCMHash, producerDeviceID: hostProducer,
            processingArtifactSHA256: Data(SHA256.hash(data: hostData)), diarization: .completed,
            clusters: [HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0)])
        _ = try await context.recordingStore.publishHostProcessedProjectionIfNotReady(recordingID: context.recordingID,
            speakerOutcome: hostOutcome, structuredTranscriptData: hostData)
        let hostStatus = try await fresh.connection.getProcessingStatus(statusRequest,
            authorization: HarcProcessingAuthorization(openedSession: fresh.session))
        try #require(hostStatus.status.hasHostSpeakerOutcome)
        try #require(try hostStatus.status.validatedHostSpeakerOutcome(canonicalID: context.canonicalID,
            originID: context.origin, canonicalPCMHash: context.canonicalPCMHash,
            producerDeviceID: hostProducer) == hostOutcome)
        try #require(!hostStatus.status.hasSelectedEdgeBundleSha256)
        // No local voice or corresponding edge submission exists for this sidecar.
        try persist([])
        let countBeforeHostReconciliation = try await decisionCount()
        try #require(try await resumed.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: freshOpened) == nil)
        let hostMarkerData = try Data(contentsOf: markerURL)
        let hostMarker = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: hostMarkerData)
        try #require(hostMarker.hostOutcome == hostOutcome)
        try #require(hostMarker.decisions == nil && hostMarker.processingArtifactSHA256 == nil)
        try #require(hostMarker.concernCount == 1)
        try #require(hostMarker.reviewDeadline != nil)
        try #require(try await decisionCount() == countBeforeHostReconciliation)
        statusRequest.canonicalRecordingID = .init(context.canonicalID)
        let canonicalStatus = try await fresh.connection.getProcessingStatus(statusRequest,
            authorization: HarcProcessingAuthorization(openedSession: fresh.session))
        try #require(try canonicalStatus.status.validatedHostSpeakerOutcome(canonicalID: context.canonicalID,
            originID: context.origin, canonicalPCMHash: context.canonicalPCMHash,
            producerDeviceID: hostProducer) == hostOutcome)
        try await context.recordingStore.updateProcessing(id: context.recordingID, descriptor: .pending)
        try #require(try await resumed.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: freshOpened) != nil)
        try #require(try Data(contentsOf: markerURL) == hostMarkerData)
        let disabledData = Data(#"{"words":[],"speakers":[]}"#.utf8)
        _ = try await context.recordingStore.stageHostProcessedTranscriptIfNotReady(recordingID: context.recordingID,
            text: "Host without diarization", modelID: "fixture-host", structuredTranscriptData: disabledData)
        let disabled = try HostSpeakerProcessingOutcome(canonicalRecordingID: context.canonicalID,
            canonicalPCMHash: context.canonicalPCMHash, producerDeviceID: hostProducer,
            processingArtifactSHA256: Data(SHA256.hash(data: disabledData)), diarization: .disabled, clusters: [])
        _ = try await context.recordingStore.publishHostProcessedProjectionIfNotReady(recordingID: context.recordingID,
            speakerOutcome: disabled, structuredTranscriptData: disabledData)
        try #require(try await resumed.submitSpeakerObservationsIfPresent(origin: context.origin,
            canonicalID: context.canonicalID, opened: freshOpened) == nil)
        let disabledMarker = try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: Data(contentsOf: markerURL))
        try #require(disabledMarker.hostOutcome == disabled && disabledMarker.concernCount == 1)
        try #require(try await decisionCount() == countBeforeHostReconciliation)
        try await fresh.connection.shutdownGracefully()
        print("Actual desktop sender: pending batch recovered on a new pinned connection and fresh authenticated session without duplicate decisions")
        } catch {
            await fresh.connection.shutdownImmediately()
            throw error
        }
    }
}
