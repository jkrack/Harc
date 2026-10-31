import Testing
import Foundation
import Darwin
import HarcCore
@preconcurrency import AVFoundation
@testable import HarcStore

@Suite("RecordingCacheRecovery")
struct RecordingCacheRecoveryTests {
    @Test("restart recovery uses the durable capture destination after preferences change")
    func persistedDestinationSurvivesRestart() async throws {
        let root = try tempDir("harc-bound-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let original = root.appendingPathComponent("original")
        let changed = root.appendingPathComponent("changed")
        let binding = CaptureDestinationBinding(source: source, baseDirectory: original,
            volumeIdentity: try RecordingPublication.volumeIdentity(containing: original.appendingPathComponent("probe")))
        try binding.save()
        try interruptedWAV(pcmBytes: 6400).write(to: source)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: root.appendingPathComponent("queue.json"), store: store)
        try await queue.scanCache(cacheDirectory: root, destinationDirectory: changed)
        let entries = try await queue.fetchAll()
        let artifact = try #require(entries.first)
        #expect(artifact.destinationURL == original)
        let restarted = RecoveryQueue(fileURL: root.appendingPathComponent("queue.json"), store: store)
        let recovered = try await restarted.recover(id: artifact.id)
        #expect(recovered.status == .recovered)
        #expect(recovered.destinationURL?.path.hasPrefix(original.path + "/") == true)
        #expect(!FileManager.default.fileExists(atPath: changed.path))
        #expect(try CaptureDestinationBinding.load(for: source) == nil)
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("corrupt capture destination binding preserves the master and metadata")
    func corruptDestinationBindingIsPreserved() async throws {
        let root = try tempDir("harc-corrupt-binding")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let bytes = canonicalWAV(pcmBytes: 3200)
        try bytes.write(to: source)
        let corrupt = Data("not a binding".utf8)
        try corrupt.write(to: CaptureDestinationBinding.url(for: source))
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root, store: store)
        await #expect(throws: (any Error).self) { try await recovery.recover(source) }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: CaptureDestinationBinding.url(for: source)) == corrupt)
        #expect(try await store.fetchAll().isEmpty)
    }

    @Test("large recovery streams a multi-hour PCM master",
          .enabled(if: ProcessInfo.processInfo.environment["HARC_LARGE_RECOVERY"] == "1",
                   "Run separately with process memory measurement"))
    func largeStreamingRecovery() async throws {
        var initialUsage = rusage()
        #expect(getrusage(RUSAGE_SELF, &initialUsage) == 0)
        let root = try tempDir("harc-large-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("recovered.wav")
        let payload = 512 * 1_048_576
        var header = canonicalWAV(pcmBytes: 0)
        for (offset, value) in [(4, UInt32(payload + 36)), (40, UInt32(payload))] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        try header.write(to: source)
        let fixture = try FileHandle(forWritingTo: source)
        try fixture.truncate(atOffset: UInt64(payload + 44))
        try fixture.seek(toOffset: UInt64(payload + 42))
        try fixture.write(contentsOf: Data([0x12, 0x34]))
        try fixture.close()
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root, store: store)
        _ = try await recovery.recover(source, to: output, removeSourceAfterCommit: false)
        _ = try await recovery.recover(source, to: output, removeSourceAfterCommit: false)
        let result = try FileHandle(forReadingFrom: output)
        defer { try? result.close() }
        #expect(try result.seekToEnd() == UInt64(payload + 44))
        try result.seek(toOffset: UInt64(payload + 42))
        #expect(try result.read(upToCount: 2) == Data([0x12, 0x34]))
        #expect(try await store.fetchAll().count == 1)
        var finalUsage = rusage()
        #expect(getrusage(RUSAGE_SELF, &finalUsage) == 0)
        print("Large recovery payload: \(payload) bytes; PCM duration: \(Double(payload) / 32_000) seconds")
        print("Test process peak RSS: before=\(initialUsage.ru_maxrss), after=\(finalUsage.ru_maxrss) bytes")
    }

    @Test("streamed recovery copies every block and rejects a conflict in the final block")
    func streamedRecoveryAndLateConflict() async throws {
        let root = try tempDir("harc-streamed-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("recovered.wav")
        var bytes = canonicalWAV(pcmBytes: 3 * 1_048_576 + 14)
        for offset in [44, 44 + 1_048_575, 44 + 1_048_576, bytes.count - 1] {
            bytes[offset] = 0x7d
        }
        try bytes.write(to: source)
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root, store: store)
        _ = try await recovery.recover(source, to: output, removeSourceAfterCommit: false)
        #expect(try Data(contentsOf: output) == bytes)
        _ = try await recovery.recover(source, to: output, removeSourceAfterCommit: false)
        #expect(try await store.fetchAll().count == 1)
        var conflict = bytes
        conflict[conflict.count - 1] ^= 0xff
        try conflict.write(to: output)
        await #expect(throws: RecordingCacheRecovery.RecoveryError.self) {
            try await recovery.recover(source, to: output, removeSourceAfterCommit: true)
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: output) == conflict)
    }

    @Test("an incomplete PCM sample is rejected even when the destination already exists")
    func oddPayloadIsPreserved() async throws {
        let root = try tempDir("harc-odd-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("recovered.wav")
        var bytes = canonicalWAV(pcmBytes: 32)
        bytes.removeLast()
        try bytes.write(to: source)
        try bytes.write(to: output)
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root, store: store)
        await #expect(throws: RecordingCacheRecovery.RecoveryError.self) {
            try await recovery.recover(source, to: output, removeSourceAfterCommit: true)
        }
        #expect(try await store.fetchAll().isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("publication intent recovers the original destination with or without its cache master",
          arguments: [false, true], [false, true])
    func journaledPublicationRecovery(removeSource: Bool, preexistingEntry: Bool) async throws {
        let root = try tempDir("harc-publication-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let destinationRoot = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let source = cache.appendingPathComponent("capture.wav")
        let destination = destinationRoot.appendingPathComponent("published.wav")
        let bytes = canonicalWAV(pcmBytes: 3200)
        try bytes.write(to: source)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: root.appendingPathComponent("recovery.json"), store: store)
        if preexistingEntry {
            try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destinationRoot)
        }
        let intent = try RecordingPublication.prepare(source: source, destination: destination)
        try intent.publish(removingSource: removeSource)
        // Crash before the Library row: only the immutable intent may remain.
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destinationRoot)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destinationRoot)
        let entries = try await queue.fetchAll()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.sourceURL == source, "publication must not rebind the recovery source identity")
        let recovered = try await queue.recover(id: entry.id)
        #expect(recovered.status == .recovered)
        #expect(recovered.destinationURL == destination)
        #expect(try await store.fetchAll().count == 1)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try RecordingPublication.load(for: source) == nil)
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destinationRoot)
        #expect(try await queue.fetchAll().count == 1)
    }

    @Test("failed publication barrier preserves the source and retries the reserved output")
    func publicationBarrierFailureIsRecoverable() async throws {
        let root = try tempDir("harc-recovery-barrier")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("reserved.wav")
        let audio = canonicalWAV(pcmBytes: 3200)
        try audio.write(to: source)
        let store = try await RecordingStore.inMemory()
        let failing = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root,
            store: store, synchronizeOutput: { _ in throw CocoaError(.fileWriteUnknown) })
        await #expect(throws: (any Error).self) {
            try await failing.recover(source, to: output, removeSourceAfterCommit: true)
        }
        #expect(try Data(contentsOf: source) == audio)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try await store.fetchAll().isEmpty)
        let retry = RecordingCacheRecovery(cacheDirectory: root, destinationDirectory: root, store: store)
        let row = try await retry.recover(source, to: output, removeSourceAfterCommit: true)
        #expect(row.wavPath == output.path)
        #expect(try await store.fetchAll().count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("recovery preserves capture-loss evidence in the sidecar and durable Library row")
    func recoveryPreservesCaptureIntegrity() async throws {
        let root = try tempDir("harc-recovery-integrity")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try canonicalWAV(pcmBytes: 3200).write(to: source)
        var report = CaptureIntegrityReport()
        report.record(source: .systemAudio, reason: .sourceStopped, frameOffset: 1200)
        try report.save(nextTo: source)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: root.appendingPathComponent("recovery.json"), store: store)
        try await queue.enqueue(RecoveryArtifact(id: "one", kind: .interruptedWAV,
            sourceURL: source, destinationURL: root.appendingPathComponent("destination"), title: "One", detail: ""))
        let recovered = try await queue.recover(id: "one")
        let destination = try #require(recovered.destinationURL)
        let row = try await store.fetchByWavPath(destination.path)
        #expect(row?.captureIntegrity == report)
        let edited = try await store.upsert(Recording(wavPath: destination.path, startedAt: Date(), title: "Edited"))
        #expect(edited.captureIntegrity == report, "ordinary edits must preserve capture provenance")
        let detail = try await store.recordingDetail(canonicalID: edited.canonicalID)
        #expect(detail?.summary.originID == nil)
        #expect(detail?.captureNeedsReview == true)
        #expect(detail?.discontinuities.isEmpty == true)
        #expect(try CaptureIntegrityReport.load(nextTo: destination) == report)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: CaptureIntegrityReport.sidecarURL(for: source).path))
    }

    @Test("corrupt integrity metadata prevents recovery from deleting or silently adopting its source")
    func corruptCaptureIntegrityPreservesSource() async throws {
        let root = try tempDir("harc-recovery-integrity-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let audio = canonicalWAV(pcmBytes: 3200)
        try audio.write(to: source)
        try Data("broken".utf8).write(to: CaptureIntegrityReport.sidecarURL(for: source))
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root,
            destinationDirectory: root.appendingPathComponent("destination"), store: store)
        await #expect(throws: (any Error).self) { try await recovery.recover(source) }
        #expect(try Data(contentsOf: source) == audio)
        #expect(try await store.fetchAll().isEmpty)
    }

    @Test("enqueue preserves source identity and terminal decisions across new artifact IDs")
    func enqueuePreservesSourceIdentity() async throws {
        let root = try tempDir("harc-recovery-source-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: root.appendingPathComponent("recovery.json"), store: store)
        var artifact = RecoveryArtifact(id: "original", kind: .interruptedWAV,
            status: .discarded, sourceURL: root.appendingPathComponent("source.wav"),
            title: "One", detail: "")
        try await queue.enqueue(artifact)
        artifact.id = "new-metadata"
        artifact.status = .pending
        try await queue.enqueue(artifact)
        let entries = try await queue.fetchAll()
        #expect(entries.count == 1)
        #expect(entries.first?.id == "original")
        #expect(entries.first?.status == .discarded)
        artifact.id = "original"
        artifact.sourceURL = root.appendingPathComponent("different.wav")
        await #expect(throws: RecoveryQueue.QueueError.self) { try await queue.enqueue(artifact) }
        #expect(try await queue.fetchAll() == entries)
    }

    @Test("restart between output creation and database commit reuses the reserved file")
    func recoveryResumesAfterOutputCreation() async throws {
        let root = try tempDir("harc-recovery-output-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("reserved.wav")
        let file = root.appendingPathComponent("recovery.json")
        let audio = canonicalWAV(pcmBytes: 3200)
        try audio.write(to: source)
        try audio.write(to: output)
        let store = try await RecordingStore.inMemory()
        let beforeRestart = RecoveryQueue(fileURL: file, store: store)
        try await beforeRestart.enqueue(RecoveryArtifact(id: "one", kind: .interruptedWAV,
            status: .recovering, sourceURL: source, destinationURL: root,
            recoveryOutputURL: output, title: "One", detail: ""))
        let restarted = RecoveryQueue(fileURL: file, store: store)
        let completed = try await restarted.recover(id: "one")
        #expect(completed.status == .recovered)
        #expect(completed.destinationURL == output)
        #expect(try Data(contentsOf: output) == audio)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("failed intent persistence cannot start recovery publication")
    func recoveryRequiresPersistedIntent() async throws {
        let root = try tempDir("harc-recovery-intent-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let file = root.appendingPathComponent("recovery.json")
        let audio = canonicalWAV(pcmBytes: 3200)
        try audio.write(to: source)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: file, store: store, writeMetadata: { data, url in
            let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            if records.contains(where: { $0["status"] as? String == "recovering" }) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        try await queue.enqueue(RecoveryArtifact(id: "one", kind: .interruptedWAV,
            sourceURL: source, destinationURL: root.appendingPathComponent("destination"),
            title: "One", detail: ""))
        await #expect(throws: (any Error).self) { try await queue.recover(id: "one") }
        #expect(try Data(contentsOf: source) == audio)
        #expect(try await store.fetchAll().isEmpty)
        #expect(try await queue.fetchAll().first?.status == .pending)
        #expect(try await queue.fetchAll().first?.recoveryOutputURL == nil)
    }

    @Test("recovery accepts the actual AVAudioFile PCM container")
    func recoversAVAudioFileOutput() async throws {
        let root = try tempDir("harc-recovery-avfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 1600))
            buffer.frameLength = 1600
            buffer.floatChannelData![0].initialize(repeating: 0.1, count: 1600)
            try writer.write(from: buffer)
        }
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root,
            destinationDirectory: root.appendingPathComponent("destination"), store: store)
        let saved = try await recovery.recover(source)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: saved.wavPath))
        #expect(audio.length == 1600)
        #expect(audio.fileFormat.sampleRate == 16_000)
    }

    @Test("recovery rejects a different PCM format instead of relabeling its audio")
    func recoveryRejectsNoncanonicalPCM() async throws {
        let root = try tempDir("harc-recovery-format")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        var bytes = canonicalWAV(pcmBytes: 3200)
        bytes.replaceSubrange(24..<28, with: le32(48_000))
        bytes.replaceSubrange(28..<32, with: le32(96_000))
        try bytes.write(to: source)
        let store = try await RecordingStore.inMemory()
        let recovery = RecordingCacheRecovery(cacheDirectory: root,
            destinationDirectory: root.appendingPathComponent("destination"), store: store)
        await #expect(throws: RecordingCacheRecovery.RecoveryError.self) { try await recovery.recover(source) }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try await store.fetchAll().isEmpty)
    }

    @Test("failed completion persistence keeps the master and resumes the same Library row")
    func recoveryResumesAfterCompletionWriteFailure() async throws {
        let root = try tempDir("harc-recovery-commit-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("destination")
        let file = root.appendingPathComponent("recovery.json")
        try canonicalWAV(pcmBytes: 3200).write(to: source)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: file, store: store, writeMetadata: { data, url in
            let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            if records.contains(where: { $0["status"] as? String == "recovered" }) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        try await queue.enqueue(RecoveryArtifact(id: "one", kind: .interruptedWAV,
            sourceURL: source, destinationURL: destination, title: "One", detail: ""))
        await #expect(throws: (any Error).self) { try await queue.recover(id: "one") }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let beforeRestart = try await store.fetchAll()
        #expect(beforeRestart.count == 1)
        #expect(try await queue.fetchAll().first?.status == .failed)

        let restarted = RecoveryQueue(fileURL: file, store: store)
        #expect(try await restarted.fetchAll().first?.status == .failed)
        let completed = try await restarted.recover(id: "one")
        let afterRestart = try await store.fetchAll()
        #expect(completed.status == .recovered)
        #expect(afterRestart.count == 1)
        #expect(afterRestart.first?.id == beforeRestart.first?.id)
        #expect(completed.recoveryOutputURL?.path == beforeRestart.first?.wavPath)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("interrupted publication reuses its journaled output without overwriting a conflict")
    func recoveryPreservesConflictingOutput() async throws {
        let root = try tempDir("harc-recovery-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let output = root.appendingPathComponent("reserved.wav")
        let file = root.appendingPathComponent("recovery.json")
        let sourceBytes = canonicalWAV(pcmBytes: 3200)
        let otherBytes = canonicalWAV(pcmBytes: 6400)
        try sourceBytes.write(to: source)
        try otherBytes.write(to: output)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: file, store: store)
        try await queue.enqueue(RecoveryArtifact(id: "one", kind: .interruptedWAV,
            status: .recovering, sourceURL: source, destinationURL: root,
            recoveryOutputURL: output, title: "One", detail: ""))
        let failed = try await queue.recover(id: "one")
        #expect(failed.status == .failed)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try Data(contentsOf: output) == otherBytes)
        #expect(try await store.fetchAll().isEmpty)
    }

    @Test("one source cannot be recovered, discarded, or replaced while publication is suspended")
    func recoverySerializesSourceOwnership() async throws {
        let root = try tempDir("harc-recovery-ownership")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let file = root.appendingPathComponent("recovery.json")
        try canonicalWAV(pcmBytes: 3200).write(to: source)
        let store = try await RecordingStore.inMemory()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let queue = RecoveryQueue(fileURL: file, store: store,
            writeMetadata: { try $0.write(to: $1, options: .atomic) },
            publish: { recovery, source, output in
                entered.continuation.yield(())
                entered.continuation.finish()
                for await _ in release.stream { break }
                return try await recovery.recover(source, to: output, removeSourceAfterCommit: false)
            })
        let artifact = RecoveryArtifact(id: "one", kind: .interruptedWAV,
            sourceURL: source, destinationURL: root.appendingPathComponent("destination"),
            title: "One", detail: "")
        try await queue.enqueue(artifact)
        let first = Task { try await queue.recover(id: artifact.id) }
        for await _ in entered.stream { break }
        #expect(try await queue.fetchAll().first?.status == .recovering)
        await #expect(throws: RecoveryQueue.QueueError.self) { try await queue.recover(id: artifact.id) }
        await #expect(throws: RecoveryQueue.QueueError.self) { try await queue.discard(id: artifact.id) }
        await #expect(throws: RecoveryQueue.QueueError.self) { try await queue.enqueue(artifact) }
        release.continuation.yield(())
        release.continuation.finish()
        #expect(try await first.value.status == .recovered)
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("failed queue loads preserve metadata and retry after repair")
    func failedQueueLoadPreservesOriginal() async throws {
        let root = try tempDir("harc-queue-load-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: file, store: store)
        let artifact = RecoveryArtifact(id: "new", kind: .interruptedWAV,
            sourceURL: root.appendingPathComponent("audio.wav"), title: "Audio", detail: "")
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await queue.fetchAll() }
            await #expect(throws: (any Error).self) { try await queue.enqueue(artifact) }
            #expect(try Data(contentsOf: file) == original)
        }
        try Data("[]".utf8).write(to: file, options: .atomic)
        try await queue.enqueue(artifact)
        #expect(try await queue.fetchAll().map(\.id) == ["new"])
        let reloaded = RecoveryQueue(fileURL: file, store: store)
        #expect(try await reloaded.fetchAll().map(\.id) == ["new"])
    }

    @Test("failed queue persistence does not publish uncommitted mutations")
    func failedQueueWritePreservesCommittedState() async throws {
        let root = try tempDir("harc-queue-write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let backup = root.appendingPathComponent("original.json")
        let store = try await RecordingStore.inMemory()
        let queue = RecoveryQueue(fileURL: file, store: store)
        let artifact = RecoveryArtifact(id: "original", kind: .interruptedWAV,
            sourceURL: root.appendingPathComponent("audio.wav"), title: "Audio", detail: "")
        try await queue.enqueue(artifact)
        let committed = try await queue.fetchAll()
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await queue.discard(id: artifact.id) }
        var additional = artifact
        additional.id = "not-committed"
        await #expect(throws: (any Error).self) { try await queue.enqueue(additional) }
        #expect(try await queue.fetchAll() == committed)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        _ = try await queue.discard(id: artifact.id)
        let reloaded = RecoveryQueue(fileURL: file, store: store)
        #expect(try await reloaded.fetchAll().first?.status == .discarded)
    }

    @Test("transient queue read failure can reload existing discard decisions")
    func queueRetriesTransientReadFailure() async throws {
        let root = try tempDir("harc-queue-read-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let backup = root.appendingPathComponent("original.json")
        let store = try await RecordingStore.inMemory()
        let original = RecoveryQueue(fileURL: file, store: store)
        let artifact = RecoveryArtifact(id: "discarded", kind: .interruptedWAV,
            status: .discarded, sourceURL: root.appendingPathComponent("audio.wav"),
            title: "Audio", detail: "")
        try await original.enqueue(artifact)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let queue = RecoveryQueue(fileURL: file, store: store)
        await #expect(throws: (any Error).self) { try await queue.fetchAll() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        #expect(try await queue.fetchAll().first?.status == .discarded)
    }

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

    @Test("recovery queue does not recreate discarded artifacts when file metadata changes")
    func recoveryQueueDoesNotRecreateDiscardedArtifactsWhenMetadataChanges() async throws {
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
        _ = try await queue.discard(id: id)

        try FileHandle(forWritingTo: cacheWAV).closeAfter {
            $0.seekToEndOfFile()
            $0.write(Data([1, 2, 3, 4]))
        }
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)

        let artifacts = try await queue.fetchAll()
        #expect(artifacts.count == 1)
        #expect(artifacts[0].id == id)
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

    @Test("recovery queue does not duplicate failed artifacts when file metadata changes")
    func recoveryQueueDoesNotDuplicateFailedArtifactsWhenMetadataChanges() async throws {
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
        _ = try await queue.recover(id: id)

        try FileHandle(forWritingTo: badWAV).closeAfter {
            $0.seekToEndOfFile()
            $0.write(Data([8, 9, 10, 11]))
        }
        try await queue.scanCache(cacheDirectory: cache, destinationDirectory: destination)

        let artifacts = try await queue.fetchAll()
        #expect(artifacts.count == 1)
        #expect(artifacts[0].id == id)
        #expect(artifacts[0].status == .failed)
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

private extension FileHandle {
    func closeAfter(_ work: (FileHandle) throws -> Void) rethrows {
        defer { try? close() }
        try work(self)
    }
}
