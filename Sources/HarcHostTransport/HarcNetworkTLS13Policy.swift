#if canImport(Network) && canImport(Security)
import Network
import Security
import HarcHost

public enum HarcTLSListenerProtocol: String, CaseIterable, Sendable {
    case grpcHTTP2 = "h2"
    case backgroundUploadHTTP1 = "http/1.1"
}

public enum HarcNetworkTLS13PolicyError: Error, Equatable {
    case invalidSecurityIdentity
}

/// Builds the narrow Network.framework TLS profiles shared by the host's two
/// process-owned listeners. Each listener receives exactly one ALPN value.
public enum HarcNetworkTLS13Policy {
    /// V1 intentionally gives up resumed handshakes on both listeners. A
    /// connection can carry side-effecting RPCs or uploads, and Security does
    /// not expose a narrower server-side early-data switch, so disabling
    /// resumption is the enforceable way to exclude TLS 1.3 0-RTT.
    public static let sessionResumptionEnabled = false

    package static func serverOptions(
        material: HostTransportListenerMaterial,
        protocol applicationProtocol: HarcTLSListenerProtocol
    ) async throws -> NWProtocolTLS.Options {
        let expectedRole: HostTransportListenerRole = switch applicationProtocol {
        case .grpcHTTP2: .grpcControl
        case .backgroundUploadHTTP1: .backgroundUpload
        }
        return try await material.bindServerIdentity(for: expectedRole) { identity in
            try serverOptions(
                identity: identity.securityIdentity,
                protocol: applicationProtocol
            )
        }
    }

    static func serverOptions(
        identity: SecIdentity,
        protocol applicationProtocol: HarcTLSListenerProtocol
    ) throws -> NWProtocolTLS.Options {
        guard let networkIdentity = sec_identity_create(identity) else {
            throw HarcNetworkTLS13PolicyError.invalidSecurityIdentity
        }

        let options = NWProtocolTLS.Options()
        let securityOptions = options.securityProtocolOptions

        sec_protocol_options_set_local_identity(securityOptions, networkIdentity)
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(
            securityOptions,
            Self.sessionResumptionEnabled
        )
        applicationProtocol.rawValue.withCString { value in
            sec_protocol_options_add_tls_application_protocol(securityOptions, value)
        }

        return options
    }

    package static func serverParameters(
        material: HostTransportListenerMaterial,
        protocol applicationProtocol: HarcTLSListenerProtocol
    ) async throws -> NWParameters {
        let tls = try await serverOptions(
            material: material,
            protocol: applicationProtocol
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
#endif
