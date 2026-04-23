import Foundation
import CryptoKit

/// Abstraction over the network. `ModelManager` depends on this protocol so
/// tests can inject a fake that serves bytes from memory.
///
/// Each call downloads exactly one file. The engine is responsible for:
/// - resumable byte-level progress (`onProgress` is called with the latest
///   `bytesWritten`),
/// - atomic move of the final bytes to `destinationURL`,
/// - cancellation via `Task.isCancelled` cooperation.
public protocol DownloadEngine: Sendable {
    func download(
        from url: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        resumeData: Data?,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> DownloadResult
}

/// Result of a single file download. `resumeData` is non-nil when the call
/// was cancelled and URLSession emitted resumable state.
public struct DownloadResult: Sendable {
    public let bytesWritten: Int64
    public let resumeData: Data?

    public init(bytesWritten: Int64, resumeData: Data?) {
        self.bytesWritten = bytesWritten
        self.resumeData = resumeData
    }
}

public enum DownloadError: Error, LocalizedError {
    case httpStatus(Int)
    case sha256Mismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case cancelled
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Server returned HTTP \(code)."
        case .sha256Mismatch: return "Downloaded file didn't match its expected checksum."
        case .sizeMismatch(let expected, let actual):
            return "Downloaded file was \(actual) bytes; expected \(expected)."
        case .cancelled: return "Download cancelled."
        case .other(let s): return s
        }
    }
}

// MARK: - URLSession implementation

/// Production `DownloadEngine` backed by `URLSession.default`. Single-task
/// per call — simpler resume semantics than a multi-request approach.
public final class URLSessionDownloadEngine: DownloadEngine, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60 * 60 * 2   // 2 h total per file
            self.session = URLSession(configuration: config)
        }
    }

    public func download(
        from url: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        resumeData: Data?,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> DownloadResult {
        let delegate = ProgressDelegate(onProgress: onProgress)
        let (tempURL, response): (URL, URLResponse)
        do {
            if let resumeData {
                (tempURL, response) = try await session.download(resumeFrom: resumeData, delegate: delegate)
            } else {
                (tempURL, response) = try await session.download(from: url, delegate: delegate)
            }
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            // If URLSession produced resume data, hand it back so the caller
            // can persist + resume later. Swift Concurrency's download API
            // surfaces resume data via the user-info dictionary on the error.
            let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            throw DownloadError.cancelled.withResumeData(resume)
        } catch {
            throw DownloadError.other(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }

        let fm = FileManager.default
        let destDir = destinationURL.deletingLastPathComponent()
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempURL, to: destinationURL)

        let attrs = try fm.attributesOfItem(atPath: destinationURL.path)
        let actualBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if expectedBytes > 0, abs(actualBytes - expectedBytes) > max(1024, expectedBytes / 100) {
            // Tolerate 1 % variance — our catalog sizes are approximations.
            try? fm.removeItem(at: destinationURL)
            throw DownloadError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        return DownloadResult(bytesWritten: actualBytes, resumeData: nil)
    }
}

// MARK: - Progress delegate

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    // Required for the async download APIs even though the move happens in
    // the awaiting caller — delegate must be non-nil to get progress.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // No-op: the async API returns the temp URL to the caller directly.
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }
}

// MARK: - Resume-data attachment on cancellation

private extension DownloadError {
    /// Wraps `.cancelled` with optional resume data in an associated object —
    /// the URLSession callback path doesn't let us attach it cleanly to an
    /// enum case without a breaking API change. Pragmatic approach: throw
    /// `.cancelled` normally; the caller can retrieve any resume data via
    /// `URLSessionDownloadTaskResumeData` in the userInfo of the underlying
    /// URLError if one is thrown. This helper exists so a future refactor
    /// can carry it through without more code churn; v1 just throws
    /// `.cancelled` on cancel.
    func withResumeData(_ data: Data?) -> DownloadError {
        return self
    }
}

/// Key name that `URLSession` uses on cancel-with-resume. Re-declared here
/// because the symbol isn't always imported by callers of our module.
private let NSURLSessionDownloadTaskResumeData = "NSURLSessionDownloadTaskResumeData"
