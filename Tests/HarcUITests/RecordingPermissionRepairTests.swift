import Testing
import Foundation
@testable import HarcUI

@Suite("RecordingPermissionRepair")
struct RecordingPermissionRepairTests {
    @Test("current plan resets every permission Harc depends on")
    func currentPlanTargetsEveryPermission() {
        let plan = RecordingPermissionRepairPlan.current(bundleID: "com.harc.Harc")

        #expect(plan?.bundleID == "com.harc.Harc")
        #expect(plan?.services == [.microphone, .screenCapture, .accessibility])
        #expect(plan?.tccutilArguments == [
            ["reset", "Microphone", "com.harc.Harc"],
            ["reset", "ScreenCapture", "com.harc.Harc"],
            ["reset", "Accessibility", "com.harc.Harc"],
        ])
    }

    /// Accessibility is what breaks most reliably when the code signature
    /// changes, and it's what dictation insertion, Esc-cancel, and auto-paste
    /// all depend on. A "reset everything" button that skipped it left the
    /// most likely culprit untouched.
    @Test("accessibility is part of the reset, not just capture permissions")
    func accessibilityIsReset() {
        let plan = RecordingPermissionRepairPlan.current(bundleID: "com.harc.Harc")
        #expect(plan?.services.contains(.accessibility) == true)
    }

    @Test("current plan rejects missing bundle id")
    func currentPlanRejectsMissingBundleID() {
        #expect(RecordingPermissionRepairPlan.current(bundleID: nil) == nil)
        #expect(RecordingPermissionRepairPlan.current(bundleID: "") == nil)
    }

    @Test("every service maps to a System Settings pane")
    func everyServiceHasASettingsDestination() {
        for service in RecordingPermissionService.allCases {
            #expect(
                service.settingsURL != nil,
                "\(service.displayName) has no Settings URL — its fallback button would do nothing."
            )
        }
    }

    /// The screen-capture prompt fires once per install and is silently inert
    /// afterwards, so the UI must route to System Settings rather than call it
    /// and hope. If this ever reports true, the "Grant" button becomes a
    /// button that does nothing for anyone who already declined.
    @Test("screen capture and accessibility never claim an in-process prompt")
    func promptsThatCannotReappearAreNotClaimed() {
        #expect(RecordingPermissionService.screenCapture.canPromptInProcess == false)
        #expect(RecordingPermissionService.accessibility.canPromptInProcess == false)
    }

    @Test("only screen recording is flagged as needing a relaunch")
    func relaunchFlagIsScopedToScreenRecording() {
        #expect(RecordingPermissionService.screenCapture.requiresRelaunchAfterGrant)
        #expect(!RecordingPermissionService.microphone.requiresRelaunchAfterGrant)
        #expect(!RecordingPermissionService.accessibility.requiresRelaunchAfterGrant)
    }

    // MARK: - Snapshot

    @Test("core grants ignore screen capture, which degrades rather than breaks")
    func coreGrantsExcludeScreenCapture() {
        let noScreen = PermissionSnapshot(microphone: true, screenCapture: false, accessibility: true)
        #expect(noScreen.coreGrantsIntact)

        let noMic = PermissionSnapshot(microphone: false, screenCapture: true, accessibility: true)
        #expect(!noMic.coreGrantsIntact)

        let noAX = PermissionSnapshot(microphone: true, screenCapture: true, accessibility: false)
        #expect(!noAX.coreGrantsIntact)
    }

    @Test("missing lists exactly the ungranted services")
    func missingListsUngrantedServices() {
        let snapshot = PermissionSnapshot(microphone: true, screenCapture: false, accessibility: false)
        #expect(snapshot.missing == [.screenCapture, .accessibility])

        let healthy = PermissionSnapshot(microphone: true, screenCapture: true, accessibility: true)
        #expect(healthy.missing.isEmpty)
    }

    // MARK: - Repair handoff

    /// The bug this guards: a reset revokes every grant, the user relaunches,
    /// and the once-per-build re-offer has already been spent — so no repair
    /// guidance appears and the app looks broken. The reset must leave a flag
    /// that forces the next launch to show the flow regardless.
    @Test("reset records a pending repair so the next launch re-offers setup")
    func resetFlagsPendingRepair() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!defaults.bool(forKey: RecordingPermissionRepair.pendingRepairKey))

        // tccutil isn't run here — the flag write is what the launch path
        // reads, so drive it directly through a plan with no services.
        let plan = RecordingPermissionRepairPlan(bundleID: "com.harc.Harc", services: [])
        try? RecordingPermissionRepair.reset(plan: plan, defaults: defaults)

        #expect(
            defaults.bool(forKey: RecordingPermissionRepair.pendingRepairKey),
            "Without this flag the post-reset launch shows no repair guidance."
        )
    }
}
