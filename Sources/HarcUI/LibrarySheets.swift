import SwiftUI
import Foundation

// Small modal sheets and the transcript display segment used by
// `HarcWindowRootView`. Extracted from the view file; previously `private`.

// MARK: - NewProjectSheet

struct NewProjectSheet: View {
    @Binding var name: String
    let errorMessage: String?
    let isSaving: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project")
                .font(.harcTitle)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isSaving)
            if let errorMessage {
                Text(errorMessage)
                    .font(.harcCaption)
                    .foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
                Button {
                    onCreate()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - AddPersonSheet

struct AddPersonSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add person")
                .font(.harcTitle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onAdd(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Transcript display

struct TranscriptDisplaySegment: Identifiable {
    let id = UUID()
    let speaker: Int
    let speakerName: String
    let startSec: Int
    let text: String
}
