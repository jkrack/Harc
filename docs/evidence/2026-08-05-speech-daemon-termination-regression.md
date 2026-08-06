# Speech-daemon termination regression

**Date:** 2026-08-05

**Status:** Fixed, verified in the signed production application, and published
in Harc 0.13.6 (51).

## Observed failure

Before installing Harc 0.13.5, the running 0.13.4 application had these exact
processes:

```text
/Applications/Harc.app/Contents/MacOS/Harc
/Applications/Harc.app/Contents/MacOS/harc-stt --socket ~/.harc/stt.sock
```

After asking the application to quit through its normal application event, the
main process exited but `harc-stt` remained parented by launchd. It had been
running since 19:06 while the application process that launched at 19:58 had
already exited. The helper was terminated explicitly before the app bundle was
replaced.

The cause was deterministic in source: `applicationShouldTerminate` performed
asynchronous cleanup only when a Host runtime existed, and neither that path nor
`applicationWillTerminate` asked the long-idle speech daemon to shut down.
`DaemonLauncher.stop()` also only reached a process launched by the current
launcher instance, not a healthy daemon inherited from an older app process.

## Fix

- Application termination is asynchronous and bounded in Standalone, Host, and
  Client roles.
- Host writer, MCP, and processing shutdown ordering remains unchanged.
- Dictation keep-warm polling is disabled before daemon shutdown.
- `DaemonLauncher.shutdownDaemon(client:)` always sends the local IPC shutdown
  request first, including when the current launcher does not own the daemon.
- `DaemonLauncher.stop()` then terminates only its still-running owned process
  as a fallback.
- Repeated termination requests continue returning `.terminateLater` until the
  one cleanup operation replies to AppKit.

## Validation

| Check | Result |
| --- | --- |
| `swift test --jobs 2 --filter HarcSTTClientTests` | 6/6 passed |
| Inherited-daemon regression | A launcher with no owned `Process` sent `.shutdown` to a healthy preconnected daemon and received its response |
| Silent-daemon timeout regression | Passed; shutdown-related IPC remains kernel-timeout bounded |
| Debug Mac app build | Passed with `xcodebuild`, arm64 destination, and two workers |
| Source hygiene | `Package.resolved` restored to the documented Sparkle-free SwiftPM state |

The Debug app was deliberately not launched against the production application
container because its ad-hoc code-signing identity is not eligible to exercise
the production Keychain items.

## Signed production proof

The installed 0.13.5 (50) application reproduced the defect immediately before
replacement: a normal Quit removed the main application process while
`/Applications/Harc.app/Contents/MacOS/harc-stt` remained alive with PPID 1.
That orphan was terminated explicitly before installing the new bundle.

The exact notarized 0.13.6 (51) release was then installed, launched, and
observed running both the main application and its `harc-stt` child. A normal
application Quit removed both exact application-bundle processes within five
seconds. No signal or force-quit was needed for the 0.13.6 termination path.

| Release evidence | Value |
| --- | --- |
| Source/version commit | `1e6a752` |
| Apple notarization | Accepted; submission `ee909842-2196-4b35-b527-f12132ee8b23` |
| Stapled DMG bytes | `64,999,354` |
| Stapled DMG SHA-256 | `64d03a4e9439d12b093d4cda7a3220b105a2b0457b74d0dbc60f2a0c816c356b` |
| Release ZIP bytes | `62,259,181` |
| Release ZIP SHA-256 | `36b48e2f9fef79845ad489a23059ae4000850ae6d267ee4057e2ff8db2b73c0a` |
| Sparkle EdDSA signature | `DutrxJYI4ePvqfPduVuTbKxFWLknsPEnh+ucSsaeNv+7G8FE5nM+j8OU/TS8yZRA3dj+wAvAKRo+btOGL4hdAA==` |
| Release | <https://github.com/jkrack/Harc/releases/tag/v0.13.6> |

GitHub's server-side sizes and SHA-256 digests for both release assets matched
the exact local artifacts. The live raw `main` appcast exposed 0.13.6 (51) as
its first item with the same DMG byte count, signature, and release URL.
