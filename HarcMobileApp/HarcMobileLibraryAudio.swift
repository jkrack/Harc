import AVFAudio
import CryptoKit
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcProtocol
import Observation

private struct HarcMobileCachedAudioManifest: Codable, Equatable, Sendable {
    let canonicalID: CanonicalRecordingID
    let revision: EntityRevision
    let totalByteLength: UInt64
    let contentSHA256: Data
}

struct HarcMobileAudioCachePaths: Sendable {
    let directory: URL
    let final: URL
    let partial: URL
    let manifest: URL

    init(cache: HarcLibraryCache, summary: LibraryRecordingSummary) throws {
        directory = cache.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Audio", isDirectory: true)
        let stem = "\(summary.canonicalID.description)-r\(summary.revision.rawValue)"
        final = directory.appendingPathComponent("\(stem).wav")
        partial = directory.appendingPathComponent("\(stem).wav.partial")
        manifest = directory.appendingPathComponent("\(stem).json")
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = FoundationClientStoreStorageAttributes()
        try attributes.applyAndVerify(
            .libraryCache,
            to: .directory(directory)
        )
    }

    func validatedCachedURL(
        summary: LibraryRecordingSummary
    ) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: final.path),
              manager.fileExists(atPath: manifest.path) else { return nil }
        do {
            let stored = try JSONDecoder().decode(
                HarcMobileCachedAudioManifest.self,
                from: Data(contentsOf: manifest, options: .mappedIfSafe)
            )
            guard stored.canonicalID == summary.canonicalID,
                  stored.revision == summary.revision,
                  stored.contentSHA256.count == 32,
                  try Self.fileByteCount(final) == stored.totalByteLength,
                  try Self.sha256(final) == stored.contentSHA256 else {
                throw HarcMobileLibraryAudioError.invalidCachedAudio
            }
            return final
        } catch {
            try? manager.removeItem(at: final)
            try? manager.removeItem(at: manifest)
            return nil
        }
    }

    func boundedResumeOffset(summary: LibraryRecordingSummary) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: partial.path) else {
            return 0
        }
        let current = try Self.fileByteCount(partial)
        guard case .available = summary.canonicalAudio.availability,
              let frames = summary.canonicalAudio.totalFrames else {
            try FileManager.default.removeItem(at: partial)
            return 0
        }
        let pcm = frames.multipliedReportingOverflow(by: 2)
        let total = pcm.partialValue.addingReportingOverflow(44)
        guard !pcm.overflow, !total.overflow,
              current <= total.partialValue else {
            try FileManager.default.removeItem(at: partial)
            return 0
        }
        return current
    }

    private static func fileByteCount(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let number = attributes[.size] as? NSNumber else {
            throw HarcMobileLibraryAudioError.invalidCachedAudio
        }
        return number.uint64Value
    }

    private static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 * 1_024 * 1_024),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }
}

actor HarcMobileAudioDownloadSink {
    private let paths: HarcMobileAudioCachePaths
    private let summary: LibraryRecordingSummary
    private let attributes = FoundationClientStoreStorageAttributes()
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var descriptor: Harc_V1_AudioDownloadDescriptorV1?
    private var offset: UInt64

    nonisolated let resumeOffset: UInt64

    init(
        paths: HarcMobileAudioCachePaths,
        summary: LibraryRecordingSummary,
        resumeOffset: UInt64
    ) throws {
        self.paths = paths
        self.summary = summary
        self.resumeOffset = resumeOffset
        offset = resumeOffset
        let manager = FileManager.default
        if resumeOffset == 0 {
            if manager.fileExists(atPath: paths.partial.path) {
                try manager.removeItem(at: paths.partial)
            }
            guard manager.createFile(
                atPath: paths.partial.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw HarcMobileLibraryAudioError.cacheWriteFailed
            }
        }
        try attributes.applyAndVerify(
            .libraryCache,
            to: .sidecar(paths.partial)
        )
        let opened = try FileHandle(forUpdating: paths.partial)
        do {
            let actual = try opened.seekToEnd()
            guard actual == resumeOffset else {
                throw HarcMobileLibraryAudioError.invalidCachedAudio
            }
            if resumeOffset > 0 {
                try opened.seek(toOffset: 0)
                var retained: UInt64 = 0
                while retained < resumeOffset {
                    let count = min(
                        1 * 1_024 * 1_024,
                        Int(resumeOffset - retained)
                    )
                    guard let data = try opened.read(upToCount: count),
                          !data.isEmpty else {
                        throw HarcMobileLibraryAudioError.invalidCachedAudio
                    }
                    hasher.update(data: data)
                    retained += UInt64(data.count)
                }
                try opened.seek(toOffset: resumeOffset)
            }
            handle = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    deinit {
        try? handle?.close()
    }

    func consume(_ response: Harc_V1_GetAudioResponseV1) throws {
        try HarcMobileLibraryCoordinator.validateLibraryProtocol(
            response.hasProtocol,
            response.protocol
        )
        switch response.value {
        case .descriptor(let value):
            let contentHash = try value.contentSha256.validatedBytes(
                field: "getAudio.contentSHA256"
            )
            let pcmHash = try value.canonicalPcmSha256.validatedBytes(
                field: "getAudio.canonicalPCMSHA256"
            )
            guard descriptor == nil,
                  value.hasCanonicalRecordingID,
                  try value.canonicalRecordingID.domainValue()
                    == summary.canonicalID,
                  value.revision == summary.revision.rawValue,
                  value.representation == .audioRepresentationCanonicalWav,
                  value.contentType == "audio/wav",
                  value.totalByteLength >= resumeOffset,
                  value.hasContentSha256,
                  contentHash.count == 32,
                  value.hasCanonicalFormat,
                  try value.canonicalFormat.domainValue() == .harcV1,
                  value.hasCanonicalPcmSha256,
                  pcmHash == summary.canonicalAudio.pcmSHA256?.rawBytes,
                  value.totalCanonicalFrames
                    == summary.canonicalAudio.totalFrames else {
                throw HarcMobileLibraryAudioError.malformedStream
            }
            descriptor = value
        case .frame(let frame):
            guard descriptor != nil,
                  frame.byteOffset == offset,
                  !frame.data.isEmpty,
                  frame.data.count <= 4 * 1_024 * 1_024,
                  let descriptor,
                  offset <= descriptor.totalByteLength,
                  UInt64(frame.data.count)
                    <= descriptor.totalByteLength - offset,
                  let handle else {
                throw HarcMobileLibraryAudioError.malformedStream
            }
            try handle.write(contentsOf: frame.data)
            hasher.update(data: frame.data)
            offset += UInt64(frame.data.count)
        case nil:
            throw HarcMobileLibraryAudioError.malformedStream
        }
    }

    func finish() throws -> URL {
        guard let descriptor,
              offset == descriptor.totalByteLength,
              Data(hasher.finalize()) == descriptor.contentSha256.value,
              let handle else {
            throw HarcMobileLibraryAudioError.malformedStream
        }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.final.path) {
            try manager.removeItem(at: paths.final)
        }
        try manager.moveItem(at: paths.partial, to: paths.final)
        let manifest = HarcMobileCachedAudioManifest(
            canonicalID: summary.canonicalID,
            revision: summary.revision,
            totalByteLength: descriptor.totalByteLength,
            contentSHA256: descriptor.contentSha256.value
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest, options: .atomic)
        try attributes.applyAndVerify(
            .libraryCache,
            to: .sidecar(paths.final)
        )
        try attributes.applyAndVerify(
            .libraryCache,
            to: .sidecar(paths.manifest)
        )
        return paths.final
    }

    func discardUnverifiedPartial() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: paths.partial)
    }
}

@MainActor
@Observable
final class HarcMobileRecordingAudioController: NSObject {
    enum State: Equatable {
        case idle
        case downloading
        case playing
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    private let coordinator: HarcMobileLibraryCoordinator
    private let summary: LibraryRecordingSummary
    private var player: AVAudioPlayer?

    init(
        coordinator: HarcMobileLibraryCoordinator,
        summary: LibraryRecordingSummary
    ) {
        self.coordinator = coordinator
        self.summary = summary
    }

    func playOrPause() async {
        if let player {
            if player.isPlaying {
                player.pause()
                state = .paused
            } else {
                player.play()
                state = .playing
            }
            return
        }
        state = .downloading
        do {
            let url = try await coordinator.downloadCanonicalAudio(
                summary: summary
            )
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw HarcMobileLibraryAudioError.playbackFailed
            }
            self.player = player
            state = .playing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

}

@MainActor
extension HarcMobileRecordingAudioController: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        state = flag ? .idle : .failed("Playback ended unexpectedly.")
    }
}

enum HarcMobileLibraryAudioError: LocalizedError {
    case invalidCachedAudio
    case cacheWriteFailed
    case malformedStream
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidCachedAudio:
            "The protected audio cache is invalid."
        case .cacheWriteFailed:
            "Harc could not create its protected audio cache."
        case .malformedStream:
            "The Host returned an invalid canonical audio stream."
        case .playbackFailed:
            "Harc could not start audio playback."
        }
    }
}
