# HarcMobile 0.14.1 (56) screenshot sources

This directory contains native, unedited, light-appearance screenshots from a
Release-configured iPhone 15 Pro Max simulator on iOS 26.5. Each retained PNG
is 1290 by 2796 pixels with no alpha channel.

## Retained captures

| Order | Surface | SHA-256 |
| --- | --- | --- |
| 01 | Ready to record | `46aa30599f498354cea509c2a92568b56c029300754b3472ad0a3e08fe4f2939` |
| 03 | Bundled offline review sample | `3a368147d426820d5d5969f0db97862243b11178c0b90e90bb016995aa467620` |
| 05 | Privacy & Data from the Host tab | `bcc8df51fc6d3bf80326462c821be00a25498843bea90308d128548d45888232` |

## Intentionally open

- 02 active recording must be captured from the exact app on physical Omega.
  The iOS 26.5 simulator aborts inside RemoteIO initialization when opening its
  microphone; the app's real recording path already passes on Omega, and the
  release image must not fake that state.
- 04 Library detail requires a purpose-made, non-sensitive recording in a real
  adopted Host library. Do not use the account holder's personal Library or
  relabel the offline review sample as Host-backed content.

The five-image screenshot preflight remains expected to fail closed until both
missing captures are added with the frozen filenames from the screenshot plan.
