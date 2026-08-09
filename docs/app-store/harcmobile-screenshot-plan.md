# HarcMobile App Store screenshot plan

**Prepared:** 2026-08-09
**Launch platform:** iPhone only

Apple currently accepts one to ten iPhone screenshots. Capture one consistent
portrait set at an accepted 6.9-inch size. Omega, an iPhone 15 Pro Max, produces
an accepted native 1290 by 2796 image in that App Store Connect slot. Keep the
unedited captures alongside any product-page variants so the depicted behavior
can be checked against the submitted build. Recheck the
[current Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
at upload time.

## Five-image launch set

| Order | Screen | Customer truth to show | Capture state |
| --- | --- | --- | --- |
| 1 | Record | Clear Start Recording control and capture readiness | Microphone permission already granted; not recording |
| 2 | Active recording | Persistent red Recording banner, elapsed time, and visible Stop control | Short real recording; no personal names or notifications |
| 3 | Offline review sample | Playback, ready status, summary, transcript, and metadata | Bundled sample only; no Host and no user data |
| 4 | Library detail | Searchable host-backed recording detail and playback | Purpose-made non-sensitive demo fixture |
| 5 | Privacy & Data / Host | Local-first trust boundary, adopted Host, and optional relay disclosure | Use truthful release configuration; do not imply relay is required |

Short factual overlays are acceptable, but they must not cover controls or
claim functionality that is absent from the exact build. Suggested captions:

1. **Capture when your Host is offline**
2. **Always know when Harc is recording**
3. **Review meetings in one private library**
4. **Transcribe locally on your Mac**
5. **Your Host. Your data. Your choice.**

## Capture checklist

- Use the final release build, final icon/name, light appearance, portrait
  orientation, and a clean status bar.
- Capture at native resolution; do not resize before upload.
- Export as PNG, JPEG, or JPG with no alpha channel or transparency; confirm
  every portrait image is exactly 1290 by 2796 pixels before upload.
- Remove notification banners, device names, IP addresses, pairing codes,
  capability strings, real transcripts, and other personal or security data.
- Use one typography/overlay treatment across the set and retain a plain,
  uncaptioned source image for each screen.
- Verify every image against the exact uploaded build and the App Store
  description. A mockup may frame a real screenshot but must not replace the
  real app UI.
- Upload the 6.9-inch set first. App Store Connect can scale it for smaller
  iPhone displays; add another required display set only if App Store Connect
  identifies an uncovered device class.
- Do not add iPad screenshots while `TARGETED_DEVICE_FAMILY = 1`.

## Evidence naming

Use names that preserve order and build identity:

```text
harcmobile-<version>-<build>-01-record-1290x2796.png
harcmobile-<version>-<build>-02-recording-1290x2796.png
harcmobile-<version>-<build>-03-review-sample-1290x2796.png
harcmobile-<version>-<build>-04-library-1290x2796.png
harcmobile-<version>-<build>-05-privacy-host-1290x2796.png
```

After capturing the exact five files, run the screenshot-aware release
preflight. It checks the current source version/build in every filename, exact
1290 by 2796 dimensions, absence of an alpha channel, and prints a SHA-256 for
each retained image:

```bash
./scripts/preflight-harcmobile-app-store.sh \
  --screenshots-dir /path/to/harcmobile-app-store-screenshots
```

Logo and icon work is intentionally outside this plan; the product-page images
must be recaptured after the final icon/name are installed if either is visible.

## Current capture status

The Release-configured iPhone 15 Pro Max simulator capture passed for images
01, 03, and 05. Native dimensions, opaque PNG encoding, visual content, and
SHA-256 values are recorded under `screenshots/0.14.1-56/`.

Images 02 and 04 remain open by design:

- capture active recording from the exact archived app on physical Omega;
  simulator RemoteIO initialization aborts before the real recording state;
- create a purpose-made, non-sensitive recording on an adopted Host and capture
  its real Library detail rather than exposing personal data or using a mock.
