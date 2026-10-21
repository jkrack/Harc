import AppKit
import SwiftUI

/// Keep macOS's search semantics (clear button, accessibility search role and
/// keyboard focus) while placing the field in Tide's detail toolbar.
struct TideLibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search meetings and transcripts"
        field.setAccessibilityIdentifier("harc.library.search")
        field.setAccessibilityLabel("Search meetings and transcripts")
        field.delegate = context.coordinator
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

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TideLibrarySearchField
        var lastFocusToken = 0

        init(parent: TideLibrarySearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
