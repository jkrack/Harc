import Foundation

public enum ExportError: Error, Sendable {
    case transcriptJSONUnreadable(path: String, underlying: String)
    case docxRenderFailed(underlying: String)
    case writeFailed(url: URL, underlying: String)
    case permissionDenied(url: URL)
    case diskFull
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transcriptJSONUnreadable(let path, _):
            return "Couldn't read transcript JSON at \(path)."
        case .docxRenderFailed:
            return "Couldn't render DOCX. Try Markdown instead."
        case .writeFailed(let url, _):
            return "Couldn't write to \(url.path)."
        case .permissionDenied(let url):
            return "No permission to write to \(url.path)."
        case .diskFull:
            return "Not enough disk space for the export."
        }
    }
}
