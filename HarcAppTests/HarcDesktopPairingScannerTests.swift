@preconcurrency import AVFoundation
import Foundation
import HarcHost
import HarcIdentity
import HarcProtocol
import Testing
@testable import Harc

@Suite("Desktop pairing QR scanner")
struct HarcDesktopPairingScannerTests {
    @Test("accepts only bounded canonical v1 QR candidates")
    func candidateFilter() {
        #expect(HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/ABC_123-xyz"))
        #expect(!HarcDesktopPairingCodeFilter.accepts(""))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v2/ABC"))
        #expect(!HarcDesktopPairingCodeFilter.accepts(" harc-pair://v1/ABC"))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/ABC\n"))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/café"))
    }

    @Test("rejects payloads above the frozen QR byte limit")
    func byteLimit() {
        let prefix = HarcDesktopPairingCodeFilter.prefix
        let accepted = prefix + String(
            repeating: "A",
            count: HarcDesktopPairingCodeFilter.maximumUTF8ByteCount
                - prefix.utf8.count
        )
        #expect(HarcDesktopPairingCodeFilter.accepts(accepted))
        #expect(!HarcDesktopPairingCodeFilter.accepts(accepted + "A"))
    }

    @Test("normalizes only surrounding pasteboard whitespace")
    func pastedCandidate() {
        let link = "harc-pair://v1/ABC_123-xyz"
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(" \n\(link)\t")
                == link
        )
        #expect(HarcDesktopPairingCodeFilter.pastedCandidate(nil) == nil)
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(
                "harc-pair://v1/ABC 123"
            ) == nil
        )
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(
                "not-a-harc-link"
            ) == nil
        )
    }

    @Test("waits for a running output to publish QR capability")
    func metadataCapabilityPolicy() {
        #expect(
            HarcDesktopPairingMetadataPolicy.readiness(
                availableTypes: [],
                attempt: 0
            ) == .retry
        )
        #expect(
            HarcDesktopPairingMetadataPolicy.readiness(
                availableTypes: [],
                attempt: HarcDesktopPairingMetadataPolicy
                    .maximumAvailabilityAttempts
            ) == .unsupported
        )
        #expect(
            HarcDesktopPairingMetadataPolicy.readiness(
                availableTypes: [.face],
                attempt: 0
            ) == .unsupported
        )
        #expect(
            HarcDesktopPairingMetadataPolicy.readiness(
                availableTypes: [.face, .qr],
                attempt: 0
            ) == .ready([.qr])
        )
    }

    @Test("Mac client pairing request passes wire and Host claim bounds")
    @MainActor
    func macClientPairingScopeLimit() throws {
        let scopes = HarcDesktopClientPairingCoordinator.requestedScopes()

        #expect(scopes.count == 10)
        #expect(scopes.count <= HarcProtocolLimits.pairingRequestedScopes)
        #expect(scopes == scopes.sorted())
        #expect(Set(scopes).count == scopes.count)

        let hostKey = SoftwareP256SigningKey()
        let request = try BeginHostPairingClaimRequest(
            ticketID: UUID(),
            ticketSecret: Data(repeating: 0x11, count: 24),
            clientNonce: Data(repeating: 0x22, count: 32),
            devicePublicKey: SoftwareP256SigningKey().publicKey,
            requestedScopes: scopes,
            deviceLabel: "Work Mac",
            source: try HostPreauthenticationSource(
                bindingSHA256: Data(repeating: 0x33, count: 32)
            ),
            context: try HostPairingClaimContext(
                hostAuthorityPublicKey: hostKey.publicKey,
                tlsSPKISHA256: Data(repeating: 0x44, count: 32)
            )
        )
        #expect(request.requestedScopes == scopes)
    }

    @Test("forgetting a Host removes only the canonical saved route")
    func removeSavedHostRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HarcDesktopHostRouteStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let routeURL = root.appendingPathComponent("host-route.json")
        let route = try HarcDesktopHostRoute(
            host: "host.example.test",
            port: 8443
        )

        try HarcDesktopHostRouteStore.save(route, to: routeURL)
        #expect(try HarcDesktopHostRouteStore.load(from: routeURL) == route)

        try HarcDesktopHostRouteStore.removeIfPresent(at: routeURL)
        #expect(!FileManager.default.fileExists(atPath: routeURL.path))

        // Forget is deliberately idempotent so retrying after a partial UI
        // failure cannot resurrect or strand the client trust state.
        try HarcDesktopHostRouteStore.removeIfPresent(at: routeURL)
    }
}
