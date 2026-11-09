import AppKit
import Testing
@testable import Harc

@Suite("Managed window menu identity")
@MainActor
struct HarcManagedWindowMenuTests {
    @Test func runningAppUsesRegularActivationPolicy() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == false)
        #expect(NSApp.activationPolicy() == .regular)
    }

    @Test func closingLastWindowDoesNotTerminateResidentWork() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    @Test func swiftUIEditMenuAloneDoesNotSuppressHarcCommands() {
        let menu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.setSubmenu(edit, for: menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: ""))
        #expect(!AppDelegate.hasManagedWindowCommands(menu))
    }

    @Test func requiresSettingsImportCloseAndSelectAll() {
        let menu = NSMenu()
        let app = NSMenu()
        let file = NSMenu(title: "File")
        let edit = NSMenu(title: "Edit")
        menu.setSubmenu(app, for: menu.addItem(withTitle: "Harc", action: nil, keyEquivalent: ""))
        menu.setSubmenu(file, for: menu.addItem(withTitle: "File", action: nil, keyEquivalent: ""))
        menu.setSubmenu(edit, for: menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: ""))
        app.addItem(withTitle: "Settings…", action: Selector(("harcShowSettingsWindow:")), keyEquivalent: ",")
        file.addItem(withTitle: "Import…", action: Selector(("presentImportOpenPanel:")), keyEquivalent: "i")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        #expect(!AppDelegate.hasManagedWindowCommands(menu))
        let selectAll = edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        #expect(AppDelegate.hasManagedWindowCommands(menu))
        edit.removeItem(selectAll)
        #expect(!AppDelegate.hasManagedWindowCommands(menu))
    }
}
