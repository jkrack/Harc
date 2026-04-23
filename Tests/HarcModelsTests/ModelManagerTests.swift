import XCTest
@testable import HarcModels

final class ModelManagerTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: ModelStorage!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        storage = ModelStorage(baseDirectory: tempRoot)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Happy path

    func test_startDownload_happyPath_writesFilesAndMarker_andEntersInstalled() async throws {
        let descriptor = Self.makeDescriptor(
            id: "happy",
            files: [
                Self.namedFile(path: "config.json", bytes: 5),
                Self.namedFile(path: "weights.bin", bytes: 11),
            ]
        )
        let engine = FakeDownloadEngine { url in
            if url.lastPathComponent == "config.json" {
                return .writeBytes(Data("hello".utf8))   // 5 bytes
            } else {
                return .writeBytes(Data("hello world".utf8))  // 11 bytes
            }
        }
        let manager = ModelManager(
            storage: storage,
            engine: engine,
            catalog: [descriptor]
        )

        try await manager.startDownload(descriptor.id)
        let final = await awaitState(manager, id: descriptor.id, where: { $0.isInstalled || $0.isFailed })

        XCTAssertEqual(final, .installed)
        // Marker exists on disk.
        XCTAssertNotNil(storage.readInstallRecord(for: descriptor.id))
        // Files are where they should be.
        let cfg = storage.modelDirectory(for: descriptor.id).appendingPathComponent("config.json")
        XCTAssertEqual(try String(contentsOf: cfg, encoding: .utf8), "hello")
    }

    // MARK: - Cancel

    func test_cancel_midDownload_returnsToAbsent() async throws {
        let descriptor = Self.makeDescriptor(
            id: "cancellable",
            files: [Self.namedFile(path: "weights.bin", bytes: 100)]
        )
        let engine = FakeDownloadEngine { _ in .sleepForever }
        let manager = ModelManager(
            storage: storage,
            engine: engine,
            catalog: [descriptor]
        )

        try await manager.startDownload(descriptor.id)
        // Wait until we know we're actually downloading, then cancel.
        _ = await awaitState(manager, id: descriptor.id, where: { state in
            if case .downloading = state { return true }; return false
        })
        await manager.cancel(descriptor.id)

        let final = await awaitState(manager, id: descriptor.id, where: { state in
            if case .absent = state { return true }
            if case .failed = state { return true }
            return false
        })
        XCTAssertEqual(final, .absent)
        XCTAssertNil(storage.readInstallRecord(for: descriptor.id),
                     "Cancelled download must not leave an install marker on disk.")
    }

    // MARK: - SHA mismatch

    func test_shaMismatch_transitionsToFailed() async throws {
        // Manifest claims a specific SHA; fake engine writes bytes whose
        // SHA doesn't match. Verification must reject and surface .failed.
        let bogusSHA = String(repeating: "0", count: 64)
        let descriptor = Self.makeDescriptor(
            id: "bad-sha",
            files: [Self.namedFile(path: "weights.bin", bytes: 5, sha256: bogusSHA)]
        )
        let engine = FakeDownloadEngine { _ in
            .writeBytes(Data("hello".utf8))
        }
        let manager = ModelManager(
            storage: storage,
            engine: engine,
            catalog: [descriptor]
        )

        try await manager.startDownload(descriptor.id)
        let final = await awaitState(manager, id: descriptor.id, where: { state in
            if case .failed = state { return true }
            if case .installed = state { return true }
            return false
        })

        guard case .failed(let reason) = final else {
            return XCTFail("Expected .failed, got \(String(describing: final))")
        }
        XCTAssertTrue(reason.lowercased().contains("checksum"),
                      "Failure reason should mention the checksum mismatch, was: \(reason)")
        // Failure cleans up the model directory so a retry starts fresh.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storage.modelDirectory(for: descriptor.id).path),
            "SHA mismatch must remove the partial model directory."
        )
    }

    // MARK: - Disk space

    func test_insufficientDiskSpace_throwsBeforeStarting() async throws {
        let descriptor = Self.makeDescriptor(
            id: "huge",
            files: [Self.namedFile(path: "weights.bin", bytes: 1_000_000)]
        )
        // Inject a guard that reports zero free bytes for any URL — the
        // 1 MB required size always exceeds it.
        let noSpaceGuard = DiskSpaceGuard(freeBytesProvider: { _ in 0 })
        let manager = ModelManager(
            storage: storage,
            diskGuard: noSpaceGuard,
            engine: FakeDownloadEngine { _ in .writeBytes(Data()) },
            catalog: [descriptor]
        )

        do {
            try await manager.startDownload(descriptor.id)
            XCTFail("Expected .insufficientDisk to throw")
        } catch ModelManager.Failure.insufficientDisk {
            // Expected.
        } catch {
            XCTFail("Expected .insufficientDisk, got \(error)")
        }
        // No state mutation on rejection.
        let s = await manager.state(of: descriptor.id)
        XCTAssertEqual(s, .absent)
    }

    // MARK: - Manifest verification gate

    func test_manifestUnverified_throwsAndDoesNotStart() async throws {
        let descriptor = Self.makeDescriptor(
            id: "unverified",
            files: [Self.namedFile(path: "weights.bin", bytes: 5)],
            manifestVerified: false
        )
        let manager = ModelManager(
            storage: storage,
            engine: FakeDownloadEngine { _ in .writeBytes(Data("hello".utf8)) },
            catalog: [descriptor]
        )

        do {
            try await manager.startDownload(descriptor.id)
            XCTFail("Expected .manifestUnverified to throw")
        } catch ModelManager.Failure.manifestUnverified(let id) {
            XCTAssertEqual(id, "unverified")
        } catch {
            XCTFail("Expected .manifestUnverified, got \(error)")
        }
        let s = await manager.state(of: descriptor.id)
        XCTAssertEqual(s, .absent)
    }

    // MARK: - Helpers

    /// Subscribe to the state stream and resolve when `condition` matches or
    /// `timeout` elapses. Returns `nil` on timeout — caller asserts.
    private func awaitState(
        _ manager: ModelManager,
        id: String,
        where condition: @escaping @Sendable (ModelInstallState) -> Bool,
        timeout: TimeInterval = 5
    ) async -> ModelInstallState? {
        let stream = manager.stateChanges(id: id)
        return await withTaskGroup(of: ModelInstallState?.self) { group in
            group.addTask {
                for await s in stream {
                    if condition(s) { return s }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func makeDescriptor(
        id: String,
        files: [ModelFile],
        manifestVerified: Bool = true
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id,
            displayName: id,
            summary: "test descriptor",
            task: .summarizer,
            tier: .standard,
            repoID: "test/\(id)",
            revision: "main",
            files: files,
            minRAMGB: 4,
            recommendedRAMGB: 4,
            contextTokens: 1024,
            manifestVerified: manifestVerified
        )
    }

    private static func namedFile(path: String, bytes: Int64, sha256: String = "") -> ModelFile {
        ModelFile(
            path: path,
            bytes: bytes,
            sha256: sha256,
            url: URL(string: "https://example.invalid/\(path)")!
        )
    }
}

// MARK: - Fake DownloadEngine

private final class FakeDownloadEngine: DownloadEngine, @unchecked Sendable {
    enum Behavior {
        case writeBytes(Data)
        case fail(DownloadError)
        case sleepForever
    }

    private let behavior: @Sendable (URL) -> Behavior

    init(_ behavior: @escaping @Sendable (URL) -> Behavior) {
        self.behavior = behavior
    }

    func download(
        from url: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        resumeData: Data?,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> DownloadResult {
        switch behavior(url) {
        case .writeBytes(let data):
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL)
            onProgress(Int64(data.count))
            return DownloadResult(bytesWritten: Int64(data.count), resumeData: nil)
        case .fail(let err):
            throw err
        case .sleepForever:
            try await Task.sleep(for: .seconds(60))
            throw DownloadError.cancelled
        }
    }
}

// MARK: - Test-only state predicate

private extension ModelInstallState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
