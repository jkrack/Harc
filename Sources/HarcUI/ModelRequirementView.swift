import SwiftUI

/// Reusable empty-state card shown wherever a feature needs a model that isn't
/// installed yet. Rebuilt on `ContentUnavailableView` for macOS 26.
public struct ModelRequirementView: View {
    let title: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        title: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.down.circle")
        } description: {
            Text(description)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
