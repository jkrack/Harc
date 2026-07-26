# Screenshot checklist

The README's screenshots live in `docs/images/`. Six exist. Four are missing,
and all four need something this project's primary development Mac does not
have: **a microphone, and a library with a real recording in it.**

Do not fake these. A marketing page showing an empty library, "No transcript
available", or the panel's "No microphone connected" warning misrepresents the
product in the least flattering possible way — which is exactly what the
current machine would produce.

## Have

| File | Surface |
|---|---|
| `welcome-canvas.png` | Welcome, page 1 |
| `welcome-local-first.png` | Welcome, page 2 — the privacy pitch |
| `welcome-dictation.png` | Welcome, page 3 — dictation |
| `settings-models.png` | Settings → AI Models |
| `settings-modes.png` | Settings → Modes |
| `settings-dictation.png` | Settings → Dictation |
| `library-hero.png` | Library — waveform, on-device summary, transcript |

## Need

Each is marked with an HTML comment at its intended position in `README.md`.

**`library-hero.png` is captured but worth retaking.** It is real output —
Parakeet transcription, a Qwen 3.5 4B summary, a real waveform — but the audio
was two macOS `say` voices imported through Settings → Import, because the
machine had no microphone. Two things suffer:

- **Diarization reports one speaker.** Two synthetic voices, even a British
  male and a US female, were not separable by the speaker embeddings. Speaker
  labels are a headline feature and the hero image cannot currently show them.
- **No action items.** The same transcript produced three with due dates on one
  run and none on two later runs, so extraction is inconsistent on this
  content.

Retake it from a real two-person recording when one exists. That is the only
thing that fixes both.

1. **`panel-recording.png`** — menu-bar panel mid-recording, showing elapsed
   time and live level bars. Requires: an active recording.

2. **`dictation-hud.png`** — the floating dictation pill mid-dictation, with
   the live waveform and the active mode chip. Requires: holding the dictation
   hotkey while capturing.

3. **`post-stop-tray.png`** *(optional)* — the 30-second tray after a
   recording stops, with Copy and Paste.

Prefer a recording whose content is presentable: a short, real, non-sensitive
conversation with **at least two speakers**, so the diarization labels are
visible and are the point of the image.

## How to capture

The computer-use MCP cannot see Harc — it is an `LSUIElement` agent, so the
enumeration skips it and screenshot filtering composites it out. Use the shell
instead (see the "Verifying UI changes on screen" section of `AGENTS.md`):

    # Guard first: screencapture takes a screen REGION, so anything covering
    # the window lands in the file. A capture taken while another app was in
    # front once wrote a personal inbox into a repo-bound image. Confirm Harc
    # is frontmost, and look at the result before committing it.
    osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'

    # exact window bounds, then downscale for the repo
    P=$(osascript -e 'tell application "System Events" to tell process "Harc" to get position of window 1')
    S=$(osascript -e 'tell application "System Events" to tell process "Harc" to get size of window 1')
    screencapture -x -R "<x>,<y>,<w>,<h>" docs/images/library-hero.png
    sips -Z 1600 docs/images/library-hero.png

House style, so the set stays coherent:

- Dark appearance, exact window bounds — no desktop bleed at the edges, which
  is what a capture margin produces.
- Downscale to 1600 px on the long edge; that lands each file around 200–500 KB.
- Take them from a **release** build so the version and UI match what users get.
- Nothing sensitive: no real names, addresses, or client detail in a transcript
  that ships in a public repo.

Once captured, replace the corresponding `<!-- SCREENSHOT: ... -->` comment in
`README.md` with the `<img>` tag.
