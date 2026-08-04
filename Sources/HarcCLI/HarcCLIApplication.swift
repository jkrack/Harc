import AVFoundation
import CryptoKit
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

public enum HarcCLIApplicationError: Error, CustomStringConvertible {
    case installationKeyLost
    case noAdoption
    case pairingRejected(String)
    case fixtureTooLarge

    public var description: String {
        switch self {
        case .installationKeyLost:
            "The CLI installation key is missing while prior state exists; refusing to create a replacement identity."
        case .noAdoption:
            "No adopted Host is stored. Pair this client first."
        case .pairingRejected(let state): "Pairing ended without approval: \(state)."
        case .fixtureTooLarge: "The requested fixture exceeds the V1 single-chunk limit."
        }
    }
}

@available(macOS 15.0, *)
public struct HarcCLIApplication {
    private static let keychainService = "com.harc.Harc.cli.installation-identity"
    private static let keychainAccount = "device-p256-signing-v1"

    public init() {}

    public func run(_ command: HarcCLICommand) async throws {
        switch command {
        case .help:
            print(Self.usage)
        case .discover(let timeout):
            try await discover(timeoutSeconds: timeout)
        case .pair(let ticket, let kind, let label, let stateDirectory):
            try await pair(
                ticketURI: ticket,
                clientKind: kind,
                deviceLabel: label,
                locations: HarcCLIStateLocations(override: stateDirectory)
            )
        case .status(let stateDirectory, let uploadID):
            try await status(
                locations: HarcCLIStateLocations(override: stateDirectory),
                uploadID: uploadID.map(UploadID.init)
            )
        case .uploadFixture(let seconds, let stateDirectory):
            try await uploadFixture(
                seconds: seconds,
                locations: HarcCLIStateLocations(override: stateDirectory)
            )
        case .qualifyCodecMatrix(let command):
            try qualifyCodecMatrix(command)
        }
    }

    private func qualifyCodecMatrix(
        _ command: HarcCodecQualificationMatrixCommand
    ) throws {
        let summary = try HarcCodecQualificationMatrixValidator.loadAndValidate(command)
        print("Codec qualification matrix passed.")
        print("Build: \(summary.buildSHA)")
        print("Version: \(summary.bundleShortVersion) (\(summary.bundleVersion))")
        for row in summary.rows {
            let memoryMiB = Double(row.maximumIncrementalResidentBytes) / 1_048_576
            let p95 = String(format: "%.1f", row.p95EncodingMilliseconds)
            let memory = String(format: "%.1f", memoryMiB)
            print(
                "\(row.role.label): \(row.deviceModel), \(row.operatingSystem), "
                    + "p95 \(p95) ms, "
                    + "queue \(row.maximumQueueDepth), "
                    + "memory \(memory) MiB, "
                    + "encoded \(row.totalEncodedBytes) bytes"
            )
        }
        print("Both candidates qualify on both devices; codec selection remains a reviewed release decision.")
    }

    private func discover(timeoutSeconds: Double) async throws {
        let browser = HarcBonjourDiscoveryBrowserV1()
        let stream = try await browser.start()
        let snapshot = await withTaskGroup(
            of: HarcBonjourDiscoverySnapshotV1?.self
        ) { group in
            group.addTask {
                for await event in stream {
                    if case .snapshot(let snapshot) = event,
                       !snapshot.candidates.isEmpty || snapshot.rejectedResultCount > 0 {
                        return snapshot
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(
                    for: .milliseconds(Int64(timeoutSeconds * 1_000))
                )
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await browser.cancel()
        guard let snapshot else {
            print("No Harc Hosts discovered within \(timeoutSeconds) seconds.")
            return
        }
        for candidate in snapshot.candidates {
            print(
                "\(candidate.hints.displayName)\t\(candidate.serviceName).\(candidate.domain)\tprotocol \(candidate.hints.protocolMajor).\(candidate.hints.protocolMinor)\tuntrusted route candidate"
            )
        }
        if snapshot.rejectedResultCount > 0 {
            print("Rejected malformed Bonjour results: \(snapshot.rejectedResultCount)")
        }
    }

    private func pair(
        ticketURI: String,
        clientKind: AdoptedClientKind,
        deviceLabel: String?,
        locations: HarcCLIStateLocations
    ) async throws {
        let nowMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        let ticket = try PairingTicketV1.decodeURI(
            ticketURI,
            atUnixMilliseconds: nowMS
        )
        let route = try HarcCLIRoute(ticket: ticket)
        let identity = try await resolveIdentity(locations: locations)
        let store = try HarcTransferStore(
            rootDirectory: locations.root,
            installationDeviceID: identity.deviceID
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: ticket.exactTransportObjectBytes,
            hostAuthorityPublicKey: ticket.hostAuthorityPublicKey
        )
        let connection = try await HarcPinnedGRPCConnection.connect(
            host: route.host,
            port: Int(route.port),
            serverHostname: route.serverHostname,
            trustCoordinator: coordinator
        )
        do {
            let policy = try Self.productionCapabilityPolicy()
            let client = HarcBootstrapClient(
                rpc: connection,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let presentation = try await client.beginPairing(
                ticket: ticket,
                deviceSigner: identity,
                requestedScopes: ScopePolicy.minimalScopes(for: clientKind),
                deviceLabel: deviceLabel ?? Host.current().localizedName ?? "Harc CLI"
            )
            print("Host: \(presentation.hostDisplayName)")
            print("Security words: \(presentation.sas.displayedPhrase)")
            print("Compare these exact four words on the Host, then approve there.")

            while true {
                switch try await client.getPairingStatus() {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .approved(let adoption):
                    _ = try store.adopt(adoption)
                    try HarcCLIRouteStore.save(route, to: locations.route)
                    print("Paired. Device ID: \(identity.deviceID)")
                    try await connection.shutdownGracefully()
                    return
                case .denied:
                    throw HarcCLIApplicationError.pairingRejected("denied")
                case .expired:
                    throw HarcCLIApplicationError.pairingRejected("expired")
                case .cancelled:
                    throw HarcCLIApplicationError.pairingRejected("cancelled")
                }
            }
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private func status(
        locations: HarcCLIStateLocations,
        uploadID: UploadID?
    ) async throws {
        let connected = try await reconnect(locations: locations)
        do {
            print("Host: \(connected.negotiated.hostInfo.displayName)")
            print("Library ID: \(connected.adoption.hostTrust.libraryID)")
            print("Device ID: \(connected.identity.deviceID)")
            print("Transport epoch: \(connected.adoption.transportSet.epoch)")
            print("Grant epoch: \(connected.adoption.grant.registryEpoch)")
            if let uploadID {
                let statusClient = try HarcRecordingStatusClientV1(
                    transport: connected.connection,
                    openedSession: connected.session
                )
                let response = try await statusClient.status(uploadID: uploadID)
                print("Upload: \(response.uploadID)")
                print("Ingest: \(response.ingestState)")
                if let processing = response.processing {
                    print("Processing: \(processing.state)")
                }
            } else {
                print("Session: authenticated")
            }
            try await connected.connection.shutdownGracefully()
        } catch {
            await connected.connection.shutdownImmediately()
            throw error
        }
    }

    private func uploadFixture(
        seconds: Double,
        locations: HarcCLIStateLocations
    ) async throws {
        let connected = try await reconnect(locations: locations)
        do {
            let fixture = try Self.makeFixture(
                seconds: seconds,
                identity: connected.identity,
                negotiated: connected.negotiated.negotiated,
                locations: locations
            )
            _ = try connected.store.persistFinalizedCapture(
                fixture.capture,
                masterFileURL: fixture.encodedFileURL
            )
            let plan = try HarcForegroundRecordingUploadPlan(
                trustTuple: AdoptedTrustTuple(
                    libraryID: connected.adoption.hostTrust.libraryID,
                    hostAuthorityID: connected.adoption.hostTrust.hostAuthorityID
                ),
                uploadID: fixture.uploadID,
                originRecordingID: fixture.capture.originRecordingID,
                frozenProfile: fixture.profile,
                chunks: [try HarcForegroundEncodedChunk(
                    descriptor: fixture.descriptor,
                    encodedFileURL: fixture.encodedFileURL
                )]
            )
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: connected.store,
                transport: connected.connection
            )
            let receipt = try await uploader.drive(
                plan,
                openedSession: connected.session,
                deviceSigner: connected.identity
            )
            print("Upload receipt verified: \(receipt.uploadID)")
            print("Canonical recording: \(receipt.canonicalRecordingID)")

            let statusClient = try HarcRecordingStatusClientV1(
                transport: connected.connection,
                openedSession: connected.session
            )
            let response = try await statusClient.status(
                uploadID: fixture.uploadID
            )
            print("Ingest: \(response.ingestState)")
            if let processing = response.processing {
                print("Processing: \(processing.state)")
            }
            try await connected.connection.shutdownGracefully()
        } catch {
            await connected.connection.shutdownImmediately()
            throw error
        }
    }

    private func reconnect(
        locations: HarcCLIStateLocations
    ) async throws -> ConnectedClient {
        let identity = try await resolveIdentity(locations: locations)
        let store = try HarcTransferStore(
            rootDirectory: locations.root,
            installationDeviceID: identity.deviceID
        )
        guard let snapshot = try store.activeAdoption() else {
            throw HarcCLIApplicationError.noAdoption
        }
        let adoption = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: identity.publicKey
        )
        let route = try HarcCLIRouteStore.load(from: locations.route)
        let trust = HarcTransportTrustCoordinator(
            adoptedPersistence: HarcTransferStoreTransportTrustPersistenceV1(
                store: store
            )
        )
        let connection = try await HarcPinnedGRPCConnection.connect(
            host: route.host,
            port: Int(route.port),
            serverHostname: route.serverHostname,
            trustCoordinator: trust
        )
        do {
            let policy = try Self.productionCapabilityPolicy()
            let client = HarcBootstrapClient(
                rpc: connection,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let negotiated = try await client.negotiateCapabilities(
                clientOffer: try Self.productionCapabilityOffer(policy: policy),
                expectation: HarcBootstrapTrustExpectation(adoption: adoption)
            )
            let session = try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: negotiated.negotiated,
                deviceSigner: identity
            )
            return ConnectedClient(
                identity: identity,
                store: store,
                adoption: adoption,
                negotiated: negotiated,
                session: session,
                connection: connection
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private func resolveIdentity(
        locations: HarcCLIStateLocations
    ) async throws -> InstallationSigningIdentity {
        let clientLocations = try ClientStoreLocations(rootDirectory: locations.root)
        let priorState = FileManager.default.fileExists(atPath: locations.route.path)
            || FileManager.default.fileExists(atPath: clientLocations.transferDatabase.path)
        let manager = InstallationIdentityManager(
            keyStore: KeychainSoftwareInstallationKeyStore(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        )
        switch try await manager.resolve(evidence: InstallationIdentityEvidence(
            hasPriorIdentityState: priorState
        )) {
        case .available(let identity, _): return identity
        case .keyLoss: throw HarcCLIApplicationError.installationKeyLost
        }
    }

    private static func productionCapabilityPolicy() throws
        -> HarcCapabilityPolicyV1
    {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue],
            supportedEncodings: [.cafALAC]
        )
    }

    private static func productionCapabilityOffer(
        policy: HarcCapabilityPolicyV1
    ) throws -> HarcValidatedCapabilityOfferV1 {
        var offer = Harc_V1_CapabilityOfferV1()
        offer.protocolMajor = 1
        offer.minimumProtocolMinor = 0
        offer.maximumProtocolMinor = 0
        offer.supportedDescriptorSchemaIds = [ChunkDescriptorSchema.v1.rawValue]
        offer.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.cafALAC),
        ]
        offer.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return try HarcValidatedCapabilityOfferV1(offer, policy: policy)
    }

    private static func makeFixture(
        seconds: Double,
        identity: InstallationSigningIdentity,
        negotiated: HarcValidatedNegotiatedCapabilitiesV1,
        locations: HarcCLIStateLocations
    ) throws -> Fixture {
        let frameCount = Int((seconds * 16_000).rounded(.down))
        guard frameCount > 0,
              UInt64(frameCount) <= TransferLimits.ordinaryChunkFrames else {
            throw HarcCLIApplicationError.fixtureTooLarge
        }
        let samples: [Int16] = (0 ..< frameCount).map { frame in
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / 16_000.0
            return Int16((sin(phase) * 8_000.0).rounded())
        }
        var canonicalPCM = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample).littleEndian
            canonicalPCM.append(UInt8(truncatingIfNeeded: bits))
            canonicalPCM.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        let canonicalHash = try CanonicalPCMHash(
            Data(SHA256.hash(data: canonicalPCM))
        )
        let origin = identity.originRecordingID()
        let began = Date()
        let ended = began.addingTimeInterval(Double(frameCount) / 16_000.0)
        let capture = try FinalizedCapture(
            producingDeviceID: identity.deviceID,
            originRecordingID: origin,
            captureStartedAt: began,
            captureEndedAt: ended,
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: UInt64(
                (Double(frameCount) / 16_000.0) * 1_000_000_000
            ),
            finalizationReason: .userStopped,
            totalCanonicalFrames: UInt64(frameCount),
            totalCanonicalBytes: UInt64(canonicalPCM.count),
            canonicalPCMSHA256: canonicalHash,
            discontinuities: []
        )
        try FileManager.default.createDirectory(
            at: locations.captures,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encodedURL = locations.captures.appendingPathComponent(
            "\(origin.recordingUUID.uuidString.lowercased()).caf"
        )
        try writeCAFALAC(samples: samples, to: encodedURL)
        let encodedBytes = try Data(contentsOf: encodedURL)
        let descriptor = try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: .random(),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: UInt64(frameCount),
            encoding: .cafALAC,
            encodedByteLength: UInt64(encodedBytes.count),
            encodedSHA256: try EncodedChunkSHA256(
                Data(SHA256.hash(data: encodedBytes))
            ),
            canonicalDecodedByteLength: UInt64(canonicalPCM.count),
            canonicalDecodedSHA256: canonicalHash
        )
        return Fixture(
            uploadID: .random(),
            capture: capture,
            descriptor: descriptor,
            encodedFileURL: encodedURL,
            profile: try frozenProfile(negotiated: negotiated)
        )
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
            profileSHA256: try UploadProfileSHA256(Data(repeating: 0, count: 32)),
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

    private static func writeCAFALAC(samples: [Int16], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let bytes = samples.withUnsafeBytes { Data($0) }
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw HarcCLIApplicationError.fixtureTooLarge
        }
        bytes.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: bytes.count
        )
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
        try file.write(from: buffer)
    }

    public static let usage = """
    Usage: harcctl <command> [options]

      discover [--timeout SECONDS]
      pair --ticket HARC_PAIR_URI [--kind mac|mobile] [--label NAME] [--state-dir PATH]
      status [--upload UUID] [--state-dir PATH]
      upload-fixture [--seconds SECONDS] [--state-dir PATH]
      qualify-codec-matrix --oldest-device MODEL --current-device MODEL
        --build-sha SHA --team-id TEAM --version VERSION --build BUILD
        --oldest-alac PATH --oldest-flac PATH
        --current-alac PATH --current-flac PATH

    Pairing requires the exact four security words to match and local approval
    on the resident Host. Ticket secrets are never persisted.
    """
}

@available(macOS 15.0, *)
private struct ConnectedClient {
    let identity: InstallationSigningIdentity
    let store: HarcTransferStore
    let adoption: ValidatedClientAdoptionEvidence
    let negotiated: HarcNegotiatedBootstrapCapabilities
    let session: HarcOpenedClientSession
    let connection: HarcPinnedGRPCConnection
}

private struct Fixture {
    let uploadID: UploadID
    let capture: FinalizedCapture
    let descriptor: LogicalChunkDescriptor
    let encodedFileURL: URL
    let profile: FrozenUploadProfile
}
