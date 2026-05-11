import SwiftUI
import WebKit

public enum NoteMarkdownEditorMode: String, CaseIterable, Identifiable {
    case source
    case live
    case read

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return "Source"
        case .live: return "Live"
        case .read: return "Read"
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

public struct NoteMarkdownWebView: NSViewRepresentable {
    @Binding private var text: String
    private let mode: NoteMarkdownEditorMode
    private let linkTargets: [NoteMarkdownLinkTarget]
    private let mentionTargets: [NoteMarkdownLinkTarget]

    public init(
        text: Binding<String>,
        mode: NoteMarkdownEditorMode,
        linkTargets: [NoteMarkdownLinkTarget] = [],
        mentionTargets: [NoteMarkdownLinkTarget] = []
    ) {
        self._text = text
        self.mode = mode
        self.linkTargets = linkTargets
        self.mentionTargets = mentionTargets
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "harc")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        if let htmlURL = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "NoteEditor"
        ) ?? Bundle.module.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(
                htmlURL,
                allowingReadAccessTo: htmlURL.deletingLastPathComponent()
            )
        }
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateSwiftText(text)
        context.coordinator.updateMode(mode)
        context.coordinator.updateLinkTargets(linkTargets)
        context.coordinator.updateMentionTargets(mentionTargets)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "harc")
        webView.navigationDelegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var text: Binding<String>
        private var loaded = false
        private var applyingFromWeb = false
        private var lastKnownText = ""
        private var lastKnownMode: NoteMarkdownEditorMode = .live
        private var lastKnownLinkTargets: [NoteMarkdownLinkTarget] = []
        private var lastKnownMentionTargets: [NoteMarkdownLinkTarget] = []
        weak var webView: WKWebView?

        init(text: Binding<String>) {
            self.text = text
            self.lastKnownText = text.wrappedValue
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "harc",
                  let body = message.body as? [String: Any],
                  body["type"] as? String == "change",
                  let next = body["text"] as? String else {
                return
            }
            applyingFromWeb = true
            lastKnownText = next
            text.wrappedValue = next
            applyingFromWeb = false
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            pushTextToWeb(text.wrappedValue)
            pushModeToWeb(lastKnownMode)
            pushLinkTargetsToWeb(lastKnownLinkTargets)
            pushMentionTargetsToWeb(lastKnownMentionTargets)
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
    }
}
