import Foundation
import HarcDomain
import HarcHost
import Testing
@testable import HarcMCP

@Suite("MCP authority routing")
struct HarcMCPModeRoutingCallerTests {
    private let databaseURL = URL(fileURLWithPath: "/tmp/Harc-routing-test.db")

    @Test("Standalone opens a fresh per-call authority and retains no writer lease")
    func standaloneAuthorityIsPerCall() async {
        let factoryCount = LockedCounter()
        let caller = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "standalone", isError: false)
        }
        let router = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in .standalone },
            standaloneFactory: { _ in
                factoryCount.increment()
                return caller
            },
            hostFactory: {
                Issue.record("Host must not be created in Standalone mode")
                return caller
            }
        )

        _ = await router.call(.init(name: "list_recent", arguments: nil))
        _ = await router.call(.init(name: "list_recent", arguments: nil))

        #expect(factoryCount.value == 2)
        #expect(await caller.callCount == 2)
    }

    @Test("Host mode routes only through the reusable IPC authority")
    func hostRoutesThroughIPC() async {
        let hostFactoryCount = LockedCounter()
        let host = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "host", isError: false)
        }
        let router = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in .host },
            standaloneFactory: { _ in
                Issue.record("Host mode must never open the canonical store directly")
                return host
            },
            hostFactory: {
                hostFactoryCount.increment()
                return host
            }
        )

        let first = await router.call(.init(name: "list_recent", arguments: nil))
        let second = await router.call(.init(name: "search_notes", arguments: nil))

        #expect(first.text == "host")
        #expect(second.text == "host")
        #expect(hostFactoryCount.value == 1)
        #expect(await host.callCount == 2)
    }

    @Test("Adoption winning before issuance redirects every operation once")
    func transitionBeforeIssuanceRedirects() async {
        let mode = LockedWriterMode(.standalone)
        let host = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "redirected", isError: false)
        }
        let router = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in mode.value },
            standaloneFactory: { _ in
                mode.value = .host
                throw TestError.adoptionWon
            },
            hostFactory: { host }
        )

        let response = await router.call(.init(
            name: "append_note",
            arguments: ["recording_id": .int(1), "note": .string("one")]
        ))

        #expect(response.text == "redirected")
        #expect(await host.callCount == 1)
    }

    @Test("A read may replay after adoption but an issued mutation never does")
    func transitionReplayPolicy() async {
        let readMode = LockedWriterMode(.standalone)
        let failedRead = StubMCPCaller { _ in
            readMode.value = .host
            return HarcMCPToolResponse(text: "lease changed", isError: true)
        }
        let hostRead = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "host read", isError: false)
        }
        let readRouter = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in readMode.value },
            standaloneFactory: { _ in failedRead },
            hostFactory: { hostRead }
        )

        let read = await readRouter.call(.init(name: "get_recording", arguments: nil))
        #expect(read.text == "host read")
        #expect(await hostRead.callCount == 1)

        let mutationMode = LockedWriterMode(.standalone)
        let failedMutation = StubMCPCaller { _ in
            mutationMode.value = .host
            return HarcMCPToolResponse(text: "uncertain write", isError: true)
        }
        let hostMutation = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "duplicated", isError: false)
        }
        let mutationRouter = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in mutationMode.value },
            standaloneFactory: { _ in failedMutation },
            hostFactory: { hostMutation }
        )

        let mutation = await mutationRouter.call(.init(
            name: "append_note",
            arguments: ["recording_id": .int(1), "note": .string("one")]
        ))
        #expect(mutation.text == "uncertain write")
        #expect(await hostMutation.callCount == 0)
    }

    @Test("A mutation rejected before its body routes safely to Host")
    func preBodyMutationRejectionRoutes() async {
        let mode = LockedWriterMode(.standalone)
        let rejectedMutation = StubMCPCaller { _ in
            mode.value = .host
            return HarcMCPToolResponse(
                text: "authority changed",
                isError: true,
                failureReason: .authorityUnavailable
            )
        }
        let host = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "host mutation", isError: false)
        }
        let router = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: true,
            metadataInspector: { _ in mode.value },
            standaloneFactory: { _ in rejectedMutation },
            hostFactory: { host }
        )

        let response = await router.call(.init(
            name: "append_note",
            arguments: ["recording_id": .int(1), "note": .string("one")]
        ))

        #expect(response.text == "host mutation")
        #expect(await host.callCount == 1)
    }

    @Test("A Host-owned db override cannot connect to the default Host socket")
    func customHostDatabaseFailsClosed() async {
        let hostFactoryCount = LockedCounter()
        let fallback = StubMCPCaller { _ in
            HarcMCPToolResponse(text: "wrong library", isError: false)
        }
        let router = HarcMCPModeRoutingCaller(
            databaseURL: databaseURL,
            permitsDefaultHostSocket: false,
            metadataInspector: { _ in .host },
            standaloneFactory: { _ in fallback },
            hostFactory: {
                hostFactoryCount.increment()
                return fallback
            }
        )

        let response = await router.call(.init(name: "list_recent", arguments: nil))

        #expect(response.isError)
        #expect(response.text.contains("--db override"))
        #expect(hostFactoryCount.value == 0)
        #expect(await fallback.callCount == 0)
    }
}

private actor StubMCPCaller: HarcMCPToolCalling {
    private let handler: @Sendable (HarcMCPToolRequest) -> HarcMCPToolResponse
    private(set) var callCount = 0

    init(handler: @escaping @Sendable (HarcMCPToolRequest) -> HarcMCPToolResponse) {
        self.handler = handler
    }

    func call(_ request: HarcMCPToolRequest) -> HarcMCPToolResponse {
        callCount += 1
        return handler(request)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedWriterMode: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LibraryWriterMode

    init(_ value: LibraryWriterMode) {
        storage = value
    }

    var value: LibraryWriterMode {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private enum TestError: Error {
    case adoptionWon
}
