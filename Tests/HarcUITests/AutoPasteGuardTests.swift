import Testing
import Foundation
import HarcUI

@Suite("AutoPasteGuard")
struct AutoPasteGuardTests {
    @Test("decide — matrix", arguments: [
        // (enabled, shiftHeld, bundleID, expected)
        (false, false, String?.none,                         AutoPasteDecision.skipDisabled),
        (false, true,  String?.none,                         .skipDisabled),
        (false, false, String?.some("com.example.foo"),      .skipDisabled),
        (true,  true,  String?.none,                         .skipModifierHeld),
        (true,  true,  String?.some("com.example.foo"),      .skipModifierHeld),
        (true,  true,  String?.some("com.apple.finder"),     .skipModifierHeld),
        (true,  false, String?.none,                         .paste),
        (true,  false, String?.some("com.example.safe"),     .paste),
        (true,  false, String?.some("com.apple.finder"),     .skipUnsafeTarget(bundleID: "com.apple.finder")),
        (true,  false, String?.some("com.agilebits.onepassword8"), .skipUnsafeTarget(bundleID: "com.agilebits.onepassword8")),
    ])
    func decide(enabled: Bool, shiftHeld: Bool, bundleID: String?, expected: AutoPasteDecision) {
        #expect(AutoPasteGuard.decide(enabled: enabled, shiftHeld: shiftHeld, frontmostBundleID: bundleID) == expected)
    }

    @Test("decide uses supplied deny list")
    func decideUsesSuppliedDenyList() {
        #expect(AutoPasteGuard.decide(
            enabled: true,
            shiftHeld: false,
            frontmostBundleID: "com.example.private",
            deniedBundleIDs: ["com.example.private"]
        ) == .skipUnsafeTarget(bundleID: "com.example.private"))
    }
}
