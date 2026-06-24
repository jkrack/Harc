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
    ./scripts/validate-note-editor.sh
