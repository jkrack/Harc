#if os(macOS) && canImport(Network)
import CryptoKit
import Foundation
@testable import HarcClientTransport
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
@testable import HarcIdentity
import HarcProtocol
@testable import HarcRemoteTransport
import HarcStore
import HarcTransfer
@preconcurrency import Network
import Testing

actor RelayFrameRecorder {
    private var frames: [Data] = []

    func record(_ data: Data) {
        frames.append(data)
    }

    func snapshot() -> [Data] { frames }
}

extension Array where Element == Data {
    func containsPlaintext(_ plaintext: Data) -> Bool {
        contains { frame in
            frame.range(of: plaintext) != nil
        }
    }
}

/// Opt-in production-path bridge for `wrangler dev`. The outer emulator uses
/// loopback HTTP/WebSocket, while the bytes it forwards are the real pinned
/// TLS 1.3 connection created by `HarcPinnedGRPCConnection` below.
final actor RelayEmulatorTunnel:
    HarcPinnedConnectionTransportLifetime
{
    nonisolated let localHost = "127.0.0.1"
    nonisolated let localPort: UInt16

    private struct Offer: Decodable {
        let type: String?
        let sessionID: String
        let capability: String
        let expiresAt: UInt64
    }

    private let listener: NWListener
    private let session: URLSession
    private let controlSocket: URLSessionWebSocketTask
    private let hostSocket: URLSessionWebSocketTask
    private let clientSocket: URLSessionWebSocketTask
    private let hostPump: HarcRemoteRelayBytePump
    private let recorder: RelayFrameRecorder
    private var clientPump: HarcRemoteRelayBytePump?
    private var stopped = false

    static func open(
        origin: URL,
        hostTLSPort: UInt16,
        recorder: RelayFrameRecorder
    ) async throws -> RelayEmulatorTunnel {
        guard origin.scheme == "http" || origin.scheme == "https" else {
            throw RelayEmulatorError.invalidOrigin
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)

        let hostRouteID = try HarcRemoteRelaySecrets.randomOpaqueToken()
        let hostCapability = try HarcRemoteRelaySecrets.randomOpaqueToken()
        let deviceRouteID = try HarcRemoteRelaySecrets.randomOpaqueToken()
        let deviceCapability = try HarcRemoteRelaySecrets.randomOpaqueToken()
        let deviceCapabilityHash = try HarcRemoteRelaySecrets
            .hashOpaqueToken(deviceCapability)

        let controlSocket = session.webSocketTask(
            with: try request(
                origin: origin,
                path: "/v1/hosts/\(hostRouteID)/connect",
                webSocket: true,
                headers: [
                    "X-Harc-Relay-Capability": hostCapability,
                ]
            )
        )
        controlSocket.resume()
        let expiresAt = UInt64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        ) + 60_000
        let commandData = try JSONSerialization.data(
            withJSONObject: [
                "capabilityHash": deviceCapabilityHash,
                "expiresAt": expiresAt,
                "kind": "device",
                "routeID": deviceRouteID,
                "type": "authorize",
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let command = String(data: commandData, encoding: .utf8) else {
            throw RelayEmulatorError.invalidControlMessage
        }
        try await controlSocket.send(.string(command))
        guard case .string("authorized") = try await receive(controlSocket) else {
            throw RelayEmulatorError.invalidControlMessage
        }

        var sessionRequest = try request(
            origin: origin,
            path: "/v1/hosts/\(hostRouteID)/sessions",
            webSocket: false,
            headers: [
                "Content-Length": "0",
                "X-Harc-Relay-Capability": deviceCapability,
                "X-Harc-Relay-Device-Route": deviceRouteID,
            ]
        )
        sessionRequest.httpMethod = "POST"
        let clientOfferTask = Task { try await session.data(for: sessionRequest) }
        guard case .string(let hostOfferText) = try await receive(controlSocket),
              let hostOfferData = hostOfferText.data(using: .utf8) else {
            clientOfferTask.cancel()
            throw RelayEmulatorError.invalidSessionOffer
        }
        let (clientOfferData, clientOfferResponse) = try await clientOfferTask.value
        guard let http = clientOfferResponse as? HTTPURLResponse,
              http.statusCode == 201 else {
            throw RelayEmulatorError.invalidSessionOffer
        }
        let decoder = JSONDecoder()
        let hostOffer = try decoder.decode(Offer.self, from: hostOfferData)
        let clientOffer = try decoder.decode(Offer.self, from: clientOfferData)
        guard hostOffer.type == "session",
              hostOffer.sessionID == clientOffer.sessionID,
              hostOffer.expiresAt == clientOffer.expiresAt else {
            throw RelayEmulatorError.invalidSessionOffer
        }

        let hostSocket = session.webSocketTask(
            with: try request(
                origin: origin,
                path: "/v1/sessions/\(hostOffer.sessionID)/connect",
                webSocket: true,
                headers: [
                    "X-Harc-Relay-Capability": hostOffer.capability,
                    "X-Harc-Relay-Role": "host",
                ]
            )
        )
        let clientSocket = session.webSocketTask(
            with: try request(
                origin: origin,
                path: "/v1/sessions/\(clientOffer.sessionID)/connect",
                webSocket: true,
                headers: [
                    "X-Harc-Relay-Capability": clientOffer.capability,
                    "X-Harc-Relay-Role": "client",
                ]
            )
        )
        hostSocket.maximumMessageSize = HarcRemoteRelayLimits.maximumFrameBytes
        clientSocket.maximumMessageSize = HarcRemoteRelayLimits.maximumFrameBytes
        hostSocket.resume()
        clientSocket.resume()
        async let hostReady: Void = ready(hostSocket)
        async let clientReady: Void = ready(clientSocket)
        _ = try await (hostReady, clientReady)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { connection in connection.cancel() }
        let listenerGate = RelayListenerGate(listener: listener)
        listener.stateUpdateHandler = { state in
            Task { await listenerGate.received(state) }
        }
        listener.start(
            queue: DispatchQueue(label: "com.harc.tests.relay-emulator")
        )
        let localPort = try await listenerGate.waitUntilReady()
        guard let targetPort = NWEndpoint.Port(rawValue: hostTLSPort) else {
            throw RelayEmulatorError.invalidHostPort
        }
        let hostConnection = NWConnection(
            host: .ipv4(.loopback),
            port: targetPort,
            using: .tcp
        )
        let observer: @Sendable (
            HarcRemoteRelayFrameDirection,
            Data
        ) async -> Void = { _, data in
            await recorder.record(data)
        }
        let hostPump = HarcRemoteRelayBytePump(
            connection: hostConnection,
            webSocket: hostSocket,
            frameObserver: observer
        )
        let tunnel = RelayEmulatorTunnel(
            localPort: localPort,
            listener: listener,
            session: session,
            controlSocket: controlSocket,
            hostSocket: hostSocket,
            clientSocket: clientSocket,
            hostPump: hostPump,
            recorder: recorder
        )
        listener.newConnectionHandler = { [weak tunnel] connection in
            guard let tunnel else {
                connection.cancel()
                return
            }
            Task { await tunnel.accept(connection) }
        }
        await hostPump.start()
        return tunnel
    }

    private init(
        localPort: UInt16,
        listener: NWListener,
        session: URLSession,
        controlSocket: URLSessionWebSocketTask,
        hostSocket: URLSessionWebSocketTask,
        clientSocket: URLSessionWebSocketTask,
        hostPump: HarcRemoteRelayBytePump,
        recorder: RelayFrameRecorder
    ) {
        self.localPort = localPort
        self.listener = listener
        self.session = session
        self.controlSocket = controlSocket
        self.hostSocket = hostSocket
        self.clientSocket = clientSocket
        self.hostPump = hostPump
        self.recorder = recorder
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        await clientPump?.shutdown()
        clientPump = nil
        await hostPump.shutdown()
        controlSocket.cancel(with: .goingAway, reason: nil)
        hostSocket.cancel(with: .goingAway, reason: nil)
        clientSocket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped, clientPump == nil else {
            connection.cancel()
            return
        }
        listener.cancel()
        let observer: @Sendable (
            HarcRemoteRelayFrameDirection,
            Data
        ) async -> Void = { [recorder] _, data in
            await recorder.record(data)
        }
        let pump = HarcRemoteRelayBytePump(
            connection: connection,
            webSocket: clientSocket,
            frameObserver: observer
        )
        clientPump = pump
        await pump.start()
    }

    private static func request(
        origin: URL,
        path: String,
        webSocket: Bool,
        headers: [String: String]
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: origin,
            resolvingAgainstBaseURL: false
        ) else { throw RelayEmulatorError.invalidOrigin }
        if webSocket {
            components.scheme = origin.scheme == "https" ? "wss" : "ws"
        }
        components.path = path
        guard let url = components.url else {
            throw RelayEmulatorError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private static func ready(_ socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string("ready"))
        guard case .string("ready") = try await receive(socket) else {
            throw RelayEmulatorError.invalidReady
        }
    }

    private static func receive(
        _ socket: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw RelayEmulatorError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw RelayEmulatorError.timeout
            }
            return value
        }
    }
}

private actor RelayListenerGate {
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
        let next: Result<UInt16, any Error>?
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                next = .success(port)
            } else {
                next = .failure(RelayEmulatorError.invalidHostPort)
            }
        case .failed(let error):
            next = .failure(error)
        case .cancelled:
            next = .failure(CancellationError())
        case .setup, .waiting:
            next = nil
        @unknown default:
            next = .failure(RelayEmulatorError.invalidHostPort)
        }
        guard let next else { return }
        result = next
        if let continuation {
            self.continuation = nil
            continuation.resume(with: next)
        }
    }
}

private enum RelayEmulatorError: Error {
    case invalidOrigin
    case invalidControlMessage
    case invalidSessionOffer
    case invalidReady
    case invalidHostPort
    case timeout
}


#endif
