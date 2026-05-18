import Foundation

public struct RecordingCacheRecovery: Sendable {
    public struct Result: Equatable, Sendable {
        public var recovered: Int
        public var skipped: Int
    }

    public enum RecoveryError: Error, LocalizedError, Sendable {
        case unreadableAudio(URL)
        case unsupportedAudio(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadableAudio(let url):
                return "Could not read interrupted recording \(url.lastPathComponent)."
            case .unsupportedAudio(let url):
                return "Interrupted recording \(url.lastPathComponent) is not recoverable PCM WAV audio."
            }
        }
    }

    public let cacheDirectory: URL
    public let destinationDirectory: URL
    public let store: RecordingStore

    public init(cacheDirectory: URL, destinationDirectory: URL, store: RecordingStore) {
        self.cacheDirectory = cacheDirectory
        self.destinationDirectory = destinationDirectory
        self.store = store
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
        if let existing = try await store.fetchByWavPath(url.path) {
            return existing
        }

        let pcm = try recoverPCMData(from: url)
        let startedAt = fileDate(url) ?? Date()
        let destination = try recoveredDestination(for: startedAt)
        try writeCanonicalWAV(pcmData: pcm, to: destination)

        let recording = Recording(
            wavPath: destination.path,
            startedAt: startedAt,
            endedAt: fileModified(url),
            title: "Recovered interrupted recording"
        )
        let saved = try await store.upsert(recording)
        try? FileManager.default.removeItem(at: url)
        return saved
    }

    private func recoveredDestination(for date: Date) throws -> URL {
        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: date))
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        let hour = String(format: "%02d", cal.component(.hour, from: date))
        let minute = String(format: "%02d", cal.component(.minute, from: date))
        let second = String(format: "%02d", cal.component(.second, from: date))

        let dayDir = destinationDirectory
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let stem = "\(hour)-\(minute)-\(second)-recovered"
        var candidate = dayDir.appendingPathComponent("\(stem).wav")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dayDir.appendingPathComponent("\(stem)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    private func recoverPCMData(from url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url) else {
            throw RecoveryError.unreadableAudio(url)
        }
        guard data.count >= 44 else {
            throw RecoveryError.unsupportedAudio(url)
        }

        if data.starts(with: Data("RIFF".utf8)),
           data.count >= 12,
           Data(data[8..<12]) == Data("WAVE".utf8),
           let dataChunk = riffChunk(named: "data", in: data) {
            let start = dataChunk.offset
            let end = min(data.count, start + dataChunk.size)
            if end > start {
                return Data(data[start..<end])
            }
            if data.count > start {
                return Data(data[start..<data.count])
            }
        }

        throw RecoveryError.unsupportedAudio(url)
    }

    private func riffChunk(named name: String, in data: Data) -> (offset: Int, size: Int)? {
        let needle = Data(name.utf8)
        var offset = 12
        while offset + 8 <= data.count {
            let id = Data(data[offset..<(offset + 4)])
            let size = Int(littleEndianUInt32(data, offset + 4))
            let payload = offset + 8
            if id == needle {
                return (payload, size)
            }
            offset = payload + size + (size % 2)
        }
        return nil
    }

    private func writeCanonicalWAV(pcmData: Data, to url: URL) throws {
        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(littleEndianUInt32Bytes(UInt32(36 + pcmData.count)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(littleEndianUInt32Bytes(16))
        out.append(littleEndianUInt16Bytes(1))
        out.append(littleEndianUInt16Bytes(1))
        out.append(littleEndianUInt32Bytes(16_000))
        out.append(littleEndianUInt32Bytes(32_000))
        out.append(littleEndianUInt16Bytes(2))
        out.append(littleEndianUInt16Bytes(16))
        out.append(Data("data".utf8))
        out.append(littleEndianUInt32Bytes(UInt32(pcmData.count)))
        out.append(pcmData)
        try out.write(to: url, options: [.atomic])
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
}
