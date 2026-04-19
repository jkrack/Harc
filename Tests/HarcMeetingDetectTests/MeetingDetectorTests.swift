import Testing
import Foundation
@testable import HarcMeetingDetect

@MainActor
@Suite("MeetingDetector")
final class MeetingDetectorTests {
    final class TestDelegate: MeetingDetector.Delegate {
        var detectedApps: [MeetingApp] = []
        func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp) {
            detectedApps.append(app)
        }
    }

    var workspace: FakeWorkspace
    var delegate: TestDelegate
    var globallyEnabled: Bool
    var appEnabled: [String: Bool]
    var recording: Bool

    init() {
        self.workspace = FakeWorkspace()
        self.delegate = TestDelegate()
        self.globallyEnabled = true
        self.appEnabled = [:]
        self.recording = false
    }

    func makeDetector() -> MeetingDetector {
        let d = MeetingDetector(
            workspace: workspace,
            isGloballyEnabled: { [self] in self.globallyEnabled },
            isAppEnabled: { [self] app in self.appEnabled[app.id] ?? true },
            isRecordingInProgress: { [self] in self.recording }
        )
        d.delegate = delegate
        return d
    }

    /// Drain any Task { @MainActor in … } dispatched by the detector's
    /// workspace handlers before assertions run.
    private func drain() async {
        for _ in 0..<3 { await Task.yield() }
    }

    @Test("launch fires once")
    func launchFiresOnce() async {
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.map(\.id) == ["us.zoom.xos"])
    }

    @Test("duplicate launches are debounced")
    func duplicateLaunchDebounced() async {
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.count == 1)
    }

    @Test("terminate re-arms detection")
    func terminateReArms() async {
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        workspace.simulateTerminate(bundleID: "us.zoom.xos")
        await drain()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.count == 2)
    }

    @Test("already-running apps at start() are skipped")
    func alreadyRunningSkipped() async {
        workspace.runningAppBundleIDs = ["us.zoom.xos"]
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.isEmpty)
    }

    @Test("per-app opt-out suppresses detection")
    func perAppOptOut() async {
        appEnabled["us.zoom.xos"] = false
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.isEmpty)
    }

    @Test("global disabled → start is a no-op")
    func globalDisabledSkipsStart() async {
        globallyEnabled = false
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.isEmpty)
    }

    @Test("unknown bundleID is ignored")
    func unknownBundleIgnored() async {
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "com.apple.finder")
        await drain()
        #expect(delegate.detectedApps.isEmpty)
    }

    @Test("recording in progress suppresses the prompt")
    func recordingInProgressSuppresses() async {
        recording = true
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "us.zoom.xos")
        await drain()
        #expect(delegate.detectedApps.isEmpty)
    }

    @Test("classic Teams bundleID matches the new-Teams catalog entry")
    func teamsAliasing() async {
        let d = makeDetector()
        d.start()
        workspace.simulateLaunch(bundleID: "com.microsoft.teams")
        await drain()
        #expect(delegate.detectedApps.first?.id == "com.microsoft.teams2")
    }
}
