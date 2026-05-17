import Testing
import Foundation
import HarcUI

@Suite("PasteDenyList")
struct PasteDenyListTests {
    @Test("seed contains the critical bundle IDs")
    func seedContainsCriticalIDs() {
        let expected: Set<String> = [
            "com.apple.loginwindow",
            "com.agilebits.onepassword8",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.apple.finder",
            "com.tinyspeck.slackmacgap",
        ]
        #expect(expected.isSubset(of: PasteDenyList.defaultBundleIDs))
    }

    @Test("locked list contains always unsafe bundle IDs")
    func lockedContainsAlwaysUnsafeIDs() {
        let expected: Set<String> = [
            "com.apple.loginwindow",
            "com.apple.ScreenSaver.Engine",
            "com.agilebits.onepassword8",
            "com.bitwarden.desktop",
        ]
        #expect(expected.isSubset(of: PasteDenyList.lockedBundleIDs))
    }

    @Test("isDenied — nil returns false")
    func isDeniedNil() {
        #expect(PasteDenyList.isDenied(nil, in: PasteDenyList.defaultBundleIDs) == false)
    }

    @Test("isDenied — unknown bundle returns false")
    func isDeniedUnknown() {
        #expect(PasteDenyList.isDenied("com.unknown.app", in: PasteDenyList.defaultBundleIDs) == false)
    }

    @Test("isDenied — known bundle returns true")
    func isDeniedKnown() {
        #expect(PasteDenyList.isDenied("com.apple.finder", in: PasteDenyList.defaultBundleIDs) == true)
        #expect(PasteDenyList.isDenied("com.agilebits.onepassword7", in: PasteDenyList.defaultBundleIDs) == true)
    }

    @Test("isDenied — custom bundle set is honored")
    func isDeniedCustomBundleSet() {
        #expect(PasteDenyList.isDenied("com.example.private", in: ["com.example.private"]) == true)
        #expect(PasteDenyList.isDenied("com.apple.finder", in: ["com.example.private"]) == false)
    }
}
