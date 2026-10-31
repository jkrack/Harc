import Foundation
import Testing
@testable import HarcCore

@Suite("Durable file barriers")
struct DurableFileIOTests {
    @Test("retry after mkdir must repeat a failed parent barrier before creating descendants")
    func retriesParentBarrier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let descendant = first.appendingPathComponent("second")
        var failedBarriers = 0
        for _ in 0..<2 {
            #expect(throws: (any Error).self) {
                try DurableFileIO.createDirectory(at: descendant, synchronizeParent: { parent in
                    if parent.standardized.path == root.standardized.path {
                        failedBarriers += 1
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try DurableFileIO.synchronizeDirectory(at: parent)
                })
            }
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: descendant.path))
        }
        #expect(failedBarriers == 2)
        var retriedParent = false
        try DurableFileIO.createDirectory(at: descendant, synchronizeParent: { parent in
            if parent.standardized.path == root.standardized.path { retriedParent = true }
            try DurableFileIO.synchronizeDirectory(at: parent)
        })
        #expect(retriedParent)
        #expect(FileManager.default.fileExists(atPath: descendant.path))
    }

    @Test("an existing leaf cannot bypass its own failed parent barrier")
    func existingLeafStillRequiresBarrier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try DurableFileIO.createDirectory(at: root, synchronizeParent: { _ in throw CocoaError(.fileWriteUnknown) })
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        try DurableFileIO.createDirectory(at: root)
    }

    @Test("atomic metadata writes create nested directories and replace complete contents")
    func nestedMetadataPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/state.json")
        try DurableFileIO.writeAtomically(Data("first".utf8), to: file)
        try DurableFileIO.writeAtomically(Data("second".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("second".utf8))
    }

    @Test("invalid barrier targets fail without replacing existing data")
    func invalidTargetsPreserveData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("existing")
        let original = Data("preserve".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try DurableFileIO.createDirectory(at: file) }
        #expect(throws: (any Error).self) { try DurableFileIO.synchronizeDirectory(at: file) }
        #expect(throws: (any Error).self) {
            try DurableFileIO.writeAtomically(Data(), to: file.appendingPathComponent("child"))
        }
        #expect(throws: (any Error).self) {
            try DurableFileIO.synchronizeFileAndParent(at: root.appendingPathComponent("missing"))
        }
        #expect(try Data(contentsOf: file) == original)
    }
}
