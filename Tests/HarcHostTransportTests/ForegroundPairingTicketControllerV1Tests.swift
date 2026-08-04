#if canImport(Network)
import Foundation
import GRDB
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcProtocol
import Testing

@Suite("Foreground pairing ticket controller")
struct ForegroundPairingTicketControllerV1Tests {
    @Test("issue persists only the secret binding and cancel closes the ticket")
    func issueAndCancel() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()

        let presented = try await controller.issue(for: .mobile)
        let decoded = try PairingTicketV1.decodeURI(
            presented.pairingURI,
            atUnixMilliseconds: fixture.nowMilliseconds
        )
        #expect(decoded.ticketID == presented.ticketID)
        #expect(decoded.libraryID == fixture.libraryID)
        #expect(decoded.hostAuthorityID == fixture.authorityID)
        #expect(decoded.ticketSecret.count == 24)
        #expect(await fixture.reservation.expiry() == presented.expiresAt)

        let issued = try await fixture.ticketRow(presented.ticketID)
        #expect(issued.state == "issued")
        #expect(issued.binding == decoded.ticketSecretBindingSHA256)
        #expect(issued.binding != decoded.ticketSecret)

        try await controller.cancel()
        #expect(try await fixture.ticketRow(presented.ticketID).state == "cancelled")
    }

    @Test("issuing a replacement cancels the prior foreground ticket")
    func replacementCancelsPrior() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        let first = try await controller.issue(for: .macClient)
        let second = try await controller.issue(for: .mobile)

        #expect(first.ticketID != second.ticketID)
        #expect(try await fixture.ticketRow(first.ticketID).state == "cancelled")
        #expect(try await fixture.ticketRow(second.ticketID).state == "issued")
        try await controller.cancel()
    }

    @Test("an expired foreground ticket cannot wedge the next issue")
    func expiredTicketDoesNotWedgeReplacement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        let first = try await controller.issue(for: .mobile)
        fixture.clock.set(first.expiresAt.addingTimeInterval(1))

        let second = try await controller.issue(for: .mobile)
        #expect(try await fixture.ticketRow(first.ticketID).state == "expired")
        #expect(try await fixture.ticketRow(second.ticketID).state == "issued")
        try await controller.cancel()
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let store: HarcHostStore
    let key: SoftwareP256SigningKey
    let libraryID: LibraryID
    let stateID: HostStateID
    let reservation: TicketTransportReservationFake
    let clock: PairingControllerClock

    var nowMilliseconds: UInt64 { 2_000_000_000_125 }
    var authorityID: HostAuthorityID { key.publicKey.hostAuthorityID }
    var tuple: HostCryptographicStateTuple {
        HostCryptographicStateTuple(
            libraryID: libraryID,
            hostAuthorityID: authorityID,
            hostStateID: stateID
        )
    }

    init() async throws {
        let fixedNowMilliseconds: UInt64 = 2_000_000_000_125
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ForegroundPairingTicketTests-\(UUID().uuidString)",
            isDirectory: true
        )
        key = SoftwareP256SigningKey()
        libraryID = .random()
        stateID = .random()
        clock = PairingControllerClock(
            Date(timeIntervalSince1970: 2_000_000_000.125)
        )
        let expires = fixedNowMilliseconds + 10 * 60 * 1_000
        let transport = try VerifiedHostTransportSetV1.issue(
            libraryID: libraryID,
            hostAuthorityID: key.publicKey.hostAuthorityID,
            setEpoch: 7,
            issuedAtUnixMilliseconds: fixedNowMilliseconds - 1_000,
            entries: [
                try HostTransportEntryV1(
                    tlsSPKISHA256: Data(repeating: 0x31, count: 32),
                    notBeforeUnixMilliseconds: fixedNowMilliseconds - 1_000,
                    notAfterUnixMilliseconds: expires
                ),
            ],
            using: key
        )
        reservation = TicketTransportReservationFake(
            exactTransport: transport.exactSignedBytes
        )
        store = try await HarcHostStore.inMemory(
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            metadata: HarcHostMetadata(
                libraryID: libraryID,
                hostAuthorityID: key.publicKey.hostAuthorityID,
                hostStateID: stateID
            ),
            now: { [clock] in clock.read() }
        )
    }

    func controller() -> HarcForegroundPairingTicketControllerV1 {
        HarcForegroundPairingTicketControllerV1(
            hostStore: store,
            tuple: tuple,
            authorityPublicKey: key.publicKey,
            transportReservation: reservation,
            endpoints: [
                try! PairingEndpointV1(
                    kind: .bonjourInstance,
                    port: 0,
                    value: Data("Harc Test".utf8)
                ),
            ],
            now: { [clock] in clock.read() }
        )
    }

    func ticketRow(_ id: UUID) async throws -> (state: String, binding: Data) {
        try await store.dbReader.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT state, ticket_secret_binding_sha256 FROM pairing_tickets WHERE ticket_id = ?",
                arguments: [id.uuidString.lowercased()]
            )!
            return (row["state"], row["ticket_secret_binding_sha256"])
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class PairingControllerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor TicketTransportReservationFake: HarcCapabilityTransportReserving {
    let exactTransport: Data
    private var capturedExpiry: Date?

    init(exactTransport: Data) { self.exactTransport = exactTransport }

    func reserveTransportForBackgroundCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        capturedExpiry = expiry
        return HostCapabilityTransportReservation(
            minimumTransportSetEpoch: 7,
            exactSignedTransportSet: exactTransport,
            retirementFloorUnixMilliseconds: 0
        )
    }

    func expiry() -> Date? { capturedExpiry }
}
#endif
