import SwiftUI

@main
struct HarcMobileApp: App {
    @UIApplicationDelegateAdaptor(HarcMobileAppDelegate.self)
    private var appDelegate
    @State private var model = HarcMobileAppModel()

#if DEBUG
    private var uiTestAppearance: ColorScheme? {
        guard (try? HarcMobileUITestConfiguration.rootID(arguments: ProcessInfo.processInfo.arguments)) != nil else { return nil }
        switch ProcessInfo.processInfo.environment["HARC_UI_TEST_APPEARANCE"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
#endif

    var body: some Scene {
        WindowGroup {
            HarcMobileRootView()
                .environment(model)
#if DEBUG
                .preferredColorScheme(uiTestAppearance)
#endif
                .task { await model.bootstrap() }
        }
    }
}
