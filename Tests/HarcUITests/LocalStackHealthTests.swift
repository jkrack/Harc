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
            .systemAudio,
            .stt,
            .summarizer,
            .embedder,
            .speakerID,
            .notifications,
            .accessibility,
        ])
        #expect(items.allSatisfy { $0.state == .ready })
    }

    @Test("compatibility shim keeps capture-critical failures as warnings and optional features muted")
    func compatibilityShimDistinguishesRequiredAndOptionalCapabilities() {
        var input = fullyReadyInput
        input.destinationReady = false
        input.captureReady = false
        input.systemAudioReady = false
        input.summarizerReady = false
        input.embedderReady = false
        input.notificationsReady = false

        let states = Dictionary(uniqueKeysWithValues: LocalStackHealthModel.items(for: input).map { ($0.id, $0.state) })

        #expect(states[.destination] == .warning)
        #expect(states[.capture] == .warning)
        #expect(states[.systemAudio] == .warning)
        #expect(states[.summarizer] == .muted)
        #expect(states[.embedder] == .muted)
        #expect(states[.notifications] == .muted)
    }

    @Test("readiness resolver blocks missing destination and microphone")
    func readinessResolverBlocksRequiredCaptureFailures() {
        var input = fullyReadyCaptureInput
        input.destinationReady = false
        input.microphone = .denied

        let items = CaptureReadinessResolver.resolve(input)
        let levels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.level) })

        #expect(levels[.destination] == .blocked)
        #expect(levels[.microphone] == .blocked)
        #expect(CaptureReadinessResolver.summary(for: items) == "Recording blocked")
    }

    @Test("readiness resolver degrades system audio instead of blocking")
    func readinessResolverDegradesSystemAudio() {
        var input = fullyReadyCaptureInput
        input.systemAudio = .denied

        let items = CaptureReadinessResolver.resolve(input)
        let levels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.level) })

        #expect(levels[.systemAudio] == .degraded)
        #expect(CaptureReadinessResolver.summary(for: items) == "Mic only")
    }

    @Test("optional AI features do not make capture look broken")
    func optionalAIStaysCaptureReady() {
        var input = fullyReadyCaptureInput
        input.summarizerReady = false
        input.semanticSearchReady = false
        input.speakerIDReady = false

        let items = CaptureReadinessResolver.resolve(input)
        let levels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.level) })

        #expect(levels[.summarizer] == .optionalOff)
        #expect(levels[.semanticSearch] == .optionalOff)
        #expect(levels[.speakerID] == .optionalOff)
        #expect(CaptureReadinessResolver.summary(for: items) == "Capture ready")
    }

    @Test("pending recovery has its own degraded action state")
    func pendingRecoveryAddsRecoveryItem() {
        var input = fullyReadyCaptureInput
        input.pendingRecoveryCount = 2

        let items = CaptureReadinessResolver.resolve(input)
        let recovery = items.first { $0.id == .recovery }

        #expect(recovery?.level == .degraded)
        #expect(recovery?.action == .openRecoveryInbox)
        #expect(CaptureReadinessResolver.summary(for: items) == "Recovery needed")
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

    private var fullyReadyCaptureInput: CaptureReadinessInput {
        CaptureReadinessInput(
            destinationReady: true,
            destinationText: "Destination ready",
            microphone: .allowed,
            microphoneText: "Microphone ready",
            systemAudio: .allowed,
            systemAudioText: "System audio ready",
            localSTTReady: true,
            localSTTText: "STT ready",
            summarizerReady: true,
            summarizerText: "Summaries ready",
            semanticSearchReady: true,
            semanticSearchText: "Search ready",
            speakerIDReady: true,
            speakerIDText: "Speaker ID ready",
            notificationsReady: true,
            notificationsText: "Notifications ready",
            pastePermissionReady: true,
            pastePermissionText: "Paste ready"
        )
    }
}
