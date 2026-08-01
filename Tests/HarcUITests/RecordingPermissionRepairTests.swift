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

    // MARK: - Core grant history

    /// The bug this guards: the welcome re-offer used to be gated once per
    /// build, and every Sparkle update mints a new build number — so a user
    /// who deliberately declined a grant got the full welcome flow again on
    /// every single update. Revocation must mean granted → ungranted, not
    /// merely "ungranted right now".
    @Test("never-granted is a standing choice, not a revocation")
    func neverGrantedIsNotARevocation() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let declined = PermissionSnapshot(microphone: true, screenCapture: false, accessibility: false)

        // No history at all — first launch of this mechanism.
        #expect(!CoreGrantHistory.revocationDetected(current: declined, defaults: defaults))

        // History agrees the grant was never there.
        CoreGrantHistory.record(declined, defaults: defaults)
        #expect(!CoreGrantHistory.revocationDetected(current: declined, defaults: defaults))
    }

    @Test("a grant seen granted that goes missing is a revocation")
    func grantedToUngrantedIsARevocation() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let healthy = PermissionSnapshot(microphone: true, screenCapture: true, accessibility: true)
        CoreGrantHistory.record(healthy, defaults: defaults)

        let micLost = PermissionSnapshot(microphone: false, screenCapture: true, accessibility: true)
        let axLost = PermissionSnapshot(microphone: true, screenCapture: true, accessibility: false)
        #expect(CoreGrantHistory.revocationDetected(current: micLost, defaults: defaults))
        #expect(CoreGrantHistory.revocationDetected(current: axLost, defaults: defaults))
    }

    /// Screen capture degrades rather than breaks (`coreGrantsIntact`
    /// excludes it), so losing it must not summon the welcome flow.
    @Test("losing screen capture alone is not a revocation")
    func screenCaptureLossIsNotARevocation() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let healthy = PermissionSnapshot(microphone: true, screenCapture: true, accessibility: true)
        CoreGrantHistory.record(healthy, defaults: defaults)

        let scLost = PermissionSnapshot(microphone: true, screenCapture: false, accessibility: true)
        #expect(!CoreGrantHistory.revocationDetected(current: scLost, defaults: defaults))
    }

    @Test("recording the ungranted state makes the nag one-shot")
    func recordConsumesTheTransition() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CoreGrantHistory.record(
            PermissionSnapshot(microphone: true, screenCapture: true, accessibility: true),
            defaults: defaults
        )
        let revoked = PermissionSnapshot(microphone: false, screenCapture: true, accessibility: false)
        #expect(CoreGrantHistory.revocationDetected(current: revoked, defaults: defaults))

        // What the launch path does right after checking.
        CoreGrantHistory.record(revoked, defaults: defaults)
        #expect(!CoreGrantHistory.revocationDetected(current: revoked, defaults: defaults))
    }

    /// noteGranted runs on every app activation, including after a
    /// mid-session revocation the user hasn't seen yet — it must never
    /// downgrade a remembered grant, or the evidence would be erased before
    /// the next launch could act on it.
    @Test("noteGranted upgrades the baseline but never downgrades it")
    func noteGrantedOnlyUpgrades() {
        let suiteName = "RecordingPermissionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Mid-session grant with no prior history is remembered…
        CoreGrantHistory.noteGranted(
            PermissionSnapshot(microphone: true, screenCapture: false, accessibility: false),
            defaults: defaults
        )
        // …and a later activation that reads everything as ungranted
        // (mid-session revocation) must not forget it.
        CoreGrantHistory.noteGranted(
            PermissionSnapshot(microphone: false, screenCapture: false, accessibility: false),
            defaults: defaults
        )
        #expect(CoreGrantHistory.revocationDetected(
            current: PermissionSnapshot(microphone: false, screenCapture: false, accessibility: false),
            defaults: defaults
        ))
    }
}
