import SwiftUI

public struct LibrarySearchField: View {
    @Binding var text: String

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
    }
}
