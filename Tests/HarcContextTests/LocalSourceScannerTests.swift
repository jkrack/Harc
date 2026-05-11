import Foundation
import Testing
@testable import HarcContext

@Suite("Local source scanner")
struct LocalSourceScannerTests {
    @Test("scans supported text files with provenance and skips excluded paths")
    func scansSupportedFilesWithProvenance() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-source-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "# Atlas\nMigration notes".write(
            to: rootURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ignored".write(
            to: rootURL.appendingPathComponent("node_modules/ignored.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0, 1, 2]).write(to: rootURL.appendingPathComponent("image.png"))

        let root = LocalSourceRoot(
            id: "root-1",
            path: rootURL.path,
            displayName: "Atlas",
            kind: .repository,
            readOnly: true
        )

        let documents = try LocalSourceScanner.scan(root: root, scannedAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(documents.map(\.provenance.relativePath) == ["README.md"])
        #expect(documents[0].title == "README")
        #expect(documents[0].provenance.rootID == "root-1")
        #expect(documents[0].provenance.documentKind == .markdown)
        #expect(documents[0].provenance.lineStart == 1)
        #expect(documents[0].provenance.contentHash.count == 64)
    }

    @Test("include globs limit scanned files")
    func includeGlobsLimitFiles() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-source-include-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        try "doc".write(to: rootURL.appendingPathComponent("docs/context.md"), atomically: true, encoding: .utf8)
        try "code".write(to: rootURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let root = LocalSourceRoot(
            path: rootURL.path,
            includeGlobs: ["docs/**"]
        )

        let documents = try LocalSourceScanner.scan(root: root)

        #expect(documents.map(\.provenance.relativePath) == ["docs/context.md"])
    }
}
