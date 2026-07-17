# Harc

Local speech-to-text menu bar app for macOS. Records meetings, transcribes on
Apple Silicon, keeps recordings in a searchable library, and prepares transcript
context for pasting into an LLM.

See `AGENTS.md` for architecture, product constraints, and repository workflow.

## Build

Requires current Xcode/Swift 6.2 tooling and Homebrew.

    brew install xcodegen
    swift test            # run the SwiftPM test suite
    xcodegen generate     # produce Harc.xcodeproj
    open Harc.xcodeproj   # build + run the Harc app target

Focused validation is usually faster while developing:

    swift test --filter RecordingCacheRecoveryTests
    swift test --filter LocalStackHealthTests

## Uninstall

Quit Harc, delete `Harc.app`, then remove what you don't want to keep
(Settings → About → Storage lists the same locations with sizes):

    ~/Documents/Harc                                # recordings + transcripts (yours — keep!)
    ~/Library/Application Support/Harc              # library DB, modes, history, summarizer models
    ~/Library/Application Support/FluidAudio/Models # speech models
    ~/Library/Caches/Harc                           # caches + daemon log
    ~/.harc                                         # daemon socket
