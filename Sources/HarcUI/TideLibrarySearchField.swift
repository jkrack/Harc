import AppKit
import SwiftUI

/// Keep macOS's search semantics (clear button, accessibility search role and
/// keyboard focus) while placing the field in Tide's detail toolbar.
struct TideLibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = TideSearchField()
        field.cell = TideSearchCell(textCell: "")
        field.placeholderString = "Search meetings and transcripts"
        field.setAccessibilityIdentifier("harc.library.search")
        field.setAccessibilityLabel("Search meetings and transcripts")
        // Native bezels use wallpaper-tinted material even in an opaque window.
        // Keep native cell tracking for the search and clear buttons.
        field.isBezeled = true
        field.drawsBackground = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard focusToken > 0, context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    final class TideSearchField: NSSearchField {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    final class TideSearchCell: NSSearchFieldCell {
        override func draw(withFrame frameRect: NSRect, in controlView: NSView) {
            // SwiftUI draws the opaque Tide surface around this native control.
            super.drawInterior(withFrame: frameRect, in: controlView)
            searchButtonCell?.draw(withFrame: searchButtonRect(forBounds: frameRect), in: controlView)
            if !stringValue.isEmpty {
                cancelButtonCell?.draw(withFrame: cancelButtonRect(forBounds: frameRect), in: controlView)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TideLibrarySearchField
        var lastFocusToken = 0

        init(parent: TideLibrarySearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            // The native clear button ends searching without a typing event.
            parent.text = sender.stringValue
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }
    }
}


/// Keep AppKit's native selection and keyboard navigation while drawing the
/// selected row with the Tide wash. NSTableView otherwise paints its accent
/// highlight over SwiftUI's listRowBackground, even for a translucent tint.
struct TideSidebarSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) { view.apply() }

    final class SelectionView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
