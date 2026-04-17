# Harc

Local speech-to-text menu bar app for macOS. Records meetings, transcribes on
Apple Silicon, drops text into a clipboard history for pasting into an LLM.

See `CLAUDE.md` for architecture and constraints.

## Build

Requires Xcode 15.4+ and Homebrew.

    brew install xcodegen
    swift test            # run HarcCore tests
    xcodegen generate     # produce Harc.xcodeproj
    open Harc.xcodeproj   # build + run the Harc app target
