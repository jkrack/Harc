import Testing
import Foundation
@testable import HarcUI

@Suite("DictationHistoryStore")
@MainActor
struct DictationHistoryStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-history-\(UUID().uuidString)")
            .appendingPathComponent("dictation-history.json")
    }

    private func entry(_ text: String) -> DictationHistoryEntry {
        DictationHistoryEntry(text: text, modeName: "Raw", delivery: .pasted)
    }

    @Test("record persists newest-first and round-trips through a fresh store")
    func roundTrip() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = HarcPreferences()
        prefs.dictationHistoryEnabled = true

        let store = DictationHistoryStore(fileURL: url, prefs: prefs)
        store.record(entry("first"))
        store.record(DictationHistoryEntry(
            text: "polished",
            rawText: "raw words",
            modeName: "Clean-up",
            targetAppName: "Notes",
            delivery: .copied
        ))
        #expect(store.entries.map(\.text) == ["polished", "first"])

        let reloaded = DictationHistoryStore(fileURL: url, prefs: prefs)
        #expect(reloaded.entries == store.entries)
        #expect(reloaded.entries[0].rawText == "raw words")
        #expect(reloaded.entries[0].targetAppName == "Notes")
        #expect(reloaded.entries[0].delivery == .copied)
    }

    @Test("history is capped at maxEntries, dropping the oldest")
    func cap() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = HarcPreferences()
        prefs.dictationHistoryEnabled = true

        let store = DictationHistoryStore(fileURL: url, prefs: prefs)
        for i in 0..<(DictationHistoryStore.maxEntries + 7) {
            store.record(entry("entry \(i)"))
        }
        #expect(store.entries.count == DictationHistoryStore.maxEntries)
        // Newest first; the earliest entries fell off.
        #expect(store.entries.first?.text == "entry \(DictationHistoryStore.maxEntries + 6)")
        #expect(store.entries.last?.text == "entry 7")
    }

    @Test("disabled pref: record is a no-op and nothing is written to disk")
    func disabledWritesNothing() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = HarcPreferences()
        prefs.dictationHistoryEnabled = false

        let store = DictationHistoryStore(fileURL: url, prefs: prefs)
        store.record(entry("should not persist"))
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clear empties entries and deletes the file")
    func clearDeletesFile() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = HarcPreferences()
        prefs.dictationHistoryEnabled = true

        let store = DictationHistoryStore(fileURL: url, prefs: prefs)
        store.record(entry("gone soon"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Window additions

extension DictationHistoryStoreTests {
    @Test("delete removes one entry and persists the remainder")
    func deleteOne() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = HarcPreferences()
        prefs.dictationHistoryEnabled = true

        let store = DictationHistoryStore(fileURL: url, prefs: prefs)
        store.record(entry("keep"))
        store.record(entry("drop"))
        let dropID = store.entries.first { $0.text == "drop" }!.id

        store.delete(id: dropID)
        #expect(store.entries.map(\.text) == ["keep"])

        let reloaded = DictationHistoryStore(fileURL: url, prefs: prefs)
        #expect(reloaded.entries.map(\.text) == ["keep"])

        // Deleting the last entry removes the file entirely.
        store.delete(id: store.entries[0].id)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("DictationHistoryWindowView search")
@MainActor
struct DictationHistorySearchTests {
    private func entry(_ text: String, raw: String? = nil) -> DictationHistoryEntry {
        DictationHistoryEntry(text: text, rawText: raw, modeName: "Raw", delivery: .pasted)
    }

    @Test("filter matches delivered text and raw transcript, case-insensitively")
    func filterMatchesBothViews() {
        let entries = [
            entry("Polished thursday plan", raw: "um thursday plan I guess"),
            entry("Grocery list"),
            entry("Formatted email", raw: "dear bob about the invoice"),
        ]
        #expect(DictationHistoryWindowView.filter(entries, query: "THURSDAY").count == 1)
        // "invoice" only appears in the raw transcript — still findable.
        #expect(DictationHistoryWindowView.filter(entries, query: "invoice").map(\.text) == ["Formatted email"])
        #expect(DictationHistoryWindowView.filter(entries, query: "  ") == entries)
        #expect(DictationHistoryWindowView.filter(entries, query: "zzz").isEmpty)
    }
}
