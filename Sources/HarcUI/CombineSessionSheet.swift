import SwiftUI
import HarcStore

/// What the "Combine Into Session…" context menu hands the sheet: the day
/// to list and the recording the menu was invoked on (pre-checked).
struct CombineSessionContext: Identifiable, Equatable {
    let day: Date
    let preselectedRecordingID: Int64?

    var id: String { "\(day.timeIntervalSince1970)-\(preselectedRecordingID ?? -1)" }
}

/// Sheet listing a day's recordings with checkboxes — the creation surface
/// for virtual sessions. Recordings already in a session are listed but
/// disabled, with the reason inline. Avoids converting the sidebar List to
/// multi-selection, which would be a far more invasive change.
struct CombineSessionSheet: View {
    let context: CombineSessionContext
    let store: RecordingStore
    let onCancel: () -> Void
    let onCreated: (Int64) -> Void

    @State private var titleDraft = ""
    @State private var dayRecordings: [Recording] = []
    @State private var alreadyGrouped: Set<Int64> = []
    @State private var checked: Set<Int64> = []
    @State private var loading = true
    @State private var creationError: String?

    private var selectableCount: Int {
        dayRecordings.filter { rec in
            guard let id = rec.id else { return false }
            return !alreadyGrouped.contains(id)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.lg) {
            Text("Combine Into Session")
                .font(.harcTitle)

            TextField("Session title (optional)", text: $titleDraft)
                .textFieldStyle(.roundedBorder)

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, HarcSpacing.xl)
            } else if selectableCount < 2 {
                Text("A session needs at least two recordings from the same day that aren't already grouped.")
                    .font(.harcBody)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(dayRecordings) { rec in
                        recordingRow(rec)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180, maxHeight: 280)
            }

            if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.failure))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Create Session") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.count < 2)
            }
        }
        .padding(HarcSpacing.xl)
        .frame(width: 440)
        .task { await load() }
    }

    @ViewBuilder
    private func recordingRow(_ rec: Recording) -> some View {
        let id = rec.id ?? -1
        let grouped = alreadyGrouped.contains(id)
        Toggle(isOn: Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.displayTitle)
                    .font(.harcBody)
                    .lineLimit(1)
                Text(grouped
                    ? "Already in a session"
                    : HarcWindowRootView.rowSecondaryLine(for: rec))
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(grouped)
    }

    private func load() async {
        let recs = (try? await store.recordings(onDay: context.day)) ?? []
        let grouped = (try? await store.sessionMemberRecordingIDs()) ?? []
        // Chronological reads better than the store's pinned-first ordering
        // when the user is assembling a day.
        dayRecordings = recs.sorted { $0.startedAt < $1.startedAt }
        alreadyGrouped = grouped
        // Pre-check everything available; the menu's origin row is included
        // by construction. Unchecking is one click, re-finding rows isn't.
        checked = Set(dayRecordings.compactMap(\.id)).subtracting(grouped)
        loading = false
    }

    private func create() {
        let ids = dayRecordings.compactMap(\.id).filter { checked.contains($0) }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let sessionID = try await store.createSession(
                    recordingIDs: ids,
                    title: title.isEmpty ? nil : title
                )
                onCreated(sessionID)
            } catch {
                creationError = error.localizedDescription
            }
        }
    }
}
