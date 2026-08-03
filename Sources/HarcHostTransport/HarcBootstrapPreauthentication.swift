import CryptoKit
import Dispatch
import Foundation
import HarcHost
import NIOCore
#if canImport(Network)
import Network
#endif

public enum HarcHostRPCSourceBindingError: Error, Equatable, Sendable {
    case invalidHostScopedSecret
    case invalidAuthenticatedTransportSource
    case unsupportedRemotePeer
}

/// The non-secret peer description supplied by gRPC Swift to the transport
/// edge. Harc never persists either description.
public struct HarcHostRPCPeer: Equatable, Sendable {
    public let remotePeer: String
    public let localPeer: String

    public init(remotePeer: String, localPeer: String) {
        self.remotePeer = remotePeer
        self.localPeer = localPeer
    }
}

/// Production source binding for pre-authentication admission. It parses only
/// gRPC Swift NIO's normalized address families, removes the ephemeral TCP
/// port, and HMACs the result with a host-scoped secret before HarcHost sees it.
public struct HarcHostRPCSourceBindingProvider: Sendable {
    private static let sourceDomain = Data("harc.bootstrap-source.v1\0".utf8)
    private static let tokenTagDomain = Data(
        "harc.bootstrap-source-token-tag.v1\0".utf8
    )
    private static let sourceBindingBytes = 32
    private static let authenticatedTokenBytes = 64

    private let hostScopedSecret: Data?
    private let resolve: @Sendable (HarcHostRPCPeer) throws
        -> HostPreauthenticationSource

    public init(hostScopedSecret: Data) throws {
        guard hostScopedSecret.count == 32,
              hostScopedSecret.contains(where: { $0 != 0 }) else {
            throw HarcHostRPCSourceBindingError.invalidHostScopedSecret
        }
        self.hostScopedSecret = hostScopedSecret
        self.resolve = { peer in
            let normalized = try Self.normalizedRemoteAddress(peer.remotePeer)
            return try Self.sourceBinding(
                normalizedSource: normalized,
                hostScopedSecret: hostScopedSecret
            )
        }
    }

    /// Internal-only seam for deterministic adapter tests.
    init(
        resolve: @escaping @Sendable (HarcHostRPCPeer) throws
            -> HostPreauthenticationSource
    ) {
        self.hostScopedSecret = nil
        self.resolve = resolve
    }

    public func sourceBinding(
        for peer: HarcHostRPCPeer
    ) throws -> HostPreauthenticationSource {
        try resolve(peer)
    }

#if canImport(Network)
    /// Creates the server-only metadata value injected at the HTTP/2 stream
    /// edge. The first half is Harc's opaque source binding. The second half
    /// authenticates that binding under a separate HMAC domain, so arbitrary
    /// client metadata cannot select another admission bucket.
    package func authenticatedTransportSourceToken(
        for endpoint: NWEndpoint
    ) throws -> Data {
        guard let hostScopedSecret else {
            throw HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        }
        let source = try Self.sourceBinding(
            normalizedSource: Self.normalizedRemoteEndpoint(endpoint),
            hostScopedSecret: hostScopedSecret
        )
        let tag = HMAC<SHA256>.authenticationCode(
            for: Self.tokenTagDomain + source.bindingSHA256,
            using: SymmetricKey(data: hostScopedSecret)
        )
        return source.bindingSHA256 + Data(tag)
    }
#endif

    /// Verifies one transport-injected token and recovers its opaque source
    /// binding. Callers must reject duplicates before reaching this method.
    package func sourceBinding(
        authenticatedTransportSourceToken token: Data
    ) throws -> HostPreauthenticationSource {
        guard let hostScopedSecret,
              token.count == Self.authenticatedTokenBytes else {
            throw HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        }
        let binding = Data(token.prefix(Self.sourceBindingBytes))
        let suppliedTag = Data(token.suffix(Self.sourceBindingBytes))
        guard HMAC<SHA256>.isValidAuthenticationCode(
            suppliedTag,
            authenticating: Self.tokenTagDomain + binding,
            using: SymmetricKey(data: hostScopedSecret)
        ) else {
            throw HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        }
        return try HostPreauthenticationSource(bindingSHA256: binding)
    }

    private static func sourceBinding(
        normalizedSource: Data,
        hostScopedSecret: Data
    ) throws -> HostPreauthenticationSource {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: sourceDomain + normalizedSource,
            using: SymmetricKey(data: hostScopedSecret)
        )
        return try HostPreauthenticationSource(
            bindingSHA256: Data(authentication)
        )
    }

    private static func normalizedRemoteAddress(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= 2_048 else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        if value.hasPrefix("ipv4:") {
            return try normalizedIPv4(String(value.dropFirst("ipv4:".count)))
        }
        if value.hasPrefix("ipv6:") {
            return try normalizedIPv6(String(value.dropFirst("ipv6:".count)))
        }
        if value.hasPrefix("unix:") {
            return try normalizedUnixDomainSocket(
                String(value.dropFirst("unix:".count))
            )
        }
        throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
    }

    private static func normalizedIPv4(_ value: String) throws -> Data {
        guard let separator = value.lastIndex(of: ":") else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        let host = String(value[..<separator])
        let port = String(value[value.index(after: separator)...])
        try validateEphemeralPort(port)
        let socket = try parseNumericAddress(host)
        guard case .v4(let address) = socket else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        var rawAddress = address.address.sin_addr
        let rawBytes = withUnsafeBytes(of: &rawAddress) { Data($0) }
        return normalizedIPv4Bytes(rawBytes)
    }

    private static func normalizedIPv6(_ value: String) throws -> Data {
        guard value.first == "[",
              let close = value.lastIndex(of: "]"),
              value.index(after: close) < value.endIndex,
              value[value.index(after: close)] == ":" else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        let hostWithOptionalZone = String(
            value[value.index(after: value.startIndex)..<close]
        )
        let portStart = value.index(close, offsetBy: 2)
        let port = String(value[portStart...])
        let host = try addressWithoutValidatedIPv6Zone(hostWithOptionalZone)
        try validateEphemeralPort(port)
        let socket = try parseNumericAddress(host)
        guard case .v6(let address) = socket else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        var rawAddress = address.address.sin6_addr
        let rawBytes = withUnsafeBytes(of: &rawAddress) { Data($0) }
        return normalizedIPv6Bytes(rawBytes)
    }

    private static func addressWithoutValidatedIPv6Zone(
        _ value: String
    ) throws -> String {
        let components = value.split(
            separator: "%",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count <= 2 else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        if components.count == 2 {
            let zone = components[1]
            guard !zone.isEmpty,
                  zone.utf8.count <= 64,
                  zone.utf8.allSatisfy({ byte in
                      (byte >= 0x41 && byte <= 0x5a)
                          || (byte >= 0x61 && byte <= 0x7a)
                          || (byte >= 0x30 && byte <= 0x39)
                          || byte == 0x2d || byte == 0x2e || byte == 0x5f
                  }) else {
                throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
            }
        }
        guard let address = components.first, !address.isEmpty else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        return String(address)
    }

    private static func normalizedUnixDomainSocket(_ path: String) throws -> Data {
        guard path != "<unknown>",
              path.first == "/",
              !path.contains("\0"),
              path.utf8.count <= 103,
              path.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
        return Data("unix\0".utf8) + Data(path.utf8)
    }

#if canImport(Network)
    private static func normalizedRemoteEndpoint(
        _ endpoint: NWEndpoint
    ) throws -> Data {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return normalizedIPv4Bytes(address.rawValue)
            case .ipv6(let address):
                return normalizedIPv6Bytes(address.rawValue)
            case .name:
                throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
            @unknown default:
                throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
            }
        case .unix(let path):
            return try normalizedUnixDomainSocket(path)
        case .service, .url, .opaque:
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        @unknown default:
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
    }
#endif

    private static func normalizedIPv4Bytes(_ rawBytes: Data) -> Data {
        Data("ipv4\0".utf8) + rawBytes
    }

    private static func normalizedIPv6Bytes(_ rawBytes: Data) -> Data {
        if rawBytes.count == 16,
           rawBytes.prefix(10).allSatisfy({ $0 == 0 }),
           rawBytes[10] == 0xff,
           rawBytes[11] == 0xff {
            return normalizedIPv4Bytes(Data(rawBytes.suffix(4)))
        }
        return Data("ipv6\0".utf8) + rawBytes
    }

    private static func validateEphemeralPort(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 5,
              value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              value.first != "0",
              let port = UInt16(value),
              port > 0,
              String(port) == value else {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
    }

    private static func parseNumericAddress(_ value: String) throws
        -> SocketAddress
    {
        do {
            return try SocketAddress(ipAddress: value, port: 0)
        } catch {
            throw HarcHostRPCSourceBindingError.unsupportedRemotePeer
        }
    }
}

public struct HarcBootstrapMonotonicClock: Sendable {
    private let readNanoseconds: @Sendable () -> UInt64

    public init() {
        self.readNanoseconds = { DispatchTime.now().uptimeNanoseconds }
    }

    init(readNanoseconds: @escaping @Sendable () -> UInt64) {
        self.readNanoseconds = readNanoseconds
    }

    fileprivate func now() -> UInt64 { readNanoseconds() }
}

public enum HarcBootstrapPreauthenticationAdmissionError:
    Error, Equatable, Sendable
{
    case malformedRequestCooldown
    case sourceCapacityExhausted
    case monotonicClockRegression
}

/// Shared malformed-request circuit breaker for all public bootstrap methods.
/// Call `admit` before any protobuf or metadata validation and record every
/// validation failure. Sixty failures in one minute impose a ten-minute
/// source cooldown.
public actor HarcBootstrapPreauthenticationGate {
    public static let maximumMalformedRequestsPerWindow = 60
    public static let malformedRequestWindowNanoseconds: UInt64 =
        60 * 1_000_000_000
    public static let cooldownNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private static let maximumTrackedSources = 4_096

    private struct SourceState: Sendable {
        var malformedAttempts: [UInt64]
        var cooldownUntil: UInt64?
    }

    private let clock: HarcBootstrapMonotonicClock
    private var sources: [HostPreauthenticationSource: SourceState] = [:]
    private var admissionsSinceSweep = 0
    private var lastObservedNanoseconds: UInt64?

    public init(clock: HarcBootstrapMonotonicClock = .init()) {
        self.clock = clock
    }

    public func admit(_ source: HostPreauthenticationSource) throws {
        let now = try observeTime()
        admissionsSinceSweep += 1
        if admissionsSinceSweep >= 64 {
            sweep(now: now)
            admissionsSinceSweep = 0
        }

        guard let state = sources[source] else {
            guard sources.count < Self.maximumTrackedSources else {
                throw HarcBootstrapPreauthenticationAdmissionError
                    .sourceCapacityExhausted
            }
            return
        }
        if let cooldownUntil = state.cooldownUntil,
           now < cooldownUntil {
            throw HarcBootstrapPreauthenticationAdmissionError
                .malformedRequestCooldown
        }
        if state.cooldownUntil != nil {
            sources.removeValue(forKey: source)
        }
    }

    public func recordMalformedRequest(
        from source: HostPreauthenticationSource
    ) throws {
        let now = try observeTime()
        var state = sources[source] ?? SourceState(
            malformedAttempts: [],
            cooldownUntil: nil
        )
        if let cooldownUntil = state.cooldownUntil, now < cooldownUntil {
            throw HarcBootstrapPreauthenticationAdmissionError
                .malformedRequestCooldown
        }
        if sources[source] == nil,
           sources.count >= Self.maximumTrackedSources {
            throw HarcBootstrapPreauthenticationAdmissionError
                .sourceCapacityExhausted
        }
        state.cooldownUntil = nil
        state.malformedAttempts = state.malformedAttempts.filter {
            now >= $0 && now - $0 < Self.malformedRequestWindowNanoseconds
        }
        state.malformedAttempts.append(now)
        if state.malformedAttempts.count
            >= Self.maximumMalformedRequestsPerWindow {
            state.malformedAttempts.removeAll(keepingCapacity: false)
            let cooldown = now.addingReportingOverflow(
                Self.cooldownNanoseconds
            )
            state.cooldownUntil = cooldown.overflow
                ? UInt64.max
                : cooldown.partialValue
        }
        sources[source] = state
    }

    private func observeTime() throws -> UInt64 {
        let now = clock.now()
        if let previous = lastObservedNanoseconds, now < previous {
            throw HarcBootstrapPreauthenticationAdmissionError
                .monotonicClockRegression
        }
        lastObservedNanoseconds = now
        return now
    }

    private func sweep(now: UInt64) {
        sources = sources.filter { _, state in
            if let cooldownUntil = state.cooldownUntil {
                return now < cooldownUntil
            }
            return state.malformedAttempts.contains {
                now >= $0 && now - $0 < Self.malformedRequestWindowNanoseconds
            }
        }
    }
}
