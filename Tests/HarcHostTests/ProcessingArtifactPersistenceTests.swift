import Foundation
import XCTest
@testable import HarcHost

final class ProcessingArtifactPersistenceTests: XCTestCase {
    func test_retryRepeatsFailedBarrierEvenWhenExactBytesAlreadyExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("artifact.harcso")
        let bytes = Data("exact signed artifact fixture".utf8)
        enum Injected: Error { case barrier }
        var calls = 0
        let failingBarrier: (URL) throws -> Void = { observed in
            XCTAssertEqual(observed, url)
            calls += 1
            throw Injected.barrier
        }
        for _ in 0..<2 {
            XCTAssertThrowsError(try HarcHostProcessingArtifactService.persistExact(bytes, at: url,
                synchronize: failingBarrier))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(calls, 2)
        // Use the real file, parent and drive-cache barriers on the retry path.
        try HarcHostProcessingArtifactService.persistExact(bytes, at: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var conflictBarrierCalled = false
        XCTAssertThrowsError(try HarcHostProcessingArtifactService.persistExact(Data("different".utf8), at: url,
            synchronize: { _ in conflictBarrierCalled = true }))
        XCTAssertFalse(conflictBarrierCalled)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func test_boundedReadAcceptsExactLimitAndRejectsOverflow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 7, count: 65_537)
        try data.write(to: url)
        XCTAssertEqual(try HarcHostProcessingArtifactService.readBoundedArtifact(at: url, maximumBytes: data.count), data)
        XCTAssertThrowsError(try HarcHostProcessingArtifactService.readBoundedArtifact(at: url, maximumBytes: data.count - 1))
        XCTAssertThrowsError(try HarcHostProcessingArtifactService.readBoundedArtifact(at: url, maximumBytes: 0))
    }

    func test_realPublicationAndRetryRejectSymlinkDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("artifact.harcpb")
        let bytes = Data("exact bundle fixture".utf8)
        try HarcHostProcessingArtifactService.persistExact(bytes, at: url)
        try HarcHostProcessingArtifactService.persistExact(bytes, at: url)
        let link = root.appendingPathComponent("linked.harcpb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try HarcHostProcessingArtifactService.persistExact(bytes, at: link))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
