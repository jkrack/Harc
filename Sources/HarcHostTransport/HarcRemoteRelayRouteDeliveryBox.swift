#if canImport(Network)
import Foundation
import HarcRemoteTransport
import HarcDomain

/// Bridges local approval to the pinned pairing-status response. Approved
/// device routes are keyed by the unguessable claim identifier and may be
/// redelivered after a Host restart until their bounded delivery lifetime ends.
package actor HarcRemoteRelayRouteDeliveryBox {
    private struct Entry: Sendable {
        let route: HarcRemoteRelayRouteV1
        let expiresAtMilliseconds: UInt64
    }

    private let persistence:
        (any HarcRemoteRelayRouteDeliveryPersistence)?
    private let nowMilliseconds: @Sendable () -> UInt64
    private var entries: [UUID: Entry] = [:]
    private var deviceBindings: [DeviceID: Entry] = [:]
    private var provisioningClaims = Set<UUID>()

    package init(
        persistence: (any HarcRemoteRelayRouteDeliveryPersistence)? = nil,
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            UInt64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        }
    ) {
        self.persistence = persistence
        self.nowMilliseconds = nowMilliseconds
    }

    package func save(
        _ route: HarcRemoteRelayRouteV1,
        forClaimID claimID: UUID,
        expiresAtMilliseconds: UInt64
    ) async throws {
        guard expiresAtMilliseconds > nowMilliseconds() else { return }
        try await persistence?.save(
            route,
            forClaimID: claimID,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        entries[claimID] = Entry(
            route: route,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }

    package func route(
        forClaimID claimID: UUID
    ) async throws -> HarcRemoteRelayRouteV1? {
        // Grant approval and Worker admission are separate durable systems.
        // Hold an approved status response briefly while the locally approved
        // route is being installed so the claimant cannot win that race and
        // persist an approval without its replacement relay route.
        for _ in 0 ..< 200 where provisioningClaims.contains(claimID) {
            try await Task.sleep(for: .milliseconds(50))
        }
        if let entry = entries[claimID] {
            guard entry.expiresAtMilliseconds > nowMilliseconds() else {
                entries.removeValue(forKey: claimID)
                try await persistence?.remove(forClaimID: claimID)
                return nil
            }
            return entry.route
        }
        guard let route = try await persistence?.load(
            forClaimID: claimID
        ) else { return nil }
        return route
    }

    package func remove(forClaimID claimID: UUID) async throws {
        entries.removeValue(forKey: claimID)
        try await persistence?.remove(forClaimID: claimID)
    }

    package func beginProvisioning(forClaimID claimID: UUID) {
        provisioningClaims.insert(claimID)
    }

    package func finishProvisioning(forClaimID claimID: UUID) {
        provisioningClaims.remove(claimID)
    }

    package func saveBinding(
        _ route: HarcRemoteRelayRouteV1,
        forDeviceID deviceID: DeviceID,
        expiresAtMilliseconds: UInt64
    ) async throws {
        guard expiresAtMilliseconds > nowMilliseconds() else { return }
        try await persistence?.saveBinding(
            route,
            forDeviceID: deviceID,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        deviceBindings[deviceID] = Entry(
            route: route,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }

    package func binding(
        forDeviceID deviceID: DeviceID
    ) async throws -> HarcRemoteRelayRouteV1? {
        if let entry = deviceBindings[deviceID] {
            guard entry.expiresAtMilliseconds > nowMilliseconds() else {
                deviceBindings.removeValue(forKey: deviceID)
                try await persistence?.removeBinding(forDeviceID: deviceID)
                return nil
            }
            return entry.route
        }
        return try await persistence?.loadBinding(forDeviceID: deviceID)
    }

    package func removeBinding(forDeviceID deviceID: DeviceID) async throws {
        deviceBindings.removeValue(forKey: deviceID)
        try await persistence?.removeBinding(forDeviceID: deviceID)
    }
}
#endif
