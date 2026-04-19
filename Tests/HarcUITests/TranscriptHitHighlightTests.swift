import Testing
import SwiftUI
@testable import HarcUI

@Suite("TranscriptHitRow.highlight")
struct TranscriptHitHighlightTests {
    @Test("plain text without marks round-trips as plain AttributedString")
    func plainText() {
        let out = TranscriptHitRow.highlight("just some words here")
        #expect(String(out.characters) == "just some words here")
    }

    @Test("mark spans produce a run tinted with HarcDesign.primary")
    func singleMark() {
        let out = TranscriptHitRow.highlight("before <mark>hit</mark> after")
        #expect(String(out.characters) == "before hit after")
        var sawPrimary = false
        for run in out.runs {
            if String(out.characters[run.range]) == "hit",
               run.foregroundColor == Color.harcPrimary {
                sawPrimary = true
            }
        }
        #expect(sawPrimary)
    }

    @Test("multiple mark spans are all highlighted")
    func multipleMarks() {
        let out = TranscriptHitRow.highlight("<mark>a</mark> b <mark>c</mark>")
        var primaryCount = 0
        for run in out.runs where run.foregroundColor == Color.harcPrimary {
            primaryCount += 1
        }
        #expect(primaryCount == 2)
    }

    @Test("unmatched opening <mark> degrades gracefully — remaining text is plain")
    func unmatchedOpen() {
        let out = TranscriptHitRow.highlight("before <mark>oops no close")
        #expect(String(out.characters) == "before oops no close")
    }
}
