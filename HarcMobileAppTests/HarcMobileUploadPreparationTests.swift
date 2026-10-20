import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
@testable import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileUploadPreparationTests: XCTestCase {
    func testDeliveryBuildSelectsCAFALAC() {
        XCTAssertEqual(HarcMobileLosslessReleaseGate.selected, .cafALAC)
    }

    func testLostBeginReusesWholeIntentUnderAdditiveCapabilitiesWithoutEncoding() async throws {
        let fixture = try await makeFixture()
        let rpc = DroppedBeginRPC()
        var encodingCalls = 0
        let initialArtifacts: [Int]? = try await HarcMobileUploadPreparation.artifacts(
            origin: fixture.origin, store: fixture.store,
            encode: { encodingCalls += 1; return [1] }
        )
        XCTAssertEqual(initialArtifacts, [1])
        let first = try fixture.plan()
        try await fixture.loseBegin(first, session: fixture.session, rpc: rpc)
        let before = try XCTUnwrap(fixture.store.uploadBeginIntent(for: fixture.origin)).intent
        let additive = try fixture.sessionWithFeatures(["library.search.v1", "transfer.chunk.v1"])
        XCTAssertNotEqual(additive.negotiatedCapabilities.exactSHA256, fixture.session.negotiatedCapabilities.exactSHA256)
        var freshProfileCalls = 0
        var freshChunkCalls = 0
        let reusedArtifacts: [Int]? = try await HarcMobileUploadPreparation.artifacts(
            origin: fixture.origin, store: fixture.store,
            encode: { encodingCalls += 1; throw Fault.unexpectedEncoding }
        )
        XCTAssertNil(reusedArtifacts)
        let retry = try HarcMobileUploadPreparation.plan(
            origin: fixture.origin, store: fixture.store, currentTrustTuple: first.trustTuple,
            freshProfile: { freshProfileCalls += 1; return try fixture.profile(additive.negotiatedCapabilities) },
            freshChunks: { freshChunkCalls += 1; return first.chunks }
        )
        XCTAssertEqual(retry, first)
        XCTAssertEqual(freshProfileCalls, 0)
        XCTAssertEqual(freshChunkCalls, 0)
        XCTAssertEqual(encodingCalls, 1)
        try await fixture.loseBegin(retry, session: additive, rpc: rpc)
        XCTAssertEqual(try fixture.store.uploadBeginIntent(for: fixture.origin)?.intent, before)
        let requests = await rpc.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(try Data(contentsOf: fixture.masterURL), fixture.bytes)
        XCTAssertNil(try fixture.store.cleanupIntent(for: fixture.origin))
    }

    func testCurrentSessionStillMustSupportFrozenCapabilitiesAndAuthorization() async throws {
        for invalidSession in 0 ..< 3 {
            let fixture = try await makeFixture()
            let rpc = DroppedBeginRPC()
            let plan = try fixture.plan()
            try await fixture.loseBegin(plan, session: fixture.session, rpc: rpc)
            let session = try fixture.sessionWithFeatures(
                invalidSession == 0 ? [] : ["transfer.chunk.v1"],
                badAuthorization: invalidSession == 1, differentEncoding: invalidSession == 2
            )
            let replay = try HarcMobileUploadPreparation.plan(
                origin: fixture.origin, store: fixture.store, currentTrustTuple: plan.trustTuple,
                freshProfile: { throw Fault.unexpectedEncoding }, freshChunks: { throw Fault.unexpectedEncoding }
            )
            do {
                _ = try await fixture.uploader(rpc).drive(replay, openedSession: session, deviceSigner: fixture.bootstrap.deviceKey)
                XCTFail("Invalid current session must fail before BeginUpload")
            } catch {
                XCTAssertFalse(error is Fault, "Invalid session reached the synthetic transport: \(error)")
            }
            let requests = await rpc.requests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(try fixture.store.uploadBeginIntent(for: fixture.origin)?.intent.frozenProfile, plan.frozenProfile)
            XCTAssertEqual(try Data(contentsOf: fixture.masterURL), fixture.bytes)
        }
    }

    func testOldHostJobCannotDelayCurrentHostJobInSameQueuePass() async throws {
        let fixture = try await makeFixture()
        let oldPlan = try fixture.plan()
        try await fixture.loseBegin(oldPlan, session: fixture.session, rpc: DroppedBeginRPC())
        XCTAssertTrue(try fixture.store.forgetActiveHost())
        let hostB = try BootstrapClientFixture(
            deviceKey: fixture.bootstrap.deviceKey, libraryID: LibraryID(UUID()), authorityByte: 0x32
        )
        let (adoptionB, _) = try await Self.open(hostB)
        _ = try fixture.store.adopt(adoptionB)
        let current = OriginRecordingID(deviceID: fixture.origin.deviceID, recordingUUID: UUID())
        let currentURL = fixture.root.appendingPathComponent("host-b-master.pcm")
        try fixture.bytes.write(to: currentURL)
        _ = try fixture.store.persistFinalizedCapture(fixture.capture(current), masterFileURL: currentURL)
        let tupleB = AdoptedTrustTuple(libraryID: adoptionB.hostTrust.libraryID, hostAuthorityID: adoptionB.hostTrust.hostAuthorityID)
        XCTAssertThrowsError(try HarcMobileUploadPreparation.plan(
            origin: fixture.origin, store: fixture.store, currentTrustTuple: tupleB,
            freshProfile: { try fixture.profile(fixture.session.negotiatedCapabilities) }, freshChunks: { oldPlan.chunks }
        ))
        var queue = [fixture.origin, current]
        var completed: [OriginRecordingID] = []
        var skipped: [OriginRecordingID] = []
        var failures: [OriginRecordingID] = []
        try await HarcMobileTransferWorkQueue.drain(
            identity: { $0 },
            next: { queue.isEmpty ? nil : queue.removeFirst() },
            shouldAttempt: { try HarcMobileUploadPreparation.canAttempt(origin: $0, store: fixture.store) },
            process: {
                guard $0 == current else { throw Fault.wrongHost }
                completed.append($0) // Synthetic terminal outcome, no Host RPC or receipt.
            }, skipped: { skipped.append($0) }, failed: { origin, _ in failures.append(origin) }
        )
        XCTAssertEqual(completed, [current])
        XCTAssertEqual(skipped, [fixture.origin])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try fixture.store.activeAdoption()?.tuple, tupleB)
        XCTAssertEqual(try fixture.store.recordingOutboxes().count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.masterURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: currentURL), fixture.bytes)
        XCTAssertNil(try fixture.store.cleanupIntent(for: fixture.origin))
    }

    func testRecoverableFailureDoesNotStrandNextJobAndGlobalFailureStillStops() async throws {
        for globalStop in [false, true] {
            var queue = [1, 2]
            var completed: [Int] = []
            do {
                try await HarcMobileTransferWorkQueue.drain(
                    identity: { $0 },
                    next: { queue.isEmpty ? nil : queue.removeFirst() }, shouldAttempt: { _ in true },
                    process: { if $0 == 1 { throw Fault.lostResponse }; completed.append($0) },
                    skipped: { _ in }, failed: { _, error in if globalStop { throw error } }
                )
            } catch { XCTAssertTrue(globalStop) }
            XCTAssertEqual(completed, globalStop ? [] : [2])
            XCTAssertEqual(queue, globalStop ? [2] : [])
        }
    }

    func testFailedOriginRequeuedDuringPassIsAttemptedOnlyOnce() async throws {
        var queue = [1, 2]
        var attempts: [Int] = []
        var skipped: [Int] = []
        try await HarcMobileTransferWorkQueue.drain(
            identity: { $0 }, next: { queue.isEmpty ? nil : queue.removeFirst() },
            shouldAttempt: { _ in true }, process: {
                attempts.append($0)
                if $0 == 1 { throw Fault.lostResponse }
            }, skipped: { skipped.append($0) }, failed: { _, _ in queue.append(1) }
        )
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(skipped, [1])
    }

    func testProductionFailureAdapterControlsQueueAndRetainsFailedMaster() async throws {
        let cases: [(String, any Error, Bool)] = [
            ("encodingFailed", HarcMobileALACEncodingError.encodingFailed(chunkIndex: 0), false),
            ("codecNotQualified", HarcMobileTransferError.codecNotQualified, true),
            ("notPaired", HarcMobileTransferError.notPaired, true),
            ("connectorNotPaired", HarcMobileHostSessionConnectorError.notPaired, true),
            ("pairingRepairRequired", HarcMobileHostSessionConnectorError.pairingRepairRequired, true),
            ("cancellation", CancellationError(), true),
            ("ordinary", Fault.lostResponse, false),
        ]
        for (name, injectedError, expectsStop) in cases {
            let fixture = try await makeFixture()
            let second = OriginRecordingID(deviceID: fixture.origin.deviceID, recordingUUID: UUID())
            let secondURL = fixture.root.appendingPathComponent("second-master.pcm")
            try fixture.bytes.write(to: secondURL)
            _ = try fixture.store.persistFinalizedCapture(fixture.capture(second), masterFileURL: secondURL)
            var queue = [fixture.origin, second]
            var completed: [OriginRecordingID] = []
            var presentations: [HarcMobileTransferFailurePresentation] = []
            var stopped = false
            do {
                try await HarcMobileTransferWorkQueue.drain(
                    identity: { $0 }, next: { queue.isEmpty ? nil : queue.removeFirst() },
                    shouldAttempt: { _ in true },
                    process: {
                        if $0 == fixture.origin { throw injectedError }
                        completed.append($0)
                    }, skipped: { _ in XCTFail("Unexpected skipped work for \(name)") },
                    failed: { origin, error in
                        // No test-chosen stop callback: this is the adapter used
                        // by the production coordinator's error handler.
                        try HarcMobileTransferFailureAdapter.handle(
                            error, origin: origin, store: fixture.store,
                            report: { presentations.append($0) },
                            persistenceFailure: { XCTFail("Adapter persistence failed: \($0)") }
                        )
                    }
                )
            } catch {
                stopped = true
                XCTAssertEqual(String(reflecting: error), String(reflecting: injectedError), name)
            }
            XCTAssertEqual(stopped, expectsStop, name)
            XCTAssertEqual(completed, expectsStop ? [] : [second], name)
            XCTAssertEqual(queue, expectsStop ? [second] : [], name)
            XCTAssertEqual(presentations.count, 1, name)
            switch (name, presentations.first) {
            case ("encodingFailed", .some(.retryNeeded)), ("ordinary", .some(.retryNeeded)),
                 ("codecNotQualified", .some(.codecQualificationRequired)),
                 ("notPaired", .some(.waitingForPairing)),
                 ("connectorNotPaired", .some(.waitingForPairing)),
                 ("pairingRepairRequired", .some(.securityBlocked)),
                 ("cancellation", .some(.cancelled)):
                break
            default:
                XCTFail("Wrong production presentation for \(name): \(presentations)")
            }
            if name == "encodingFailed", case .retryNeeded(let message)? = presentations.first {
                XCTAssertTrue(message.contains("saved on this iPhone"))
                XCTAssertFalse(message.lowercased().contains("qualification"))
            }
            if name == "pairingRepairRequired" {
                XCTAssertEqual(try fixture.store.recordingOutbox(for: fixture.origin)?.stateMachine.state, .securityBlocked)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.masterURL), fixture.bytes, name)
            XCTAssertEqual(try Data(contentsOf: secondURL), fixture.bytes, name)
            XCTAssertEqual(try fixture.store.recordingOutbox(for: fixture.origin)?.finalizedCapture.masterFileState, .present, name)
            XCTAssertNil(try fixture.store.cleanupIntent(for: fixture.origin), name)
            XCTAssertNil(try fixture.store.verifiedRecordingReceipt(for: fixture.origin), name)
        }
    }

    private static func open(_ fixture: BootstrapClientFixture) async throws -> (ValidatedClientAdoptionEvidence, HarcOpenedClientSession) {
        let client = try fixture.client(rpc: BootstrapClientFakeRPC(fixture: fixture))
        _ = try await client.beginPairing(ticket: fixture.ticket, deviceSigner: fixture.deviceKey,
                                        requestedScopes: fixture.scopes, deviceLabel: "Synthetic upload composition")
        guard case .approved(let adoption, _) = try await client.getPairingStatus() else { throw Fault.unexpectedCall }
        return (adoption, try await client.openSession(adoption: adoption, negotiatedCapabilities: fixture.negotiated, deviceSigner: fixture.deviceKey))
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try await Fixture.make()
        let root = fixture.root
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        return fixture
    }

    private struct Fixture {
        let root: URL
        let bootstrap: BootstrapClientFixture
        let session: HarcOpenedClientSession
        let store: HarcTransferStore
        let origin: OriginRecordingID
        let masterURL: URL
        let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8])
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let bootstrap = try BootstrapClientFixture()
            let (adoption, session) = try await HarcMobileUploadPreparationTests.open(bootstrap)
            let store = try HarcTransferStore(rootDirectory: root, installationDeviceID: bootstrap.deviceKey.publicKey.deviceID,
                                             storageAttributes: UploadStorageAttributes(),
                                             now: { Date(timeIntervalSince1970: Double(bootstrap.now) / 1000) })
            _ = try store.adopt(adoption)
            let origin = OriginRecordingID(deviceID: bootstrap.deviceKey.publicKey.deviceID, recordingUUID: UUID())
            let result = Self(root: root, bootstrap: bootstrap, session: session, store: store,
                              origin: origin, masterURL: root.appendingPathComponent("master.pcm"))
            try result.bytes.write(to: result.masterURL)
            _ = try store.persistFinalizedCapture(result.capture(origin), masterFileURL: result.masterURL)
            return result
        }
        func capture(_ origin: OriginRecordingID) throws -> FinalizedCapture {
            try FinalizedCapture(producingDeviceID: origin.deviceID, originRecordingID: origin,
                captureStartedAt: Date(timeIntervalSince1970: Double(bootstrap.now - 1000) / 1000),
                captureEndedAt: Date(timeIntervalSince1970: Double(bootstrap.now) / 1000),
                captureStartedMonotonicNanoseconds: 1000, captureEndedMonotonicNanoseconds: 2000,
                finalizationReason: .userStopped, totalCanonicalFrames: 4, totalCanonicalBytes: 8,
                canonicalPCMSHA256: CanonicalPCMHash(Data(SHA256.hash(data: bytes))), discontinuities: [])
        }
        func profile(_ negotiated: HarcValidatedNegotiatedCapabilitiesV1) throws -> FrozenUploadProfile {
            let provisional = try FrozenUploadProfile(protocolVersion: TransferProtocolVersion(minor: 0), encoding: .rawPCMFixture,
                requiredCapabilities: negotiated.selectedFeatureIDs.map(TransferCapabilityID.init).sorted(),
                negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(negotiated.exactSHA256),
                profileSHA256: UploadProfileSHA256(Data(repeating: 0, count: 32)), purpose: .fixtureLoopback)
            let payload = try HarcExactProtobufPayload(serializingOnce: Harc_V1_UploadProfileV1(provisional))
            return try FrozenUploadProfile(protocolVersion: provisional.protocolVersion, encoding: provisional.encoding,
                requiredCapabilities: provisional.requiredCapabilities, negotiatedCapabilitiesSHA256: provisional.negotiatedCapabilitiesSHA256,
                profileSHA256: UploadProfileSHA256(HarcSignedEnvelopeV1.payloadDigest(payload.exactBytes)), purpose: .fixtureLoopback)
        }
        func plan() throws -> HarcForegroundRecordingUploadPlan {
            let chunkURL = root.appendingPathComponent("chunk.pcm")
            try bytes.write(to: chunkURL)
            let hash = Data(SHA256.hash(data: bytes))
            let chunk = try LogicalChunkDescriptor(originRecordingID: origin, chunkID: ChunkID(UUID()), chunkIndex: 0,
                canonicalStartFrame: 0, canonicalFrameCount: 4, encoding: .rawPCMFixture, encodedByteLength: 8,
                encodedSHA256: EncodedChunkSHA256(hash), canonicalDecodedByteLength: 8, canonicalDecodedSHA256: CanonicalPCMHash(hash))
            return try HarcMobileUploadPreparation.plan(origin: origin, store: store,
                currentTrustTuple: AdoptedTrustTuple(libraryID: session.grant.hostTrust.libraryID, hostAuthorityID: session.grant.hostTrust.hostAuthorityID),
                freshProfile: { try profile(session.negotiatedCapabilities) },
                freshChunks: { [try HarcForegroundEncodedChunk(descriptor: chunk, encodedFileURL: chunkURL)] })
        }
        func sessionWithFeatures(_ features: [String], badAuthorization: Bool = false, differentEncoding: Bool = false) throws -> HarcOpenedClientSession {
            var raw = BootstrapClientFixture.makeNegotiatedCapabilities()
            raw.selectedFeatureIds = features
            if differentEncoding { raw.encoding = Harc_V1_LosslessEncodingConfigurationV1(.cafALAC) }
            let negotiated = try HarcValidatedNegotiatedCapabilitiesV1(serializingOnce: raw,
                policy: HarcCapabilityPolicyV1(supportedFeatureIDs: ["library.search.v1", "transfer.chunk.v1"],
                    supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue], supportedEncodings: [.rawPCMFixture, .cafALAC], allowRawPCMFixture: true))
            let credential = Data([1]) + Data(repeating: 0x73, count: 47)
            return HarcOpenedClientSession(credential: credential,
                authorizationHeader: badAuthorization ? "HarcSession invalid" : try HarcBootstrapAuthorization.sessionHeader(credential: credential),
                issuedAtUnixMilliseconds: session.issuedAtUnixMilliseconds, expiresAtUnixMilliseconds: session.expiresAtUnixMilliseconds,
                serverTimeUnixMilliseconds: session.serverTimeUnixMilliseconds, grant: session.grant,
                negotiatedCapabilities: negotiated, tlsSPKISHA256: session.tlsSPKISHA256)
        }
        func uploader(_ rpc: DroppedBeginRPC) -> HarcForegroundRecordingOutboxCoordinator {
            HarcForegroundRecordingOutboxCoordinator(store: store, transport: rpc,
                now: { Date(timeIntervalSince1970: Double(bootstrap.now) / 1000) })
        }
        func loseBegin(_ plan: HarcForegroundRecordingUploadPlan, session: HarcOpenedClientSession, rpc: DroppedBeginRPC) async throws {
            do {
                _ = try await uploader(rpc).drive(plan, openedSession: session, deviceSigner: bootstrap.deviceKey)
                XCTFail("Synthetic transport must drop the Begin response")
            } catch let fault as Fault { XCTAssertEqual(fault, .lostResponse) }
        }
    }
}

private enum Fault: Error, Equatable { case lostResponse, unexpectedCall, unexpectedEncoding, wrongHost }
private struct UploadStorageAttributes: ClientStoreStorageAttributeApplying {
    func isProtectedDataAvailable(for _: ClientStoreStoragePolicy) -> Bool { true }
    func applyAndVerify(_: ClientStoreStoragePolicy, to _: ClientStoreStorageArtifact) throws {}
}
private actor DroppedBeginRPC: HarcRecordingTransferRPCTransport {
    private var captured: [Data] = []
    func requests() -> [Data] { captured }
    func beginUpload(_ request: Harc_V1_BeginUploadRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_BeginUploadResponseV1 {
        captured.append(try HarcExactProtobufPayload(serializingOnce: request).exactBytes)
        throw Fault.lostResponse
    }
    func declareChunks(_: Harc_V1_DeclareChunksRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_DeclareChunksResponseV1 { throw Fault.unexpectedCall }
    func uploadChunks(authorization _: HarcRecordingTransferAuthorization, requestProducer _: @escaping HarcUploadChunkRequestProducer, responseConsumer _: @escaping HarcUploadChunkResponseConsumer) async throws { throw Fault.unexpectedCall }
    func reconcileUpload(_: Harc_V1_ReconcileUploadRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_ReconcileUploadResponseV1 { throw Fault.unexpectedCall }
    func commitUpload(_: Harc_V1_CommitUploadRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_CommitUploadResponseV1 { throw Fault.unexpectedCall }
    func abandonUpload(_: Harc_V1_AbandonUploadRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_AbandonUploadResponseV1 { throw Fault.unexpectedCall }
    func getRecordingStatus(_: Harc_V1_GetRecordingStatusRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_GetRecordingStatusResponseV1 { throw Fault.unexpectedCall }
    func mintBackgroundUploadAuthorization(_: Harc_V1_MintBackgroundCapabilityRequestV1, authorization _: HarcRecordingTransferAuthorization) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1 { throw Fault.unexpectedCall }
}
