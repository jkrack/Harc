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
            .speakerID,
            .notifications,
            .accessibility,
            .dictation,
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
        input.notificationsReady = false

        let states = Dictionary(uniqueKeysWithValues: LocalStackHealthModel.items(for: input).map { ($0.id, $0.state) })

        #expect(states[.destination] == .warning)
        #expect(states[.capture] == .warning)
        #expect(states[.systemAudio] == .warning)
        #expect(states[.summarizer] == .muted)
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
        input.speakerIDReady = false

        let items = CaptureReadinessResolver.resolve(input)
        let levels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.level) })

        #expect(levels[.summarizer] == .optionalOff)
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

    @Test("local stack summary text uses product readiness language")
    func localStackSummaryTextSelection() {
        #expect(LocalStackHealthModel.summary(for: localItems(for: fullyReadyCaptureInput)) == "Ready to record")

        var optionalOff = fullyReadyCaptureInput
        optionalOff.summarizerReady = false
        #expect(LocalStackHealthModel.summary(for: localItems(for: optionalOff)) == "Capture ready")

        var micOnly = fullyReadyCaptureInput
        micOnly.systemAudio = .denied
        #expect(LocalStackHealthModel.summary(for: localItems(for: micOnly)) == "Mic only")

        var blocked = fullyReadyCaptureInput
        blocked.microphone = .denied
        #expect(LocalStackHealthModel.summary(for: localItems(for: blocked)) == "Recording blocked")

        var recovery = fullyReadyCaptureInput
        recovery.pendingRecoveryCount = 1
        #expect(LocalStackHealthModel.summary(for: localItems(for: recovery)) == "Recovery needed")
    }

    @Test("expanded local stack groups readiness by product area")
    func expandedLocalStackGroupsByProductArea() {
        var input = fullyReadyCaptureInput
        input.pendingRecoveryCount = 1

        let grouped = LocalStackHealthModel.groupedItems(localItems(for: input))
        let groupIDs: [LocalStackHealthModel.Group: [LocalStackHealthItem.ID]] = Dictionary(
            uniqueKeysWithValues: grouped.map { group, items in
                (group, items.map(\.id))
            }
        )

        #expect(grouped.map { $0.0 } == [
            LocalStackHealthModel.Group.required,
            .quality,
            .afterRecording,
            .dictation,
            .recovery,
        ])
        #expect(groupIDs[.required] == [.destination, .capture, .stt])
        #expect(groupIDs[.quality] == [.systemAudio, .speakerID])
        #expect(groupIDs[.afterRecording] == [.summarizer, .notifications, .accessibility])
        #expect(groupIDs[.dictation] == [.dictation])
        #expect(groupIDs[.recovery] == [.recovery])
    }

    @Test("dictation row is ready only with STT plus Accessibility, and never blocks capture")
    func dictationRowLevels() {
        // Fully ready → dictation ready.
        var input = fullyReadyCaptureInput
        var items = CaptureReadinessResolver.resolve(input)
        #expect(items.first { $0.id == .dictation }?.level == .ready)

        // Missing Accessibility → optional-off with an open-accessibility fix.
        input.pastePermissionReady = false
        items = CaptureReadinessResolver.resolve(input)
        let noAX = items.first { $0.id == .dictation }
        #expect(noAX?.level == .optionalOff)
        #expect(noAX?.action == .openAccessibility)
        #expect(CaptureReadinessResolver.summary(for: items) != "Recording blocked")

        // Missing STT → optional-off, but the fix belongs to the STT row.
        input.pastePermissionReady = true
        input.localSTTReady = false
        items = CaptureReadinessResolver.resolve(input)
        let noSTT = items.first { $0.id == .dictation }
        #expect(noSTT?.level == .optionalOff)
        #expect(noSTT?.action == nil)
    }

    @Test("dictation row reports a cleared hotkey instead of claiming readiness")
    func dictationRowHotkeyCleared() {
        var input = fullyReadyCaptureInput
        input.dictationHotkeySet = false
        let items = CaptureReadinessResolver.resolve(input)
        let row = items.first { $0.id == .dictation }
        #expect(row?.level == .optionalOff)
        #expect(row?.detail == "Set a dictation hotkey in Settings")
        // Never blocks core capture.
        #expect(CaptureReadinessResolver.summary(for: items) != "Recording blocked")
    }

    private func localItems(for input: CaptureReadinessInput) -> [LocalStackHealthItem] {
        LocalStackHealthModel.items(for: CaptureReadinessResolver.resolve(input))
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
            speakerIDReady: true,
            speakerIDText: "Speaker ID ready",
            notificationsReady: true,
            notificationsText: "Notifications ready",
            pastePermissionReady: true,
            pastePermissionText: "Paste ready"
        )
    }
}
