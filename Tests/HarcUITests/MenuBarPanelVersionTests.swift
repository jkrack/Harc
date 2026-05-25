import Testing
import HarcCore
@testable import HarcUI

@Suite("Menu bar panel version")
struct MenuBarPanelVersionTests {
    @MainActor
    @Test("bottom footer version includes marketing version and build number")
    func footerVersionIncludesMarketingVersionAndBuildNumber() {
        #expect(MenuBarPanelView.versionDisplayText(build: "12") == "Harc v\(HarcVersion.current) (12)")
    }
}
