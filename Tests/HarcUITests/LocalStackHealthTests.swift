import Testing
@testable import HarcUI

@Suite("LocalStackHealth")
struct LocalStackHealthTests {
    @Test("model returns all local stack dependencies")
    func returnsAllDependencies() {
        let items = LocalStackHealthModel.items(for: fullyReadyInput)

        #expect(items.map(\.id) == [
            .destination,
            .capture,
            .stt,
            .summarizer,
            .embedder,
            .speakerID,
            .notifications,
            .accessibility,
        ])
        #expect(items.allSatisfy { $0.state == .ready })
    }

    @Test("capture-critical failures are warnings while optional features are muted")
    func severityDistinguishesRequiredAndOptionalCapabilities() {
        var input = fullyReadyInput
        input.destinationReady = false
        input.captureReady = false
        input.summarizerReady = false
        input.embedderReady = false
        input.notificationsReady = false

        let states = Dictionary(uniqueKeysWithValues: LocalStackHealthModel.items(for: input).map { ($0.id, $0.state) })

        #expect(states[.destination] == .warning)
        #expect(states[.capture] == .warning)
        #expect(states[.summarizer] == .muted)
        #expect(states[.embedder] == .muted)
        #expect(states[.notifications] == .muted)
    }

    private var fullyReadyInput: LocalStackHealthInput {
        LocalStackHealthInput(
            destinationReady: true,
            destinationText: "Destination ready",
            captureReady: true,
            captureText: "Capture ready",
            sttReady: true,
            sttText: "STT ready",
            summarizerReady: true,
            summarizerText: "Summaries ready",
            embedderReady: true,
            embedderText: "Search ready",
            speakerIDReady: true,
            speakerIDText: "Speaker ID ready",
            notificationsReady: true,
            notificationsText: "Notifications ready",
            accessibilityReady: true,
            accessibilityText: "Paste ready"
        )
    }
}
