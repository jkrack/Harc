import Foundation
import HarcCore

/// Minimal protocol so RequestHandler can be unit-tested against fakes.
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
}

extension Transcriber: TranscribeService {}

public protocol DiarizeService: Sendable {
    func diarize(audioPath: String) async throws -> [SpeakerSegment]
    var isLoaded: Bool { get async }
}

/// Routes IPCRequests to the appropriate service, producing an IPCResponse.
/// Stateless except for a handful of daemon-lifetime values (version, startedAt).
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
        case .status:
            let loaded = await transcriber.isLoaded
            return .status(DaemonStatus(
                version: version,
                modelLoaded: loaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .shutdown:
            let loaded = await transcriber.isLoaded
            return .status(DaemonStatus(
                version: version,
                modelLoaded: loaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .transcribe(let req):
            return await transcribe(req)
        }
    }

    private func transcribe(_ req: TranscribeRequest) async -> IPCResponse {
        let textResult: TranscribeResult
        do {
            textResult = try await transcriber.transcribe(audioPath: req.audioPath)
        } catch let err as DaemonError {
            return .error(IPCError(code: err.ipcCode, message: err.errorDescription ?? "transcribe failed"))
        } catch {
            return .error(IPCError(code: "transcribe_failed", message: error.localizedDescription))
        }

        guard req.diarize, let diarizer else {
            return .result(textResult)
        }

        let speakers: [SpeakerSegment]
        do {
            speakers = try await diarizer.diarize(audioPath: req.audioPath)
        } catch let err as DaemonError {
            // Transcription succeeded; degrade to empty speakers and return success.
            // Clients that care can inspect speakers.isEmpty.
            _ = err
            speakers = []
        } catch {
            speakers = []
        }

        return .result(TranscribeResult(
            text: textResult.text,
            words: textResult.words,
            speakers: speakers,
            processingMs: textResult.processingMs
        ))
    }
}
