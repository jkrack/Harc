import Testing
import Foundation
@testable import HarcUI
import HarcCore

@MainActor
struct HarcPreferencesTests {
    @Test("addEntry persists in memory and roundtrips through UserDefaults")
    func addEntryRoundTrip() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        let startCount = prefs.vocabulary.entries.count
        prefs.addEntry(from: marker, to: "Parakeet")
        #expect(prefs.vocabulary.entries.count == startCount + 1)
        #expect(prefs.vocabulary.entries.last?.from == marker)
        #expect(prefs.vocabulary.entries.last?.to == "Parakeet")

        let reloaded = HarcPreferences()
        #expect(reloaded.vocabulary.entries.contains(where: { $0.from == marker }))

        if let id = prefs.vocabulary.entries.first(where: { $0.from == marker })?.id {
            prefs.deleteEntries(ids: [id])
        }
    }

    @Test("toggleEntry flips enabled flag")
    func toggleEntry() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        prefs.addEntry(from: marker, to: "Bar")
        guard let id = prefs.vocabulary.entries.first(where: { $0.from == marker })?.id else {
            Issue.record("added entry not found")
            return
        }
        let before = prefs.vocabulary.entries.first(where: { $0.id == id })?.enabled ?? false
        prefs.toggleEntry(id: id)
        let after = prefs.vocabulary.entries.first(where: { $0.id == id })?.enabled ?? false
        #expect(after != before)
        prefs.deleteEntries(ids: [id])
    }

    @Test("deleteEntries removes by id")
    func deleteEntriesById() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        prefs.addEntry(from: marker, to: "X")
        let id = prefs.vocabulary.entries.first(where: { $0.from == marker })!.id
        prefs.deleteEntries(ids: [id])
        #expect(!prefs.vocabulary.entries.contains(where: { $0.id == id }))
    }

    @Test("autoPasteEnabled defaults to true when UserDefaults has no key")
    func autoPasteEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.autoPasteEnabled == true)
    }

    @Test("autoPasteEnabled persists and round-trips through UserDefaults")
    func autoPasteEnabledPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        prefs.autoPasteEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.autoPasteEnabled == false)
        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
    }
}
