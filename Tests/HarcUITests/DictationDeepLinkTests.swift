import Testing
import Foundation
@testable import HarcUI

@Suite("DictationDeepLink")
struct DictationDeepLinkTests {

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("harc://dictate starts dictation with no mode override")
    func dictatePlain() {
        #expect(DictationDeepLink.parse(url("harc://dictate")) == .dictate(modeRef: nil))
    }

    @Test("harc://dictate?mode= carries the mode reference")
    func dictateWithMode() {
        #expect(
            DictationDeepLink.parse(url("harc://dictate?mode=builtin.email"))
                == .dictate(modeRef: "builtin.email")
        )
        #expect(
            DictationDeepLink.parse(url("harc://dictate?mode=Clean-up"))
                == .dictate(modeRef: "Clean-up")
        )
        // Empty mode value degrades to a plain dictate.
        #expect(
            DictationDeepLink.parse(url("harc://dictate?mode="))
                == .dictate(modeRef: nil)
        )
    }

    @Test("harc://mode/<ref> switches the active mode")
    func switchMode() {
        #expect(
            DictationDeepLink.parse(url("harc://mode/builtin.bullets"))
                == .switchMode(modeRef: "builtin.bullets")
        )
        // A bare harc://mode with no ref is not a valid link.
        #expect(DictationDeepLink.parse(url("harc://mode")) == nil)
        #expect(DictationDeepLink.parse(url("harc://mode/")) == nil)
    }

    @Test("harc://history opens the history window")
    func history() {
        #expect(DictationDeepLink.parse(url("harc://history")) == .openHistory)
    }

    @Test("unknown hosts and foreign schemes are rejected")
    func rejects() {
        #expect(DictationDeepLink.parse(url("harc://selfdestruct")) == nil)
        #expect(DictationDeepLink.parse(url("https://dictate")) == nil)
        #expect(DictationDeepLink.parse(url("superwhisper://mode/x")) == nil)
    }

    @Test("mode references resolve by exact id, then case-insensitive name")
    func resolution() {
        let modes = DictationMode.builtIns
        #expect(DictationDeepLink.resolveMode("builtin.email", in: modes)?.id == "builtin.email")
        #expect(DictationDeepLink.resolveMode("bullet list", in: modes)?.id == "builtin.bullets")
        #expect(DictationDeepLink.resolveMode("EMAIL", in: modes)?.id == "builtin.email")
        #expect(DictationDeepLink.resolveMode("no-such-mode", in: modes) == nil)
    }
}
