import CryptoKit
import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

@Suite("Background capability redemption admission")
struct BackgroundCapabilityAdmissionTests {
    private struct FixedRandomness: HostBackgroundCapabilityRandomness {
        let capabilityID: UUID
        let secretByte: UInt8

        func generateCapabilityID() throws -> UUID { capabilityID }

        func generateSecret(byteCount: Int) throws -> Data {
            Data(repeating: secretByte, count: byteCount)
        }
    }

    private struct FixedTransportProvider:
        HostBackgroundCapabilityTransportSnapshotProviding
    {
        let exactSignedTransportSet: Data

        func reserveBackgroundCapabilityTransport(
            forHTTPPath httpPath: String,
            capabilityExpiresAt: Date
        ) async throws -> HostBackgroundCapabilityTransportSnapshot {
            try HostBackgroundCapabilityTransportSnapshot(
                absoluteUploadURL: try #require(
                    URL(string: "https://harc-mini.local:7443\(httpPath)")
                ),
                currentTransportSetEpoch: 1,
                exactSignedTransportSet: exactSignedTransportSet
            )
        }
    }

    private struct AdmissionFixture {
        let directory: URL
        let fixture: HostTestFixture
        let store: HarcHostStore
        let grant: DeviceGrantClaims
        let context: AuthenticatedDeviceContext
        let uploadID: UploadID
        let origin: OriginRecordingID
        let profile: FrozenUploadProfile
        let descriptor: LogicalChunkDescriptor
        let mintRequest: HostBackgroundCapabilityMintRequest
        let mintResult: HostBackgroundCapabilityMintResult
        let provider: FixedTransportProvider
        let issuedAt: Date
    }

    private func makeFixture(
        capabilityLifetime: TimeInterval = 7 * 24 * 60 * 60,
        capabilityID: UUID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000801"
        )!
    ) async throws -> AdmissionFixture {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { issuedAt }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("background-admission-grant".utf8)
        )
        let context = fixture.context(for: grant)
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        let profile = try fixture.profile()
        let descriptor = try fixture.descriptor(
            origin: origin,
            bytes: Data([0, 1, 2, 3, 4, 5, 6, 7])
        )
        let begin = try await store.beginUpload(
            context: context,
            sessionCapabilities: try fixture.sessionCapabilities(for: profile),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: profile,
                beganAt: fixture.beganAt.addingTimeInterval(1)
            ),
            at: fixture.beganAt.addingTimeInterval(1)
        )
        guard case .created = begin else {
            throw HarcHostError.uploadConflict("test setup")
        }
        _ = try await store.declareChunks(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: profile.profileSHA256,
            descriptors: [descriptor],
            at: fixture.beganAt.addingTimeInterval(2)
        )

        let exactSignedTransportSet = Data("admission-transport-set".utf8)
        let transportObjectID = Data(SHA256.hash(data: exactSignedTransportSet))
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO host_transport_sets (
                        epoch, exact_signed_bytes, object_id, publication_kind,
                        issued_at_unix_ms, published_at,
                        retirement_floor_unix_ms
                    ) VALUES (1, ?, ?, 'initial', 1, ?, 0)
                    """,
                arguments: [
                    exactSignedTransportSet,
                    transportObjectID,
                    HarcHostStore.unixTime(issuedAt),
                ]
            )
            try db.execute(
                sql: """
                    UPDATE host_metadata
                       SET highest_transport_set_epoch = 1,
                           exact_transport_set_bytes = ?,
                           transport_set_object_sha256 = ?,
                           updated_at = ?
                     WHERE singleton = 1
                    """,
                arguments: [
                    exactSignedTransportSet,
                    transportObjectID,
                    HarcHostStore.unixTime(issuedAt),
                ]
            )
        }
        let provider = FixedTransportProvider(
            exactSignedTransportSet: exactSignedTransportSet
        )
        let mintRequest = try HostBackgroundCapabilityMintRequest(
            uploadID: uploadID,
            generation: .initial,
            uploadProfileSHA256: profile.profileSHA256,
            batchID: .random(),
            chunks: [HostBackgroundChunkBinding(
                chunkIndex: descriptor.chunkIndex,
                encodedSHA256: descriptor.encodedSHA256
            )],
            exactBatchBodySHA256: ImmutableBatchSHA256(
                Data(repeating: 0xD1, count: 32)
            ),
            exactBatchBodyLength: 64,
            requestedExpiresAt: issuedAt.addingTimeInterval(capabilityLifetime)
        )
        let mintResult = try await store.mintBackgroundCapability(
            context: context,
            request: mintRequest,
            transportSnapshotProvider: provider,
            policy: try HostBackgroundCapabilityPolicy(
                maximumLifetime: capabilityLifetime
            ),
            randomness: FixedRandomness(
                capabilityID: capabilityID,
                secretByte: 0x81
            ),
            at: issuedAt
        )
        return AdmissionFixture(
            directory: directory,
            fixture: fixture,
            store: store,
            grant: grant,
            context: context,
            uploadID: uploadID,
            origin: origin,
            profile: profile,
            descriptor: descriptor,
            mintRequest: mintRequest,
            mintResult: mintResult,
            provider: provider,
            issuedAt: issuedAt
        )
    }

    private func request(
        for fixture: AdmissionFixture,
        credential: Data? = nil,
        method: String? = nil,
        path: String? = nil,
        contentLength: UInt64? = nil,
        bodySHA256: ImmutableBatchSHA256? = nil,
        servedEpoch: UInt64 = 1
    ) -> HostBackgroundCapabilityAdmissionRequest {
        HostBackgroundCapabilityAdmissionRequest(
            opaqueCapabilityCredential: credential
                ?? fixture.mintResult.opaqueCapabilityCredential,
            httpMethod: method ?? fixture.mintResult.httpMethod,
            httpPath: path ?? fixture.mintResult.httpPath,
            contentLength: contentLength ?? fixture.mintResult.byteCeiling,
            claimedExactBodySHA256: bodySHA256
                ?? fixture.mintResult.exactBatchBodySHA256,
            servedTransportSetEpoch: servedEpoch
        )
    }

    private func acknowledgement(
        fixture: AdmissionFixture,
        batch: ImmutableAudioBatchDescriptor,
        exactBytes: Data,
        durableAt: Date
    ) throws -> ValidatedBatchAcknowledgementEvidence {
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: fixture.fixture.libraryID,
            hostAuthorityID: fixture.fixture.metadata.hostAuthorityID,
            hostAuthorityPublicKey: fixture.fixture.hostKey.publicKey
        )
        return try ValidatedBatchAcknowledgementEvidence(
            hostTrust: hostTrust,
            exactAcknowledgementObject: OpaqueExactObjectSlot(
                kind: .audioBatchAckV1,
                exactBytes: exactBytes,
                objectSHA256: ExactObjectSHA256(
                    Data(SHA256.hash(data: exactBytes))
                )
            ),
            batch: batch,
            durableChunks: batch.chunks.map {
                DurableChunkStatus(
                    chunkIndex: $0.chunkIndex,
                    chunkID: $0.chunkID,
                    encodedSHA256: $0.encodedSHA256
                )
            },
            acknowledgementID: UUID(),
            durableAt: durableAt
        )
    }

    private func requireAdmission(
        _ disposition: HostBackgroundCapabilityAdmissionDisposition
    ) throws -> HostBackgroundBatchAdmission {
        guard case .receiveBody(let admission) = disposition else {
            Issue.record("Expected body admission, received exact replay")
            throw HostBackgroundCapabilityAdmissionError.capabilityUnavailable
        }
        return admission
    }

    @Test("valid redemption finalizes once and every completed replay returns the first exact ACK")
    func acceptanceAndExactReplay() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admission = try requireAdmission(
            try await fixture.store.admitBackgroundCapability(
                request(for: fixture),
                at: fixture.issuedAt.addingTimeInterval(1)
            )
        )
        #expect(admission.batch.batchID == fixture.mintRequest.batchID)
        #expect(admission.batch.chunks == [fixture.descriptor])
        #expect(admission.contentLength == 64)
        #expect(admission.byteCeiling == 64)
        #expect(admission.minimumTransportSetEpoch == 1)
        #expect(admission.servedTransportSetEpoch == 1)

        let firstACK = Data("exact-signed-batch-ack-one".utf8)
        let firstEvidence = try acknowledgement(
            fixture: fixture,
            batch: admission.batch,
            exactBytes: firstACK,
            durableAt: fixture.issuedAt.addingTimeInterval(2)
        )
        let finalized = try await fixture.store
            .finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: firstEvidence,
                at: fixture.issuedAt.addingTimeInterval(3)
            )
        guard case .accepted(let accepted) = finalized else {
            Issue.record("Expected first durable acceptance")
            return
        }
        #expect(accepted.exactAcknowledgementBytes == firstACK)

        let replay = try await fixture.store.admitBackgroundCapability(
            request(for: fixture),
            at: fixture.issuedAt.addingTimeInterval(4)
        )
        guard case .exactReplay(let completed) = replay else {
            Issue.record("Completed batch should bypass body restaging")
            return
        }
        #expect(completed.batch == admission.batch)
        #expect(completed.exactAcknowledgementBytes == firstACK)

        let secondACK = Data("different-signed-batch-ack".utf8)
        let secondEvidence = try acknowledgement(
            fixture: fixture,
            batch: admission.batch,
            exactBytes: secondACK,
            durableAt: fixture.issuedAt.addingTimeInterval(4)
        )
        let raced = try await fixture.store
            .finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: secondEvidence,
                at: fixture.issuedAt.addingTimeInterval(5)
            )
        guard case .exactReplay(let racedReplay) = raced else {
            Issue.record("A repeated finalization must replay the first ACK")
            return
        }
        #expect(racedReplay.exactAcknowledgementBytes == firstACK)

        let secondCapability = try await fixture.store.mintBackgroundCapability(
            context: fixture.context,
            request: fixture.mintRequest,
            transportSnapshotProvider: fixture.provider,
            randomness: FixedRandomness(
                capabilityID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000802"
                )!,
                secretByte: 0x82
            ),
            at: fixture.issuedAt
        )
        let secondCapabilityReplay = try await fixture.store
            .admitBackgroundCapability(
                request(
                    for: fixture,
                    credential: secondCapability.opaqueCapabilityCredential
                ),
                at: fixture.issuedAt.addingTimeInterval(6)
            )
        guard case .exactReplay(let freshReplay) = secondCapabilityReplay else {
            Issue.record("A fresh narrow capability should replay a completed batch")
            return
        }
        #expect(freshReplay.exactAcknowledgementBytes == firstACK)

        let persisted = try await fixture.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT batch.state AS batch_state, batch.exact_ack_bytes,
                           capability.state AS capability_state
                      FROM upload_batches AS batch
                      JOIN background_capabilities AS capability
                        ON capability.batch_id = batch.batch_id
                     WHERE capability.capability_id = ?
                    """,
                arguments: [
                    fixture.mintResult.capabilityID.uuidString.lowercased()
                ]
            )
        }
        #expect(persisted?["batch_state"] as String? == "accepted")
        #expect(persisted?["capability_state"] as String? == "accepted")
        #expect(persisted?["exact_ack_bytes"] as Data? == firstACK)
    }

    @Test("credential method path length body and served epoch mismatches fail without mutation")
    func requestBindingRejections() async throws {
        let fixture = try await makeFixture(
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000811"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkedAt = fixture.issuedAt.addingTimeInterval(1)

        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .credentialRejected) {
            _ = try await fixture.store.admitBackgroundCapability(
                self.request(
                    for: fixture,
                    credential: Data(
                        fixture.mintResult.opaqueCapabilityCredential.dropLast()
                    )
                ),
                at: checkedAt
            )
        }
        var wrongSecret = fixture.mintResult.opaqueCapabilityCredential
        wrongSecret[47] ^= 0xFF
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .credentialRejected) {
            _ = try await fixture.store.admitBackgroundCapability(
                self.request(for: fixture, credential: wrongSecret),
                at: checkedAt
            )
        }
        var wrongID = fixture.mintResult.opaqueCapabilityCredential
        wrongID[0] ^= 0x01
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .credentialRejected) {
            _ = try await fixture.store.admitBackgroundCapability(
                self.request(for: fixture, credential: wrongID),
                at: checkedAt
            )
        }

        for (candidate, expected) in [
            (
                request(for: fixture, method: "POST"),
                HostBackgroundCapabilityAdmissionError
                    .requestBindingMismatch(field: "httpMethod")
            ),
            (
                request(for: fixture, path: fixture.mintResult.httpPath + "/"),
                HostBackgroundCapabilityAdmissionError
                    .requestBindingMismatch(field: "httpPath")
            ),
            (
                request(for: fixture, contentLength: 63),
                HostBackgroundCapabilityAdmissionError
                    .requestBindingMismatch(field: "contentLength")
            ),
            (
                request(
                    for: fixture,
                    bodySHA256: try ImmutableBatchSHA256(
                        Data(repeating: 0xD2, count: 32)
                    )
                ),
                HostBackgroundCapabilityAdmissionError
                    .requestBindingMismatch(field: "exactBodySHA256")
            ),
            (
                request(for: fixture, servedEpoch: 0),
                HostBackgroundCapabilityAdmissionError
                    .transportSetEpochRejected(minimum: 1, served: 0)
            ),
            (
                request(for: fixture, servedEpoch: 2),
                HostBackgroundCapabilityAdmissionError
                    .transportSetEpochRejected(minimum: 1, served: 2)
            ),
        ] {
            await #expect(throws: expected) {
                _ = try await fixture.store.admitBackgroundCapability(
                    candidate,
                    at: checkedAt
                )
            }
        }

        let persisted = try await fixture.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT batch.state AS batch_state, batch.exact_ack_bytes,
                           capability.state AS capability_state
                      FROM upload_batches AS batch
                      JOIN background_capabilities AS capability
                        ON capability.batch_id = batch.batch_id
                     WHERE capability.capability_id = ?
                    """,
                arguments: [
                    fixture.mintResult.capabilityID.uuidString.lowercased()
                ]
            )
        }
        #expect(persisted?["batch_state"] as String? == "awaiting-upload")
        #expect(persisted?["capability_state"] as String? == "issued")
        #expect(persisted?["exact_ack_bytes"] as Data? == nil)

        try await fixture.store.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM background_capability_bindings WHERE capability_id = ?",
                arguments: [
                    fixture.mintResult.capabilityID.uuidString.lowercased()
                ]
            )
        }
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .capabilityUnavailable) {
            _ = try await fixture.store.admitBackgroundCapability(
                self.request(for: fixture),
                at: checkedAt
            )
        }
    }

    @Test("finalization rechecks body ACK and live capability state")
    func finalizationReauthorization() async throws {
        let fixture = try await makeFixture(
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000821"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admission = try requireAdmission(
            try await fixture.store.admitBackgroundCapability(
                request(for: fixture),
                at: fixture.issuedAt.addingTimeInterval(1)
            )
        )
        let evidence = try acknowledgement(
            fixture: fixture,
            batch: admission.batch,
            exactBytes: Data("valid-final-ack".utf8),
            durableAt: fixture.issuedAt.addingTimeInterval(2)
        )
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .requestBindingMismatch(field: "contentLength")) {
            _ = try await fixture.store.finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 63,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: evidence,
                at: fixture.issuedAt.addingTimeInterval(3)
            )
        }
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .requestBindingMismatch(field: "exactBodySHA256")) {
            _ = try await fixture.store.finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: try ImmutableBatchSHA256(
                    Data(repeating: 0xD3, count: 32)
                ),
                acknowledgement: evidence,
                at: fixture.issuedAt.addingTimeInterval(3)
            )
        }

        let otherBatch = try ImmutableAudioBatchDescriptor(
            batchID: .random(),
            uploadID: admission.batch.uploadID,
            generation: admission.batch.generation,
            uploadProfileSHA256: admission.batch.uploadProfileSHA256,
            originRecordingID: admission.batch.originRecordingID,
            ownerDeviceID: admission.batch.ownerDeviceID,
            chunks: admission.batch.chunks,
            exactBodyByteLength: admission.batch.exactBodyByteLength,
            exactBodySHA256: admission.batch.exactBodySHA256
        )
        let wrongEvidence = try acknowledgement(
            fixture: fixture,
            batch: otherBatch,
            exactBytes: Data("wrong-batch-ack".utf8),
            durableAt: fixture.issuedAt.addingTimeInterval(2)
        )
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .acknowledgementMismatch(field: "batchAcknowledgement")) {
            _ = try await fixture.store.finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: wrongEvidence,
                at: fixture.issuedAt.addingTimeInterval(3)
            )
        }

        try await fixture.store.revokeDevice(
            fixture.fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "background-admission-race",
            exactRevocationBytes: Data("admission-race-revocation".utf8),
            issuedAt: fixture.issuedAt.addingTimeInterval(3)
        )
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .capabilityUnavailable) {
            _ = try await fixture.store.finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: evidence,
                at: fixture.issuedAt.addingTimeInterval(4)
            )
        }
        let notAccepted = try await fixture.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT batch.exact_ack_bytes, capability.state
                      FROM upload_batches AS batch
                      JOIN background_capabilities AS capability
                        ON capability.batch_id = batch.batch_id
                     WHERE capability.capability_id = ?
                    """,
                arguments: [
                    fixture.mintResult.capabilityID.uuidString.lowercased()
                ]
            )
        }
        #expect(notAccepted?["exact_ack_bytes"] as Data? == nil)
        #expect(notAccepted?["state"] as String? == "revoked")
    }

    @Test("capability expiry between headers and final acceptance fails closed")
    func expiryRace() async throws {
        let fixture = try await makeFixture(
            capabilityLifetime: 5,
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000831"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admission = try requireAdmission(
            try await fixture.store.admitBackgroundCapability(
                request(for: fixture),
                at: fixture.issuedAt.addingTimeInterval(1)
            )
        )
        let evidence = try acknowledgement(
            fixture: fixture,
            batch: admission.batch,
            exactBytes: Data("expiry-race-ack".utf8),
            durableAt: fixture.issuedAt.addingTimeInterval(2)
        )
        await #expect(throws: HostBackgroundCapabilityAdmissionError
            .capabilityUnavailable) {
            _ = try await fixture.store.finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: 64,
                observedBodySHA256: admission.exactBodySHA256,
                acknowledgement: evidence,
                at: fixture.issuedAt.addingTimeInterval(6)
            )
        }
        let exactACK = try await fixture.store.dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT exact_ack_bytes FROM upload_batches WHERE batch_id = ?",
                arguments: [fixture.mintRequest.batchID.description]
            )
        }
        #expect(exactACK == nil)
    }
}
