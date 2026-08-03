#if canImport(Network)
import Foundation
import HarcHost

package enum HarcResidentBackgroundCapabilityTransportProviderError:
    Error, Equatable, Sendable
{
    case invalidDNSServiceTarget
    case invalidUploadPort
    case invalidHTTPPath
    case unableToConstructURL
}

package protocol HarcCapabilityTransportReserving: Sendable {
    func reserveTransportForBackgroundCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation
}

extension HostTransportResidentRuntime: HarcCapabilityTransportReserving {
    package func reserveTransportForBackgroundCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        try await reserveTransportForCapability(expiringAt: expiry)
    }
}

/// Binds capability minting to the resident transport lifecycle. The DNS-SD
/// target and port remain reachability hints; authority and leaf acceptance
/// stay in the signed transport set returned by the lifecycle reservation.
package struct HarcResidentBackgroundCapabilityTransportProvider:
    HostBackgroundCapabilityTransportSnapshotProviding, Sendable
{
    private let runtime: any HarcCapabilityTransportReserving
    private let dnsServiceTarget: String
    private let uploadPort: UInt16

    package init(
        runtime: HostTransportResidentRuntime,
        dnsServiceTarget: String,
        uploadPort: UInt16
    ) throws {
        try self.init(
            transportReservation: runtime,
            dnsServiceTarget: dnsServiceTarget,
            uploadPort: uploadPort
        )
    }

    init(
        transportReservation: any HarcCapabilityTransportReserving,
        dnsServiceTarget: String,
        uploadPort: UInt16
    ) throws {
        let normalizedTarget = dnsServiceTarget.lowercased()
        guard Self.isValidLocalDNSTarget(normalizedTarget) else {
            throw HarcResidentBackgroundCapabilityTransportProviderError
                .invalidDNSServiceTarget
        }
        guard uploadPort > 0 else {
            throw HarcResidentBackgroundCapabilityTransportProviderError
                .invalidUploadPort
        }
        self.runtime = transportReservation
        self.dnsServiceTarget = normalizedTarget
        self.uploadPort = uploadPort
    }

    package func reserveBackgroundCapabilityTransport(
        forHTTPPath httpPath: String,
        capabilityExpiresAt: Date
    ) async throws -> HostBackgroundCapabilityTransportSnapshot {
        guard httpPath.utf8.count <= 2_048,
              httpPath.first == "/",
              !httpPath.contains("?"),
              !httpPath.contains("#"),
              !httpPath.contains("%"),
              !httpPath.contains("\\") else {
            throw HarcResidentBackgroundCapabilityTransportProviderError
                .invalidHTTPPath
        }
        let reservation = try await runtime.reserveTransportForBackgroundCapability(
            expiringAt: capabilityExpiresAt
        )
        var components = URLComponents()
        components.scheme = "https"
        components.host = dnsServiceTarget
        components.port = Int(uploadPort)
        components.percentEncodedPath = httpPath
        guard let url = components.url,
              url.absoluteString.utf8.count <= 2_048 else {
            throw HarcResidentBackgroundCapabilityTransportProviderError
                .unableToConstructURL
        }
        return try HostBackgroundCapabilityTransportSnapshot(
            absoluteUploadURL: url,
            currentTransportSetEpoch: reservation.minimumTransportSetEpoch,
            exactSignedTransportSet: reservation.exactSignedTransportSet
        )
    }

    private static func isValidLocalDNSTarget(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 253,
              value.hasSuffix(".local"),
              !value.contains(":"),
              !value.contains("/"),
              !value.contains("%") else {
            return false
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "local" else { return false }
        return labels.dropLast().allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7a)
                    || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2d
            }
        }
    }
}
#endif
