import Foundation

/// A client connection path is usable only after an authenticated,
/// idempotent Host operation succeeds on it. Creating a transport owner is not
/// proof that DNS, TLS, HTTP/2, or the encrypted relay is usable.
public enum HarcVerifiedRoutePath: Equatable, Sendable {
    case direct
    case encryptedRelay
}

public struct HarcVerifiedRouteSelection<
    Connection: Sendable,
    Verification: Sendable
>: Sendable {
    public let connection: Connection
    public let path: HarcVerifiedRoutePath
    /// The authenticated result produced by the operation which selected this
    /// exact connection. Callers can carry it into the next protocol step
    /// instead of repeating verification on a potentially changed route.
    public let verification: Verification

    init(
        connection: Connection,
        path: HarcVerifiedRoutePath,
        verification: Verification
    ) {
        self.connection = connection
        self.path = path
        self.verification = verification
    }
}

public struct HarcVerifiedRouteFailure: Error, LocalizedError {
    public let directError: any Error
    public let relayError: (any Error)?

    public var triedEncryptedRelay: Bool { relayError != nil }

    public var errorDescription: String? {
        let direct = HarcTransportErrorDiagnostic.describe(directError)
        let directMessage = Self.userMessage(direct)
        guard let relayError else {
            return "The direct Host route failed: \(directMessage)"
        }
        let relay = HarcTransportErrorDiagnostic.describe(relayError)
        return "The direct Host route failed: \(directMessage). The encrypted relay also failed: \(Self.userMessage(relay))"
    }

    init(directError: any Error, relayError: (any Error)?) {
        self.directError = directError
        self.relayError = relayError
    }

    private static func userMessage(
        _ diagnostic: HarcTransportErrorDiagnostic
    ) -> String {
        if let code = diagnostic.rpcCode {
            var detail = "gRPC \(code)"
            if let message = diagnostic.rpcMessage, !message.isEmpty {
                detail += ": \(message)"
            } else if let cause = diagnostic.cause, !cause.isEmpty {
                detail += ": \(cause)"
            }
            return detail
        }
        return diagnostic.summary
    }
}

/// Transport-independent direct-then-relay policy shared by iOS and macOS.
/// Every candidate must pass `verify`; rejected connections are closed before
/// failover or returning an error.
public enum HarcVerifiedRouteStrategy {
    public static func openVerified<
        Connection: Sendable,
        Verification: Sendable
    >(
        direct: @escaping @Sendable () async throws -> Connection,
        relay: (@Sendable () async throws -> Connection)?,
        verify: @escaping @Sendable (Connection) async throws -> Verification,
        close: @escaping @Sendable (Connection) async -> Void
    ) async throws -> HarcVerifiedRouteSelection<Connection, Verification> {
        var directConnection: Connection?
        do {
            let connection = try await direct()
            directConnection = connection
            let verification = try await verify(connection)
            return HarcVerifiedRouteSelection(
                connection: connection,
                path: .direct,
                verification: verification
            )
        } catch {
            if let directConnection {
                await close(directConnection)
            }
            let directError = error
            guard let relay else {
                throw HarcVerifiedRouteFailure(
                    directError: directError,
                    relayError: nil
                )
            }

            var relayConnection: Connection?
            do {
                let connection = try await relay()
                relayConnection = connection
                let verification = try await verify(connection)
                return HarcVerifiedRouteSelection(
                    connection: connection,
                    path: .encryptedRelay,
                    verification: verification
                )
            } catch {
                if let relayConnection {
                    await close(relayConnection)
                }
                throw HarcVerifiedRouteFailure(
                    directError: directError,
                    relayError: error
                )
            }
        }
    }
}
