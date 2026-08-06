import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import Testing
@testable import HarcHost

@Suite("Host paired-device summaries")
struct HostPairedDeviceSummaryTests {
    @Test("lists the durable label, client kind, fingerprint, and grant")
    func listsDurablePairedIdentity() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storedAt = fixture.beganAt.addingTimeInterval(10)
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { storedAt }
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("grant".utf8)
        )

        let ticketID = UUID()
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET label = ? WHERE device_id = ?",
                arguments: ["Office iPhone", fixture.deviceID.rawBytes]
            )
            try db.execute(
                sql: """
                    INSERT INTO pairing_tickets (
                        ticket_id, ticket_secret_binding_sha256, client_kind,
                        state, issued_at, expires_at, reserved_device_id,
                        updated_at
                    ) VALUES (?, ?, 'mobile', 'consumed', ?, ?, ?, ?)
                    """,
                arguments: [
                    ticketID.uuidString.lowercased(),
                    Data(repeating: 0x44, count: 32),
                    HarcHostStore.unixTime(storedAt.addingTimeInterval(-2)),
                    HarcHostStore.unixTime(storedAt.addingTimeInterval(120)),
                    fixture.deviceID.rawBytes,
                    HarcHostStore.unixTime(storedAt),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO pairing_attempts (
                        claim_id, ticket_id, device_id, state, created_at,
                        expires_at, updated_at
                    ) VALUES (?, ?, ?, 'approved', ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    ticketID.uuidString.lowercased(),
                    fixture.deviceID.rawBytes,
                    HarcHostStore.unixTime(storedAt.addingTimeInterval(-1)),
                    HarcHostStore.unixTime(storedAt.addingTimeInterval(120)),
                    HarcHostStore.unixTime(storedAt),
                ]
            )
        }

        let devices = try await store.pairedDevices()
        let device = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(device.label == "Office iPhone")
        #expect(device.clientKind == .mobile)
        #expect(device.deviceID == fixture.deviceID)
        #expect(device.status == .active)
        #expect(device.scopes == grant.scopes)
        #expect(device.pairedAt == storedAt)
        #expect(device.lastConnectedAt == nil)
    }
}
