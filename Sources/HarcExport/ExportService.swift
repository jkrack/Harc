import Foundation
import HarcStore

public enum ExportFormat: Sendable {
    case markdown
    case docx

    public var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .docx:     return "docx"
        }
    }
}

/// Thin façade over renderers + filesystem. UI calls these; renderers stay
/// pure and testable.
public enum ExportService {
    /// Default destination: same folder and stem as the recording's .wav,
    /// with the format's extension.
    public static func defaultDestination(for recording: Recording, format: ExportFormat) -> URL {
        let wav = URL(fileURLWithPath: recording.wavPath)
        let stem = wav.deletingPathExtension().lastPathComponent
        return wav.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(format.filenameExtension)")
    }

    /// Render + write to `url`. Atomic write.
    public static func write(
        recording: Recording,
        format: ExportFormat,
        to url: URL
    ) throws {
        let input = ExportInputBuilder.build(from: recording)
        let data: Data
        switch format {
        case .markdown:
            data = Data(MarkdownExporter.render(input).utf8)
        case .docx:
            data = try DocxExporter.render(input)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteOutOfSpaceError:
                    throw ExportError.diskFull
                case NSFileWriteNoPermissionError:
                    throw ExportError.permissionDenied(url: url)
                default:
                    break
                }
            }
            throw ExportError.writeFailed(url: url, underlying: error.localizedDescription)
        }
    }

    /// Render Markdown only, return the string. For the "Copy Markdown" UI.
    public static func markdownString(for recording: Recording) -> String {
        let input = ExportInputBuilder.build(from: recording)
        return MarkdownExporter.render(input)
    }
}
