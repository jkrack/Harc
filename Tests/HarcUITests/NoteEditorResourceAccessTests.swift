import Foundation
import Testing
@testable import HarcUI

@Suite("Note editor resource access")
struct NoteEditorResourceAccessTests {
    @MainActor
    @Test("installed app editor uses filesystem root read access")
    func installedAppEditorUsesFilesystemRootReadAccess() {
        let htmlURL = URL(fileURLWithPath: "/Applications/Harc.app/Contents/Resources/Harc_HarcUI.bundle/Contents/Resources/index.html")

        #expect(NoteMarkdownWebView.readAccessURL(forEditorHTMLAt: htmlURL).path == "/")
    }

    @MainActor
    @Test("local development editor keeps home directory read access")
    func localDevelopmentEditorKeepsHomeDirectoryReadAccess() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let htmlURL = home
            .appendingPathComponent("Documents/GitHub/Harc/build/local-dist/Harc.app/Contents/Resources/Harc_HarcUI.bundle/Contents/Resources/index.html")

        #expect(NoteMarkdownWebView.readAccessURL(forEditorHTMLAt: htmlURL).path == home.path)
    }
}
