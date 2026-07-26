import Testing
@testable import HarcUI

@Suite("Pluralize")
struct PluralizeTests {
    /// The Library chip read "1 speakers" — visible on any recording with a
    /// single speaker, which is most short captures.
    @Test("one is singular")
    func singular() {
        #expect(Pluralize.count(1, "speaker") == "1 speaker")
        #expect(Pluralize.count(1, "file") == "1 file")
    }

    @Test("zero and many are plural")
    func plural() {
        #expect(Pluralize.count(0, "speaker") == "0 speakers")
        #expect(Pluralize.count(2, "speaker") == "2 speakers")
        #expect(Pluralize.count(17, "file") == "17 files")
    }

    @Test("an irregular plural can be supplied")
    func irregular() {
        #expect(Pluralize.count(1, "person", plural: "people") == "1 person")
        #expect(Pluralize.count(3, "person", plural: "people") == "3 people")
    }
}
