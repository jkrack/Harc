import CryptoKit
import Foundation
import HarcDomain
@testable import HarcHost
import HarcIdentity
import HarcTransfer
import Testing

@Suite("Public host information service")
struct HostInfoServiceTests {
    @Test("GetHostInfo projects only public bootstrap facts and the exact current transport set")
    func publicProjection() async throws {
        let fixture = try await makeFixture(publishTransportSet: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = try HarcHostInfoService(
            store: fixture.store,
            displayName: "Studio Harc",
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            protocolBoundary: fixture.protocolBoundary
        )

        let response = try await service.getHostInfo(
            GetHostInfoRequest(
                protocolMajor: 1,
                protocolMinor: 0,
                source: try source(0x11)
            )
        )

        #expect(response.protocolMajor == 1)
        #expect(response.protocolMinor == 0)
        #expect(response.displayName == "Studio Harc")
        #expect(response.libraryID == fixture.metadata.libraryID)
        #expect(response.hostAuthorityID == fixture.metadata.hostAuthorityID)
        #expect(response.hostAuthorityPublicKey == fixture.hostKey.publicKey)
        #expect(response.offers == [fixture.offer])
        #expect(response.exactSignedTransportSet == fixture.exactTransportSet)
        #expect(response.serverTime == fixture.clock.read())
    }

    @Test("NegotiateCapabilities preserves the exact payload/hash and current transport set")
    func exactNegotiationProjection() async throws {
        let fixture = try await makeFixture(publishTransportSet: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = try HarcHostInfoService(
            store: fixture.store,
            displayName: "Studio Harc",
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            protocolBoundary: fixture.protocolBoundary
        )
        let request = try NegotiateHostCapabilitiesRequest(
            protocolMajor: 1,
            protocolMinor: 0,
            clientOffer: fixture.offer,
            source: try source(0x12)
        )

        let response = try await service.negotiateCapabilities(request)

        #expect(response.protocolMajor == 1)
        #expect(response.protocolMinor == 0)
        #expect(
            response.exactNegotiatedCapabilities
                == fixture.protocolBoundary.negotiated.exactBytes
        )
        #expect(
            response.negotiatedCapabilitiesSHA256
                == Data(SHA256.hash(
                    data: response.exactNegotiatedCapabilities
                ))
        )
        #expect(response.exactSignedTransportSet == fixture.exactTransportSet)
        #expect(response.serverTime == fixture.clock.read())
    }

    @Test("public requests require a current committed transport set and canonical identity")
    func readinessAndIdentityFailures() async throws {
        let absent = try await makeFixture(publishTransportSet: false)
        defer { try? FileManager.default.removeItem(at: absent.directory) }
        let service = try HarcHostInfoService(
            store: absent.store,
            displayName: "Studio Harc",
            hostAuthorityPublicKey: absent.hostKey.publicKey,
            protocolBoundary: absent.protocolBoundary
        )
        await #expect(throws: HarcHostError.transportSetNotInitialized) {
            try await service.getHostInfo(
                GetHostInfoRequest(
                    protocolMajor: 1,
                    protocolMinor: 0,
                    source: try source(0x13)
                )
            )
        }

        let anotherAuthority = SoftwareP256SigningKey()
        #expect(throws: HarcHostError.metadataMismatch) {
            try HarcHostInfoService(
                store: absent.store,
                displayName: "Studio Harc",
                hostAuthorityPublicKey: anotherAuthority.publicKey,
                protocolBoundary: absent.protocolBoundary
            )
        }
        #expect(throws: HarcHostError.invalidHostInfoInput("display name")) {
            try HarcHostInfoService(
                store: absent.store,
                displayName: " Studio Harc ",
                hostAuthorityPublicKey: absent.hostKey.publicKey,
                protocolBoundary: absent.protocolBoundary
            )
        }
    }

    @Test("a pending publication is not exposed as public bootstrap state")
    func pendingPublicationFailsClosed() async throws {
        let fixture = try await makeFixture(publishTransportSet: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await reserveTransportSet(fixture)
        let service = try HarcHostInfoService(
            store: fixture.store,
            displayName: "Studio Harc",
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            protocolBoundary: fixture.protocolBoundary
        )

        await #expect(throws: HarcHostError.transportSetTransitionInProgress) {
            try await service.getHostInfo(
                GetHostInfoRequest(
                    protocolMajor: 1,
                    protocolMinor: 0,
                    source: try source(0x14)
                )
            )
        }
    }

    @Test("GetHostInfo and negotiation share the frozen 60-request source window")
    func combinedPublicRateLimit() async throws {
        let fixture = try await makeFixture(publishTransportSet: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = try HarcHostInfoService(
            store: fixture.store,
            displayName: "Studio Harc",
            hostAuthorityPublicKey: fixture.hostKey.publicKey,
            protocolBoundary: fixture.protocolBoundary
        )
        let requestSource = try source(0x15)
        let hostInfo = GetHostInfoRequest(
            protocolMajor: 1,
            protocolMinor: 0,
            source: requestSource
        )
        let negotiation = try NegotiateHostCapabilitiesRequest(
            protocolMajor: 1,
            protocolMinor: 0,
            clientOffer: fixture.offer,
            source: requestSource
        )

        for _ in 0..<30 {
            _ = try await service.getHostInfo(hostInfo)
            _ = try await service.negotiateCapabilities(negotiation)
        }
        await #expect(throws: HarcHostError.publicHostInfoRateLimited) {
            try await service.getHostInfo(hostInfo)
        }

        fixture.clock.set(fixture.clock.read().addingTimeInterval(61))
        _ = try await service.getHostInfo(hostInfo)
    }

    @Test("capability projections reject noncanonical or incomplete advertisement facts")
    func capabilityProjectionValidation() throws {
        #expect(throws: HarcHostError.invalidHostInfoInput(
            "supported feature identifiers"
        )) {
            try HostInfoCapabilityOffer(
                protocolMajor: 1,
                minimumProtocolMinor: 0,
                maximumProtocolMinor: 0,
                supportedFeatureIDs: ["transfer.chunk.v1", "capture.gaps.v1"],
                supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
                supportedEncodings: [.cafALAC],
                supportedCanonicalFormats: [.harcV1]
            )
        }
        #expect(throws: HarcHostError.invalidHostInfoInput(
            "capability selection sets"
        )) {
            try HostInfoCapabilityOffer(
                protocolMajor: 1,
                minimumProtocolMinor: 0,
                maximumProtocolMinor: 0,
                requiredFeatureIDs: ["transfer.chunk.v1"],
                supportedFeatureIDs: [],
                supportedDescriptorSchemaIDs: [],
                supportedEncodings: [.cafALAC],
                supportedCanonicalFormats: [.harcV1]
            )
        }
    }

    private func makeFixture(
        publishTransportSet: Bool
    ) async throws -> HostInfoFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcHostInfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let hostKey = SoftwareP256SigningKey()
        let metadata = HarcHostMetadata(
            libraryID: .random(),
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostStateID: .random()
        )
        let clock = LockedHostClock(Date(timeIntervalSince1970: 2_000_000_000))
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory.appendingPathComponent("staging"),
            metadata: metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let offer = try HostInfoCapabilityOffer(
            protocolMajor: 1,
            minimumProtocolMinor: 0,
            maximumProtocolMinor: 0,
            requiredFeatureIDs: ["transfer.chunk.v1"],
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.cafALAC],
            supportedCanonicalFormats: [.harcV1]
        )
        let negotiated = try HostNegotiatedSessionCapabilities(
            exactBytes: Data([0x08, 0x01, 0x12, 0x11]),
            protocolMinor: 0,
            selectedCodec: LosslessEncodingConfiguration.cafALAC.codec.rawValue,
            selectedContainer:
                LosslessEncodingConfiguration.cafALAC.container.rawValue
        )
        let protocolBoundary = FixedHostInfoProtocolBoundary(
            offer: offer,
            negotiated: negotiated
        )
        let fixture = HostInfoFixture(
            directory: directory,
            hostKey: hostKey,
            metadata: metadata,
            clock: clock,
            store: store,
            offer: offer,
            protocolBoundary: protocolBoundary,
            exactTransportSet: Data("host-info-exact-transport-set".utf8)
        )
        if publishTransportSet {
            try await reserveTransportSet(fixture)
            let snapshot = try await store.transportDatabaseSnapshot()
            let pending = try #require(snapshot.pending)
            try await store.applyPendingTransportSetPublication(
                expected: pending,
                verified: try fixture.validatedTransportSet(),
                at: clock.read()
            )
        }
        return fixture
    }

    private func reserveTransportSet(_ fixture: HostInfoFixture) async throws {
        let verified = try fixture.validatedTransportSet()
        try await fixture.store.prepareTransportSetPublication(
            verified,
            kind: .initial,
            expectedActiveSPKISHA256: fixture.tlsSPKI,
            secondarySPKISHA256: nil,
            retirementFloorUnixMilliseconds: 0,
            at: fixture.clock.read()
        )
    }

    private func source(_ byte: UInt8) throws -> HostPreauthenticationSource {
        try HostPreauthenticationSource(
            bindingSHA256: Data(repeating: byte, count: SHA256.Digest.byteCount)
        )
    }
}

private struct FixedHostInfoProtocolBoundary: HostInfoProtocolBoundary {
    let offer: HostInfoCapabilityOffer
    let negotiated: HostNegotiatedSessionCapabilities

    func validateProtocolVersion(major: UInt16, minor: UInt16) throws {
        guard major == 1, minor == 0 else {
            throw HarcHostError.invalidHostInfoInput("protocol version")
        }
    }

    func advertisedCapabilityOffers() throws -> [HostInfoCapabilityOffer] {
        [offer]
    }

    func negotiateCapabilities(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        clientOffer: HostInfoCapabilityOffer
    ) throws -> HostNegotiatedSessionCapabilities {
        guard clientOffer == offer,
              clientOffer.supports(
                  protocolMajor: protocolMajor,
                  protocolMinor: protocolMinor
              ) else {
            throw HarcHostError.invalidHostInfoInput("client capability offer")
        }
        return negotiated
    }
}

private struct HostInfoFixture {
    let directory: URL
    let hostKey: SoftwareP256SigningKey
    let metadata: HarcHostMetadata
    let clock: LockedHostClock
    let store: HarcHostStore
    let offer: HostInfoCapabilityOffer
    let protocolBoundary: FixedHostInfoProtocolBoundary
    let exactTransportSet: Data
    let tlsSPKI = Data(repeating: 0x44, count: 32)

    func validatedTransportSet() throws -> HostValidatedTransportSet {
        let nowMilliseconds = UInt64(
            clock.read().timeIntervalSince1970 * 1_000
        )
        return try HostValidatedTransportSet(
            exactSignedBytes: exactTransportSet,
            objectID: Data(repeating: 0x55, count: 32),
            libraryID: metadata.libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            setEpoch: 1,
            issuedAtUnixMilliseconds: nowMilliseconds,
            entries: [
                try HostValidatedTransportSetEntry(
                    tlsSPKISHA256: tlsSPKI,
                    notBeforeUnixMilliseconds: nowMilliseconds - 300_000,
                    notAfterUnixMilliseconds:
                        nowMilliseconds + (30 * 86_400_000)
                ),
            ]
        )
    }
}
