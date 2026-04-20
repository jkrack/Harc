import SwiftUI
import HarcStore
import HarcExport

/// Inline editor showing one row per distinct speaker index present in
/// the recording. Users type display names; commits fire on Enter or
/// focus-loss via the `onCommit` callback. Visibility: the view renders
/// nothing when `speakerIndices` is empty (un-diarized recording).
public struct SpeakerNameEditor: View {
    private let speakerIndices: [Int]           // ascending, distinct
    private let initialNames: [Int: String]
    private let onCommit: ([Int: String]) -> Void

    @State private var draftNames: [Int: String]

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void
    ) {
        self.speakerIndices = speakerIndices.sorted()
        self.initialNames = initialNames
        self.onCommit = onCommit
        self._draftNames = State(initialValue: initialNames)
    }

    public var body: some View {
        if speakerIndices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                Text("SPEAKERS")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .tracking(1.2)
                ForEach(speakerIndices, id: \.self) { index in
                    row(for: index)
                }
            }
        }
    }

    private func row(for index: Int) -> some View {
        HStack(spacing: HarcDesign.Space.sm) {
            Text("Speaker \(index + 1)")
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(Color.harcOnSurface)
                .frame(width: 90, alignment: .leading)
            TextField("Name (e.g. Jason)", text: binding(for: index))
                .textFieldStyle(.roundedBorder)
                .font(HarcDesign.Font.bodyMd)
                .onSubmit { commit() }
        }
    }

    /// Two-way binding into the `draftNames` dict. Reads return "" when
    /// the index has no entry so the TextField shows empty. Writes store
    /// the raw string; trimming happens at commit time.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { draftNames[index] ?? "" },
            set: { newValue in
                draftNames[index] = newValue
            }
        )
    }

    /// Normalise draftNames (trim, drop empty), compare against
    /// initialNames, fire callback only if changed.
    private func commit() {
        var normalised: [Int: String] = [:]
        for (k, v) in draftNames {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { normalised[k] = trimmed }
        }
        if normalised != initialNames {
            onCommit(normalised)
        }
    }
}
