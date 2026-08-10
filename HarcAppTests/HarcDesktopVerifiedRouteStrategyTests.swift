import Foundation
import Testing
@testable import Harc

@Suite("Desktop Host route verification")
struct HarcDesktopVerifiedRouteStrategyTests {
    private enum Failure: Error {
        case direct
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

        let selected = try await HarcDesktopVerifiedRouteStrategy.openVerified(
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

        let selected = try await HarcDesktopVerifiedRouteStrategy.openVerified(
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
            },
            close: { connection in
                await events.append("close-\(connection)")
            }
        )

        #expect(selected.connection == "relay")
        #expect(selected.path == .encryptedRelay)
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

    @Test("rejected relay is closed and reported with direct failure")
    func rejectedRelayIsClosed() async {
        let events = Events()

        do {
            _ = try await HarcDesktopVerifiedRouteStrategy.openVerified(
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
        } catch let error as HarcDesktopHostRouteFailure {
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
            _ = try await HarcDesktopVerifiedRouteStrategy.openVerified(
                direct: { "direct" },
                relay: nil,
                verify: { _ in throw Failure.direct },
                close: { connection in
                    await events.append("close-\(connection)")
                }
            )
            Issue.record("Expected the direct route to fail")
        } catch let error as HarcDesktopHostRouteFailure {
            #expect(!error.triedEncryptedRelay)
            #expect(error.directError is Failure)
            #expect(error.relayError == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await events.snapshot() == ["close-direct"])
    }
}
