#if canImport(Network)
import CryptoKit
import Foundation
import HarcDomain
import HarcProtocol
@preconcurrency import Network
import Security

/// Lifetime attached below a pinned application transport. A relay tunnel is
/// one example: inner authentication remains owned by the caller, while this
/// owner guarantees the outer reachability path cannot outlive shutdown.
public protocol HarcPinnedConnectionTransportLifetime: Sendable {
    func shutdown() async
}

public enum HarcRemoteRelayLimits {
    public static let opaqueTokenLength = 43
    public static let maximumFrameBytes = 1_048_576
    public static let maximumControlBytes = 4_096
    public static let sessionLifetimeMilliseconds: UInt64 = 86_400_000
    public static let connectionTimeout: Duration = .seconds(10)
    public static let hostPingInterval: Duration = .seconds(30)
    public static let maximumHostReconnectDelay: Duration = .seconds(30)
}

public enum HarcRemoteRelaySecrets {
    public static func randomOpaqueToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HarcRemoteRelayError.secureRandomFailed(status)
        }
        return Data(bytes).base64URLEncodedWithoutPadding()
    }

    public static func hashOpaqueToken(_ token: String) throws -> String {
        guard HarcRemoteRelayRouteV1.isOpaqueToken(token) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "token")
        }
        return Data(SHA256.hash(data: Data(token.utf8)))
            .base64URLEncodedWithoutPadding()
    }
}

/// Persisted reachability material for one already-adopted Host. These random
/// identifiers are independent of Harc authority/device keys. The capability
/// is protected by the same current-user-only route file as the direct route.
public struct HarcRemoteRelayRouteV1: Codable, Equatable, Sendable {
    public let serviceOrigin: URL
    public let hostRouteID: String
    public let deviceRouteID: String
    public let capability: String

    public init(
        serviceOrigin: URL,
        hostRouteID: String,
        deviceRouteID: String,
        capability: String
    ) throws {
        guard Self.isValidServiceOrigin(serviceOrigin) else {
            throw HarcRemoteRelayError.invalidServiceOrigin
        }
        guard Self.isOpaqueToken(hostRouteID) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "hostRouteID")
        }
        guard Self.isOpaqueToken(deviceRouteID) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "deviceRouteID")
        }
        guard Self.isOpaqueToken(capability) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "capability")
        }
        self.serviceOrigin = serviceOrigin
        self.hostRouteID = hostRouteID
        self.deviceRouteID = deviceRouteID
        self.capability = capability
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            serviceOrigin: values.decode(URL.self, forKey: .serviceOrigin),
            hostRouteID: values.decode(String.self, forKey: .hostRouteID),
            deviceRouteID: values.decode(String.self, forKey: .deviceRouteID),
            capability: values.decode(String.self, forKey: .capability)
        )
    }

    public init(pairingWire wire: Harc_V1_RemoteRelayRouteV1) throws {
        let hostRouteID = Data(wire.hostRouteID)
            .base64URLEncodedWithoutPadding()
        let deviceRouteID = Data(wire.deviceRouteID)
            .base64URLEncodedWithoutPadding()
        let capability = Data(wire.capability)
            .base64URLEncodedWithoutPadding()
        _ = try PairingRelayEndpointV1(
            serviceHost: wire.serviceHost,
            hostRouteID: hostRouteID,
            admissionRouteID: deviceRouteID,
            capability: capability
        )
        guard let origin = URL(string: "https://\(wire.serviceHost)") else {
            throw HarcRemoteRelayError.invalidServiceOrigin
        }
        try self.init(
            serviceOrigin: origin,
            hostRouteID: hostRouteID,
            deviceRouteID: deviceRouteID,
            capability: capability
        )
    }

    public func pairingWireV1() throws -> Harc_V1_RemoteRelayRouteV1 {
        guard let serviceHost = serviceOrigin.host else {
            throw HarcRemoteRelayError.invalidServiceOrigin
        }
        var wire = Harc_V1_RemoteRelayRouteV1()
        wire.serviceHost = serviceHost
        wire.hostRouteID = try Self.decodeOpaqueToken(hostRouteID)
        wire.deviceRouteID = try Self.decodeOpaqueToken(deviceRouteID)
        wire.capability = try Self.decodeOpaqueToken(capability)
        return wire
    }

    public static func isOpaqueToken(_ value: String) -> Bool {
        guard value.utf8.count == HarcRemoteRelayLimits.opaqueTokenLength else {
            return false
        }
        guard value.utf8.allSatisfy({ byte in
            (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || (48 ... 57).contains(byte)
                || byte == 45
                || byte == 95
        }) else { return false }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        guard let decoded = Data(base64Encoded: base64),
              decoded.count == 32 else { return false }
        return decoded.base64URLEncodedWithoutPadding() == value
    }

    static func isValidServiceOrigin(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && (components.port == nil || components.port == 443)
            && (components.path.isEmpty || components.path == "/")
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func decodeOpaqueToken(_ value: String) throws -> Data {
        guard isOpaqueToken(value) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "token")
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let decoded = Data(base64Encoded: base64), decoded.count == 32 else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "token")
        }
        return decoded
    }
}

/// This-device-only persistence used by the Host to make an approved relay
/// route redeliverable after an app restart until the claimant receives it.
public protocol HarcRemoteRelayRouteDeliveryPersistence: Sendable {
    func save(
        _ route: HarcRemoteRelayRouteV1,
        forClaimID claimID: UUID,
        expiresAtMilliseconds: UInt64
    ) async throws

    func load(forClaimID claimID: UUID) async throws
        -> HarcRemoteRelayRouteV1?

    func remove(forClaimID claimID: UUID) async throws

    /// Persists the post-adoption route independently from its short-lived
    /// delivery envelope so Host-side device revocation can also revoke the
    /// corresponding relay capability after a restart.
    func saveBinding(
        _ route: HarcRemoteRelayRouteV1,
        forDeviceID deviceID: DeviceID,
        expiresAtMilliseconds: UInt64
    ) async throws

    func loadBinding(forDeviceID deviceID: DeviceID) async throws
        -> HarcRemoteRelayRouteV1?

    func removeBinding(forDeviceID deviceID: DeviceID) async throws
}

/// Persistent Host-side relay identity. It is deliberately independent of the
/// Harc authority key and must be stored in this-device-only secure storage.
public struct HarcRemoteRelayHostConfigurationV1: Codable, Equatable, Sendable {
    public let serviceOrigin: URL
    public let hostRouteID: String
    public let hostCapability: String
    public let localControlPort: UInt16

    public init(
        serviceOrigin: URL,
        hostRouteID: String,
        hostCapability: String,
        localControlPort: UInt16
    ) throws {
        guard HarcRemoteRelayRouteV1.isValidServiceOrigin(serviceOrigin) else {
            throw HarcRemoteRelayError.invalidServiceOrigin
        }
        guard HarcRemoteRelayRouteV1.isOpaqueToken(hostRouteID) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "hostRouteID")
        }
        guard HarcRemoteRelayRouteV1.isOpaqueToken(hostCapability) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "hostCapability")
        }
        guard localControlPort > 0 else {
            throw HarcRemoteRelayError.invalidLocalControlPort
        }
        self.serviceOrigin = serviceOrigin
        self.hostRouteID = hostRouteID
        self.hostCapability = hostCapability
        self.localControlPort = localControlPort
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            serviceOrigin: values.decode(URL.self, forKey: .serviceOrigin),
            hostRouteID: values.decode(String.self, forKey: .hostRouteID),
            hostCapability: values.decode(String.self, forKey: .hostCapability),
            localControlPort: values.decode(UInt16.self, forKey: .localControlPort)
        )
    }

    public static func generate(
        serviceOrigin: URL,
        localControlPort: UInt16
    ) throws -> Self {
        try Self(
            serviceOrigin: serviceOrigin,
            hostRouteID: HarcRemoteRelaySecrets.randomOpaqueToken(),
            hostCapability: HarcRemoteRelaySecrets.randomOpaqueToken(),
            localControlPort: localControlPort
        )
    }
}

/// Explicit product opt-in. A persisted relay route alone never enables the
/// Host connection: either the user-facing Harc Remote preference or the
/// launch-environment override must opt this installation in. The preference
/// defaults off so the Host owner explicitly chooses to permit remote service.
public enum HarcRemoteRelayFeaturePolicy {
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults? = .standard
    ) -> Bool {
        environment["HARC_ENABLE_REMOTE_RELAY"] == "1"
            || userDefaults?.bool(forKey: "harc.remoteRelayEnabled") == true
    }
}

public struct HarcRemoteRelaySessionOfferV1: Equatable, Sendable {
    public let sessionID: String
    public let capability: String
    public let expiresAtMilliseconds: UInt64

    public static func decode(
        _ data: Data,
        nowMilliseconds: UInt64
    ) throws -> HarcRemoteRelaySessionOfferV1 {
        guard !data.isEmpty,
              data.count <= HarcRemoteRelayLimits.maximumControlBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == ["sessionID", "capability", "expiresAt"],
              let sessionID = object["sessionID"] as? String,
              let capability = object["capability"] as? String,
              let expiresNumber = object["expiresAt"] as? NSNumber,
              CFGetTypeID(expiresNumber) != CFBooleanGetTypeID(),
              expiresNumber.doubleValue.rounded() == expiresNumber.doubleValue,
              expiresNumber.doubleValue >= 0,
              expiresNumber.doubleValue <= Double(UInt64.max),
              HarcRemoteRelayRouteV1.isOpaqueToken(sessionID),
              HarcRemoteRelayRouteV1.isOpaqueToken(capability) else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        let expiresAt = expiresNumber.uint64Value
        guard expiresAt > nowMilliseconds,
              expiresAt - nowMilliseconds
                <= HarcRemoteRelayLimits.sessionLifetimeMilliseconds else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        return HarcRemoteRelaySessionOfferV1(
            sessionID: sessionID,
            capability: capability,
            expiresAtMilliseconds: expiresAt
        )
    }
}

public struct HarcRemoteRelayHostSessionOfferV1: Equatable, Sendable {
    public let sessionID: String
    public let capability: String
    public let expiresAtMilliseconds: UInt64

    public static func decode(
        _ data: Data,
        nowMilliseconds: UInt64
    ) throws -> Self {
        guard !data.isEmpty,
              data.count <= HarcRemoteRelayLimits.maximumControlBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == ["type", "sessionID", "capability", "expiresAt"],
              object["type"] as? String == "session",
              let sessionID = object["sessionID"] as? String,
              let capability = object["capability"] as? String,
              let expiresNumber = object["expiresAt"] as? NSNumber,
              CFGetTypeID(expiresNumber) != CFBooleanGetTypeID(),
              expiresNumber.doubleValue.rounded() == expiresNumber.doubleValue,
              expiresNumber.doubleValue >= 0,
              expiresNumber.doubleValue <= Double(UInt64.max),
              HarcRemoteRelayRouteV1.isOpaqueToken(sessionID),
              HarcRemoteRelayRouteV1.isOpaqueToken(capability) else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        let expiresAt = expiresNumber.uint64Value
        guard expiresAt > nowMilliseconds,
              expiresAt - nowMilliseconds
                <= HarcRemoteRelayLimits.sessionLifetimeMilliseconds else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        return Self(
            sessionID: sessionID,
            capability: capability,
            expiresAtMilliseconds: expiresAt
        )
    }
}

public enum HarcRemoteRelayError: Error, Equatable, Sendable {
    case invalidServiceOrigin
    case invalidOpaqueValue(field: String)
    case invalidSessionOffer
    case unexpectedHTTPStatus(Int)
    case responseTooLarge
    case invalidWebSocketReady
    case listenerFailed(String)
    case listenerStopped
    case localPeerAlreadyConnected
    case relayFrameTooLarge
    case unexpectedRelayText
    case secureRandomFailed(OSStatus)
    case invalidLocalControlPort
    case hostControlDisconnected
    case invalidHostControlMessage
    case hostControlCommandRejected
}

extension HarcRemoteRelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServiceOrigin:
            "The Harc Remote service address is invalid."
        case .invalidOpaqueValue(let field):
            "The Harc Remote \(field) value is invalid."
        case .invalidSessionOffer:
            "The Harc Remote service returned an invalid session."
        case .unexpectedHTTPStatus(let status):
            "The Harc Remote service returned HTTP \(status)."
        case .responseTooLarge:
            "The Harc Remote control response exceeded its safety limit."
        case .invalidWebSocketReady:
            "The Harc Remote tunnel did not complete its private ready handshake."
        case .listenerFailed(let description):
            "The private local relay endpoint failed: \(description)"
        case .listenerStopped:
            "The private local relay endpoint stopped before it was ready."
        case .localPeerAlreadyConnected:
            "The private local relay endpoint already has a peer."
        case .relayFrameTooLarge:
            "The Harc Remote tunnel received an oversized frame."
        case .unexpectedRelayText:
            "The Harc Remote tunnel received unexpected control text."
        case .secureRandomFailed(let status):
            "Secure relay randomness failed with OSStatus \(status)."
        case .invalidLocalControlPort:
            "The Harc Host relay has an invalid local control port."
        case .hostControlDisconnected:
            "The Harc Host relay control connection is offline."
        case .invalidHostControlMessage:
            "The Harc Remote service sent an invalid Host control message."
        case .hostControlCommandRejected:
            "The Harc Remote service rejected a Host control command."
        }
    }
}

/// Client-side loopback bridge. The existing pinned gRPC connection performs
/// its normal inner TLS handshake against `127.0.0.1:localPort`; this bridge
/// forwards only those already-encrypted TLS records through Cloudflare.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final actor HarcRemoteRelayClientTunnel:
    HarcPinnedConnectionTransportLifetime
{
    public nonisolated let localHost = "127.0.0.1"
    public nonisolated let localPort: UInt16

    private let listener: NWListener
    private let urlSession: URLSession
    private let webSocket: URLSessionWebSocketTask
    private var pump: HarcRemoteRelayBytePump?
    private var stopped = false

    public static func open(
        route: HarcRemoteRelayRouteV1
    ) async throws -> HarcRemoteRelayClientTunnel {
        let session = makeEphemeralRelaySession()
        let offer = try await requestSession(route: route, session: session)
        let webSocket = try await openWebSocket(
            route: route,
            offer: offer,
            session: session
        )

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: .any
            )
            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { connection in connection.cancel() }
            let gate = HarcRemoteRelayListenerGate(listener: listener)
            listener.stateUpdateHandler = { state in
                Task { await gate.received(state) }
            }
            listener.start(
                queue: DispatchQueue(label: "com.harc.remote-relay.listener")
            )
            let port = try await gate.waitUntilReady()
            let tunnel = HarcRemoteRelayClientTunnel(
                localPort: port,
                listener: listener,
                urlSession: session,
                webSocket: webSocket
            )
            listener.newConnectionHandler = { [weak tunnel] connection in
                guard let tunnel else {
                    connection.cancel()
                    return
                }
                Task { await tunnel.accept(connection) }
            }
            return tunnel
        } catch {
            webSocket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
    }

    private init(
        localPort: UInt16,
        listener: NWListener,
        urlSession: URLSession,
        webSocket: URLSessionWebSocketTask
    ) {
        self.localPort = localPort
        self.listener = listener
        self.urlSession = urlSession
        self.webSocket = webSocket
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        await pump?.shutdown()
        pump = nil
        webSocket.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped else {
            connection.cancel()
            return
        }
        guard pump == nil else {
            connection.cancel()
            return
        }
        listener.cancel()
        let pump = HarcRemoteRelayBytePump(
            connection: connection,
            webSocket: webSocket
        )
        self.pump = pump
        await pump.start()
    }

    private static func requestSession(
        route: HarcRemoteRelayRouteV1,
        session: URLSession
    ) async throws -> HarcRemoteRelaySessionOfferV1 {
        let url = try relayURL(
            origin: route.serviceOrigin,
            scheme: "https",
            path: "/v1/hosts/\(route.hostRouteID)/sessions"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(route.capability, forHTTPHeaderField: "X-Harc-Relay-Capability")
        request.setValue(route.deviceRouteID, forHTTPHeaderField: "X-Harc-Relay-Device-Route")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        guard http.statusCode == 201 else {
            throw HarcRemoteRelayError.unexpectedHTTPStatus(http.statusCode)
        }
        var data = Data()
        data.reserveCapacity(512)
        for try await byte in bytes {
            guard data.count < HarcRemoteRelayLimits.maximumControlBytes else {
                throw HarcRemoteRelayError.responseTooLarge
            }
            data.append(byte)
        }
        return try HarcRemoteRelaySessionOfferV1.decode(
            data,
            nowMilliseconds: currentTimeMilliseconds()
        )
    }

    private static func openWebSocket(
        route: HarcRemoteRelayRouteV1,
        offer: HarcRemoteRelaySessionOfferV1,
        session: URLSession
    ) async throws -> URLSessionWebSocketTask {
        let url = try relayURL(
            origin: route.serviceOrigin,
            scheme: "wss",
            path: "/v1/sessions/\(offer.sessionID)/connect"
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(offer.capability, forHTTPHeaderField: "X-Harc-Relay-Capability")
        request.setValue("client", forHTTPHeaderField: "X-Harc-Relay-Role")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = HarcRemoteRelayLimits.maximumFrameBytes
        task.resume()
        do {
            try await completeReadyHandshake(task)
            return task
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }
}

public enum HarcRemoteRelayHostConnectionState: Equatable, Sendable {
    case stopped
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

public enum HarcRemoteRelayAdmissionKind: String, Sendable {
    case pairing
    case device

    var maximumLifetimeMilliseconds: UInt64 {
        switch self {
        case .pairing: 120_000
        case .device: 366 * 24 * 60 * 60 * 1_000
        }
    }
}

/// Host-side lifecycle for Harc Remote. One persistent outbound control socket
/// receives opaque session offers. Every offer creates a separate, transient
/// byte tunnel to the existing loopback TLS gRPC listener. The agent never
/// parses or terminates the inner Harc TLS stream.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final actor HarcRemoteRelayHostAgent {
    private struct PendingCommand {
        let expectedAcknowledgement: String
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: HarcRemoteRelayHostConfigurationV1
    private var runTask: Task<Void, Never>?
    private var controlSession: URLSession?
    private var controlSocket: URLSessionWebSocketTask?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var pendingCommand: PendingCommand?
    private var currentState = HarcRemoteRelayHostConnectionState.stopped
    private var stopped = false

    public static func start(
        configuration: HarcRemoteRelayHostConfigurationV1
    ) async -> HarcRemoteRelayHostAgent {
        let agent = HarcRemoteRelayHostAgent(configuration: configuration)
        await agent.startRunLoop()
        return agent
    }

    private init(configuration: HarcRemoteRelayHostConfigurationV1) {
        self.configuration = configuration
    }

    public func state() -> HarcRemoteRelayHostConnectionState {
        currentState
    }

    public func authorize(
        routeID: String,
        capability: String,
        kind: HarcRemoteRelayAdmissionKind,
        expiresAtMilliseconds: UInt64
    ) async throws {
        guard HarcRemoteRelayRouteV1.isOpaqueToken(routeID) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "routeID")
        }
        let capabilityHash = try HarcRemoteRelaySecrets.hashOpaqueToken(
            capability
        )
        let now = currentTimeMilliseconds()
        guard expiresAtMilliseconds > now,
              expiresAtMilliseconds - now
                <= kind.maximumLifetimeMilliseconds,
              expiresAtMilliseconds <= UInt64(Int64.max) else {
            throw HarcRemoteRelayError.invalidSessionOffer
        }
        let command: [String: Any] = [
            "type": "authorize",
            "routeID": routeID,
            "capabilityHash": capabilityHash,
            "kind": kind.rawValue,
            "expiresAt": expiresAtMilliseconds,
        ]
        try await sendCommand(command, expecting: "authorized")
    }

    public func issueAdmission(
        kind: HarcRemoteRelayAdmissionKind,
        expiresAtMilliseconds: UInt64
    ) async throws -> HarcRemoteRelayRouteV1 {
        let routeID = try HarcRemoteRelaySecrets.randomOpaqueToken()
        let capability = try HarcRemoteRelaySecrets.randomOpaqueToken()
        try await authorize(
            routeID: routeID,
            capability: capability,
            kind: kind,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        return try HarcRemoteRelayRouteV1(
            serviceOrigin: configuration.serviceOrigin,
            hostRouteID: configuration.hostRouteID,
            deviceRouteID: routeID,
            capability: capability
        )
    }

    public func revoke(routeID: String) async throws {
        guard HarcRemoteRelayRouteV1.isOpaqueToken(routeID) else {
            throw HarcRemoteRelayError.invalidOpaqueValue(field: "routeID")
        }
        try await sendCommand(
            ["type": "revoke", "routeID": routeID],
            expecting: "revoked"
        )
    }

    public func handleSystemWake() {
        guard !stopped else { return }
        restartRunLoop()
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        currentState = .stopped
        runTask?.cancel()
        runTask = nil
        controlSocket?.cancel(with: .goingAway, reason: nil)
        controlSocket = nil
        controlSession?.invalidateAndCancel()
        controlSession = nil
        failPendingCommand(HarcRemoteRelayError.hostControlDisconnected)
        let tasks = sessionTasks.values
        sessionTasks.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func startRunLoop() {
        guard runTask == nil, !stopped else { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func restartRunLoop() {
        runTask?.cancel()
        controlSocket?.cancel(with: .goingAway, reason: nil)
        controlSession?.invalidateAndCancel()
        failPendingCommand(HarcRemoteRelayError.hostControlDisconnected)
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        controlSocket = nil
        controlSession = nil
        runTask = nil
        currentState = .connecting
        startRunLoop()
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled, !stopped {
            currentState = attempt == 0 ? .connecting : .reconnecting(
                attempt: attempt
            )
            do {
                try await connectAndServe()
                attempt = 0
            } catch {
                failPendingCommand(error)
                if Task.isCancelled || stopped { break }
                attempt += 1
                currentState = .reconnecting(attempt: attempt)
                let delaySeconds = min(1 << min(attempt - 1, 5), 30)
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
        if !stopped { currentState = .stopped }
    }

    private func connectAndServe() async throws {
        let session = makeEphemeralRelaySession()
        let url = try relayURL(
            origin: configuration.serviceOrigin,
            scheme: "wss",
            path: "/v1/hosts/\(configuration.hostRouteID)/connect"
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            configuration.hostCapability,
            forHTTPHeaderField: "X-Harc-Relay-Capability"
        )
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = HarcRemoteRelayLimits.maximumControlBytes
        controlSession = session
        controlSocket = socket
        socket.resume()

        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if controlSocket === socket { controlSocket = nil }
            if controlSession === session { controlSession = nil }
        }

        try await sendPing(socket)
        currentState = .connected
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.receiveControlMessages(from: socket)
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(
                        for: HarcRemoteRelayLimits.hostPingInterval
                    )
                    try await sendPing(socket)
                }
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw HarcRemoteRelayError.hostControlDisconnected
            }
            throw HarcRemoteRelayError.hostControlDisconnected
        }
    }

    private func receiveControlMessages(
        from socket: URLSessionWebSocketTask
    ) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  data.count <= HarcRemoteRelayLimits.maximumControlBytes else {
                throw HarcRemoteRelayError.invalidHostControlMessage
            }
            if text == "authorized" || text == "revoked" {
                receiveCommandAcknowledgement(text)
                continue
            }
            let offer = try HarcRemoteRelayHostSessionOfferV1.decode(
                data,
                nowMilliseconds: currentTimeMilliseconds()
            )
            startSession(offer)
        }
    }

    private func startSession(_ offer: HarcRemoteRelayHostSessionOfferV1) {
        guard sessionTasks[offer.sessionID] == nil,
              sessionTasks.count < 8 else { return }
        let configuration = self.configuration
        let task = Task { [weak self] in
            await HarcRemoteRelayHostTunnel.run(
                configuration: configuration,
                offer: offer
            )
            await self?.sessionFinished(offer.sessionID)
        }
        sessionTasks[offer.sessionID] = task
    }

    private func sessionFinished(_ sessionID: String) {
        sessionTasks.removeValue(forKey: sessionID)
    }

    private func sendCommand(
        _ object: [String: Any],
        expecting acknowledgement: String
    ) async throws {
        guard currentState == .connected, let socket = controlSocket else {
            throw HarcRemoteRelayError.hostControlDisconnected
        }
        guard pendingCommand == nil,
              JSONSerialization.isValidJSONObject(object) else {
            throw HarcRemoteRelayError.hostControlCommandRejected
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= HarcRemoteRelayLimits.maximumControlBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw HarcRemoteRelayError.hostControlCommandRejected
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let timeout = Task { [weak self] in
                try? await Task.sleep(
                    for: HarcRemoteRelayLimits.connectionTimeout
                )
                await self?.failPendingCommand(
                    HarcRemoteRelayError.hostControlDisconnected
                )
            }
            pendingCommand = PendingCommand(
                expectedAcknowledgement: acknowledgement,
                continuation: continuation,
                timeoutTask: timeout
            )
            Task { [weak self] in
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self?.failPendingCommand(error)
                }
            }
        }
    }

    private func receiveCommandAcknowledgement(_ acknowledgement: String) {
        guard let pendingCommand else { return }
        self.pendingCommand = nil
        pendingCommand.timeoutTask.cancel()
        if acknowledgement == pendingCommand.expectedAcknowledgement {
            pendingCommand.continuation.resume()
        } else {
            pendingCommand.continuation.resume(
                throwing: HarcRemoteRelayError.hostControlCommandRejected
            )
        }
    }

    private func failPendingCommand(_ error: any Error) {
        guard let pendingCommand else { return }
        self.pendingCommand = nil
        pendingCommand.timeoutTask.cancel()
        pendingCommand.continuation.resume(throwing: error)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private enum HarcRemoteRelayHostTunnel {
    static func run(
        configuration: HarcRemoteRelayHostConfigurationV1,
        offer: HarcRemoteRelayHostSessionOfferV1
    ) async {
        let session = makeEphemeralRelaySession()
        var socket: URLSessionWebSocketTask?
        defer {
            socket?.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            let url = try relayURL(
                origin: configuration.serviceOrigin,
                scheme: "wss",
                path: "/v1/sessions/\(offer.sessionID)/connect"
            )
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                offer.capability,
                forHTTPHeaderField: "X-Harc-Relay-Capability"
            )
            request.setValue("host", forHTTPHeaderField: "X-Harc-Relay-Role")
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = HarcRemoteRelayLimits.maximumFrameBytes
            socket = task
            task.resume()
            try await completeReadyHandshake(task)

            guard let port = NWEndpoint.Port(
                rawValue: configuration.localControlPort
            ) else { throw HarcRemoteRelayError.invalidLocalControlPort }
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: port,
                using: .tcp
            )
            let pump = HarcRemoteRelayBytePump(
                connection: connection,
                webSocket: task
            )
            await pump.start()
            await pump.waitForTermination()
        } catch {
            return
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum HarcRemoteRelayFrameDirection: Sendable {
    case localToRelay
    case relayToLocal
}

final actor HarcRemoteRelayBytePump {
    private let connection: NWConnection
    private let webSocket: URLSessionWebSocketTask
    private let frameObserver:
        (@Sendable (HarcRemoteRelayFrameDirection, Data) async -> Void)?
    private var runTask: Task<Void, Never>?
    private var stopped = false
    private let relaySendCredit = HarcRemoteRelayCreditGate()

    init(
        connection: NWConnection,
        webSocket: URLSessionWebSocketTask,
        frameObserver:
            (@Sendable (HarcRemoteRelayFrameDirection, Data) async -> Void)? = nil
    ) {
        self.connection = connection
        self.webSocket = webSocket
        self.frameObserver = frameObserver
    }

    func start() {
        guard runTask == nil, !stopped else { return }
        connection.start(
            queue: DispatchQueue(label: "com.harc.remote-relay.local-peer")
        )
        runTask = Task { await run() }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        runTask?.cancel()
        runTask = nil
        await relaySendCredit.stop()
        connection.cancel()
        webSocket.cancel(with: .goingAway, reason: nil)
    }

    func waitForTermination() async {
        let task = runTask
        await task?.value
    }

    private func run() async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try? await localToRelay()
                }
                group.addTask { [self] in
                    try? await relayToLocal()
                }
                _ = await group.next()
                group.cancelAll()
                await relaySendCredit.stop()
            }
        } onCancel: {
            Task { await self.relaySendCredit.stop() }
        }
        if !stopped {
            stopped = true
            connection.cancel()
            webSocket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func localToRelay() async throws {
        while !Task.isCancelled {
            let (data, complete) = try await receiveFromLocal()
            if let data, !data.isEmpty {
                guard data.count <= HarcRemoteRelayLimits.maximumFrameBytes else {
                    throw HarcRemoteRelayError.relayFrameTooLarge
                }
                try await relaySendCredit.acquire()
                if let frameObserver {
                    await frameObserver(.localToRelay, data)
                }
                try await webSocket.send(.data(data))
            }
            if complete { return }
        }
    }

    private func relayToLocal() async throws {
        while !Task.isCancelled {
            let message = try await webSocket.receive()
            switch message {
            case .data(let data):
                guard data.count <= HarcRemoteRelayLimits.maximumFrameBytes else {
                    throw HarcRemoteRelayError.relayFrameTooLarge
                }
                if let frameObserver {
                    await frameObserver(.relayToLocal, data)
                }
                try await sendToLocal(data)
                try await webSocket.send(.string("ack"))
            case .string("ack"):
                await relaySendCredit.release()
            case .string:
                throw HarcRemoteRelayError.unexpectedRelayText
            @unknown default:
                throw HarcRemoteRelayError.unexpectedRelayText
            }
        }
    }

    private func receiveFromLocal() async throws -> (Data?, Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: HarcRemoteRelayLimits.maximumFrameBytes
                ) { content, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (content, complete))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func sendToLocal(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// One credit means at most one 1 MiB frame can be outstanding in this
/// direction, independent of URLSession or Workers WebSocket queue behavior.
private actor HarcRemoteRelayCreditGate {
    private var available = true
    private var stopped = false
    private var waiter: CheckedContinuation<Void, any Error>?

    func acquire() async throws {
        if stopped { throw CancellationError() }
        if available {
            available = false
            return
        }
        guard waiter == nil else {
            throw HarcRemoteRelayError.invalidHostControlMessage
        }
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        guard !stopped else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            available = true
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        available = false
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }
}

private actor HarcRemoteRelayListenerGate {
    private let listener: NWListener
    private var result: Result<UInt16, any Error>?
    private var continuation: CheckedContinuation<UInt16, any Error>?

    init(listener: NWListener) {
        self.listener = listener
    }

    func waitUntilReady() async throws -> UInt16 {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func received(_ state: NWListener.State) {
        guard result == nil else { return }
        let resolved: Result<UInt16, any Error>?
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                resolved = .success(port)
            } else {
                resolved = .failure(HarcRemoteRelayError.listenerStopped)
            }
        case .failed(let error):
            resolved = .failure(
                HarcRemoteRelayError.listenerFailed(String(describing: error))
            )
        case .cancelled:
            resolved = .failure(HarcRemoteRelayError.listenerStopped)
        case .setup, .waiting:
            resolved = nil
        @unknown default:
            resolved = .failure(HarcRemoteRelayError.listenerStopped)
        }
        guard let resolved else { return }
        result = resolved
        if let continuation {
            self.continuation = nil
            continuation.resume(with: resolved)
        }
    }
}

private func relayURL(
    origin: URL,
    scheme: String,
    path: String
) throws -> URL {
    guard var components = URLComponents(
        url: origin,
        resolvingAgainstBaseURL: false
    ) else { throw HarcRemoteRelayError.invalidServiceOrigin }
    components.scheme = scheme
    components.path = path
    guard let url = components.url else {
        throw HarcRemoteRelayError.invalidServiceOrigin
    }
    return url
}

private func makeEphemeralRelaySession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 30
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
}

private func completeReadyHandshake(
    _ task: URLSessionWebSocketTask
) async throws {
    try await task.send(.string("ready"))
    let ready = try await withThrowingTaskGroup(
        of: URLSessionWebSocketTask.Message.self
    ) { group in
        group.addTask { try await task.receive() }
        group.addTask {
            try await Task.sleep(for: HarcRemoteRelayLimits.connectionTimeout)
            throw HarcRemoteRelayError.invalidWebSocketReady
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw HarcRemoteRelayError.invalidWebSocketReady
        }
        return first
    }
    guard case .string("ready") = ready else {
        throw HarcRemoteRelayError.invalidWebSocketReady
    }
}

private func sendPing(_ task: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        task.sendPing { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

private extension Data {
    func base64URLEncodedWithoutPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func currentTimeMilliseconds() -> UInt64 {
    UInt64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}
#endif
