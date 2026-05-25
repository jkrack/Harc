import Foundation
import Testing
import AppKit
@testable import HarcStore
@testable import HarcUI

@MainActor
@Suite("Note image paste flow")
struct NoteImagePasteFlowTests {
    private final class SpySink: NoteImagePasteSink {
        private(set) var insertedMarkdown: [String] = []
        private(set) var attachmentErrors: [String] = []

        func insertMarkdown(_ markdown: String) {
            insertedMarkdown.append(markdown)
        }

        func showAttachmentError(_ message: String) {
            attachmentErrors.append(message)
        }
    }

    private enum PasteFailure: Error, LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "Caption unavailable until the vision model is installed."
            }
        }
    }

    private func makeStore() -> NoteStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-note-ui-paste-\(UUID().uuidString)", isDirectory: true)
        return NoteStore(rootURL: root)
    }

    private func makeScreenshotTIFFData() throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return try #require(image.tiffRepresentation)
    }

    @Test("valid image paste inserts exactly one Markdown image token")
    func validImagePasteInsertsOneMarkdownToken() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var receivedImage: NotePastedImage?
        let handler = NoteImagePasteHandler { image in
            receivedImage = image
            return "![slide](./note.assets/slide.png)"
        }
        let sink = SpySink()

        await handler.handle([
            "type": "pasteImage",
            "data": imageData.base64EncodedString(),
            "mimeType": "image/png",
            "filename": "Roadmap Slide.png",
        ], sink: sink)

        #expect(receivedImage == NotePastedImage(
            data: imageData,
            mimeType: "image/png",
            filename: "Roadmap Slide.png"
        ))
        #expect(sink.insertedMarkdown == ["![slide](./note.assets/slide.png)"])
        #expect(sink.attachmentErrors.isEmpty)
    }

    @Test("native pasteboard PNG is converted into a note image paste")
    func nativePasteboardPNGConvertsToNoteImagePaste() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("harc-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .png)

        var receivedImage: NotePastedImage?
        let handler = NoteImagePasteHandler { image in
            receivedImage = image
            return "![screenshot](./note.assets/screenshot.png)"
        }
        let sink = SpySink()

        #expect(handler.handlePasteboard(pasteboard, sink: sink))
        try await Task.sleep(for: .milliseconds(50))

        #expect(receivedImage == NotePastedImage(
            data: imageData,
            mimeType: "image/png",
            filename: nil
        ))
        #expect(sink.insertedMarkdown == ["![screenshot](./note.assets/screenshot.png)"])
        #expect(sink.attachmentErrors.isEmpty)
    }

    @Test("macOS screenshot TIFF paste payload is normalized to PNG")
    func macOSScreenshotTIFFPastePayloadNormalizesToPNG() async throws {
        let tiff = try makeScreenshotTIFFData()
        var receivedImage: NotePastedImage?
        let handler = NoteImagePasteHandler { image in
            receivedImage = image
            return "![screenshot](./note.assets/screenshot.png)"
        }
        let sink = SpySink()

        await handler.handle([
            "type": "pasteImage",
            "data": tiff.base64EncodedString(),
            "mimeType": "image/tiff",
            "filename": "Screenshot.tiff",
        ], sink: sink)

        let image = try #require(receivedImage)
        #expect(image.mimeType == "image/png")
        #expect(image.filename == "Screenshot.tiff")
        #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(sink.insertedMarkdown == ["![screenshot](./note.assets/screenshot.png)"])
        #expect(sink.attachmentErrors.isEmpty)
    }

    @Test("native pasteboard NSImage screenshot is converted into a note image paste")
    func nativePasteboardNSImageScreenshotConvertsToNoteImagePaste() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("harc-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        var receivedImage: NotePastedImage?
        let handler = NoteImagePasteHandler { pasted in
            receivedImage = pasted
            return "![screenshot](./note.assets/screenshot.png)"
        }
        let sink = SpySink()

        #expect(handler.handlePasteboard(pasteboard, sink: sink))
        try await Task.sleep(for: .milliseconds(50))

        let pasted = try #require(receivedImage)
        #expect(pasted.mimeType == "image/png")
        #expect(pasted.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(sink.insertedMarkdown == ["![screenshot](./note.assets/screenshot.png)"])
        #expect(sink.attachmentErrors.isEmpty)
    }

    @Test("native pasteboard without an image falls through to normal paste handling")
    func nativePasteboardWithoutImageFallsThrough() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("harc-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        let handler = NoteImagePasteHandler { _ in
            Issue.record("Text-only pasteboard should not call the image attachment closure")
            return "![unexpected](./unexpected.png)"
        }
        let sink = SpySink()

        #expect(!handler.handlePasteboard(pasteboard, sink: sink))
        #expect(sink.insertedMarkdown.isEmpty)
        #expect(sink.attachmentErrors.isEmpty)
    }

    @Test("invalid image paste payload shows an attachment error and inserts nothing")
    func invalidImagePastePayloadShowsAttachmentError() async {
        let handler = NoteImagePasteHandler { _ in
            Issue.record("Invalid paste payload should not call the image attachment closure")
            return "![unexpected](./unexpected.png)"
        }
        let sink = SpySink()

        await handler.handle([
            "type": "pasteImage",
            "data": "not-base64",
            "mimeType": "image/png",
        ], sink: sink)

        #expect(sink.insertedMarkdown.isEmpty)
        #expect(sink.attachmentErrors == ["Could not read the pasted image."])
    }

    @Test("attachment failures surface as editor attachment errors")
    func attachmentFailureSurfacesAsEditorError() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let handler = NoteImagePasteHandler { _ in
            throw PasteFailure.modelUnavailable
        }
        let sink = SpySink()

        await handler.handle([
            "type": "pasteImage",
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
            "filename": "Slide.png",
        ], sink: sink)

        #expect(sink.insertedMarkdown.isEmpty)
        #expect(sink.attachmentErrors == ["Caption unavailable until the vision model is installed."])
    }

    @Test("active note image paste writes a note-owned asset and inserts a portable Markdown reference")
    func activeNoteImagePasteWritesNoteOwnedAssetAndMarkdownReference() async throws {
        let store = makeStore()
        let note = try await store.create(title: "Customer roadmap")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let handler = NoteImagePasteHandler { image in
            let result = try await store.attachImage(
                toNoteID: note.id,
                data: image.data,
                mimeType: image.mimeType,
                preferredFilename: image.filename
            )
            return result.markdown
        }
        let sink = SpySink()

        await handler.handle([
            "type": "pasteImage",
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
            "filename": "Customer Roadmap.png",
        ], sink: sink)

        #expect(sink.attachmentErrors.isEmpty)
        #expect(sink.insertedMarkdown.count == 1)
        let markdown = try #require(sink.insertedMarkdown.first)
        #expect(markdown.range(
            of: #"^!\[customer roadmap\]\(\./\Q\#(note.id)\E\.assets/customer-roadmap-[A-Z0-9]{26}\.png\)$"#,
            options: .regularExpression
        ) != nil)

        let saved = try #require(try await store.fetch(id: note.id))
        let attachment = try #require(saved.attachments.first)
        #expect(saved.attachments.count == 1)
        #expect(attachment.relativePath.hasPrefix("\(note.id).assets/"))
        #expect(attachment.altText == "customer roadmap")
        #expect(FileManager.default.fileExists(
            atPath: note.fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(attachment.relativePath)
                .path
        ))
    }
}
