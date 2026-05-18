import Testing
import Foundation
@testable import HarcStore

@Suite("RecordingCacheRecovery")
struct RecordingCacheRecoveryTests {
    private func tempDir(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("recoverAll moves cache WAVs into destination and inserts a visible row")
    func recoversCacheWAV() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
        }

        let cacheWAV = cache.appendingPathComponent("orphan.wav")
        try canonicalWAV(pcmBytes: 3200).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(
            cacheDirectory: cache,
            destinationDirectory: destination,
            store: store
        )

        let result = try await recovery.recoverAll()
        #expect(result.recovered == 1)
        #expect(result.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: cacheWAV.path) == false)

        let rows = try await store.fetchAll()
        #expect(rows.count == 1)
        #expect(rows[0].title == "Recovered interrupted recording")
        #expect(rows[0].wavPath.contains("-recovered.wav"))
        #expect(rows[0].wavPath.hasPrefix(destination.path))
        #expect(FileManager.default.fileExists(atPath: rows[0].wavPath))
    }

    @Test("recoverAll repairs interrupted WAVs whose data chunk length was never finalized")
    func repairsZeroLengthDataChunk() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
        }

        let cacheWAV = cache.appendingPathComponent("interrupted.wav")
        try interruptedWAV(pcmBytes: 6400).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(
            cacheDirectory: cache,
            destinationDirectory: destination,
            store: store
        )

        let result = try await recovery.recoverAll()
        #expect(result.recovered == 1)

        let row = try #require(try await store.fetchAll().first)
        let data = try Data(contentsOf: URL(fileURLWithPath: row.wavPath))
        #expect(data.count == 44 + 6400)
        #expect(data[40] == UInt8(6400 & 0xff))
        #expect(data[41] == UInt8((6400 >> 8) & 0xff))
    }

    @Test("recoverAll is idempotent after cache files have been recovered")
    func idempotentAfterRecovery() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
        }

        let cacheWAV = cache.appendingPathComponent("orphan.wav")
        try canonicalWAV(pcmBytes: 1600).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(
            cacheDirectory: cache,
            destinationDirectory: destination,
            store: store
        )

        let first = try await recovery.recoverAll()
        let second = try await recovery.recoverAll()
        let rows = try await store.fetchAll()

        #expect(first.recovered == 1)
        #expect(second.recovered == 0)
        #expect(rows.count == 1)
    }

    @Test("recoverAll skips unsupported files without blocking valid recoveries")
    func skipsUnsupported() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
        }

        try Data("not wav".utf8).write(to: cache.appendingPathComponent("bad.wav"))
        try canonicalWAV(pcmBytes: 1600).write(to: cache.appendingPathComponent("good.wav"))

        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(
            cacheDirectory: cache,
            destinationDirectory: destination,
            store: store
        )

        let result = try await recovery.recoverAll()
        let rows = try await store.fetchAll()
        #expect(result.recovered == 1)
        #expect(result.skipped == 1)
        #expect(rows.count == 1)
    }

    @Test("recovery queue creates deterministic artifact IDs")
    func recoveryQueueCreatesDeterministicIDs() async throws {
        let date = Date(timeIntervalSince1970: 1_779_000_000)
        let url = URL(fileURLWithPath: "/tmp/Harc Cache/orphan.wav")

        let first = RecoveryQueue.deterministicID(for: url, fileSize: 4096, modifiedAt: date)
        let second = RecoveryQueue.deterministicID(for: url, fileSize: 4096, modifiedAt: date)

        #expect(first == second)
        #expect(first.contains(url.path))
        #expect(first.contains("4096"))
    }

    @Test("recovery queue scan is idempotent and persists artifacts")
    func recoveryQueueScanIsIdempotent() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        let queueFile = try tempDir("harc-queue").appendingPathComponent("recovery.json")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent())
        }

        let cacheWAV = cache.appendingPathComponent("orphan.wav")
        try canonicalWAV(pcmBytes: 3200).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: queueFile, store: store)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)

        let artifacts = try await queue.fetchAll()
        #expect(artifacts.count == 1)
        #expect(artifacts[0].status == .pending)
        #expect(artifacts[0].sourceURL == cacheWAV)

        let reloaded = RecoveryQueue(fileURL: queueFile, store: store)
        let reloadedArtifacts = try await reloaded.fetchAll()
        #expect(reloadedArtifacts.count == 1)
        #expect(reloadedArtifacts[0].id == artifacts[0].id)
        #expect(reloadedArtifacts[0].status == artifacts[0].status)
        #expect(reloadedArtifacts[0].sourceURL == artifacts[0].sourceURL)
    }

    @Test("recovery queue recovers an artifact once")
    func recoveryQueueRecoversOnce() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        let queueFile = try tempDir("harc-queue").appendingPathComponent("recovery.json")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent())
        }

        let cacheWAV = cache.appendingPathComponent("orphan.wav")
        try canonicalWAV(pcmBytes: 3200).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: queueFile, store: store)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)
        let id = try #require(await queue.fetchAll().first?.id)

        let first = try await queue.recover(id: id)
        let second = try await queue.recover(id: id)
        let rows = try await store.fetchAll()

        #expect(first.status == .recovered)
        #expect(second.status == .recovered)
        #expect(first.recordingID == second.recordingID)
        #expect(rows.count == 1)
        #expect(FileManager.default.fileExists(atPath: cacheWAV.path) == false)
    }

    @Test("recovery queue discard hides without deleting source")
    func recoveryQueueDiscardKeepsSource() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        let queueFile = try tempDir("harc-queue").appendingPathComponent("recovery.json")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent())
        }

        let cacheWAV = cache.appendingPathComponent("orphan.wav")
        try canonicalWAV(pcmBytes: 3200).write(to: cacheWAV)

        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: queueFile, store: store)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)
        let id = try #require(await queue.fetchAll().first?.id)

        let discarded = try await queue.discard(id: id)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)
        let artifacts = try await queue.fetchAll()

        #expect(discarded.status == .discarded)
        #expect(FileManager.default.fileExists(atPath: cacheWAV.path))
        #expect(artifacts.count == 1)
        #expect(artifacts[0].status == .discarded)
    }

    @Test("recovery queue marks corrupted WAVs as failed")
    func recoveryQueueMarksCorruptedWAVsFailed() async throws {
        let cache = try tempDir("harc-cache")
        let destination = try tempDir("harc-dest")
        let queueFile = try tempDir("harc-queue").appendingPathComponent("recovery.json")
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: queueFile.deletingLastPathComponent())
        }

        let badWAV = cache.appendingPathComponent("bad.wav")
        try Data(repeating: 7, count: 64).write(to: badWAV)

        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: queueFile, store: store)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)
        let id = try #require(await queue.fetchAll().first?.id)

        let failed = try await queue.recover(id: id)

        #expect(failed.status == .failed)
        #expect(failed.lastError?.contains("not recoverable") == true)
        #expect(FileManager.default.fileExists(atPath: badWAV.path))
        #expect(try await store.fetchAll().isEmpty)
    }

    private func canonicalWAV(pcmBytes: Int) -> Data {
        wav(pcmBytes: pcmBytes, riffSize: 36 + pcmBytes, dataSize: pcmBytes)
    }

    private func interruptedWAV(pcmBytes: Int) -> Data {
        wav(pcmBytes: pcmBytes, riffSize: 36, dataSize: 0)
    }

    private func wav(pcmBytes: Int, riffSize: Int, dataSize: Int) -> Data {
        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(le32(UInt32(riffSize)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(le32(16))
        out.append(le16(1))
        out.append(le16(1))
        out.append(le32(16_000))
        out.append(le32(32_000))
        out.append(le16(2))
        out.append(le16(16))
        out.append(Data("data".utf8))
        out.append(le32(UInt32(dataSize)))
        out.append(Data((0..<pcmBytes).map { UInt8($0 % 255) }))
        return out
    }

    private func le16(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }

    private func le32(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}
