import XCTest
@testable import HarcModels

final class ModelStorageTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: ModelStorage!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcModelsTests-\(UUID().uuidString)", isDirectory: true)
        storage = ModelStorage(baseDirectory: tempRoot)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    func test_modelDirectory_pathShape() {
        let url = storage.modelDirectory(for: "gemma-4-e2b-it-4bit")
        XCTAssertEqual(url.lastPathComponent, "gemma-4-e2b-it-4bit")
        XCTAssertEqual(url.deletingLastPathComponent(), tempRoot)
    }

    func test_ensureAndRemoveModelDirectory_roundTrip() throws {
        let id = "test-model"
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.modelDirectory(for: id).path))

        try storage.ensureModelDirectory(for: id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.modelDirectory(for: id).path,
                                                    isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        try storage.removeModelDirectory(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.modelDirectory(for: id).path))
    }

    func test_removeModelDirectory_swallowsMissingDir() throws {
        XCTAssertNoThrow(try storage.removeModelDirectory(for: "never-existed"))
    }

    func test_installRecord_roundTrip() throws {
        let id = "my-model"
        try storage.ensureModelDirectory(for: id)
        let record = ModelStorage.InstallRecord(
            modelID: id,
            revision: "main",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bytes: 1_234_567,
            skippedSHAVerification: true
        )
        try storage.writeInstallRecord(record)
        let read = storage.readInstallRecord(for: id)
        XCTAssertEqual(read, record)
    }

    func test_installRecord_absent_returnsNil() {
        XCTAssertNil(storage.readInstallRecord(for: "never-installed"))
    }

    func test_clearInstallRecord_removesFile() throws {
        let id = "clear-me"
        try storage.ensureModelDirectory(for: id)
        try storage.writeInstallRecord(.init(modelID: id, revision: "x",
                                             bytes: 0, skippedSHAVerification: false))
        XCTAssertNotNil(storage.readInstallRecord(for: id))
        try storage.clearInstallRecord(for: id)
        XCTAssertNil(storage.readInstallRecord(for: id))
    }

    func test_persistedState_withNoMarker_isAbsent() {
        XCTAssertEqual(storage.persistedState(for: "absent-model"), .absent)
    }

    func test_persistedState_withMarker_isInstalled() throws {
        let id = "installed-model"
        try storage.ensureModelDirectory(for: id)
        try storage.writeInstallRecord(.init(modelID: id, revision: "x",
                                             bytes: 0, skippedSHAVerification: false))
        XCTAssertEqual(storage.persistedState(for: id), .installed)
    }
}
