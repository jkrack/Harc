import Testing
import Foundation
@testable import HarcUI

// MARK: - Store

@Suite("DictationModeStore")
@MainActor
struct DictationModeStoreTests {
    private func makeStore() -> (DictationModeStore, URL, HarcPreferences) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-mode-tests-\(UUID().uuidString)/modes.json")
        let prefs = HarcPreferences()
        return (DictationModeStore(fileURL: url, prefs: prefs), url, prefs)
    }

    @Test("seeds built-ins on first launch")
    func seedsBuiltIns() {
        let (store, _, _) = makeStore()
        #expect(store.modes.count == DictationMode.builtIns.count)
        let allBuiltIn = store.modes.allSatisfy { $0.isBuiltIn }
        #expect(allBuiltIn)
        #expect(store.modes.first?.id == DictationMode.rawID)
    }

    @Test("add + update + delete round-trips through persistence")
    func crudRoundTrip() {
        let (store, url, prefs) = makeStore()
        let custom = DictationMode(
            id: "custom.test", name: "Test", symbolName: "star",
            postProcess: .llm, instruction: "Do the thing."
        )
        store.add(custom)
        store.update({
            var m = custom
            m.name = "Renamed"
            return m
        }())

        // Reload from disk into a fresh store.
        let reloaded = DictationModeStore(fileURL: url, prefs: prefs)
        let renamed = reloaded.modes.first { $0.id == "custom.test" }
        #expect(renamed?.name == "Renamed")

        store.delete(id: "custom.test")
        let reloaded2 = DictationModeStore(fileURL: url, prefs: prefs)
        let deleted = reloaded2.modes.first { $0.id == "custom.test" }
        #expect(deleted == nil)
    }

    @Test("built-ins cannot be deleted but can be edited and reset")
    func builtInProtection() {
        let (store, _, _) = makeStore()
        store.delete(id: "builtin.cleanup")
        let stillThere = store.modes.contains { $0.id == "builtin.cleanup" }
        #expect(stillThere)

        var edited = store.modes.first { $0.id == "builtin.cleanup" }!
        edited.instruction = "Custom instruction."
        store.update(edited)
        let afterEdit = store.modes.first { $0.id == "builtin.cleanup" }
        #expect(afterEdit?.instruction == "Custom instruction.")
        // Editing can't strip built-in status.
        #expect(afterEdit?.isBuiltIn == true)

        store.resetBuiltIn(id: "builtin.cleanup")
        let afterReset = store.modes.first { $0.id == "builtin.cleanup" }
        #expect(afterReset == DictationMode.builtIn(id: "builtin.cleanup"))
    }

    @Test("active mode falls back to Raw when selection vanishes")
    func activeModeFallback() {
        let (store, _, prefs) = makeStore()
        let custom = DictationMode(
            id: "custom.gone", name: "Gone", symbolName: "star",
            postProcess: .llm, instruction: "x"
        )
        store.add(custom)
        store.setActiveMode(id: "custom.gone")
        #expect(store.activeMode.id == "custom.gone")

        store.delete(id: "custom.gone")
        #expect(prefs.activeDictationModeID == DictationMode.rawID)
        #expect(store.activeMode.id == DictationMode.rawID)
    }

    @Test("setActiveMode ignores unknown ids")
    func unknownActiveID() {
        let (store, _, prefs) = makeStore()
        let before = prefs.activeDictationModeID
        store.setActiveMode(id: "does.not.exist")
        #expect(prefs.activeDictationModeID == before)
    }
}
