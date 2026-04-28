import SwiftUI
import AppKit

/// SwiftUI wrapper around `NSTextView` so we can: bind plain text two-way,
/// apply a background-color attribute to a specific range (current-word
/// highlight during playback), and report cmd-click character offsets.
public struct TranscriptTextView: NSViewRepresentable {
    @Binding public var text: String
    public let highlightRange: NSRange?
    public let onCommandClick: (Int) -> Void

    public init(
        text: Binding<String>,
        highlightRange: NSRange?,
        onCommandClick: @escaping (Int) -> Void
    ) {
        self._text = text
        self.highlightRange = highlightRange
        self.onCommandClick = onCommandClick
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = CmdClickTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onCommandClick = { [weak coordinator = context.coordinator] offset in
            coordinator?.parent.onCommandClick(offset)
        }

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        applyHighlight(on: textView, range: highlightRange, coordinator: context.coordinator)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func applyHighlight(
        on textView: NSTextView,
        range: NSRange?,
        coordinator: Coordinator
    ) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)

        // Clear previous highlight if it was applied.
        if let previous = coordinator.appliedHighlightRange,
           NSMaxRange(previous) <= fullRange.length {
            storage.removeAttribute(.backgroundColor, range: previous)
        }

        guard let range, range.location >= 0, NSMaxRange(range) <= fullRange.length else {
            coordinator.appliedHighlightRange = nil
            return
        }

        storage.addAttribute(
            .backgroundColor,
            value: NSColor(Color.accentColor.opacity(0.18)),
            range: range
        )
        coordinator.appliedHighlightRange = range
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: TranscriptTextView
        weak var textView: NSTextView?
        var appliedHighlightRange: NSRange?

        init(parent: TranscriptTextView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newValue = tv.string
            if parent.text != newValue {
                parent.text = newValue
            }
        }
    }
}

/// NSTextView subclass that reports cmd-click insertion offsets.
final class CmdClickTextView: NSTextView {
    var onCommandClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let local = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: local)
            onCommandClick?(Int(offset))
            return
        }
        super.mouseDown(with: event)
    }
}
