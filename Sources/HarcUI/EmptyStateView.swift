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
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .imageScale(.large)
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}
