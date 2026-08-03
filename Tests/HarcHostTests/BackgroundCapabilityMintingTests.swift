import CryptoKit
import Foundation
import GRDB
import Testing
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

@Suite("Background capability minting")
struct BackgroundCapabilityMintingTests {
    private struct FixedRandomness: HostBackgroundCapabilityRandomness {
        let capabilityID: UUID
        let secret: Data

        func generateCapabilityID() throws -> UUID { capabilityID }

        func generateSecret(byteCount: Int) throws -> Data {
            #expect(byteCount == 32)
            return secret
        }
    }

    private struct FixedTransportProvider:
        HostBackgroundCapabilityTransportSnapshotProviding
    {
        let exactSignedTransportSet: Data
        var epoch: UInt64 = 1
        var host = "harc-mini.local:7443"
        var pathSuffix = ""

        func reserveBackgroundCapabilityTransport(
            forHTTPPath httpPath: String,
            capabilityExpiresAt: Date
        ) async throws -> HostBackgroundCapabilityTransportSnapshot {
            try HostBackgroundCapabilityTransportSnapshot(
                absoluteUploadURL: try #require(
                    URL(string: "https://\(host)\(httpPath)\(pathSuffix)")
                ),
                currentTransportSetEpoch: epoch,
                exactSignedTransportSet: exactSignedTransportSet
            )
        }
    }

    private actor RecordingTransportProvider:
        HostBackgroundCapabilityTransportSnapshotProviding
    {
        let exactSignedTransportSet: Data
        private var reservedExpiry: Date?

        init(exactSignedTransportSet: Data) {
            self.exactSignedTransportSet = exactSignedTransportSet
        }

        func reserveBackgroundCapabilityTransport(
            forHTTPPath httpPath: String,
            capabilityExpiresAt: Date
        ) async throws -> HostBackgroundCapabilityTransportSnapshot {
            reservedExpiry = capabilityExpiresAt
            return try HostBackgroundCapabilityTransportSnapshot(
                absoluteUploadURL: try #require(
                    URL(string: "https://harc-mini.local:7443\(httpPath)")
                ),
                currentTransportSetEpoch: 1,
                exactSignedTransportSet: exactSignedTransportSet
            )
        }

        func expiry() -> Date? { reservedExpiry }
    }

    private struct TransitioningTransportProvider:
        HostBackgroundCapabilityTransportSnapshotProviding
    {
        let store: HarcHostStore
        let exactSignedTransportSet: Data
        let currentObjectID: Data

        func reserveBackgroundCapabilityTransport(
            forHTTPPath httpPath: String,
            capabilityExpiresAt: Date
        ) async throws -> HostBackgroundCapabilityTransportSnapshot {
            let nextBytes = Data("pending-transport-set".utf8)
            let nextObjectID = Data(SHA256.hash(data: nextBytes))
            try await store.dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO pending_transport_set_publications (
                            singleton, previous_epoch, next_epoch,
                            expected_previous_object_id, exact_signed_bytes,
                            object_id, publication_kind,
                            expected_active_spki_sha256, secondary_spki_sha256,
                            retirement_floor_unix_ms, created_at
                        ) VALUES (1, 1, 2, ?, ?, ?, 'stableRenewal', ?, NULL, 0, ?)
                        """,
                    arguments: [
                        currentObjectID,
                        nextBytes,
                        nextObjectID,
                        Data(repeating: 0xA8, count: 32),
                        HarcHostStore.unixTime(capabilityExpiresAt),
                    ]
                )
            }
            return try HostBackgroundCapabilityTransportSnapshot(
                absoluteUploadURL: try #require(
                    URL(string: "https://harc-mini.local:7443\(httpPath)")
                ),
                currentTransportSetEpoch: 1,
                exactSignedTransportSet: exactSignedTransportSet
            )
        }
    }

    private struct StartedUpload {
        let directory: URL
        let fixture: HostTestFixture
        let store: HarcHostStore
        let grant: DeviceGrantClaims
        let context: AuthenticatedDeviceContext
        let uploadID: UploadID
        let profile: FrozenUploadProfile
        let descriptor: LogicalChunkDescriptor
        let issuedAt: Date
        let exactSignedTransportSet: Data
        let transportObjectID: Data
    }

    private struct PersistenceFacts: Sendable {
        let credentialBinding: Data
        let parentGrantID: String
        let parentGeneration: Int64
        let libraryID: String
        let hostAuthorityID: Data
        let minimumEpoch: Int64
        let method: String
        let path: String
        let bodyHash: Data
        let bodyLength: Int64
        let byteCeiling: Int64
        let descriptor: ImmutableAudioBatchDescriptor
        let batchCount: Int
        let capabilityCount: Int
        let bindingCount: Int
    }

    private func startUpload(
        grantExpiresAt: Date? = nil
    ) async throws -> StartedUpload {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        let issuedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { issuedAt }
        )
        let grant = try fixture.grant(expiresAt: grantExpiresAt)
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("background-grant".utf8)
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

        let exactSignedTransportSet = Data("exact-signed-transport-set".utf8)
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
        return StartedUpload(
            directory: directory,
            fixture: fixture,
            store: store,
            grant: grant,
            context: context,
            uploadID: uploadID,
            profile: profile,
            descriptor: descriptor,
            issuedAt: issuedAt,
            exactSignedTransportSet: exactSignedTransportSet,
            transportObjectID: transportObjectID
        )
    }

    private func request(
        for upload: StartedUpload,
        batchID: AudioBatchID = .random(),
        generation: UploadGeneration = .initial,
        profileSHA256: UploadProfileSHA256? = nil,
        chunkBinding: HostBackgroundChunkBinding? = nil,
        bodySHA256: ImmutableBatchSHA256? = nil,
        requestedExpiresAt: Date? = nil
    ) throws -> HostBackgroundCapabilityMintRequest {
        try HostBackgroundCapabilityMintRequest(
            uploadID: upload.uploadID,
            generation: generation,
            uploadProfileSHA256: profileSHA256 ?? upload.profile.profileSHA256,
            batchID: batchID,
            chunks: [chunkBinding ?? HostBackgroundChunkBinding(
                chunkIndex: upload.descriptor.chunkIndex,
                encodedSHA256: upload.descriptor.encodedSHA256
            )],
            exactBatchBodySHA256: bodySHA256 ?? ImmutableBatchSHA256(
                Data(repeating: 0xB1, count: 32)
            ),
            exactBatchBodyLength: 64,
            requestedExpiresAt: requestedExpiresAt
                ?? upload.issuedAt.addingTimeInterval(20 * 24 * 60 * 60)
        )
    }

    private func randomness(
        _ uuid: String,
        byte: UInt8
    ) -> FixedRandomness {
        FixedRandomness(
            capabilityID: UUID(uuidString: uuid)!,
            secret: Data(repeating: byte, count: 32)
        )
    }

    private func counts(in store: HarcHostStore) async throws -> (Int, Int, Int) {
        try await store.dbQueue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM upload_batches") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM background_capabilities") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM background_capability_bindings") ?? -1
            )
        }
    }

    @Test("mint persists only the credential binding and exact replay mints a fresh narrow capability")
    func durableBindingAndExactReplay() async throws {
        let upload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: upload.directory) }
        let batchID = AudioBatchID.random()
        let request = try request(for: upload, batchID: batchID)
        let provider = FixedTransportProvider(
            exactSignedTransportSet: upload.exactSignedTransportSet
        )
        let first = try await upload.store.mintBackgroundCapability(
            context: upload.context,
            request: request,
            transportSnapshotProvider: provider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000701",
                byte: 0x71
            ),
            at: upload.issuedAt
        )

        var bindingInput = Data("HARC-UPLOAD-CAPABILITY-V1\0".utf8)
        bindingInput.append(first.opaqueCapabilityCredential)
        let expectedBinding = Data(SHA256.hash(data: bindingInput))
        let facts = try await upload.store.dbQueue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: """
                    SELECT capability.capability_binding_sha256,
                           capability.grant_id, capability.generation,
                           binding.library_id, binding.host_authority_id,
                           binding.minimum_transport_set_epoch,
                           binding.http_method, binding.http_path,
                           binding.exact_body_sha256,
                           binding.exact_body_length, binding.byte_ceiling,
                           batch.descriptor_json
                      FROM background_capabilities AS capability
                      JOIN background_capability_bindings AS binding
                        ON binding.capability_id = capability.capability_id
                      JOIN upload_batches AS batch
                        ON batch.batch_id = capability.batch_id
                     WHERE capability.capability_id = ?
                    """,
                arguments: [first.capabilityID.uuidString.lowercased()]
            ))
            return PersistenceFacts(
                credentialBinding: row["capability_binding_sha256"],
                parentGrantID: row["grant_id"],
                parentGeneration: row["generation"],
                libraryID: row["library_id"],
                hostAuthorityID: row["host_authority_id"],
                minimumEpoch: row["minimum_transport_set_epoch"],
                method: row["http_method"],
                path: row["http_path"],
                bodyHash: row["exact_body_sha256"],
                bodyLength: row["exact_body_length"],
                byteCeiling: row["byte_ceiling"],
                descriptor: try HarcHostStore.decode(
                    ImmutableAudioBatchDescriptor.self,
                    from: row["descriptor_json"]
                ),
                batchCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM upload_batches"
                ) ?? -1,
                capabilityCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM background_capabilities"
                ) ?? -1,
                bindingCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM background_capability_bindings"
                ) ?? -1
            )
        }

        #expect(first.opaqueCapabilityCredential.count == 48)
        #expect(facts.credentialBinding == expectedBinding)
        #expect(facts.credentialBinding != first.opaqueCapabilityCredential)
        #expect(facts.credentialBinding != Data(repeating: 0x71, count: 32))
        #expect(facts.parentGrantID == upload.grant.grantID.description)
        #expect(facts.parentGeneration == 1)
        #expect(facts.libraryID == upload.fixture.libraryID.description)
        #expect(facts.hostAuthorityID == upload.fixture.metadata.hostAuthorityID.rawBytes)
        #expect(facts.minimumEpoch == 1)
        #expect(facts.method == "PUT")
        #expect(facts.path == "/v1/uploads/\(upload.uploadID)/batches/\(batchID)")
        #expect(facts.bodyHash == request.exactBatchBodySHA256.rawBytes)
        #expect(facts.bodyLength == 64)
        #expect(facts.byteCeiling == 64)
        #expect(facts.descriptor.uploadProfileSHA256 == upload.profile.profileSHA256)
        #expect(facts.descriptor.originRecordingID == upload.descriptor.originRecordingID)
        #expect(facts.descriptor.chunks == [upload.descriptor])
        #expect(first.httpMethod == "PUT")
        #expect(first.httpPath == facts.path)
        #expect(first.minimumTransportSetEpoch == 1)
        #expect(first.exactSignedTransportSet == upload.exactSignedTransportSet)
        #expect(first.absoluteUploadURL.host == "harc-mini.local")

        let second = try await upload.store.mintBackgroundCapability(
            context: upload.context,
            request: request,
            transportSnapshotProvider: provider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000702",
                byte: 0x72
            ),
            at: upload.issuedAt
        )
        #expect(second.capabilityID != first.capabilityID)
        #expect(second.opaqueCapabilityCredential != first.opaqueCapabilityCredential)
        #expect(try await counts(in: upload.store) == (1, 2, 2))

        let conflicting = try self.request(
            for: upload,
            batchID: batchID,
            bodySHA256: ImmutableBatchSHA256(Data(repeating: 0xB2, count: 32))
        )
        await #expect(throws: HarcHostError.replayConflict) {
            _ = try await upload.store.mintBackgroundCapability(
                context: upload.context,
                request: conflicting,
                transportSnapshotProvider: provider,
                randomness: self.randomness(
                    "00000000-0000-0000-0000-000000000703",
                    byte: 0x73
                ),
                at: upload.issuedAt
            )
        }
        #expect(try await counts(in: upload.store) == (1, 2, 2))
    }

    @Test("expiry clamps to policy and live grant before transport reservation")
    func expiryClamping() async throws {
        let policyUpload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: policyUpload.directory) }
        let policyProvider = RecordingTransportProvider(
            exactSignedTransportSet: policyUpload.exactSignedTransportSet
        )
        let policyResult = try await policyUpload.store.mintBackgroundCapability(
            context: policyUpload.context,
            request: try request(for: policyUpload),
            transportSnapshotProvider: policyProvider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000711",
                byte: 0x74
            ),
            at: policyUpload.issuedAt
        )
        let policyExpiry = policyUpload.issuedAt.addingTimeInterval(
            HostBackgroundCapabilityPolicy.defaultMaximumLifetime
        )
        #expect(policyResult.expiresAt == policyExpiry)
        #expect(policyResult.expiryWasClamped)
        #expect(await policyProvider.expiry() == policyExpiry)

        let grantFixture = HostTestFixture()
        let grantExpiry = grantFixture.beganAt.addingTimeInterval(
            2 * 24 * 60 * 60
        )
        let grantUpload = try await startUpload(grantExpiresAt: grantExpiry)
        defer { try? FileManager.default.removeItem(at: grantUpload.directory) }
        let grantProvider = RecordingTransportProvider(
            exactSignedTransportSet: grantUpload.exactSignedTransportSet
        )
        let grantResult = try await grantUpload.store.mintBackgroundCapability(
            context: grantUpload.context,
            request: try request(for: grantUpload),
            transportSnapshotProvider: grantProvider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000712",
                byte: 0x75
            ),
            at: grantUpload.issuedAt
        )
        #expect(grantResult.expiresAt == grantExpiry)
        #expect(grantResult.expiryWasClamped)
        #expect(await grantProvider.expiry() == grantExpiry)
    }

    @Test("authorization profile generation and chunk mismatches leave no capability state")
    func rejectedBindingsAreAtomic() async throws {
        let upload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: upload.directory) }
        let provider = FixedTransportProvider(
            exactSignedTransportSet: upload.exactSignedTransportSet
        )
        let fixedRandomness = randomness(
            "00000000-0000-0000-0000-000000000721",
            byte: 0x76
        )

        let wrongContext = AuthenticatedDeviceContext(
            libraryID: upload.fixture.libraryID,
            hostAuthorityID: upload.fixture.metadata.hostAuthorityID,
            authenticatedDeviceID: upload.fixture.deviceID,
            grantID: .random(),
            grantEpoch: upload.grant.grantEpoch
        )
        await #expect(throws: HarcHostError.grantMismatch) {
            _ = try await upload.store.mintBackgroundCapability(
                context: wrongContext,
                request: try self.request(for: upload),
                transportSnapshotProvider: provider,
                randomness: fixedRandomness,
                at: upload.issuedAt
            )
        }

        let wrongProfile = try UploadProfileSHA256(Data(repeating: 0xC1, count: 32))
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "uploadProfileSHA256"
        )) {
            _ = try await upload.store.mintBackgroundCapability(
                context: upload.context,
                request: try self.request(
                    for: upload,
                    profileSHA256: wrongProfile
                ),
                transportSnapshotProvider: provider,
                randomness: fixedRandomness,
                at: upload.issuedAt
            )
        }

        let staleGeneration = try UploadGeneration(2)
        await #expect(throws: TransferValidationError.staleUploadGeneration(
            expected: 1,
            actual: 2
        )) {
            _ = try await upload.store.mintBackgroundCapability(
                context: upload.context,
                request: try self.request(
                    for: upload,
                    generation: staleGeneration
                ),
                transportSnapshotProvider: provider,
                randomness: fixedRandomness,
                at: upload.issuedAt
            )
        }

        await #expect(throws: TransferValidationError.self) {
            _ = try await upload.store.mintBackgroundCapability(
                context: upload.context,
                request: try self.request(
                    for: upload,
                    chunkBinding: HostBackgroundChunkBinding(
                        chunkIndex: 1,
                        encodedSHA256: upload.descriptor.encodedSHA256
                    )
                ),
                transportSnapshotProvider: provider,
                randomness: fixedRandomness,
                at: upload.issuedAt
            )
        }

        let wrongChunkHash = try EncodedChunkSHA256(
            Data(repeating: 0xC2, count: 32)
        )
        await #expect(throws: TransferValidationError.profileMismatch(
            field: "backgroundChunk.encodedSHA256"
        )) {
            _ = try await upload.store.mintBackgroundCapability(
                context: upload.context,
                request: try self.request(
                    for: upload,
                    chunkBinding: HostBackgroundChunkBinding(
                        chunkIndex: upload.descriptor.chunkIndex,
                        encodedSHA256: wrongChunkHash
                    )
                ),
                transportSnapshotProvider: provider,
                randomness: fixedRandomness,
                at: upload.issuedAt
            )
        }
        #expect(try await counts(in: upload.store) == (0, 0, 0))
    }

    @Test("URL epoch mismatch and an in-flight transport transition fail closed")
    func transportSnapshotRaceAndURLValidation() async throws {
        let invalidURLUpload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: invalidURLUpload.directory) }
        let fixedRandomness = randomness(
            "00000000-0000-0000-0000-000000000731",
            byte: 0x77
        )

        await #expect(throws: HarcHostError.invalidAuthenticationInput(
            "backgroundCapabilityUploadURL"
        )) {
            _ = try await invalidURLUpload.store.mintBackgroundCapability(
                context: invalidURLUpload.context,
                request: try self.request(for: invalidURLUpload),
                transportSnapshotProvider: FixedTransportProvider(
                    exactSignedTransportSet:
                        invalidURLUpload.exactSignedTransportSet,
                    host: "192.0.2.1:7443"
                ),
                randomness: fixedRandomness,
                at: invalidURLUpload.issuedAt
            )
        }
        #expect(try await counts(in: invalidURLUpload.store) == (0, 0, 0))

        await #expect(throws: HarcHostError.transportSetTransitionInProgress) {
            _ = try await invalidURLUpload.store.mintBackgroundCapability(
                context: invalidURLUpload.context,
                request: try self.request(for: invalidURLUpload),
                transportSnapshotProvider: FixedTransportProvider(
                    exactSignedTransportSet:
                        invalidURLUpload.exactSignedTransportSet,
                    epoch: 2
                ),
                randomness: fixedRandomness,
                at: invalidURLUpload.issuedAt
            )
        }
        #expect(try await counts(in: invalidURLUpload.store) == (0, 0, 0))

        let racingUpload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: racingUpload.directory) }
        await #expect(throws: HarcHostError.transportSetTransitionInProgress) {
            _ = try await racingUpload.store.mintBackgroundCapability(
                context: racingUpload.context,
                request: try self.request(for: racingUpload),
                transportSnapshotProvider: TransitioningTransportProvider(
                    store: racingUpload.store,
                    exactSignedTransportSet: racingUpload.exactSignedTransportSet,
                    currentObjectID: racingUpload.transportObjectID
                ),
                randomness: fixedRandomness,
                at: racingUpload.issuedAt
            )
        }
        #expect(try await counts(in: racingUpload.store) == (0, 0, 0))
    }

    @Test("grant replacement and revocation invalidate minted capabilities")
    func securityMutationsInvalidateCapabilities() async throws {
        let upload = try await startUpload()
        defer { try? FileManager.default.removeItem(at: upload.directory) }
        let request = try request(for: upload)
        let provider = FixedTransportProvider(
            exactSignedTransportSet: upload.exactSignedTransportSet
        )
        let first = try await upload.store.mintBackgroundCapability(
            context: upload.context,
            request: request,
            transportSnapshotProvider: provider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000741",
                byte: 0x78
            ),
            at: upload.issuedAt
        )

        let current = try #require(
            try await upload.store.deviceRegistryEntry(
                deviceID: upload.fixture.deviceID
            )
        )
        let replacement = try current.replacingScopesAfterLocalAuthorization(
            Set(current.currentScopes),
            issuedAt: upload.issuedAt
        )
        try await upload.store.replaceDeviceGrant(
            replacement.grant,
            exactGrantBytes: Data("replacement-background-grant".utf8)
        )
        let firstState = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, invalidated_at FROM background_capabilities WHERE capability_id = ?",
                arguments: [first.capabilityID.uuidString.lowercased()]
            )
        }
        #expect(firstState?["state"] as String? == "grant-replaced")
        #expect(firstState?["invalidated_at"] as Double? != nil)

        let replacementContext = upload.fixture.context(for: replacement.grant)
        let second = try await upload.store.mintBackgroundCapability(
            context: replacementContext,
            request: request,
            transportSnapshotProvider: provider,
            randomness: randomness(
                "00000000-0000-0000-0000-000000000742",
                byte: 0x79
            ),
            at: upload.issuedAt
        )
        try await upload.store.revokeDevice(
            upload.fixture.deviceID,
            revocationID: UUID(),
            reasonCode: "test-revocation",
            exactRevocationBytes: Data("background-revocation".utf8),
            issuedAt: upload.issuedAt.addingTimeInterval(1)
        )
        let secondState = try await upload.store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, invalidated_at FROM background_capabilities WHERE capability_id = ?",
                arguments: [second.capabilityID.uuidString.lowercased()]
            )
        }
        #expect(secondState?["state"] as String? == "revoked")
        #expect(secondState?["invalidated_at"] as Double? != nil)
        #expect(try await counts(in: upload.store) == (1, 2, 2))
    }
}
