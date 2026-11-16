import AVFoundation
import CryptoKit
import Darwin
import Foundation
import HarcDomain
import Speech

/// No SFSpeechRecognizer/server fallback and no AppleLLM/network wrapper.
/// Only finalized WAVs are read; this never opens or changes an audio session.
enum HarcMobileAppleSpeech {
    static func transcribe(_ request: HarcMobileTranscriptRequest) async throws -> HarcMobileLocalTranscript {
        guard SpeechTranscriber.isAvailable else { throw HarcMobileTranscriptionError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw HarcMobileTranscriptionError.unavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        // Routine processing is offline. Model installation is a separate,
        // explicit UI action; audio is never sent to acquire a model.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw HarcMobileTranscriptionError.needsModel
        }
        try Task.checkCancellation()
        let identity = try verifyAudio(request)
        let file = try AVAudioFile(forReading: request.audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                var segments: [HarcMobileLocalTranscript.Segment] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    guard segments.count < 100_000 else {
                        throw HarcMobileTranscriptionError.invalidEvidence
                    }
                    segments.append(.init(start: result.range.start.seconds,
                        end: CMTimeRangeGetEnd(result.range).seconds, text: text))
                }
                try Task.checkCancellation()
                guard try verifyAudio(request) == identity else {
                    throw HarcMobileTranscriptionError.invalidEvidence
                }
                let transcript = HarcMobileLocalTranscript(origin: request.origin,
                    pcmHash: request.pcmHash, frames: request.frames,
                    localeIdentifier: locale.identifier, engine: "apple-speechtranscriber-v1",
                    segments: segments)
                try transcript.validate(for: request)
                return transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    static func installCurrentLanguage() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw HarcMobileTranscriptionError.unavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: Int
        let modifiedNanos: Int
    }

    /// Bounded reads validate the exact canonical master before and after STT.
    /// The transcript cannot silently attach to replaced or changed audio.
    private static func verifyAudio(_ request: HarcMobileTranscriptRequest) throws -> Identity {
        guard request.audioURL.isFileURL, request.frames > 0,
              request.frames <= UInt64((UInt32.max - 36) / 2) else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        let fd = open(request.audioURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HarcMobileTranscriptionError.invalidEvidence }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == Int64(44 + request.frames * 2) else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        let identity = Identity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let header = try handle.read(upToCount: 44) ?? Data()
        guard header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<16], encoding: .ascii) == "WAVEfmt ",
              String(data: header[36..<40], encoding: .ascii) == "data",
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }) == UInt32(36 + request.frames * 2),
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self)) }) == 16,
              header.withUnsafeBytes({ UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 20, as: UInt16.self)) }) == 1,
              header.withUnsafeBytes({ UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self)) }) == 1,
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) }) == 16_000,
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) }) == 32_000,
              header.withUnsafeBytes({ UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 32, as: UInt16.self)) }) == 2,
              header.withUnsafeBytes({ UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self)) }) == 16,
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self)) }) == UInt32(request.frames * 2) else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        var hash = SHA256()
        var remaining = request.frames * 2
        while remaining > 0 {
            try Task.checkCancellation()
            let consumed = try autoreleasepool {
                let data = try handle.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
                guard !data.isEmpty else { throw HarcMobileTranscriptionError.invalidEvidence }
                hash.update(data: data)
                return UInt64(data.count)
            }
            remaining -= consumed
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              Data(hash.finalize()) == request.pcmHash.rawBytes else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        return identity
    }
}
