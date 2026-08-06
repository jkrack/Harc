# Speech-daemon termination regression

**Date:** 2026-08-05

**Status:** Source fix and bounded regression green; not yet included in the
published 0.13.5 application.

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
the production Keychain items. The final runtime proof must use the next signed
Developer ID build: launch Harc so it starts `harc-stt`, quit normally, and
verify both exact application-bundle processes exit.
