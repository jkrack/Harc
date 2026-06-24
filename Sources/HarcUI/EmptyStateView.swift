import SwiftUI

public struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let action: (label: String, run: () -> Void)?

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        action: (label: String, run: () -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let subtitle {
                Text(subtitle)
            }
        } actions: {
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132)
    }
}
