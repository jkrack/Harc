#if canImport(Network)
import Foundation
@testable import HarcHost
@testable import HarcHostTransport
import Testing

@Suite("Deferred background capability transport provider relay")
struct DeferredBackgroundCapabilityTransportProviderRelayTests {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A request waits for installation and then delegates exactly once")
    func requestBeforeInstall() async throws {
        let relay = HarcDeferredBackgroundCapabilityTransportProviderRelay()
        let reservation = DeferredBackgroundTransportReservationFake(
            epoch: 11,
            signedTransportSetByte: 0x11
        )
        let provider = try makeProvider(reservation: reservation)
        let request = Task {
            try await relay.reserveBackgroundCapabilityTransport(
                forHTTPPath: "/v1/uploads/before-install",
                capabilityExpiresAt: expiry
            )
        }

        await relay.waitUntilPendingRequestCountForTesting(1)
        #expect(await reservation.callCount() == 0)
        try await relay.install(provider)

        let snapshot = try await request.value
        #expect(
            snapshot.absoluteUploadURL.absoluteString
                == "https://relay-host.local:7444/v1/uploads/before-install"
        )
        #expect(snapshot.currentTransportSetEpoch == 11)
        #expect(snapshot.exactSignedTransportSet == Data([0x11]))
        #expect(await reservation.capturedExpiries() == [expiry])
    }

    @Test("Installation before a request delegates without queueing")
    func installBeforeRequest() async throws {
        let relay = HarcDeferredBackgroundCapabilityTransportProviderRelay()
        let reservation = DeferredBackgroundTransportReservationFake(
            epoch: 12,
            signedTransportSetByte: 0x12
        )
        try await relay.install(makeProvider(reservation: reservation))

        let snapshot = try await relay.reserveBackgroundCapabilityTransport(
            forHTTPPath: "/v1/uploads/installed",
            capabilityExpiresAt: expiry
        )

        #expect(snapshot.currentTransportSetEpoch == 12)
        #expect(snapshot.exactSignedTransportSet == Data([0x12]))
        #expect(await relay.pendingRequestCountForTesting() == 0)
        #expect(await reservation.callCount() == 1)
    }

    @Test("One installation releases every pending request")
    func manyWaiters() async throws {
        let relay = HarcDeferredBackgroundCapabilityTransportProviderRelay()
        let reservation = DeferredBackgroundTransportReservationFake(
            epoch: 13,
            signedTransportSetByte: 0x13
        )
        let requestCount = 32
        let requests = (0 ..< requestCount).map { index in
            Task {
                try await relay.reserveBackgroundCapabilityTransport(
                    forHTTPPath: "/v1/uploads/waiter-\(index)",
                    capabilityExpiresAt: expiry.addingTimeInterval(Double(index))
                )
            }
        }

        await relay.waitUntilPendingRequestCountForTesting(requestCount)
        #expect(await reservation.callCount() == 0)
        try await relay.install(makeProvider(reservation: reservation))

        var returnedURLs: Set<String> = []
        for request in requests {
            let snapshot = try await request.value
            returnedURLs.insert(snapshot.absoluteUploadURL.absoluteString)
        }
        #expect(returnedURLs.count == requestCount)
        #expect(await reservation.callCount() == requestCount)
        #expect(await relay.pendingRequestCountForTesting() == 0)
    }

    @Test("Cancellation removes a pending request and never reaches the provider")
    func cancellation() async throws {
        let relay = HarcDeferredBackgroundCapabilityTransportProviderRelay()
        let reservation = DeferredBackgroundTransportReservationFake(
            epoch: 14,
            signedTransportSetByte: 0x14
        )
        let request = Task {
            try await relay.reserveBackgroundCapabilityTransport(
                forHTTPPath: "/v1/uploads/cancelled",
                capabilityExpiresAt: expiry
            )
        }

        await relay.waitUntilPendingRequestCountForTesting(1)
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled pending request must fail with cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(await relay.pendingRequestCountForTesting() == 0)

        try await relay.install(makeProvider(reservation: reservation))
        #expect(await reservation.callCount() == 0)
        _ = try await relay.reserveBackgroundCapabilityTransport(
            forHTTPPath: "/v1/uploads/after-cancel",
            capabilityExpiresAt: expiry
        )
        #expect(await reservation.callCount() == 1)
    }

    @Test("Exact replay and a different duplicate installation are both rejected")
    func duplicateInstall() async throws {
        let relay = HarcDeferredBackgroundCapabilityTransportProviderRelay()
        let firstReservation = DeferredBackgroundTransportReservationFake(
            epoch: 15,
            signedTransportSetByte: 0x15
        )
        let secondReservation = DeferredBackgroundTransportReservationFake(
            epoch: 16,
            signedTransportSetByte: 0x16
        )
        let firstProvider = try makeProvider(reservation: firstReservation)
        try await relay.install(firstProvider)

        do {
            try await relay.install(firstProvider)
            Issue.record("An exact installation replay must be rejected")
        } catch let error as HarcDeferredBackgroundCapabilityTransportProviderRelayError {
            #expect(error == .providerAlreadyInstalled)
        }
        do {
            try await relay.install(makeProvider(reservation: secondReservation))
            Issue.record("A different provider must not replace the installed provider")
        } catch let error as HarcDeferredBackgroundCapabilityTransportProviderRelayError {
            #expect(error == .providerAlreadyInstalled)
        }

        let first = try await relay.reserveBackgroundCapabilityTransport(
            forHTTPPath: "/v1/uploads/replay",
            capabilityExpiresAt: expiry
        )
        let exactReplay = try await relay.reserveBackgroundCapabilityTransport(
            forHTTPPath: "/v1/uploads/replay",
            capabilityExpiresAt: expiry
        )
        #expect(first == exactReplay)
        #expect(first.currentTransportSetEpoch == 15)
        #expect(await firstReservation.callCount() == 2)
        #expect(await secondReservation.callCount() == 0)
    }

    private func makeProvider(
        reservation: any HarcCapabilityTransportReserving
    ) throws -> HarcResidentBackgroundCapabilityTransportProvider {
        try HarcResidentBackgroundCapabilityTransportProvider(
            transportReservation: reservation,
            dnsServiceTarget: "relay-host.local",
            uploadPort: 7_444
        )
    }
}

private actor DeferredBackgroundTransportReservationFake:
    HarcCapabilityTransportReserving
{
    private let epoch: UInt64
    private let signedTransportSetByte: UInt8
    private var expiries: [Date] = []

    init(epoch: UInt64, signedTransportSetByte: UInt8) {
        self.epoch = epoch
        self.signedTransportSetByte = signedTransportSetByte
    }

    func reserveTransportForBackgroundCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        expiries.append(expiry)
        return HostCapabilityTransportReservation(
            minimumTransportSetEpoch: epoch,
            exactSignedTransportSet: Data([signedTransportSetByte]),
            retirementFloorUnixMilliseconds: 2_000_000_030_000
        )
    }

    func capturedExpiries() -> [Date] { expiries }
    func callCount() -> Int { expiries.count }
}
#endif
