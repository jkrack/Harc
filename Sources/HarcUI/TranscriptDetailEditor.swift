import SwiftUI
import AppKit

/// The transcript, editable in place — the Library detail pane's single
/// text surface, replacing the separate editor window that used to duplicate
/// this recording's toolbar, transport, find bar and waveform.
///
/// SwiftUI wrapper around `NSTextView` (not `TextEditor`) because the two
/// things this surface must do are things `TextEditor` cannot: apply a
/// background attribute to an arbitrary range (find match, playback word
/// highlight) and report ⌘-click character offsets for click-to-seek.
public struct TranscriptDetailEditor: NSViewRepresentable {
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
        Self.applySpeakerChannel(to: textView)
        return scroll
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
            Self.applySpeakerChannel(to: textView)
        }
        applyHighlight(on: textView, range: highlightRange, coordinator: context.coordinator)
    }

    // MARK: - Speaker channel

    /// Gives speaker turns a visual channel inside the editable text: the
    /// "Name:" head of each turn is semibold in a color that stays stable for
    /// that speaker across the transcript, and turns get breathing room via
    /// paragraph spacing. Re-applied after every edit — the attributes are
    /// presentation only; the string stays plain.
    static func applySpeakerChannel(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }

        let baseFont = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let turnStyle = NSMutableParagraphStyle()
        turnStyle.paragraphSpacingBefore = 10
        turnStyle.lineSpacing = 2
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 2

        storage.beginEditing()
        // Reset the whole channel before re-applying, colors included.
        // NSTextView's typing attributes inherit from the insertion point,
        // and a later programmatic `textView.string =` restyles the ENTIRE
        // document with them — with the caret parked at a colored head,
        // one reload painted every body in Speaker 1's green. Only the
        // "Name:" heads may carry color; bodies stay label-colored.
        let fullRange = NSRange(location: 0, length: ns.length)
        storage.addAttribute(.font, value: baseFont, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        storage.addAttribute(.paragraphStyle, value: bodyStyle, range: fullRange)

        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let line = ns.substring(with: lineRange)
            if let colon = line.firstIndex(of: ":"),
               line.distance(from: line.startIndex, to: colon) <= 40 {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let headLength = line.distance(from: line.startIndex, to: colon) + 1
                    let headRange = NSRange(location: lineStart, length: headLength)
                    storage.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                        range: headRange
                    )
                    storage.addAttribute(.foregroundColor,
                                         value: speakerColor(for: name),
                                         range: headRange)
                    storage.addAttribute(.paragraphStyle, value: turnStyle, range: lineRange)
                }
            }
            lineStart = lineEnd
        }
        storage.endEditing()

        // Future programmatic string sets must come in plain, not in
        // whatever the caret last touched.
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyStyle,
        ]
    }

    /// Stable per-speaker hue: same name, same color, for the whole
    /// transcript and across recordings. A small fixed ramp rather than
    /// arbitrary hues, so adjacent speakers stay distinguishable.
    static func speakerColor(for name: String) -> NSColor {
        let ramp: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange,
            .systemPurple, .systemTeal, .systemPink,
        ]
        var hash = 5381
        for byte in name.lowercased().utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return ramp[abs(hash) % ramp.count]
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

        // The highlight is only useful on screen — find navigation and
        // playback both want the eye taken to it.
        if range != coordinator.lastScrolledRange {
            textView.scrollRangeToVisible(range)
            coordinator.lastScrolledRange = range
        }
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: TranscriptDetailEditor
        weak var textView: NSTextView?
        var appliedHighlightRange: NSRange?
        var lastScrolledRange: NSRange?

        init(parent: TranscriptDetailEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newValue = tv.string
            if parent.text != newValue {
                parent.text = newValue
            }
            TranscriptDetailEditor.applySpeakerChannel(to: tv)
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
