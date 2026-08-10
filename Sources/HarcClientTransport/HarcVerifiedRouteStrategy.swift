/// A client connection path is usable only after an authenticated,
/// idempotent Host operation succeeds on it. Creating a transport owner is not
/// proof that DNS, TLS, HTTP/2, or the encrypted relay is usable.
public enum HarcVerifiedRoutePath: Sendable {
    case direct
    case encryptedRelay
}

public struct HarcVerifiedRouteSelection<Connection: Sendable>: Sendable {
    public let connection: Connection
    public let path: HarcVerifiedRoutePath

    init(connection: Connection, path: HarcVerifiedRoutePath) {
        self.connection = connection
        self.path = path
    }
}

public struct HarcVerifiedRouteFailure: Error {
    public let directError: any Error
    public let relayError: (any Error)?

    public var triedEncryptedRelay: Bool { relayError != nil }

    init(directError: any Error, relayError: (any Error)?) {
        self.directError = directError
        self.relayError = relayError
    }
}

/// Transport-independent direct-then-relay policy shared by iOS and macOS.
/// Every candidate must pass `verify`; rejected connections are closed before
/// failover or returning an error.
public enum HarcVerifiedRouteStrategy {
    public static func openVerified<Connection: Sendable>(
        direct: @escaping @Sendable () async throws -> Connection,
        relay: (@Sendable () async throws -> Connection)?,
        verify: @escaping @Sendable (Connection) async throws -> Void,
        close: @escaping @Sendable (Connection) async -> Void
    ) async throws -> HarcVerifiedRouteSelection<Connection> {
        var directConnection: Connection?
        do {
            let connection = try await direct()
            directConnection = connection
            try await verify(connection)
            return HarcVerifiedRouteSelection(
                connection: connection,
                path: .direct
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
                try await verify(connection)
                return HarcVerifiedRouteSelection(
                    connection: connection,
                    path: .encryptedRelay
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
