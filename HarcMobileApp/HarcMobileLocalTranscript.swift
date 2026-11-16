import Foundation
import HarcAudioMobile
import HarcDomain
import HarcTransfer
import Observation

/// A private derived preview, never a Host receipt, canonical artifact, speaker
/// assignment or edited transcript. Binding includes the immutable audio digest.
struct HarcMobileLocalTranscript: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }
    let origin: OriginRecordingID
    let pcmHash: CanonicalPCMHash
    let frames: UInt64
    let localeIdentifier: String
    let engine: String
    let segments: [Segment]

    var text: String { segments.map(\.text).joined(separator: " ") }

    func validate(for request: HarcMobileTranscriptRequest) throws {
        guard origin == request.origin, pcmHash == request.pcmHash,
              frames == request.frames, engine == "apple-speechtranscriber-v1",
              !localeIdentifier.isEmpty, segments.count <= 100_000,
              text.utf8.count <= 8_000_000 else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        var previousEnd: Double = 0
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= previousEnd, segment.end >= segment.start,
                  segment.end <= Double(frames) / 16_000 + 0.05 else {
                throw HarcMobileTranscriptionError.invalidEvidence
            }
            previousEnd = segment.end
        }
    }
}

struct HarcMobileTranscriptRequest: Codable, Equatable, Sendable {
    let origin: OriginRecordingID
    let pcmHash: CanonicalPCMHash
    let frames: UInt64
    let audioURL: URL

    init(capture: FinalizedCapture, audioURL: URL) {
        origin = capture.originRecordingID
        pcmHash = capture.canonicalPCMSHA256
        frames = capture.totalCanonicalFrames
        self.audioURL = audioURL
    }

    var id: UUID { origin.recordingUUID }
    var storageName: String { id.uuidString.lowercased() + "-" + pcmHash.description }
}

enum HarcMobileTranscriptionError: Error {
    case unavailable, needsModel, invalidEvidence
}

/// Separate from capture/outbox storage: derived failures never affect audio
/// durability, transfer eligibility or codec qualification.
actor HarcMobileLocalTranscriptStore {
    let root: URL
    private let attributes: any HarcMobileCaptureStorageAttributeApplying

    init(root: URL, attributes: any HarcMobileCaptureStorageAttributeApplying =
         FoundationHarcMobileCaptureStorageAttributes()) {
        self.root = root
        self.attributes = attributes
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func register(_ request: HarcMobileTranscriptRequest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try attributes.applyAndVerify(.transferArtifact, to: root)
        // Persist only identity, not a sandbox path that can change on update.
        let marker = Marker(origin: request.origin, hash: request.pcmHash, frames: request.frames)
        try HarcMobileTransferArtifactPublisher.publishImmutable(
            encoder.encode(marker),
            to: root.appendingPathComponent(request.storageName + ".pending.json"),
            attributes: attributes
        )
    }

    func isRegistered(_ request: HarcMobileTranscriptRequest) -> Bool {
        FileManager.default.fileExists(atPath:
            root.appendingPathComponent(request.storageName + ".pending.json").path)
    }

    func hasSaved(_ request: HarcMobileTranscriptRequest) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(request.storageName + ".json").path)
    }

    func load(_ request: HarcMobileTranscriptRequest) throws -> HarcMobileLocalTranscript? {
        let url = root.appendingPathComponent(request.storageName + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 12_000_000 else {
            throw HarcMobileTranscriptionError.invalidEvidence
        }
        let result = try JSONDecoder().decode(HarcMobileLocalTranscript.self, from: Data(contentsOf: url))
        try result.validate(for: request)
        return result
    }

    func save(_ transcript: HarcMobileLocalTranscript, for request: HarcMobileTranscriptRequest) throws {
        try transcript.validate(for: request)
        try Task.checkCancellation()
        // Commit point: once the synchronous immutable publication starts, a
        // later cancellation may leave a complete validated preview on disk.
        // The coordinator still suppresses presentation until it resumes.
        try HarcMobileTransferArtifactPublisher.publishImmutable(
            encoder.encode(transcript),
            to: root.appendingPathComponent(request.storageName + ".json"),
            attributes: attributes
        )
    }

    private struct Marker: Codable { let origin: OriginRecordingID; let hash: CanonicalPCMHash; let frames: UInt64 }
}

@MainActor
@Observable
final class HarcMobileLocalTranscriptionCoordinator {
    enum State: Equatable {
        case queued, transcribing, available, ready(HarcMobileLocalTranscript)
        case needsModel, unavailable, failed
    }
    private(set) var states: [UUID: State] = [:]
    private let store: HarcMobileLocalTranscriptStore
    private let transcribe: @Sendable (HarcMobileTranscriptRequest) async throws -> HarcMobileLocalTranscript
    private var requests: [UUID: HarcMobileTranscriptRequest] = [:]
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var captureActive = false
    private var foreground: Bool
    private var generation: UInt64 = 0

    init(store: HarcMobileLocalTranscriptStore, foreground: Bool = true,
         transcribe: @escaping @Sendable (HarcMobileTranscriptRequest) async throws -> HarcMobileLocalTranscript = HarcMobileAppleSpeech.transcribe) {
        self.store = store
        self.foreground = foreground
        self.transcribe = transcribe
    }

    func restore(_ candidates: [HarcMobileTranscriptRequest]) async {
        for request in candidates {
            guard states[request.id] == nil else { continue }
            requests[request.id] = request
            if await store.hasSaved(request) {
                // Read transcript payload only when its recording is opened.
                states[request.id] = .available
            } else if await store.isRegistered(request),
                      FileManager.default.fileExists(atPath: request.audioURL.path) {
                enqueue(request)
            }
        }
    }

    func hasPreview(for origin: OriginRecordingID) -> Bool {
        guard requests[origin.recordingUUID]?.origin == origin else { return false }
        switch states[origin.recordingUUID] {
        case .available, .ready: return true
        default: return false
        }
    }

    func loadPreview(_ id: UUID) async {
        guard states[id] == .available, let request = requests[id] else { return }
        do {
            if let saved = try await store.load(request), states[id] == .available {
                states[id] = .ready(saved)
                trimPayloads(keeping: id)
            } else if states[id] == .available { states[id] = .failed }
        } catch { states[id] = .failed }
    }

    private func trimPayloads(keeping id: UUID) {
        let loaded = states.keys.filter { key in
            if case .ready = states[key] { return key != id }; return false
        }
        for key in loaded.dropFirst(7) { states[key] = .available }
    }

    func enqueue(_ request: HarcMobileTranscriptRequest) {
        // The first exact binding owns this slot. Reject a mismatched request
        // without mutating or relabelling the original job/result.
        if let existing = requests[request.id], existing != request { return }
        if case .ready = states[request.id] { return }
        if states[request.id] == .transcribing || queue.contains(request.id) { return }
        requests[request.id] = request
        states[request.id] = .queued
        queue.append(request.id)
        // A recording can stop in the background. Persist its intent without
        // waiting for foreground inference, but never block the capture commit.
        let store = self.store
        Task { try? await store.register(request) }
        startWorker()
    }

    func setCaptureActive(_ value: Bool) { captureActive = value; updateSuspension() }
    func setForeground(_ value: Bool) { foreground = value; updateSuspension() }

    private func updateSuspension() {
        if captureActive || !foreground {
            generation &+= 1
            worker?.cancel()
        } else { startWorker() }
    }

    private func startWorker() {
        guard worker == nil, !captureActive, foreground, !queue.isEmpty else { return }
        let currentGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !captureActive, foreground,
                  let id = queue.first, let request = requests[id] {
                do {
                    try await store.register(request)
                    try Task.checkCancellation()
                    let saved = try await store.load(request)
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { break }
                    if let saved {
                        guard generation == currentGeneration else { break }
                        states[id] = .ready(saved)
                    } else {
                        states[id] = .transcribing
                        let result = try await transcribe(request)
                        try Task.checkCancellation()
                        guard generation == currentGeneration else { break }
                        try await store.save(result, for: request)
                        try Task.checkCancellation()
                        guard generation == currentGeneration else { break }
                        states[id] = .ready(result)
                    }
                    trimPayloads(keeping: id)
                    queue.removeFirst()
                } catch {
                    if Task.isCancelled || generation != currentGeneration {
                        states[id] = .queued
                        break
                    }
                    switch error as? HarcMobileTranscriptionError {
                    case .needsModel: states[id] = .needsModel
                    case .unavailable: states[id] = .unavailable
                    default: states[id] = .failed
                    }
                    queue.removeFirst()
                }
            }
            // Wait for the cancelled worker to really exit before replacement.
            worker = nil
            startWorker()
        }
    }
}
