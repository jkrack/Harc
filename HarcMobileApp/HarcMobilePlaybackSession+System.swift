import AVFAudio

@MainActor
extension HarcMobilePlaybackSession {
    static let shared = HarcMobilePlaybackSession(
        activate: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        },
        deactivate: {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    )

}
