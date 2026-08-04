import AVFAudio
import Foundation
import Observation
import SwiftUI

enum HarcMobileAccessibilityID {
    static let root = "harc.mobile.root"
    static let startRecording = "harc.mobile.record.start"
    static let stopRecording = "harc.mobile.record.stop"
    static let recordingBanner = "harc.mobile.record.banner"
    static let recordingBannerStop = "harc.mobile.record.banner.stop"
    static let openReviewSample = "harc.mobile.reviewSample.open"
    static let openReviewSampleToolbar =
        "harc.mobile.reviewSample.open.toolbar"
    static let reviewSampleRoot = "harc.mobile.reviewSample.root"
    static let reviewSampleAudio = "harc.mobile.reviewSample.audio"
    static let scanPairingCode = "harc.mobile.pairing.scan"
    static let pairingWordsMatch = "harc.mobile.pairing.wordsMatch"
    static let pairingWordsMismatch = "harc.mobile.pairing.wordsMismatch"
    static let exportDisclosure = "harc.mobile.export.disclosure"
    static let exportShare = "harc.mobile.export.share"
    static let privacy = "harc.mobile.privacy"
}

enum HarcMobileReviewSample {
    static let title = "Product Planning Sample"
    static let durationSeconds = 8
    static let startedAt = Date(timeIntervalSince1970: 1_756_704_600)
    static let transcript = """
    This bundled sample demonstrates how a completed recording appears in Harc. The transcript, summary, and tags are fixed review content; they were not captured from a person and are not uploaded anywhere.
    """
    static let summary = """
    The team reviewed a product plan, confirmed the next milestone, and recorded follow-up actions. This is read-only sample content for reviewers without access to a Harc Host.
    """
    static let tags = ["sample", "planning", "offline"]
    static let requiresHost = false
    static let containsUserData = false
    static let writesClientState = false
}

struct HarcMobileReviewSampleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var audio = HarcMobileReviewSampleAudioController()

    var body: some View {
        List {
            Section {
                Label(
                    "Bundled, read-only sample",
                    systemImage: "checkmark.shield"
                )
                Text(
                    "This review path works without a Host, contains no user data, and never enters Harc's Library cache or transfer outbox."
                )
                .foregroundStyle(.secondary)
                NavigationLink("Privacy & Data") {
                    HarcMobilePrivacyView()
                }
            }

            Section("Audio") {
                Button {
                    Task { await audio.playOrStop() }
                } label: {
                    switch audio.state {
                    case .idle:
                        Label("Play synthetic sample", systemImage: "play.fill")
                    case .playing:
                        Label("Stop synthetic sample", systemImage: "stop.fill")
                    case .failed:
                        Label("Retry synthetic sample", systemImage: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier(
                    HarcMobileAccessibilityID.reviewSampleAudio
                )
                Text(
                    "The eight-second tone is generated on this iPhone and is not a recording of a person."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if case .failed(let message) = audio.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Status") {
                LabeledContent("Processing", value: "Ready")
                LabeledContent("Canonical audio", value: "Bundled sample")
                LabeledContent("Source", value: "Offline review content")
                LabeledContent("Duration", value: "0:08")
            }

            Section("Summary") {
                Text(HarcMobileReviewSample.summary)
            }

            Section("Transcript") {
                Text(HarcMobileReviewSample.transcript)
                    .textSelection(.enabled)
            }

            Section("Metadata") {
                LabeledContent(
                    "Title",
                    value: HarcMobileReviewSample.title
                )
                LabeledContent(
                    "Tags",
                    value: HarcMobileReviewSample.tags.joined(separator: ", ")
                )
                LabeledContent(
                    "Started",
                    value: HarcMobileReviewSample.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            }
        }
        .navigationTitle("Review Sample")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(HarcMobileAccessibilityID.reviewSampleRoot)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onDisappear { audio.stop() }
    }
}

enum HarcMobilePrivacyCopy {
    static let dataCollectionAnswer = "No, we do not collect data from this app."
    static let summary = """
    Harc has no cloud account, advertising, analytics, or developer-operated processing service. Recordings and derived content stay on your devices and the Harc Host you adopt.
    """
    static let recording = """
    Harc accesses the microphone only after you explicitly start recording. A protected local master remains on this iPhone until the adopted Host returns a verified durable receipt. Harc's developer cannot access your iPhone or Host library.
    """
    static let permissions = """
    Camera access is used only to scan a short-lived Host pairing code. Local Network access discovers and connects to the Host you approve. Harc does not upload photos, contacts, location, advertising identifiers, or analytics.
    """
    static let export = """
    Automatic transfer is limited to your adopted Host. A recording leaves that trust boundary only when you explicitly choose Export and select a destination in the system share sheet.
    """
}

struct HarcMobilePrivacyView: View {
    var body: some View {
        List {
            Section("Harc's privacy model") {
                Text(HarcMobilePrivacyCopy.summary)
            }
            Section("Recording and processing") {
                Text(HarcMobilePrivacyCopy.recording)
            }
            Section("Permissions") {
                Text(HarcMobilePrivacyCopy.permissions)
            }
            Section("Export") {
                Text(HarcMobilePrivacyCopy.export)
            }
            Section("App Privacy answer") {
                Text(HarcMobilePrivacyCopy.dataCollectionAnswer)
                Text(
                    "This answer must be re-reviewed if a future build adds developer-accessible servers, analytics, advertising, telemetry, or third-party processing."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy & Data")
        .accessibilityIdentifier(HarcMobileAccessibilityID.privacy)
    }
}

@MainActor
@Observable
final class HarcMobileReviewSampleAudioController: NSObject {
    enum State: Equatable {
        case idle
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private var player: AVAudioPlayer?

    func playOrStop() async {
        if player?.isPlaying == true {
            stop()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(
                data: HarcMobileReviewSampleAudio.makeWAV()
            )
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw HarcMobileReviewSampleAudioError.startFailed
            }
            self.player = player
            state = .playing
        } catch {
            player = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

extension HarcMobileReviewSampleAudioController:
    @preconcurrency AVAudioPlayerDelegate
{
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        state = flag
            ? .idle
            : .failed("The synthetic review sample ended unexpectedly.")
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

enum HarcMobileReviewSampleAudio {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    static func makeWAV() -> Data {
        let frameCount = Int(sampleRate)
            * HarcMobileReviewSample.durationSeconds
        let dataByteCount = UInt32(frameCount * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(dataByteCount))
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        let byteRate = sampleRate * UInt32(channels)
            * UInt32(bitsPerSample / 8)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(channels * (bitsPerSample / 8))
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)

        for frame in 0..<frameCount {
            let seconds = Double(frame) / Double(sampleRate)
            let phrase = Int(seconds / 0.8)
            let withinPhrase = seconds.truncatingRemainder(dividingBy: 0.8)
            let envelope = min(1, withinPhrase * 12)
                * min(1, (0.8 - withinPhrase) * 10)
            let baseFrequency = 185.0 + Double(phrase % 5) * 23.0
            let carrier = sin(2 * .pi * baseFrequency * seconds)
            let overtone = 0.28 * sin(
                2 * .pi * baseFrequency * 2.01 * seconds
            )
            let value = (carrier + overtone) * envelope * 7_500
            var sample = Int16(clamping: Int(value.rounded())).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private enum HarcMobileReviewSampleAudioError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "Harc could not start the synthetic review sample."
    }
}
