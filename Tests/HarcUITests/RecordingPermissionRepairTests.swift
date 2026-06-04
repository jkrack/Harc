import Testing
@testable import HarcUI

@Suite("RecordingPermissionRepair")
struct RecordingPermissionRepairTests {
    @Test("current plan targets microphone and screen capture for bundle id")
    func currentPlanTargetsCapturePermissions() {
        let plan = RecordingPermissionRepairPlan.current(bundleID: "com.harc.Harc")

        #expect(plan?.bundleID == "com.harc.Harc")
        #expect(plan?.services == [.microphone, .screenCapture])
        #expect(plan?.tccutilArguments == [
            ["reset", "Microphone", "com.harc.Harc"],
            ["reset", "ScreenCapture", "com.harc.Harc"],
        ])
    }

    @Test("current plan rejects missing bundle id")
    func currentPlanRejectsMissingBundleID() {
        #expect(RecordingPermissionRepairPlan.current(bundleID: nil) == nil)
        #expect(RecordingPermissionRepairPlan.current(bundleID: "") == nil)
    }
}
