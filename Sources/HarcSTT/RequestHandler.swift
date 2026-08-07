import Foundation
import HarcCore

/// Minimal protocol so RequestHandler can be unit-tested against fakes.
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
    var modelState: Transcriber.ModelState { get async }
}

extension Transcriber: TranscribeService {}

extension Transcriber.ModelState {
    /// Wire mapping for `DaemonStatus`.
    var statusFields: (state: DaemonStatus.ModelState, progress: Double?, error: String?) {
        switch self {
        case .idle, .loading:
            return (.loading, nil, nil)
        case .downloading(let progress):
            return (.downloading, progress, nil)
        case .ready:
            return (.ready, nil, nil)
        case .failed(let message):
            return (.failed, nil, message)
        }
    }
}

public protocol DiarizeService: Sendable {
    func diarize(audioPath: String) async throws -> [SpeakerSegment]
    func diarizeWithEmbeddings(audioPath: String) async throws -> Diarizer.DiarizationOutput
    var isLoaded: Bool { get async }
}

public struct RequestHandler: Sendable {
    private let transcriber: any TranscribeService
    private let diarizer: (any DiarizeService)?
    private let version: String
    private let startedAt: Date

    public init(
        transcriber: any TranscribeService,
        diarizer: (any DiarizeService)?,
        version: String,
        startedAt: Date
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.version = version
        self.startedAt = startedAt
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request {
        case .status, .shutdown:
            let fields = await transcriber.modelState.statusFields
            return .status(DaemonStatus(
                version: version,
                modelLoaded: await transcriber.isLoaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
                modelState: fields.state,
                downloadProgress: fields.progress,
                errorMessage: fields.error
            ))

        case .transcribe(let req):
            do {
                var result = try await transcriber.transcribe(audioPath: req.audioPath, vad: req.vad)
                if req.diarize, let diarizer {
                    do {
                        let output = try await diarizer.diarizeWithEmbeddings(
                            audioPath: req.audioPath
                        )
                        result.speakers = output.segments
                        result.speakerEmbeddings = output.speakers
                    } catch {
                        // Diarization is best-effort during chunked transcribe;
                        // log but return text + words intact.
                        FileHandle.standardError.write(Data(
                            "harc-stt: diarize failed (transcribe path): \(error.localizedDescription)\n".utf8
                        ))
                    }
                }
                return .result(result)
            } catch let err as DaemonError {
                return .error(IPCError(code: err.ipcCode, message: err.errorDescription ?? "transcribe failed"))
            } catch {
                return .error(IPCError(
                    code: "transcribe_failed",
                    message: error.localizedDescription
                ))
            }

        case .diarize(let req):
            guard let diarizer else {
                return .error(IPCError(
                    code: "diarizer_unavailable",
                    message: "Diarizer model not loaded"
                ))
            }
            let started = Date()
            do {
                let output = try await diarizer.diarizeWithEmbeddings(audioPath: req.audioPath)
                let processingMs = Int(Date().timeIntervalSince(started) * 1000)
                return .diarization(DiarizeResult(
                    segments: output.segments,
                    speakers: output.speakers,
                    processingMs: processingMs
                ))
            } catch {
                return .error(IPCError(
                    code: "diarize_failed",
                    message: error.localizedDescription
                ))
            }
        }
    }
}
