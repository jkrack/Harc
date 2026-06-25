import SwiftUI

public enum NativeStatusIntent {
    case info
    case success
    case warning
    case danger

    var tint: Color {
        switch self {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

public struct NativeStatusCallout<Content: View>: View {
    private let intent: NativeStatusIntent
    private let content: Content

    public init(
        intent: NativeStatusIntent = .info,
        @ViewBuilder content: () -> Content
    ) {
        self.intent = intent
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(intent.tint)
                    .frame(width: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
    }
}
