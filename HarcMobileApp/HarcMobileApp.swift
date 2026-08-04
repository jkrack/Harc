import SwiftUI

@main
struct HarcMobileApp: App {
    @UIApplicationDelegateAdaptor(HarcMobileAppDelegate.self)
    private var appDelegate
    @State private var model = HarcMobileAppModel()

    var body: some Scene {
        WindowGroup {
            HarcMobileRootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
    }
}
