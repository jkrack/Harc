import Foundation
import Darwin
import HarcCore

public struct RecordingCacheRecovery: Sendable {
    public struct Result: Equatable, Sendable {
        public var recovered: Int
        public var skipped: Int
    }

    public enum RecoveryError: Error, LocalizedError, Sendable {
        case unreadableAudio(URL)
        case unsupportedAudio(URL)
        case destinationConflict(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadableAudio(let url):
                return "Could not read interrupted recording \(url.lastPathComponent)."
            case .unsupportedAudio(let url):
                return "Interrupted recording \(url.lastPathComponent) is not recoverable PCM WAV audio."
            case .destinationConflict(let url):
                return "Recovery destination \(url.lastPathComponent) contains different audio. Both files were preserved."
            }
        }
    }

    public let cacheDirectory: URL
    public let destinationDirectory: URL
    public let store: RecordingStore
    private let synchronizeOutput: @Sendable (URL) throws -> Void

    public init(cacheDirectory: URL, destinationDirectory: URL, store: RecordingStore) {
        self.init(cacheDirectory: cacheDirectory, destinationDirectory: destinationDirectory,
                  store: store, synchronizeOutput: { try DurableFileIO.synchronizeFileAndParent(at: $0) })
    }

    init(cacheDirectory: URL, destinationDirectory: URL, store: RecordingStore,
         synchronizeOutput: @escaping @Sendable (URL) throws -> Void) {
        self.cacheDirectory = cacheDirectory
        self.destinationDirectory = destinationDirectory
        self.store = store
        self.synchronizeOutput = synchronizeOutput
    }

    @discardableResult
    public func recoverAll() async throws -> Result {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result(recovered: 0, skipped: 0)
        }

        var result = Result(recovered: 0, skipped: 0)
        for url in files where url.pathExtension.lowercased() == "wav" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            guard (values?.fileSize ?? 0) > 0 else {
                result.skipped += 1
                continue
            }

            if try await store.fetchByWavPath(url.path) != nil {
                result.skipped += 1
                continue
            }

            do {
                _ = try await recover(url)
            } catch RecoveryError.unreadableAudio, RecoveryError.unsupportedAudio {
                result.skipped += 1
                continue
            }
            result.recovered += 1
        }
        return result
    }

    @discardableResult
    public func recover(_ url: URL) async throws -> Recording {
        try await recover(url, to: nil, removeSourceAfterCommit: true)
    }

    /// The queue persists this path before any output is created. A unique
    /// basename prevents concurrent recoveries from reserving the same name.
    func plannedDestination(for source: URL) throws -> URL {
        let binding = try CaptureDestinationBinding.load(for: source)
        try binding?.validate()
        let base = try recoveredDestination(for: fileDate(source) ?? Date(), baseDirectory: binding?.baseDirectory)
        return base.deletingLastPathComponent().appendingPathComponent(
            "\(UUID().uuidString.lowercased())-recovered.wav"
        )
    }

    /// With a journaled destination, retry reuses the same file and Library row.
    /// The queue owns source cleanup after its completion record is durable.
    func recover(
        _ url: URL,
        to plannedDestination: URL?,
        removeSourceAfterCommit: Bool
    ) async throws -> Recording {
        if let existing = try await store.fetchByWavPath(url.path) {
            return existing
        }

        let publication = try RecordingPublication.load(for: url)
        let binding = try CaptureDestinationBinding.load(for: url)
        try binding?.validate()
        let readURL = FileManager.default.fileExists(atPath: url.path) ? url : (publication?.destination ?? url)
        let pcm = try inspectPCM(from: readURL)
        let startedAt = fileDate(readURL) ?? Date()
        let destination = try plannedDestination ?? publication?.destination ?? recoveredDestination(for: startedAt, baseDirectory: binding?.baseDirectory)
        try binding?.validate(destination: destination)
        if let publication {
            guard publication.destination == destination.standardized else {
                throw RecoveryError.destinationConflict(destination)
            }
            try publication.verifyDestinationVolume()
            _ = try CaptureIntegrityReport.carry(from: readURL, to: destination)
            // Preserve exact published bytes; rewriting an AVAudioFile header
            // would invalidate the immutable publication digest on retry.
            try publication.publish(removingSource: false)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            _ = try CaptureIntegrityReport.carry(from: readURL, to: destination)
            // Never overwrite an unrelated file, even if the output path was
            // replaced while Harc was stopped. Compare before adopting it.
            guard try equalPCM(pcm, inspectPCM(from: destination)) else {
                throw RecoveryError.destinationConflict(destination)
            }
        } else {
            _ = try CaptureIntegrityReport.carry(from: readURL, to: destination)
            try writeCanonicalWAV(pcm: pcm, to: destination)
        }
        // Also synchronize an output reused after an interrupted prior attempt.
        try synchronizeOutput(destination)
        try binding?.validate(destination: destination)

        if let existing = try await store.fetchByWavPath(destination.path) {
            return existing
        }

        let recording = Recording(
            wavPath: destination.path,
            startedAt: startedAt,
            endedAt: fileModified(readURL),
            title: "Recovered interrupted recording"
        )
        let saved = try await store.upsert(recording)
        if removeSourceAfterCommit {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: CaptureIntegrityReport.sidecarURL(for: url))
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: CaptureDestinationBinding.url(for: url))
            }
        }
        return saved
    }

    private func recoveredDestination(for date: Date, baseDirectory: URL? = nil) throws -> URL {
        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: date))
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        let hour = String(format: "%02d", cal.component(.hour, from: date))
        let minute = String(format: "%02d", cal.component(.minute, from: date))
        let second = String(format: "%02d", cal.component(.second, from: date))

        let dayDir = (baseDirectory ?? destinationDirectory)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day)", isDirectory: true)
        try DurableFileIO.createDirectory(at: dayDir)

        let stem = "\(hour)-\(minute)-\(second)-recovered"
        var candidate = dayDir.appendingPathComponent("\(stem).wav")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dayDir.appendingPathComponent("\(stem)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// Only metadata is retained. Audio copy and comparison use fixed-size blocks,
    /// independent of the duration of an interrupted recording.
    private struct PCMRegion {
        let url: URL
        let offset: UInt64
        let count: UInt64
    }

    private static let transferBlockSize = 1_048_576

    private func inspectPCM(from url: URL) throws -> PCMRegion {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw RecoveryError.unreadableAudio(url)
        }
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 12) ?? Data()
        guard length >= 44, header.count == 12,
              header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8) else {
            throw RecoveryError.unsupportedAudio(url)
        }
        var offset: UInt64 = 12
        var validFormat = false
        var audio: PCMRegion?
        while offset <= length - 8 {
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: 8) ?? Data()
            guard chunk.count == 8 else { throw RecoveryError.unreadableAudio(url) }
            let size = UInt64(littleEndianUInt32(chunk, 4))
            let payload = offset + 8
            if chunk.prefix(4) == Data("fmt ".utf8) {
                guard size >= 16, length - payload >= 16 else {
                    throw RecoveryError.unsupportedAudio(url)
                }
                let format = try handle.read(upToCount: 16) ?? Data()
                guard format.count == 16,
                      littleEndianUInt16(format, 0) == 1,
                      littleEndianUInt16(format, 2) == 1,
                      littleEndianUInt32(format, 4) == 16_000,
                      littleEndianUInt32(format, 8) == 32_000,
                      littleEndianUInt16(format, 12) == 2,
                      littleEndianUInt16(format, 14) == 16 else {
                    throw RecoveryError.unsupportedAudio(url)
                }
                validFormat = true
            } else if chunk.prefix(4) == Data("data".utf8), audio == nil {
                // A capture interrupted before header finalization has a zero
                // data length. Its remaining bytes are the recoverable payload.
                let count = size == 0 ? length - payload : min(size, length - payload)
                guard count > 0, count.isMultiple(of: 2), count <= UInt64(UInt32.max) - 36 else {
                    throw RecoveryError.unsupportedAudio(url)
                }
                audio = PCMRegion(url: url, offset: payload, count: count)
            }
            if validFormat, let audio { return audio }
            guard size <= length - payload else { break }
            offset = payload + size + size % 2
        }
        throw RecoveryError.unsupportedAudio(url)
    }

    private func equalPCM(_ lhs: PCMRegion, _ rhs: PCMRegion) throws -> Bool {
        guard lhs.count == rhs.count else { return false }
        let left = try FileHandle(forReadingFrom: lhs.url)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: rhs.url)
        defer { try? right.close() }
        try left.seek(toOffset: lhs.offset)
        try right.seek(toOffset: rhs.offset)
        var remaining = lhs.count
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(Self.transferBlockSize)))
            let matches = try autoreleasepool {
                let a = try left.read(upToCount: count) ?? Data()
                let b = try right.read(upToCount: count) ?? Data()
                guard a.count == count, b.count == count else {
                    throw RecoveryError.unreadableAudio(a.count != count ? lhs.url : rhs.url)
                }
                return a == b
            }
            guard matches else { return false }
            remaining -= UInt64(count)
        }
        return true
    }

    private func writeCanonicalWAV(pcm: PCMRegion, to url: URL) throws {
        var header = Data("RIFF".utf8)
        header.append(littleEndianUInt32Bytes(UInt32(36 + pcm.count)))
        header.append(Data("WAVEfmt ".utf8))
        header.append(littleEndianUInt32Bytes(16))
        header.append(littleEndianUInt16Bytes(1))
        header.append(littleEndianUInt16Bytes(1))
        header.append(littleEndianUInt32Bytes(16_000))
        header.append(littleEndianUInt32Bytes(32_000))
        header.append(littleEndianUInt16Bytes(2))
        header.append(littleEndianUInt16Bytes(16))
        header.append(Data("data".utf8))
        header.append(littleEndianUInt32Bytes(UInt32(pcm.count)))
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".harc-recovery-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try header.write(to: temporary, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: pcm.url)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try input.seek(toOffset: pcm.offset)
        try output.seekToEnd()
        var remaining = pcm.count
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(Self.transferBlockSize)))
            // Foundation can autorelease each read buffer. Drain per block so
            // the loop's memory remains bounded even on a long-lived worker.
            try autoreleasepool {
                let bytes = try input.read(upToCount: count) ?? Data()
                guard bytes.count == count else { throw RecoveryError.unreadableAudio(pcm.url) }
                try output.write(contentsOf: bytes)
            }
            remaining -= UInt64(count)
        }
        try output.close()
        try DurableFileIO.synchronizeFileAndParent(at: temporary)
        // Refuse replacement atomically, including a destination created while
        // the bounded copy was running.
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func fileDate(_ url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.creationDate] as? Date ?? attrs?[.modificationDate] as? Date
    }

    private func fileModified(_ url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func littleEndianUInt16Bytes(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }

    private func littleEndianUInt32Bytes(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }

    private func littleEndianUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func littleEndianUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
