import SwiftUI
import HarcStore
import HarcDomain

/// Explicit single-source producer entry. Never launches from view appearance,
/// scans the Library, or interprets an inferred connection as an assignment.
struct ProjectMentionConsentView: View {
    let store: RecordingStore
    let host: LibraryMetadata
    let source: Recording?
    let canWrite: @MainActor () -> Bool
    let onProduced: () -> Void
    @State private var projects: [KnowledgeProject] = []
    @State private var projectID: UUID?
    @State private var newName = ""
    @State private var consent = false
    @State private var busy = false
    @State private var feedback: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("Find a connection in the selected recording") {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                if let source, source.id != nil {
                    Text("Source: \(source.displayTitle)").font(.harcLabel)
                    Text("Only this recording’s transcript will be checked on this Mac. Exact project-name mentions become suggestions, not assignments. Other recordings and audio are not scanned.")
                        .font(.harcBody)
                    Picker("Knowledge project", selection: $projectID) {
                        Text("Choose a project").tag(nil as UUID?)
                        ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("New project name (3–120 characters)", text: $newName)
                        .accessibilityIdentifier("projectMention.newProject")
                    Button("Create project") { createProject() }
                        .accessibilityIdentifier("projectMention.create")
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || newName.count > 120)
                    Toggle("Check this transcript for the selected project name", isOn: $consent)
                        .accessibilityIdentifier("projectMention.consent")
                    Button("Find name mentions") { produce() }
                        .accessibilityIdentifier("projectMention.find")
                        .disabled(!consent || projectID == nil)
                    Text("First 100 projects shown. A name mention does not prove this recording belongs to that project.")
                        .font(.harcCaption)
                } else {
                    Text("Select a recording in the Library, then reopen Connections to choose that source.")
                }
                if let feedback { Text(feedback).font(.harcBody).textSelection(.enabled) }
                if busy { ProgressView("Working locally…") }
            }
            .disabled(busy || !canWrite())
        }
        .padding(.horizontal, HarcSpacing.lg)
        .task { await loadProjects() }
        .onChange(of: source?.id) { _, _ in consent = false }
        .onChange(of: projectID) { _, _ in consent = false }
        .onDisappear { operation?.cancel() }
    }

    @MainActor private func loadProjects() async {
        do { projects = try await store.knowledgeProjectsForReview(expectedHost: host) }
        catch { feedback = "Projects are unavailable. Reopen Connections on the active Host." }
    }

    @MainActor private func createProject() {
        guard !busy, canWrite() else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...120).contains(name.count) else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                let project = try await store.createKnowledgeProject(name: name, expectedHost: host)
                await loadProjects()
                if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
                projectID = project.id; newName = ""; consent = false
                feedback = "Project created. Choose whether to check the selected transcript."
            } catch { feedback = "Could not create the project on the active Host." }
        }
    }

    @MainActor private func produce() {
        guard !busy, consent, canWrite(), let source, let id = source.id, let projectID else { return }
        busy = true
        operation = Task {
            defer { busy = false; consent = false }
            do {
                let batch = try await store.prepareProjectMentionProposals(recordingIDs: [id], projectID: projectID, expectedHost: host,
                    expectedCanonicalIDs: [id: source.canonicalID])
                try Task.checkCancellation()
                guard canWrite() else { throw ProjectRefinementError.hostUnavailable }
                let result = try await store.commitProjectMentionProposals(batch)
                feedback = "\(result.inserted) new suggestions; \(result.existing) existing answers or suggestions preserved. \(batch.noMatchCount) without an exact name mention; \(batch.oversizedCount) too large; \(batch.unavailableCount + result.stale) unavailable or changed. No assignments made."
                onProduced()
            } catch is CancellationError {
                feedback = "Stopped. Reopen Connections to see any completed results."
            } catch { feedback = "Could not check this source. Reopen Connections on the active Host." }
        }
    }
}
