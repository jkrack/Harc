import Foundation
import HarcCore
import Testing

@Suite("Diagnostic log")
@MainActor
struct HarcDiagnosticLogTests {
    @Test("persists structured events and formats deterministic context")
    func persistenceAndFormatting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 1_755_641_234.125)
        let store = try HarcDiagnosticLogStore(
            fileURL: fixture.logURL,
            maximumEntries: 10
        )
        store.append(
            severity: .error,
            area: "transfer",
            stage: "upload-chunk",
            message: "RPC cancelled",
            context: ["route": "relay", "chunk": "0/15"],
            at: timestamp
        )

        let reloaded = try HarcDiagnosticLogStore(
            fileURL: fixture.logURL,
            maximumEntries: 10
        )
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries[0].message == "RPC cancelled")
        #expect(reloaded.entries[0].context["route"] == "relay")
        #expect(
            reloaded.formattedText().contains(
                "chunk=0/15 route=relay"
            )
        )
    }

    @Test("retains only the newest bounded events and clear survives relaunch")
    func boundedRetentionAndClear() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try HarcDiagnosticLogStore(
            fileURL: fixture.logURL,
            maximumEntries: 2
        )
        for index in 0 ..< 3 {
            store.append(
                severity: .info,
                area: "test",
                stage: "event",
                message: "event-\(index)"
            )
        }
        #expect(store.entries.map(\.message) == ["event-1", "event-2"])

        store.clear()
        let reloaded = try HarcDiagnosticLogStore(
            fileURL: fixture.logURL,
            maximumEntries: 2
        )
        #expect(reloaded.entries.isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let logURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-diagnostic-log-\(UUID().uuidString)",
            isDirectory: true
        )
        logURL = root.appendingPathComponent("client.jsonl")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
