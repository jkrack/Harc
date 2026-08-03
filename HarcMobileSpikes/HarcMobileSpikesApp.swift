import SwiftUI

@main
struct HarcMobileSpikesApp: App {
    @StateObject private var model = CodecSpikeViewModel()

    var body: some Scene {
        WindowGroup {
            CodecSpikeView(model: model)
        }
    }
}

@MainActor
final class CodecSpikeViewModel: ObservableObject {
    @Published var selectedCodec: SpikeCodec = .cafALAC
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Ready"
    @Published private(set) var completedChunks = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var lastReport: CodecSpikeReport?
    @Published private(set) var reportURL: URL?
    @Published private(set) var failure: String?

    private var runTask: Task<Void, Never>?

    func runQuickMatrix() {
        start(mode: .quickMatrix, codec: selectedCodec)
    }

    func runThreeHour() {
        start(mode: .threeHourRealTime, codec: selectedCodec)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled"
    }

    func runLaunchAutomationIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !isRunning else { return }
        if arguments.contains("--run-quick-codec-spike") {
            runQuickMatrix()
        } else if arguments.contains("--run-three-hour-alac-spike") {
            selectedCodec = .cafALAC
            runThreeHour()
        } else if arguments.contains("--run-three-hour-flac-spike") {
            selectedCodec = .flac
            runThreeHour()
        }
    }

    private func start(mode: CodecSpikeMode, codec: SpikeCodec) {
        guard !isRunning else { return }
        isRunning = true
        failure = nil
        reportURL = nil
        lastReport = nil
        completedChunks = 0
        totalChunks = 0
        status = "Preparing fixtures"

        runTask = Task { [weak self] in
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let runner = CodecSpikeRunner()
                    let progress: CodecSpikeRunner.ProgressHandler = { update in
                        await MainActor.run {
                            guard let self else { return }
                            self.completedChunks = update.completedChunks
                            self.totalChunks = update.totalChunks
                            self.status = "\(update.codec.displayName): \(update.message)"
                        }
                    }
                    switch mode {
                    case .quickMatrix:
                        return try await runner.runQuickMatrix(progress: progress)
                    case .threeHourRealTime:
                        return try await runner.runThreeHour(codec: codec, progress: progress)
                    }
                }.value
                guard let self else { return }
                lastReport = report
                reportURL = try Self.write(report)
                status = report.passesCandidateDeviceThresholds
                    ? "Candidate/device threshold run passed"
                    : "Run complete — review evidence"
            } catch is CancellationError {
                self?.status = "Cancelled"
            } catch {
                self?.failure = error.localizedDescription
                self?.status = "Run failed"
            }
            self?.isRunning = false
            self?.runTask = nil
        }
    }

    private static func write(_ report: CodecSpikeReport) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent(
            "harc-codec-spike-\(formatter.string(from: report.endedAt)).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: [.atomic])
        return url
    }
}

private struct CodecSpikeView: View {
    @ObservedObject var model: CodecSpikeViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Codec") {
                    Picker("Real-time candidate", selection: $model.selectedCodec) {
                        ForEach(SpikeCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                }

                Section("Runs") {
                    Button("Run quick comparison") {
                        model.runQuickMatrix()
                    }
                    .disabled(model.isRunning)

                    Button("Run three-hour real-time gate") {
                        model.runThreeHour()
                    }
                    .disabled(model.isRunning)

                    if model.isRunning {
                        ProgressView(
                            value: Double(model.completedChunks),
                            total: Double(max(model.totalChunks, 1))
                        )
                        Button("Cancel", role: .destructive) {
                            model.cancel()
                        }
                    }
                }

                Section("Status") {
                    Text(model.status)
                    if let failure = model.failure {
                        Text(failure).foregroundStyle(.red)
                    }
                    if let report = model.lastReport {
                        LabeledContent("Device", value: report.deviceModel)
                        LabeledContent("OS", value: report.operatingSystem)
                        LabeledContent("Build", value: report.buildSHA)
                        LabeledContent("Failures", value: "\(report.failures.count)")
                        LabeledContent(
                            "Decision evidence",
                            value: report.passesCandidateDeviceThresholds ? "Passed" : "Not passed"
                        )
                    }
                }

                if let reportURL = model.reportURL {
                    Section("Evidence") {
                        ShareLink(item: reportURL) {
                            Label("Export JSON report", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Acceptance note") {
                    Text(
                        "A simulator or quick run is diagnostic only. The release codec is frozen only after the three-hour physical-device matrix passes on the named oldest-supported and current iPhones."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Harc Codec Spikes")
            .task {
                model.runLaunchAutomationIfRequested()
            }
        }
    }
}
