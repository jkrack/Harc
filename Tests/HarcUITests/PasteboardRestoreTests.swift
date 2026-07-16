import Testing
import AppKit
@testable import HarcUI

/// Clipboard snapshot/restore for dictation (SuperWhisper parity: a dictation
/// paste must not permanently clobber whatever the user had copied).
/// Uses uniquely named pasteboards so the user's real clipboard is untouched.
@Suite("FrontmostAppPaster clipboard restore")
@MainActor
struct PasteboardRestoreTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("harc.test.\(UUID().uuidString)"))
    }

    @Test("snapshot and restore round-trips the previous contents")
    func roundTrip() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("user's precious clipboard", forType: .string)

        let snapshot = FrontmostAppPaster.snapshotPasteboard(pb)

        // Dictation writes its text…
        pb.clearContents()
        pb.setString("dictated text", forType: .string)
        let changeCount = pb.changeCount

        // …and the restore puts the original back.
        FrontmostAppPaster.restorePasteboard(snapshot, to: pb, ifChangeCountIs: changeCount)
        #expect(pb.string(forType: .string) == "user's precious clipboard")
    }

    @Test("restore is skipped when the user copied something newer")
    func skipsWhenSuperseded() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let snapshot = FrontmostAppPaster.snapshotPasteboard(pb)

        pb.clearContents()
        pb.setString("dictated text", forType: .string)
        let changeCountAfterOurWrite = pb.changeCount

        // The user copies something else before the restore fires.
        pb.clearContents()
        pb.setString("user's newer copy", forType: .string)

        FrontmostAppPaster.restorePasteboard(snapshot, to: pb, ifChangeCountIs: changeCountAfterOurWrite)
        #expect(pb.string(forType: .string) == "user's newer copy")
    }

    @Test("empty previous clipboard restores to empty, not stale text")
    func emptySnapshot() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = FrontmostAppPaster.snapshotPasteboard(pb)
        #expect(snapshot.isEmpty)

        pb.setString("dictated text", forType: .string)
        let changeCount = pb.changeCount
        FrontmostAppPaster.restorePasteboard(snapshot, to: pb, ifChangeCountIs: changeCount)
        #expect(pb.string(forType: .string) == nil)
    }
}
