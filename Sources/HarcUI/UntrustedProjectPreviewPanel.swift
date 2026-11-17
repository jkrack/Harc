import SwiftUI
import HarcStore

/// Isolated presentation only. There is no production entry point or model,
/// persistence, confirmation, or assignment action. The test harness owns the
/// controller and explicit selected-source lifecycle.
@MainActor
struct UntrustedProjectPreviewPanel: View {
    @ObservedObject var controller: SelectedProjectPreviewController
    @Environment(\.dismiss) private var dismissPresentation
    private let presentationToken: ProjectPreviewPresentationToken

    init(controller: SelectedProjectPreviewController) {
        self.controller = controller
        presentationToken = controller.presentationToken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Possible connection").font(.harcTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Dismiss") {
                    controller.dismiss(presentation: presentationToken)
                    dismissPresentation()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("untrusted-project-preview-dismiss")
                .help("Close this preview without changing any connections.")
            }
            Text("Unverified suggestion. No connection has been saved.")
                .font(.harcBody)
                .accessibilityIdentifier("untrusted-project-preview-warning")
            Text("A matching quote only shows that words occur in the recording. It does not prove a relationship, decision or commitment.")
                .font(.harcCaption)

            ScrollView {
                VStack(alignment: .leading, spacing: HarcSpacing.xl) {
                    if controller.isCurrentPresentation(presentationToken),
                       let preview = controller.preview, controller.state == .showingPreview {
                        literalSection("Project", value: preview.projectName, id: "project")
                        literalSection("Project brief", value: preview.projectBrief, id: "brief")
                        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                            heading("Selected excerpt")
                            Text("Partial context only. Read the complete source below, including corrections, conditions and blockers.")
                                .font(.harcCaption)
                            literal(preview.quote, id: "excerpt")
                        }
                        literalSection("Complete source transcript", value: preview.fullSourceText, id: "source")
                        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                            heading("Unverified model label")
                            literal(preview.unverifiedModelLabel, id: "model-label")
                            Text("This supplied label is not authenticated model provenance.")
                                .font(.harcCaption)
                        }
                    } else {
                        Text(verbatim: Self.statusText(controller.isCurrentPresentation(presentationToken) ? controller.state : .invalidated))
                            .font(.harcBody)
                            .accessibilityIdentifier("untrusted-project-preview-status")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Preview only. Dismiss makes no changes to your Library.")
                .font(.harcCaption)
        }
        .padding(HarcSpacing.xl)
        .frame(minWidth: 320, idealWidth: 640, minHeight: 300, idealHeight: 640)
        .onDisappear { controller.dismiss(presentation: presentationToken) }
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: title).font(.harcTitle).accessibilityAddTraits(.isHeader)
    }
    private func literal(_ value: String, id: String) -> some View {
        // Explicit verbatim rendering: source/model strings are not Markdown,
        // links, instructions, generated titles or executable actions.
        Text(verbatim: value)
            .font(.harcBody)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("untrusted-project-preview-" + id)
    }
    private func literalSection(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            heading(title)
            literal(value, id: id)
        }
    }
    static func statusText(_ state: SelectedProjectPreviewController.State) -> String {
        switch state {
        case .idle: "No preview is open."
        case .preparing: "Checking the selected recording and project."
        case .awaitingResponse: "Waiting for this selected-source response."
        case .processingResponse: "Checking source fidelity. This does not verify meaning."
        case .showingPreview: "This preview is unavailable."
        case .abstained: "No suggestion was returned. This does not mean there is no connection."
        case .invalidated: "This preview is no longer current. Close it and explicitly select the source again."
        }
    }
}
