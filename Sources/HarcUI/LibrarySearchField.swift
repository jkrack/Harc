import SwiftUI

extension Notification.Name {
    /// Posted when something (typically the popover Search quick action)
    /// wants the Library window's search field to grab keyboard focus.
    /// `LibrarySearchField` listens via `.onReceive` while it's mounted.
    public static let harcLibraryFocusSearch = Notification.Name("HarcLibraryFocusSearch")
}

public struct LibrarySearchField: View {
    @Binding var text: String
    @FocusState private var fieldFocused: Bool

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.harcOnSurfaceVariant)
            TextField("Search recordings…", text: $text)
                .textFieldStyle(.plain)
                .font(HarcDesign.Font.bodyMd)
                .focused($fieldFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HarcDesign.Space.sm)
        .padding(.vertical, HarcDesign.Space.xs)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
        .onReceive(NotificationCenter.default.publisher(for: .harcLibraryFocusSearch)) { _ in
            fieldFocused = true
        }
    }
}
