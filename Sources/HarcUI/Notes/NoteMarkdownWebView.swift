import SwiftUI
import WebKit
import AppKit

public enum NoteMarkdownEditorMode: String, CaseIterable, Identifiable {
    case source
    case live
    case read

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return "Source"
        case .live: return "Edit"
        case .read: return "Preview"
        }
    }
}

public struct NoteMarkdownLinkTarget: Codable, Equatable, Sendable {
    public let label: String
    public let kind: String
    public let detail: String

    public init(label: String, kind: String, detail: String = "") {
        self.label = label
        self.kind = kind
        self.detail = detail
    }
}

public struct NotePastedImage: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let filename: String?
}

@MainActor
protocol NoteImagePasteSink: AnyObject {
    func insertMarkdown(_ markdown: String)
    func showAttachmentError(_ message: String)
}

@MainActor
final class NoteImagePasteHandler {
    private let onPasteImage: (@MainActor (NotePastedImage) async throws -> String)?

    init(onPasteImage: (@MainActor (NotePastedImage) async throws -> String)?) {
        self.onPasteImage = onPasteImage
    }

    func handle(_ body: [String: Any], sink: NoteImagePasteSink) async {
        guard let onPasteImage,
              let base64 = body["data"] as? String,
              let data = Data(base64Encoded: base64),
              let mimeType = body["mimeType"] as? String else {
            sink.showAttachmentError("Could not read the pasted image.")
            return
        }
        do {
            guard let image = Self.normalizedImage(
                data: data,
                mimeType: mimeType,
                filename: body["filename"] as? String
            ) else {
                sink.showAttachmentError("Could not read the pasted image.")
                return
            }
            let markdown = try await onPasteImage(image)
            sink.insertMarkdown(markdown)
        } catch {
            sink.showAttachmentError(error.localizedDescription)
        }
    }

    func handlePasteboard(_ pasteboard: NSPasteboard, sink: NoteImagePasteSink) -> Bool {
        guard let image = Self.pastedImage(from: pasteboard) else { return false }
        Task { @MainActor in
            await self.handle(image, sink: sink)
        }
        return true
    }

    func handle(_ image: NotePastedImage, sink: NoteImagePasteSink) async {
        guard let onPasteImage else {
            sink.showAttachmentError("Could not read the pasted image.")
            return
        }
        do {
            let markdown = try await onPasteImage(image)
            sink.insertMarkdown(markdown)
        } catch {
            sink.showAttachmentError(error.localizedDescription)
        }
    }

    static func pastedImage(from pasteboard: NSPasteboard) -> NotePastedImage? {
        if let png = pasteboard.data(forType: .png) {
            return NotePastedImage(data: png, mimeType: "image/png", filename: nil)
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return NotePastedImage(data: png, mimeType: "image/png", filename: nil)
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let png = pngData(from: image) {
            return NotePastedImage(data: png, mimeType: "image/png", filename: nil)
        }

        if let fileURLString = pasteboard.string(forType: .fileURL),
           let url = URL(string: fileURLString),
           let loaded = pastedImageFile(from: url) {
            return loaded
        }

        return nil
    }

    static func normalizedImage(data: Data, mimeType: String, filename: String?) -> NotePastedImage? {
        let lowered = mimeType.lowercased()
        if lowered == "image/png" || lowered == "image/jpeg" || lowered == "image/jpg" {
            return NotePastedImage(data: data, mimeType: lowered == "image/jpg" ? "image/jpeg" : lowered, filename: filename)
        }

        if lowered == "image/tiff" || lowered == "image/tif",
           let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return NotePastedImage(data: png, mimeType: "image/png", filename: filename)
        }

        if let image = NSImage(data: data), let png = pngData(from: image) {
            return NotePastedImage(data: png, mimeType: "image/png", filename: filename)
        }

        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func pastedImageFile(from url: URL) -> NotePastedImage? {
        guard let mimeType = mimeType(forImageExtension: url.pathExtension),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NotePastedImage(data: data, mimeType: mimeType, filename: url.lastPathComponent)
    }

    private static func mimeType(forImageExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }
}

@MainActor
private final class NoteMarkdownWKWebView: WKWebView {
    weak var pasteSink: NoteMarkdownWebView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isPasteShortcut(event),
           pasteSink?.handleNativePasteboard(NSPasteboard.general) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isPasteShortcut(event),
           pasteSink?.handleNativePasteboard(NSPasteboard.general) == true {
            return
        }
        super.keyDown(with: event)
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command &&
            event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}

public struct NoteMarkdownWebView: NSViewRepresentable {
    @Binding private var text: String
    private let mode: NoteMarkdownEditorMode
    private let linkTargets: [NoteMarkdownLinkTarget]
    private let mentionTargets: [NoteMarkdownLinkTarget]
    private let attachmentBaseURL: URL?
    private let showsFormattingRibbon: Bool
    private let onPasteImage: (@MainActor (NotePastedImage) async throws -> String)?

    public init(
        text: Binding<String>,
        mode: NoteMarkdownEditorMode,
        linkTargets: [NoteMarkdownLinkTarget] = [],
        mentionTargets: [NoteMarkdownLinkTarget] = [],
        attachmentBaseURL: URL? = nil,
        showsFormattingRibbon: Bool = true,
        onPasteImage: (@MainActor (NotePastedImage) async throws -> String)? = nil
    ) {
        self._text = text
        self.mode = mode
        self.linkTargets = linkTargets
        self.mentionTargets = mentionTargets
        self.attachmentBaseURL = attachmentBaseURL
        self.showsFormattingRibbon = showsFormattingRibbon
        self.onPasteImage = onPasteImage
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPasteImage: onPasteImage)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "harc")

        let webView = NoteMarkdownWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.pasteSink = context.coordinator

        if let htmlURL = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "NoteEditor"
        ) ?? Bundle.module.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(
                htmlURL,
                allowingReadAccessTo: Self.readAccessURL(forEditorHTMLAt: htmlURL)
            )
        }
        return webView
    }

    static func readAccessURL(forEditorHTMLAt htmlURL: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let html = htmlURL.standardizedFileURL
        if html.path == home.path || html.path.hasPrefix(home.path + "/") {
            return home
        }

        // Installed builds load editor assets from /Applications/Harc.app while note
        // attachments commonly live under ~/Documents/Harc. WKWebView accepts a
        // single file read-access root, so installed app bundles need the filesystem
        // root to let both bundled JS/CSS and note-owned images render.
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateSwiftText(text)
        context.coordinator.updateMode(mode)
        context.coordinator.updateLinkTargets(linkTargets)
        context.coordinator.updateMentionTargets(mentionTargets)
        context.coordinator.updateAttachmentBaseURL(attachmentBaseURL)
        context.coordinator.updateFormattingRibbonVisibility(showsFormattingRibbon)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "harc")
        webView.navigationDelegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NoteImagePasteSink {
        private var text: Binding<String>
        private var loaded = false
        private var applyingFromWeb = false
        private var lastKnownText = ""
        private var lastKnownMode: NoteMarkdownEditorMode = .live
        private var lastKnownLinkTargets: [NoteMarkdownLinkTarget] = []
        private var lastKnownMentionTargets: [NoteMarkdownLinkTarget] = []
        private var lastKnownAttachmentBaseURL: URL?
        private var lastKnownFormattingRibbonVisibility = true
        private let onPasteImage: (@MainActor (NotePastedImage) async throws -> String)?
        private let imagePasteHandler: NoteImagePasteHandler
        weak var webView: WKWebView?

        init(
            text: Binding<String>,
            onPasteImage: (@MainActor (NotePastedImage) async throws -> String)?
        ) {
            self.text = text
            self.onPasteImage = onPasteImage
            self.imagePasteHandler = NoteImagePasteHandler(onPasteImage: onPasteImage)
            self.lastKnownText = text.wrappedValue
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "harc",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }
            switch type {
            case "change":
                guard let next = body["text"] as? String else { return }
                applyingFromWeb = true
                lastKnownText = next
                text.wrappedValue = next
                applyingFromWeb = false
            case "pasteImage":
                handlePastedImage(body)
            default:
                return
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            pushTextToWeb(text.wrappedValue)
            pushModeToWeb(lastKnownMode)
            pushLinkTargetsToWeb(lastKnownLinkTargets)
            pushMentionTargetsToWeb(lastKnownMentionTargets)
            pushAttachmentBaseURLToWeb(lastKnownAttachmentBaseURL)
            pushFormattingRibbonVisibilityToWeb(lastKnownFormattingRibbonVisibility)
        }

        func updateSwiftText(_ next: String) {
            guard !applyingFromWeb else { return }
            guard next != lastKnownText else { return }
            pushTextToWeb(next)
        }

        func updateMode(_ next: NoteMarkdownEditorMode) {
            guard next != lastKnownMode else { return }
            lastKnownMode = next
            pushModeToWeb(next)
        }

        func updateLinkTargets(_ next: [NoteMarkdownLinkTarget]) {
            guard next != lastKnownLinkTargets else { return }
            lastKnownLinkTargets = next
            pushLinkTargetsToWeb(next)
        }

        func updateMentionTargets(_ next: [NoteMarkdownLinkTarget]) {
            guard next != lastKnownMentionTargets else { return }
            lastKnownMentionTargets = next
            pushMentionTargetsToWeb(next)
        }

        func updateAttachmentBaseURL(_ next: URL?) {
            guard next != lastKnownAttachmentBaseURL else { return }
            lastKnownAttachmentBaseURL = next
            pushAttachmentBaseURLToWeb(next)
        }

        func updateFormattingRibbonVisibility(_ next: Bool) {
            guard next != lastKnownFormattingRibbonVisibility else { return }
            lastKnownFormattingRibbonVisibility = next
            pushFormattingRibbonVisibilityToWeb(next)
        }

        private func pushTextToWeb(_ next: String) {
            guard loaded, let webView else { return }
            lastKnownText = next
            let encoded = (try? JSONEncoder().encode(next))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.HarcEditor?.setText(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor JavaScript bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func pushModeToWeb(_ mode: NoteMarkdownEditorMode) {
            guard loaded, let webView else { return }
            let encoded = (try? JSONEncoder().encode(mode.rawValue))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"live\""
            webView.evaluateJavaScript("window.HarcEditor?.setMode(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor mode bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func pushLinkTargetsToWeb(_ targets: [NoteMarkdownLinkTarget]) {
            guard loaded, let webView else { return }
            let encoded = (try? JSONEncoder().encode(targets))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            webView.evaluateJavaScript("window.HarcEditor?.setLinkTargets(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor link target bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func pushMentionTargetsToWeb(_ targets: [NoteMarkdownLinkTarget]) {
            guard loaded, let webView else { return }
            let encoded = (try? JSONEncoder().encode(targets))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            webView.evaluateJavaScript("window.HarcEditor?.setMentionTargets(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor mention target bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func pushAttachmentBaseURLToWeb(_ url: URL?) {
            guard loaded, let webView else { return }
            let value = url?.absoluteString ?? ""
            let encoded = (try? JSONEncoder().encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.HarcEditor?.setAttachmentBaseURL(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor attachment bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func pushFormattingRibbonVisibilityToWeb(_ isVisible: Bool) {
            guard loaded, let webView else { return }
            webView.evaluateJavaScript("window.HarcEditor?.setFormattingRibbonVisible(\(isVisible ? "true" : "false"));") { _, error in
                if let error {
                    assertionFailure("Note editor formatting ribbon bridge failed: \(error.localizedDescription)")
                }
            }
        }

        private func handlePastedImage(_ body: [String: Any]) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await imagePasteHandler.handle(body, sink: self)
            }
        }

        func handleNativePasteboard(_ pasteboard: NSPasteboard) -> Bool {
            guard lastKnownMode != .read else { return false }
            return imagePasteHandler.handlePasteboard(pasteboard, sink: self)
        }

        func insertMarkdown(_ markdown: String) {
            guard loaded, let webView else { return }
            let encoded = (try? JSONEncoder().encode(markdown))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.HarcEditor?.insertMarkdown(\(encoded));") { _, error in
                if let error {
                    assertionFailure("Note editor insert markdown failed: \(error.localizedDescription)")
                }
            }
        }

        func showAttachmentError(_ message: String) {
            guard loaded, let webView else { return }
            let encoded = (try? JSONEncoder().encode(message))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"Could not attach image.\""
            webView.evaluateJavaScript("window.HarcEditor?.showAttachmentError(\(encoded));") { _, _ in }
        }
    }
}
