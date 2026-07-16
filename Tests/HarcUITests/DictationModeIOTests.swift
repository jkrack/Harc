import Testing
import Foundation
@testable import HarcUI

@Suite("DictationModeIO")
struct DictationModeIOTests {
    @Test("export/import round-trips a user mode")
    func roundTrip() throws {
        let mode = DictationMode(
            id: "user.pirate",
            name: "Pirate",
            symbolName: "sailboat",
            postProcess: .llm,
            instruction: "Rewrite in pirate speak. Output only the result.",
            modelID: "gemma-4-e2b-it-4bit",
            includeSelectedText: true
        )
        let data = try DictationModeIO.exportData(mode)
        let imported = try DictationModeIO.importMode(from: data, existingIDs: [])
        #expect(imported == mode)
    }

    @Test("import regenerates the id on collision")
    func idCollision() throws {
        let mode = DictationMode(
            id: "user.pirate",
            name: "Pirate",
            symbolName: "sailboat",
            postProcess: .llm,
            instruction: "Arr."
        )
        let data = try DictationModeIO.exportData(mode)
        let imported = try DictationModeIO.importMode(from: data, existingIDs: ["user.pirate"])
        #expect(imported.id != "user.pirate")
        #expect(imported.name == "Pirate")
    }

    @Test("imported modes are never built-in")
    func builtInStripped() throws {
        var mode = DictationMode.builtIns[1]  // Clean-up, isBuiltIn: true
        mode.isBuiltIn = true
        let data = try DictationModeIO.exportData(mode)
        let imported = try DictationModeIO.importMode(from: data, existingIDs: [])
        #expect(!imported.isBuiltIn)
    }

    @Test("garbage data throws a readable error")
    func undecodable() {
        #expect(throws: DictationModeIO.ImportError.self) {
            _ = try DictationModeIO.importMode(
                from: Data("not json".utf8),
                existingIDs: []
            )
        }
    }
}
