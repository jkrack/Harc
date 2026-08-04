import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation

@MainActor
@Observable
final class HarcMobileTransferCoordinator {
    enum State: Equatable {
        case idle
        case encoding(recordingUUID: UUID)
        case waitingForPairing(pending: Int)
        case connecting(recordingUUID: UUID)
        case uploading(recordingUUID: UUID)
        case uploaded(recordingUUID: UUID)
        case codecQualificationRequired(recordingUUID: UUID)
        case retryNeeded(recordingUUID: UUID, message: String)
        case securityBlocked(recordingUUID: UUID, message: String)
    }

    private(set) var state: State = .idle
    private(set) var pendingCount = 0

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let locations: HarcMobileCaptureLocations
    private let routeURL: URL
    private var queue: [HarcMobileFinalizedMaster] = []
    private var queuedOrigins = Set<OriginRecordingID>()
    private var worker: Task<Void, Never>?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        locations: HarcMobileCaptureLocations,
        routeURL: URL
    ) {
        self.identity = identity
        self.store = store
        self.locations = locations
        self.routeURL = routeURL
    }

    func enqueue(_ master: HarcMobileFinalizedMaster) {
        guard queuedOrigins.insert(master.originRecordingID).inserted else {
            return
        }
        queue.append(master)
        pendingCount = max(pendingCount, queue.count)
        startWorkerIfNeeded()
    }

    func retryPending() {
        do {
            let pending = try store.recordingOutboxes().filter {
                $0.stateMachine.state != .committed
                    && $0.stateMachine.state != .securityBlocked
                    && $0.integrityBlock == nil
                    && $0.finalizedCapture.masterFileState == .present
            }
            pendingCount = pending.count
            for outbox in pending {
                let master = try Self.master(from: outbox.finalizedCapture)
                guard queuedOrigins.insert(master.originRecordingID).inserted
                else { continue }
                queue.append(master)
            }
            startWorkerIfNeeded()
        } catch {
            state = .retryNeeded(
                recordingUUID: UUID(),
                message: error.localizedDescription
            )
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer { worker = nil }
        while !queue.isEmpty {
            let master = queue.removeFirst()
            do {
                try await transfer(master)
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(0, pendingCount - 1)
                state = .uploaded(
                    recordingUUID: master.originRecordingID.recordingUUID
                )
            } catch HarcMobileTransferError.notPaired {
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(pendingCount, queue.count + 1)
                state = .waitingForPairing(pending: pendingCount)
                return
            } catch HarcMobileTransferError.codecNotQualified {
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(pendingCount, queue.count + 1)
                state = .codecQualificationRequired(
                    recordingUUID: master.originRecordingID.recordingUUID
                )
                return
            } catch let error as HarcMobileALACEncodingError {
                queuedOrigins.remove(master.originRecordingID)
                if case .encodingFailed = error {
                    pendingCount = max(pendingCount, queue.count + 1)
                    state = .codecQualificationRequired(
                        recordingUUID:
                            master.originRecordingID.recordingUUID
                    )
                    return
                }
                state = .retryNeeded(
                    recordingUUID: master.originRecordingID.recordingUUID,
                    message: String(describing: error)
                )
                return
            } catch {
                queuedOrigins.remove(master.originRecordingID)
                let outbox = try? store.recordingOutbox(
                    for: master.originRecordingID
                )
                if outbox?.stateMachine.state == .securityBlocked {
                    state = .securityBlocked(
                        recordingUUID:
                            master.originRecordingID.recordingUUID,
                        message: error.localizedDescription
                    )
                } else {
                    state = .retryNeeded(
                        recordingUUID:
                            master.originRecordingID.recordingUUID,
                        message: error.localizedDescription
                    )
                }
                return
            }
        }
    }

    private func transfer(_ master: HarcMobileFinalizedMaster) async throws {
        state = .encoding(
            recordingUUID: master.originRecordingID.recordingUUID
        )
        guard HarcMobileLosslessReleaseGate.selected == .cafALAC else {
            throw HarcMobileTransferError.codecNotQualified
        }
        let locations = locations
        let artifacts = try await Task.detached(priority: .utility) {
            try HarcMobileALACChunkEncoder().encode(
                master,
                locations: locations
            )
        }.value

        guard let snapshot = try store.activeAdoption() else {
            throw HarcMobileTransferError.notPaired
        }
        let adoption = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: identity.publicKey
        )
        let route: HarcMobileHostRoute
        do {
            route = try HarcMobileHostRouteStore.load(from: routeURL)
        } catch {
            throw HarcMobileTransferError.notPaired
        }
        state = .connecting(
            recordingUUID: master.originRecordingID.recordingUUID
        )
        let trust = HarcTransportTrustCoordinator(
            adoptedPersistence:
                HarcTransferStoreTransportTrustPersistenceV1(store: store)
        )
        let connection = try await HarcPinnedGRPCConnection.connect(
            host: route.host,
            port: Int(route.port),
            serverHostname: route.serverHostname,
            trustCoordinator: trust
        )
        do {
            let policy = try Self.capabilityPolicy()
            let client = HarcBootstrapClient(
                rpc: connection,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let negotiated = try await client.negotiateCapabilities(
                clientOffer: try Self.capabilityOffer(policy: policy),
                expectation: HarcBootstrapTrustExpectation(
                    adoption: adoption
                )
            )
            let session = try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: negotiated.negotiated,
                deviceSigner: identity
            )
            let profile = try Self.frozenProfile(
                negotiated: negotiated.negotiated
            )
            let outbox = try store.recordingOutbox(
                for: master.originRecordingID
            )
            let existingIntent = try store.uploadBeginIntent(
                for: master.originRecordingID
            )
            let uploadID = existingIntent?.intent.uploadID
                ?? outbox?.uploadID
                ?? .random()
            let chunks = try artifacts.map { artifact in
                let descriptor = try LogicalChunkDescriptor(
                    originRecordingID: master.originRecordingID,
                    chunkID: Self.chunkID(
                        origin: master.originRecordingID,
                        index: artifact.chunkIndex
                    ),
                    chunkIndex: artifact.chunkIndex,
                    canonicalStartFrame: artifact.canonicalStartFrame,
                    canonicalFrameCount: artifact.canonicalFrameCount,
                    encoding: .cafALAC,
                    encodedByteLength: artifact.encodedByteLength,
                    encodedSHA256: try EncodedChunkSHA256(
                        artifact.encodedSHA256
                    ),
                    canonicalDecodedByteLength:
                        artifact.canonicalDecodedByteLength,
                    canonicalDecodedSHA256: try CanonicalPCMHash(
                        artifact.canonicalDecodedSHA256
                    )
                )
                return try HarcForegroundEncodedChunk(
                    descriptor: descriptor,
                    encodedFileURL: artifact.encodedFileURL
                )
            }
            let plan = try HarcForegroundRecordingUploadPlan(
                trustTuple: AdoptedTrustTuple(
                    libraryID: adoption.hostTrust.libraryID,
                    hostAuthorityID: adoption.hostTrust.hostAuthorityID
                ),
                uploadID: uploadID,
                originRecordingID: master.originRecordingID,
                frozenProfile: profile,
                chunks: chunks
            )
            state = .uploading(
                recordingUUID: master.originRecordingID.recordingUUID
            )
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: store,
                transport: connection
            )
            _ = try await uploader.drive(
                plan,
                openedSession: session,
                deviceSigner: identity
            )
            try await connection.shutdownGracefully()
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private static func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
    }

    private static func capabilityOffer(
        policy: HarcCapabilityPolicyV1
    ) throws -> HarcValidatedCapabilityOfferV1 {
        var offer = Harc_V1_CapabilityOfferV1()
        offer.protocolMajor = 1
        offer.minimumProtocolMinor = 0
        offer.maximumProtocolMinor = 0
        offer.supportedDescriptorSchemaIds = [
            ChunkDescriptorSchema.v1.rawValue,
        ]
        offer.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.cafALAC),
        ]
        offer.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return try HarcValidatedCapabilityOfferV1(offer, policy: policy)
    }

    private static func frozenProfile(
        negotiated: HarcValidatedNegotiatedCapabilitiesV1
    ) throws -> FrozenUploadProfile {
        let protocolVersion = try TransferProtocolVersion(
            minor: negotiated.protocolVersion.minor
        )
        let capabilities = try negotiated.selectedFeatureIDs
            .map(TransferCapabilityID.init)
            .sorted()
        let negotiatedDigest = try NegotiatedCapabilitiesSHA256(
            negotiated.exactSHA256
        )
        let provisional = try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                Data(repeating: 0, count: 32)
            ),
            purpose: .production
        )
        let exact = try HarcExactProtobufPayload(
            serializingOnce: Harc_V1_UploadProfileV1(provisional)
        )
        return try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                HarcSignedEnvelopeV1.payloadDigest(exact.exactBytes)
            ),
            purpose: .production
        )
    }

    private static func chunkID(
        origin: OriginRecordingID,
        index: UInt32
    ) -> ChunkID {
        var input = Data("harc-mobile-chunk-id-v1".utf8)
        input.append(origin.deviceID.rawBytes)
        input.append(Data(origin.recordingUUID.uuidString.lowercased().utf8))
        var bigEndianIndex = index.bigEndian
        withUnsafeBytes(of: &bigEndianIndex) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return ChunkID(uuid)
    }

    private static func master(
        from stored: StoredFinalizedCapture
    ) throws -> HarcMobileFinalizedMaster {
        let capture = stored.capture
        let reason: HarcMobileCaptureFinalizationReason =
            switch capture.finalizationReason {
            case .userStopped: .userStopped
            case .systemEnded: .systemEnded
            case .recoveredDurablePrefix: .recoveredDurablePrefix
            case .storageExhausted: .storageExhausted
            case .writerFailure: .writerFailure
            }
        return try HarcMobileFinalizedMaster(
            producingDeviceID: capture.producingDeviceID,
            originRecordingID: capture.originRecordingID,
            masterFileURL: stored.masterFileURL,
            captureStartedAt: capture.captureStartedAt,
            captureEndedAt: capture.captureEndedAt,
            captureStartedMonotonicNanoseconds:
                capture.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                capture.captureEndedMonotonicNanoseconds,
            finalizationReason: reason,
            totalCanonicalFrames: capture.totalCanonicalFrames,
            canonicalPCMSHA256: capture.canonicalPCMSHA256,
            discontinuities: capture.discontinuities
        )
    }
}

private enum HarcMobileTransferError: Error {
    case notPaired
    case codecNotQualified
}

/// This compile-time gate is deliberately closed until the physical-iPhone
/// matrix in the implementation spec freezes a release codec. Enabling it is
/// a reviewed release change backed by the signed qualification report.
private enum HarcMobileLosslessReleaseGate {
    #if HARC_MOBILE_QUALIFIED_CAF_ALAC
    static let selected: LosslessEncodingConfiguration? = .cafALAC
    #else
    static let selected: LosslessEncodingConfiguration? = nil
    #endif
}
