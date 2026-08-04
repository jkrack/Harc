import Foundation
import GRDB

/// The two process-owned ports that identify one resident host exposure.
///
/// The upload port is intentionally durable: background URLSession work may
/// outlive the process that minted its scoped capability. A normal restart
/// therefore reuses this exact pair instead of silently selecting new ports.
public struct HarcHostListenerPorts: Codable, Equatable, Sendable {
    public let controlPort: UInt16
    public let uploadPort: UInt16

    public init(controlPort: UInt16, uploadPort: UInt16) throws {
        guard controlPort > 0 else {
            throw HarcHostError.invalidListenerPort(field: "controlPort")
        }
        guard uploadPort > 0 else {
            throw HarcHostError.invalidListenerPort(field: "uploadPort")
        }
        guard controlPort != uploadPort else {
            throw HarcHostError.listenerPortsMustBeDistinct
        }
        self.controlPort = controlPort
        self.uploadPort = uploadPort
    }
}

extension HarcHostStore {
    /// Returns the exact persisted listener pair. A partial or malformed pair
    /// is a fail-closed HostDB corruption, never permission to choose anew.
    public func listenerPorts() async throws -> HarcHostListenerPorts? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT control_port, upload_port FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            let controlValue: Int64? = row["control_port"]
            let uploadValue: Int64? = row["upload_port"]
            switch (controlValue, uploadValue) {
            case (nil, nil):
                return nil
            case let (.some(control), .some(upload)):
                guard let controlPort = UInt16(exactly: control),
                      let uploadPort = UInt16(exactly: upload) else {
                    throw HarcHostError.listenerPortPersistenceConflict
                }
                do {
                    return try HarcHostListenerPorts(
                        controlPort: controlPort,
                        uploadPort: uploadPort
                    )
                } catch {
                    throw HarcHostError.listenerPortPersistenceConflict
                }
            default:
                throw HarcHostError.listenerPortPersistenceConflict
            }
        }
    }

    /// Persists the first successful port choice, or proves that a restart is
    /// reusing the identical pair. It deliberately has no overwrite behavior:
    /// forced rebinding requires a separate reachability-recovery operation so
    /// ordinary startup can never invalidate queued background work.
    public func persistListenerPorts(_ ports: HarcHostListenerPorts) async throws {
        let timestamp = Self.unixTime(now())
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT control_port, upload_port FROM host_metadata WHERE singleton = 1"
            ) else {
                throw HarcHostError.metadataMismatch
            }
            let storedControl: Int64? = row["control_port"]
            let storedUpload: Int64? = row["upload_port"]
            if storedControl == nil, storedUpload == nil {
                try db.execute(
                    sql: """
                        UPDATE host_metadata
                           SET control_port = ?, upload_port = ?, updated_at = ?
                         WHERE singleton = 1
                           AND control_port IS NULL
                           AND upload_port IS NULL
                        """,
                    arguments: [
                        Int64(ports.controlPort),
                        Int64(ports.uploadPort),
                        timestamp,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw HarcHostError.listenerPortPersistenceConflict
                }
                return
            }
            guard storedControl == Int64(ports.controlPort),
                  storedUpload == Int64(ports.uploadPort) else {
                throw HarcHostError.listenerPortPersistenceConflict
            }
        }
    }
}
