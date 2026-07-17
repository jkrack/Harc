import Testing
import Foundation
@testable import HarcUI

@MainActor
private final class SpyTapHandle: DictationEscTapHandle {
    private(set) var invalidated = false
    func invalidate() { invalidated = true }
}

@Suite("DictationEscMonitor")
@MainActor
struct DictationEscMonitorTests {

    @Test("installs the tap when listening starts and tears it down when it ends")
    func lifecycle() {
        var created: [SpyTapHandle] = []
        let monitor = DictationEscMonitor(
            isTrusted: { true },
            makeTap: { _ in
                let handle = SpyTapHandle()
                created.append(handle)
                return handle
            },
            onCancel: {}
        )

        #expect(!monitor.isMonitoring)
        monitor.setListening(true)
        #expect(monitor.isMonitoring)
        #expect(created.count == 1)

        monitor.setListening(false)
        #expect(!monitor.isMonitoring)
        #expect(created[0].invalidated)
    }

    @Test("setListening(true) is idempotent — one tap per session")
    func idempotentStart() {
        var createdCount = 0
        let monitor = DictationEscMonitor(
            isTrusted: { true },
            makeTap: { _ in
                createdCount += 1
                return SpyTapHandle()
            },
            onCancel: {}
        )
        monitor.setListening(true)
        monitor.setListening(true)
        #expect(createdCount == 1)
        monitor.setListening(false)
        monitor.setListening(false)
        #expect(!monitor.isMonitoring)
    }

    @Test("skips silently when Accessibility isn't granted")
    func untrustedSkips() {
        var createdCount = 0
        let monitor = DictationEscMonitor(
            isTrusted: { false },
            makeTap: { _ in
                createdCount += 1
                return SpyTapHandle()
            },
            onCancel: {}
        )
        monitor.setListening(true)
        #expect(createdCount == 0)
        #expect(!monitor.isMonitoring)
    }

    @Test("the tap's cancel action reaches the monitor's onCancel")
    func cancelPlumbing() {
        var cancelled = false
        var capturedAction: (@MainActor () -> Void)?
        let monitor = DictationEscMonitor(
            isTrusted: { true },
            makeTap: { action in
                capturedAction = action
                return SpyTapHandle()
            },
            onCancel: { cancelled = true }
        )
        monitor.setListening(true)
        capturedAction?()
        #expect(cancelled)
    }
}
