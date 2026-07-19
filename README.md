# Harc

Local speech-to-text menu bar app for macOS with two surfaces: meeting
recording and push-to-talk dictation, both transcribed on Apple Silicon with
AI post-processing modes. Stores transcripts in a searchable library for LLM
paste workflows.

## Quick Start

1. Download the DMG from [GitHub Releases](https://github.com/jkrack/Harc/releases),
   drag Harc.app to /Applications, then clear quarantine:

       xattr -dr com.apple.quarantine /Applications/Harc.app

2. Launch and follow the welcome flow: grant Microphone + Screen Recording,
   enable Accessibility for dictation, and optionally download a summarizer
   model.

3. The speech model (~460 MB) downloads automatically on first run; the
   menu-bar panel shows progress. Summarizer models install on demand in
   Settings → Models.

4. **Recording:** start/stop from the menu-bar panel, or record a global
   hotkey in Settings → Recording. Transcription runs in the background
   while you record.

5. **Dictation:** hold ⌃⌥D (customizable), speak, release — text inserts at
   the cursor. Switch modes from the HUD chip or menu-bar panel for AI
   post-processing (Clean-up, Email, Message, Bullet List, Answer, or your
   own custom modes).

See `AGENTS.md` for architecture, product constraints, and repository workflow.

## Build

Requires Xcode/Swift 6.2 and Homebrew.

    brew install xcodegen
    swift test            # run the SwiftPM test suite
    xcodegen generate     # produce Harc.xcodeproj
    open Harc.xcodeproj   # build + run the Harc app target

Focused testing while developing:

    swift test --filter RecordingCacheRecoveryTests
    swift test --filter LocalStackHealthTests
    swift test --filter CustomerExperienceE2ETests

## Uninstall

Quit Harc, delete `Harc.app`, then remove what you don't want to keep
(Settings → About → Storage lists the same locations with sizes):

    ~/Documents/Harc                                # recordings + transcripts (yours — keep!)
    ~/Library/Application Support/Harc              # library DB, modes, history, summarizer models
    ~/Library/Application Support/FluidAudio/Models # speech models
    ~/Library/Caches/Harc                           # caches + daemon log
    ~/.harc                                         # daemon socket

## License

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
— see `LICENSE`. The source is open for personal and other noncommercial use;
commercial use requires a separate license. Official signed builds are
available from [Releases](https://github.com/jkrack/Harc/releases).
