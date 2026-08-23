import HarcClientTransport
import Testing

@Suite("Verified Host route strategy")
struct HarcVerifiedRouteStrategyTests {
    private enum Failure: Error {
        case direct
        case recovered
        case persistence
        case relay
    }

    private actor Events {
        private var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }

        func snapshot() -> [String] {
            values
        }
    }

    @Test("direct route wins only after verification")
    func verifiedDirectRouteWins() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy.openVerified(
            direct: {
                await events.append("open-direct")
                return "direct"
            },
            relay: {
                await events.append("open-relay")
                return "relay"
            },
            verify: { connection in
                await events.append("verify-\(connection)")
            },
            close: { connection in
                await events.append("close-\(connection)")
            }
        )

        #expect(selected.connection == "direct")
        #expect(selected.path == .direct)
        #expect(await events.snapshot() == ["open-direct", "verify-direct"])
    }

    @Test("failed first RPC closes direct route and verifies relay")
    func firstRPCFailureFallsBackToRelay() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy.openVerified(
            direct: {
                await events.append("open-direct")
                return "direct"
            },
            relay: {
                await events.append("open-relay")
                return "relay"
            },
            verify: { connection in
                await events.append("verify-\(connection)")
                if connection == "direct" {
                    throw Failure.direct
                }
                return "authenticated-\(connection)"
            },
            close: { connection in
                await events.append("close-\(connection)")
            }
        )

        #expect(selected.connection == "relay")
        #expect(selected.path == .encryptedRelay)
        #expect(selected.verification == "authenticated-relay")
        #expect(
            await events.snapshot() == [
                "open-direct",
                "verify-direct",
                "close-direct",
                "open-relay",
                "verify-relay",
            ]
        )
    }

    @Test("rejected relay is closed and reports both route failures")
    func rejectedRelayIsClosed() async {
        let events = Events()
        do {
            _ = try await HarcVerifiedRouteStrategy.openVerified(
                direct: { "direct" },
                relay: { "relay" },
                verify: { connection in
                    await events.append("verify-\(connection)")
                    throw connection == "direct"
                        ? Failure.direct
                        : Failure.relay
                },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )
            Issue.record("Expected both routes to fail")
        } catch let error as HarcVerifiedRouteFailure {
            #expect(error.triedEncryptedRelay)
            #expect(error.directError is Failure)
            #expect(error.relayError is Failure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(
            await events.snapshot() == [
                "verify-direct",
                "close-direct",
                "verify-relay",
                "close-relay",
            ]
        )
    }

    @Test("missing relay reports a direct-only failure")
    func missingRelayReportsDirectFailure() async {
        let events = Events()
        do {
            _ = try await HarcVerifiedRouteStrategy.openVerified(
                direct: { "direct" },
                relay: nil,
                verify: { _ in throw Failure.direct },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )
            Issue.record("Expected the direct route to fail")
        } catch let error as HarcVerifiedRouteFailure {
            #expect(!error.triedEncryptedRelay)
            #expect(error.directError is Failure)
            #expect(error.relayError == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await events.snapshot() == ["close-direct"])
    }

    @Test("route failure exposes the underlying cause to the recovery UI")
    func routeFailureHasUsefulDescription() async {
        do {
            _ = try await HarcVerifiedRouteStrategy.openVerified(
                direct: { "direct" },
                relay: { "relay" },
                verify: { connection in
                    throw connection == "direct"
                        ? Failure.direct
                        : Failure.relay
                },
                close: { _ in }
            )
            Issue.record("Expected both routes to fail")
        } catch let error as HarcVerifiedRouteFailure {
            #expect(error.localizedDescription.contains("direct"))
            #expect(error.localizedDescription.contains("relay"))
            #expect(!error.localizedDescription.contains("error 1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("authenticated recovered direct route wins before relay")
    func recoveredDirectWinsBeforeRelay() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy
            .openRecoveringVerified(
                direct: {
                    await events.append("open-stale")
                    return "stale"
                },
                recoveryCandidates: {
                    await events.append("discover")
                    return ["impostor", "moved-host"]
                },
                recoveredDirect: { candidate in
                    await events.append("open-\(candidate)")
                    return candidate
                },
                relay: {
                    await events.append("open-relay")
                    return "relay"
                },
                verify: { connection in
                    await events.append("verify-\(connection)")
                    if connection == "stale" { throw Failure.direct }
                    if connection == "impostor" { throw Failure.recovered }
                    return "authenticated-\(connection)"
                },
                acceptRecovered: { candidate in
                    await events.append("persist-\(candidate)")
                },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )

        #expect(selected.connection == "moved-host")
        #expect(selected.path == .direct)
        #expect(selected.verification == "authenticated-moved-host")
        #expect(
            await events.snapshot() == [
                "open-stale",
                "verify-stale",
                "close-stale",
                "discover",
                "open-impostor",
                "verify-impostor",
                "close-impostor",
                "open-moved-host",
                "verify-moved-host",
                "persist-moved-host",
            ]
        )
    }

    @Test("relay is used only after every recovered direct route is rejected")
    func relayFollowsRecoveredDirectFailures() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy
            .openRecoveringVerified(
                direct: { "stale" },
                recoveryCandidates: { ["wrong-host"] },
                recoveredDirect: { $0 },
                relay: {
                    await events.append("open-relay")
                    return "relay"
                },
                verify: { connection in
                    await events.append("verify-\(connection)")
                    if connection != "relay" { throw Failure.recovered }
                    return connection
                },
                acceptRecovered: { candidate in
                    await events.append("persist-\(candidate)")
                },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )

        #expect(selected.path == .encryptedRelay)
        #expect(selected.connection == "relay")
        #expect(
            await events.snapshot() == [
                "verify-stale",
                "close-stale",
                "verify-wrong-host",
                "close-wrong-host",
                "open-relay",
                "verify-relay",
            ]
        )
    }

    @Test("a recovered route is closed when durable acceptance fails")
    func persistenceFailureDoesNotSelectRecoveredRoute() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy
            .openRecoveringVerified(
                direct: { "stale" },
                recoveryCandidates: { ["moved-host"] },
                recoveredDirect: { $0 },
                relay: { "relay" },
                verify: { connection in
                    await events.append("verify-\(connection)")
                    if connection == "stale" { throw Failure.direct }
                    return connection
                },
                acceptRecovered: { _ in throw Failure.persistence },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )

        #expect(selected.path == .encryptedRelay)
        #expect(selected.connection == "relay")
        #expect(
            await events.snapshot() == [
                "verify-stale",
                "close-stale",
                "verify-moved-host",
                "close-moved-host",
                "verify-relay",
            ]
        )
    }

    @Test("healthy persisted direct route does not start discovery")
    func healthyDirectSkipsRecovery() async throws {
        let events = Events()
        let selected = try await HarcVerifiedRouteStrategy
            .openRecoveringVerified(
                direct: { "direct" },
                recoveryCandidates: {
                    await events.append("discover")
                    return ["unused"]
                },
                recoveredDirect: { $0 },
                relay: { "relay" },
                verify: { $0 },
                acceptRecovered: { _ in },
                close: { _ in }
            )

        #expect(selected.path == .direct)
        #expect(await events.snapshot().isEmpty)
    }
}
