# Harc

Local speech-to-text menu bar app for macOS with two surfaces: meeting
recording and push-to-talk dictation, both transcribed on Apple Silicon with
AI post-processing modes. Stores transcripts in a searchable library for LLM
paste workflows.

## Quick Start

1. Download from [GitHub Releases](https://github.com/jlane/Harc/releases) and run
   the DMG. If macOS complains about quarantine, allow it:

       xattr -d com.apple.quarantine ~/Downloads/Harc.app

2. Grant Microphone + Screen Recording permissions (app will prompt). Dictation
   also requires Accessibility (see Settings).

3. On first use, STT engine downloads Parakeet (~460 MB). Models install
   on-demand in Settings → Models (no restart required).

4. **Recording:** tap the menu-bar icon or press ⌃⌘R to start/stop. Stops
   automatically when you close the panel. Transcription runs in the background;
   library icon badge shows status.

5. **Dictation:** hold ⌃⌥D (customizable in Settings → Dictation), speak, release.
   Text inserts at cursor. Switch modes from the HUD or menu-bar panel to
   apply AI cleanup (Clean-up, Email, Message, Bullet List, Answer, or custom
   modes).

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

Remove the app and optional data:

    rm -rf ~/Applications/Harc.app
    rm -rf ~/Documents/Harc                          # recordings library
    rm -rf ~/Library/Application\ Support/Harc       # preferences + recovery
    rm -rf ~/Library/Caches/Harc                     # temp recordings/dictations
    rm -rf ~/.harc                                   # daemon socket
    rm -rf ~/Library/Application\ Support/FluidAudio # STT model cache
