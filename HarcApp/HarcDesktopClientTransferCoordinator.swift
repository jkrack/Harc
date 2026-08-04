import Combine
import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

@MainActor
final class HarcDesktopClientTransferCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case encoding(UUID)
        case waitingForPairing(pending: Int)
        case connecting(UUID)
        case uploading(UUID)
        case uploaded(UUID)
        case retryNeeded(UUID, String)
        case securityBlocked(UUID, String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var pendingCount = 0

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
        clientRoot: URL,
        routeURL: URL
    ) throws {
        self.identity = identity
        self.store = store
        locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: clientRoot
        )
        self.routeURL = routeURL
    }

    var statusMessage: String {
        switch state {
        case .idle:
            pendingCount == 0
                ? "Client storage ready"
                : "\(pendingCount) recording(s) waiting for Host"
        case .encoding:
            "Compressing a recording for Host"
        case .waitingForPairing(let pending):
            "\(pending) recording(s) waiting for Host pairing"
        case .connecting:
            "Connecting securely to Host"
        case .uploading:
            "Uploading a recording to Host"
        case .uploaded:
            pendingCount == 0
                ? "All Client recordings are on Host"
                : "\(pendingCount) recording(s) still waiting for Host"
        case .retryNeeded(_, let message):
            "Host transfer needs retry: \(message)"
        case .securityBlocked(_, let message):
            "Host transfer blocked for security: \(message)"
        }
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
            if pending.isEmpty { state = .idle }
            startWorkerIfNeeded()
        } catch {
            state = .retryNeeded(UUID(), error.localizedDescription)
        }
    }

    func shutdown() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        queuedOrigins.removeAll()
        state = .idle
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
            guard !Task.isCancelled else { return }
            let master = queue.removeFirst()
            do {
                try await transfer(master)
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(0, pendingCount - 1)
                state = .uploaded(
                    master.originRecordingID.recordingUUID
                )
            } catch HarcDesktopClientTransferError.notPaired {
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(pendingCount, queue.count + 1)
                state = .waitingForPairing(pending: pendingCount)
                return
            } catch is CancellationError {
                queuedOrigins.remove(master.originRecordingID)
                return
            } catch {
                queuedOrigins.remove(master.originRecordingID)
                let outbox = try? store.recordingOutbox(
                    for: master.originRecordingID
                )
                if outbox?.stateMachine.state == .securityBlocked {
                    state = .securityBlocked(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                } else {
                    state = .retryNeeded(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                }
                return
            }
        }
    }

    private func transfer(_ master: HarcMobileFinalizedMaster) async throws {
        state = .encoding(master.originRecordingID.recordingUUID)
        let locations = locations
        let artifacts = try await Task.detached(priority: .utility) {
            try HarcMobileALACChunkEncoder().encode(
                master,
                locations: locations
            )
        }.value

        state = .connecting(master.originRecordingID.recordingUUID)
        let opened: HarcDesktopOpenedHostConnection
        do {
            opened = try await HarcDesktopHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
        } catch HarcDesktopHostConnectionError.notPaired {
            throw HarcDesktopClientTransferError.notPaired
        }
        let connection = opened.connection
        do {
            let profile = try Self.frozenProfile(
                negotiated: opened.negotiated
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
                    libraryID: opened.adoption.hostTrust.libraryID,
                    hostAuthorityID:
                        opened.adoption.hostTrust.hostAuthorityID
                ),
                uploadID: uploadID,
                originRecordingID: master.originRecordingID,
                frozenProfile: profile,
                chunks: chunks
            )
            state = .uploading(master.originRecordingID.recordingUUID)
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: store,
                transport: connection
            )
            _ = try await uploader.drive(
                plan,
                openedSession: opened.session,
                deviceSigner: identity
            )
            try await connection.shutdownGracefully()
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
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
        var input = Data("harc-desktop-chunk-id-v1".utf8)
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

private enum HarcDesktopClientTransferError: Error {
    case notPaired
}
