import SwiftUI
import HarcModels

/// Settings → About → Storage. Every location Harc writes to, with live
/// sizes and Reveal buttons — a privacy-positioned app shouldn't have
/// hidden multi-GB footprints, and uninstalling shouldn't be a scavenger
/// hunt.
struct StorageSettingsSection: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        Section {
            ForEach(locations, id: \.path) { location in
                row(for: location)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("To uninstall Harc completely: quit the app, delete Harc.app, then remove the folders above. Recordings and transcripts are yours — they stay wherever your recordings folder points.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
        .task { await computeSizes() }
    }

    private struct Location {
        let title: String
        let path: String
        let detail: String
    }

    private var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = "\(home)/Library/Application Support"
        return [
            Location(
                title: "Recordings & transcripts",
                path: prefs.destinationPath,
                detail: "Audio, transcript, and JSON files, organized by date"
            ),
            Location(
                title: "Library database",
                path: "\(appSupport)/Harc",
                detail: "Search index, people, dictation modes and history"
            ),
            Location(
                title: "Summarizer models",
                path: ModelStorage.defaultBase().path,
                detail: "Gemma tiers downloaded from Settings → Models"
            ),
            Location(
                title: "Speech models",
                path: "\(appSupport)/FluidAudio/Models",
                detail: "Parakeet speech-to-text, diarizer, and VAD"
            ),
            Location(
                title: "Caches",
                path: "\(home)/Library/Caches/Harc",
                detail: "In-progress recordings, dictation clips, daemon log"
            ),
        ]
    }

    private func row(for location: Location) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HarcSpacing.sm) {
                    Text(location.title)
                        .font(.harcLabel.weight(.medium))
                    if let bytes = sizes[location.path] {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.harcMono)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Text(location.detail)
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                Text((location.path as NSString).abbreviatingWithTildeInPath)
                    .font(.harcMono)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: location.path, isDirectory: true)]
                )
            }
            .controlSize(.small)
            .disabled(!FileManager.default.fileExists(atPath: location.path))
        }
        .padding(.vertical, 2)
    }

    private func computeSizes() async {
        let paths = locations.map(\.path)
        let computed: [String: Int64] = await Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for path in paths {
                result[path] = Self.directorySize(atPath: path)
            }
            return result
        }.value
        sizes = computed
    }

    nonisolated private static func directorySize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
