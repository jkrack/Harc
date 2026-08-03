#if canImport(Network)
import Foundation
@testable import HarcHost
@testable import HarcHostTransport
import Testing

@Suite("Resident background capability transport provider")
struct ResidentBackgroundCapabilityTransportProviderTests {
    @Test("reservation produces a canonical local HTTPS reachability hint")
    func canonicalURL() async throws {
        let reservation = BackgroundTransportReservationFake()
        let provider = try HarcResidentBackgroundCapabilityTransportProvider(
            transportReservation: reservation,
            dnsServiceTarget: "HARC-HOST.local",
            uploadPort: 7_444
        )
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)

        let snapshot = try await provider.reserveBackgroundCapabilityTransport(
            forHTTPPath: "/v1/uploads/u/batches/b",
            capabilityExpiresAt: expiry
        )

        #expect(
            snapshot.absoluteUploadURL.absoluteString
                == "https://harc-host.local:7444/v1/uploads/u/batches/b"
        )
        #expect(snapshot.currentTransportSetEpoch == 9)
        #expect(snapshot.exactSignedTransportSet == Data([0x09]))
        #expect(await reservation.capturedExpiry() == expiry)
    }

    @Test("numeric, nonlocal, malformed targets and invalid paths fail before reservation")
    func invalidHints() async throws {
        let reservation = BackgroundTransportReservationFake()
        for target in [
            "192.168.1.20",
            "host.example.com",
            "-host.local",
            "host-.local",
            "host..local",
            "host.local:7444",
        ] {
            #expect(throws: HarcResidentBackgroundCapabilityTransportProviderError.self) {
                try HarcResidentBackgroundCapabilityTransportProvider(
                    transportReservation: reservation,
                    dnsServiceTarget: target,
                    uploadPort: 7_444
                )
            }
        }
        #expect(throws: HarcResidentBackgroundCapabilityTransportProviderError.self) {
            try HarcResidentBackgroundCapabilityTransportProvider(
                transportReservation: reservation,
                dnsServiceTarget: "host.local",
                uploadPort: 0
            )
        }

        let provider = try HarcResidentBackgroundCapabilityTransportProvider(
            transportReservation: reservation,
            dnsServiceTarget: "host.local",
            uploadPort: 7_444
        )
        do {
            _ = try await provider.reserveBackgroundCapabilityTransport(
                forHTTPPath: "v1/uploads/u/batches/b?secret=x",
                capabilityExpiresAt: Date(timeIntervalSince1970: 2_000_000_000)
            )
            Issue.record("Expected an invalid background path to fail")
        } catch let error as HarcResidentBackgroundCapabilityTransportProviderError {
            #expect(error == .invalidHTTPPath)
        }
        #expect(await reservation.callCount() == 0)
    }
}

private actor BackgroundTransportReservationFake:
    HarcCapabilityTransportReserving
{
    private var expiry: Date?
    private var calls = 0

    func reserveTransportForBackgroundCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        self.expiry = expiry
        calls += 1
        return HostCapabilityTransportReservation(
            minimumTransportSetEpoch: 9,
            exactSignedTransportSet: Data([0x09]),
            retirementFloorUnixMilliseconds: 2_000_000_030_000
        )
    }

    func capturedExpiry() -> Date? { expiry }
    func callCount() -> Int { calls }
}
#endif
