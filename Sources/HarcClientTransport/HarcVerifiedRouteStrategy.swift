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
        guard let relayError else {
            return "The adopted Host could not be reached on its saved direct route."
        }
        let relay = HarcTransportErrorDiagnostic.describe(relayError)
        return "The adopted Host could not be reached directly. Harc Remote also could not connect: \(Self.userMessage(relay))"
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
    /// Direct-route recovery used after an adopted Host moves to a different
    /// local address. Discovery candidates are untrusted hints: every one is
    /// opened and passed through the same authenticated `verify` operation as
    /// the persisted route. A candidate is accepted only after
    /// `acceptRecovered` durably records the verified replacement.
    ///
    /// Ordering is intentional. A stale local route must not pin a Client to
    /// the encrypted relay forever merely because the relay is healthy:
    /// persisted direct, authenticated recovered direct, then relay.
    public static func openRecoveringVerified<
        Connection: Sendable,
        Verification: Sendable,
        RecoveryCandidate: Sendable
    >(
        direct: @escaping @Sendable () async throws -> Connection,
        recoveryCandidates: @escaping @Sendable () async
            -> [RecoveryCandidate],
        recoveredDirect: @escaping @Sendable (RecoveryCandidate) async throws
            -> Connection,
        relay: (@Sendable () async throws -> Connection)?,
        verify: @escaping @Sendable (Connection) async throws -> Verification,
        acceptRecovered: @escaping @Sendable (RecoveryCandidate) async throws
            -> Void,
        close: @escaping @Sendable (Connection) async -> Void
    ) async throws -> HarcVerifiedRouteSelection<Connection, Verification> {
        var directConnection: Connection?
        let directError: any Error
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
            if error is CancellationError { throw error }
            directError = error
        }

        var lastRecoveredError: (any Error)?
        for candidate in await recoveryCandidates() {
            try Task.checkCancellation()
            var recoveredConnection: Connection?
            do {
                let connection = try await recoveredDirect(candidate)
                recoveredConnection = connection
                let verification = try await verify(connection)
                try await acceptRecovered(candidate)
                return HarcVerifiedRouteSelection(
                    connection: connection,
                    path: .direct,
                    verification: verification
                )
            } catch {
                if let recoveredConnection {
                    await close(recoveredConnection)
                }
                if error is CancellationError { throw error }
                lastRecoveredError = error
            }
        }

        guard let relay else {
            throw HarcVerifiedRouteFailure(
                directError: lastRecoveredError ?? directError,
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
            if error is CancellationError { throw error }
            throw HarcVerifiedRouteFailure(
                directError: lastRecoveredError ?? directError,
                relayError: error
            )
        }
    }

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
