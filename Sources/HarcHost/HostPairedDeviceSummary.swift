import Foundation
import GRDB
import HarcDomain
import HarcIdentity

/// Display-safe durable identity for one device in the Host security registry.
/// Private keys, exact grants, and local paths never cross this boundary.
public struct HostPairedDeviceSummary: Equatable, Sendable {
    public let label: String
    public let clientKind: AdoptedClientKind?
    public let deviceID: DeviceID
    public let status: DeviceRegistryStatus
    public let scopes: [AuthorizationScope]
    public let pairedAt: Date
    public let updatedAt: Date
    public let lastConnectedAt: Date?

    public init(
        label: String,
        clientKind: AdoptedClientKind?,
        deviceID: DeviceID,
        status: DeviceRegistryStatus,
        scopes: [AuthorizationScope],
        pairedAt: Date,
        updatedAt: Date,
        lastConnectedAt: Date?
    ) {
        self.label = label
        self.clientKind = clientKind
        self.deviceID = deviceID
        self.status = status
        self.scopes = scopes
        self.pairedAt = pairedAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

extension HarcHostStore {
    /// Returns the complete device registry for local Host-management UI.
    /// The latest pairing ticket supplies display-only client kind metadata;
    /// authorization continues to come exclusively from the registry entry.
    public func pairedDevices() async throws -> [HostPairedDeviceSummary] {
        try await repairSecurityRegistryOnReopen()
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.label, d.registry_entry_json, d.created_at,
                           d.updated_at,
                           (
                               SELECT pt.client_kind
                               FROM pairing_attempts pa
                               JOIN pairing_tickets pt
                                 ON pt.ticket_id = pa.ticket_id
                               WHERE pa.device_id = d.device_id
                                 AND pa.state = 'approved'
                               ORDER BY COALESCE(pa.terminal_at, pa.updated_at)
                                   DESC, pa.claim_id DESC
                               LIMIT 1
                           ) AS client_kind,
                           (
                               SELECT MAX(st.issued_at)
                               FROM session_tokens st
                               WHERE st.device_id = d.device_id
                           ) AS last_connected_at
                    FROM devices d
                    ORDER BY CASE d.status WHEN 'active' THEN 0 ELSE 1 END,
                             d.updated_at DESC,
                             d.device_id ASC
                    """
            )
            return try rows.map { row in
                let entry = try Self.decode(
                    DeviceRegistryEntry.self,
                    from: row["registry_entry_json"] as Data
                )
                let rawKind = row["client_kind"] as String?
                let clientKind = rawKind.flatMap(AdoptedClientKind.init(rawValue:))
                let storedLabel = (row["label"] as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackLabel = switch clientKind {
                case .some(.mobile): "iPhone"
                case .some(.macClient): "Mac client"
                case nil: "Unknown device"
                }
                let label = if let storedLabel, !storedLabel.isEmpty {
                    storedLabel
                } else {
                    fallbackLabel
                }
                return HostPairedDeviceSummary(
                    label: label,
                    clientKind: clientKind,
                    deviceID: entry.deviceID,
                    status: entry.status,
                    scopes: entry.currentScopes,
                    pairedAt: Self.date(row["created_at"] as Double),
                    updatedAt: Self.date(row["updated_at"] as Double),
                    lastConnectedAt: (row["last_connected_at"] as Double?)
                        .map(Self.date)
                )
            }
        }
    }
}
