import Foundation
@preconcurrency import AVFoundation

/// Yields fixed-duration slices of a growing WAV file.
/// Each chunk is written to `/tmp/harc-chunk-<uuid>.wav`; caller is responsible for cleanup.
/// Not Sendable — hold on a single actor (ChunkedTranscriber in Task 4).
public final class WAVChunker {
    public struct Chunk: Sendable {
        public let audioURL: URL
        public let startMs: Int
        public let endMs: Int
    }

    private let audioURL: URL
    private let chunkDurationSeconds: Double
    private var consumedFrames: AVAudioFramePosition = 0
    private let targetSampleRate: Double = 16000

    /// Cached data-chunk body offset (bytes from start of file to first PCM sample).
    /// Computed once by scanning the RIFF chunk list on first use.
    private var dataBodyOffset: Int? = nil

    public init(audioURL: URL, chunkDurationSeconds: Double = 60.0) {
        self.audioURL = audioURL
        self.chunkDurationSeconds = chunkDurationSeconds
    }

    /// Returns the next full chunk if at least `chunkDurationSeconds` worth of
    /// unseen audio has accumulated; otherwise nil.
    public func nextChunk() async throws -> Chunk? {
        let chunkFrames = AVAudioFramePosition(chunkDurationSeconds * targetSampleRate)
        let currentLength = try readCurrentLength()
        guard currentLength - consumedFrames >= chunkFrames else { return nil }

        let start = consumedFrames
        let end = start + chunkFrames
        let chunk = try writeSlice(startFrame: start, endFrame: end)
        consumedFrames = end
        return chunk
    }

    /// Write out whatever remains past `consumedFrames` as a final chunk.
    public func flush() async throws -> Chunk? {
        let currentLength = try readCurrentLength()
        guard currentLength > consumedFrames else { return nil }

        let start = consumedFrames
        let end = currentLength
        let chunk = try writeSlice(startFrame: start, endFrame: end)
        consumedFrames = end
        return chunk
    }

    // MARK: - Private helpers

    /// Returns the number of PCM frames currently in the source file.
    /// Re-reads the file each call so newly appended frames are visible.
    /// Works whether the writer is still open (header not finalised) or closed.
    private func readCurrentLength() throws -> AVAudioFramePosition {
        // Happy path: file is closed and header is finalised.
        if let af = try? AVAudioFile(forReading: audioURL), af.length > 0 {
            return af.length
        }

        // Writer is still open — header size fields are 0.
        // Derive frame count from on-disk file size and the data-chunk offset.
        let offset = try resolvedDataBodyOffset()
        let fileSize = try onDiskFileSize()
        let available = max(0, fileSize - offset)
        let bytesPerFrame = 2  // 16-bit mono
        return AVAudioFramePosition(available / bytesPerFrame)
    }

    /// Writes `[startFrame, endFrame)` from the source file into a fresh temp WAV.
    /// Uses raw FileHandle I/O so it works even when the source writer is still open.
    private func writeSlice(startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition) throws -> Chunk {
        let outURL = URL(fileURLWithPath: "/tmp/harc-chunk-\(UUID().uuidString.prefix(8)).wav")

        let bytesPerFrame = 2  // 16-bit mono
        let frameCount = Int(endFrame - startFrame)
        let readOffset = try resolvedDataBodyOffset() + Int(startFrame) * bytesPerFrame
        let readLength = frameCount * bytesPerFrame

        // Read raw PCM bytes from the source.
        let rawBytes: Data
        do {
            let handle = try FileHandle(forReadingFrom: audioURL)
            defer { try? handle.close() }
            handle.seek(toFileOffset: UInt64(readOffset))
            rawBytes = handle.readData(ofLength: readLength)
        } catch {
            throw ClientError.chunkerFailed("read slice: \(error.localizedDescription)")
        }
        guard rawBytes.count == readLength else {
            throw ClientError.chunkerFailed(
                "slice underread: expected \(readLength) bytes, got \(rawBytes.count)"
            )
        }

        // Convert Int16 → Float32 and write to a new WAV file.
        do {
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(frameCount))!
            outBuf.frameLength = AVAudioFrameCount(frameCount)
            let outCh = outBuf.floatChannelData![0]
            rawBytes.withUnsafeBytes { ptr in
                let samples = ptr.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    outCh[i] = Float(samples[i]) / 32767.0
                }
            }
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let outFile = try AVAudioFile(forWriting: outURL, settings: fileSettings)
            try outFile.write(from: outBuf)
        } catch let err as ClientError {
            throw err
        } catch {
            throw ClientError.chunkerFailed(error.localizedDescription)
        }

        let startMs = Int(Double(startFrame) * 1000 / targetSampleRate)
        let endMs   = Int(Double(endFrame)   * 1000 / targetSampleRate)
        return Chunk(audioURL: outURL, startMs: startMs, endMs: endMs)
    }

    /// Returns the byte offset of the first PCM sample in the source WAV.
    /// Scans the RIFF chunk list once and caches the result.
    private func resolvedDataBodyOffset() throws -> Int {
        if let cached = dataBodyOffset { return cached }
        let offset = try parseDataBodyOffset()
        dataBodyOffset = offset
        return offset
    }

    /// Reads up to 8 KB of the file header and walks the RIFF chunk list to
    /// find the `data` chunk.  Returns the byte offset of the first PCM sample
    /// (i.e. after the 8-byte chunk header).
    private func parseDataBodyOffset() throws -> Int {
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: audioURL)
            defer { try? handle.close() }
            header = handle.readData(ofLength: 8192)
        } catch {
            throw ClientError.chunkerFailed("open for header: \(error.localizedDescription)")
        }
        guard header.count >= 12 else {
            throw ClientError.chunkerFailed("file too small to be a WAV")
        }

        var offset = 12  // skip 'RIFF'(4) + size(4) + 'WAVE'(4)
        while offset + 8 <= header.count {
            guard let chunkId = String(bytes: header[offset..<offset + 4], encoding: .ascii) else { break }
            let chunkSize = header[offset + 4..<offset + 8].withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkId == "data" {
                return offset + 8  // body starts after 4-byte id + 4-byte size
            }
            let nextOffset = offset + 8 + Int(chunkSize)
            if nextOffset <= offset { break }  // guard against zero/corrupt sizes
            offset = nextOffset
        }
        throw ClientError.chunkerFailed("no 'data' chunk found in WAV header")
    }

    private func onDiskFileSize() throws -> Int {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            return (attrs[.size] as? Int) ?? 0
        } catch {
            throw ClientError.chunkerFailed("file size: \(error.localizedDescription)")
        }
    }
}
