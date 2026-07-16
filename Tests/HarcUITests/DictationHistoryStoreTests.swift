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
