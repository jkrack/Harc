# HarcMobile configuration CI

The `mobile-configuration` job runs only after the Mac `build` job succeeds.
It builds and executes the 15 HarcMobileConfigurationTests on one installed
available iPhone simulator with iOS 18 or newer. The selector prefers an already booted eligible iPhone, then chooses the newest
available iOS runtime within that set and sorts devices by name and UDID. Cold
CI hosts use all available eligible iPhones. This avoids unnecessary local cold
startup while preserving explicit destination evidence; unavailable
runtimes/devices and iPads are excluded. No usable simulator fails explicitly.

Run the equivalent local check after `xcodegen generate`:

```sh
bash scripts/test-mobile-configuration.sh
```

The command caps Xcode at two workers, disables parallel testing, uses one
simulator, and enforces a 30-minute process deadline. CI adds a 32-minute test
step limit and 45-minute job limit. Apple Silicon and 5 GiB free disk are
required. The existing bounded runner preserves task-owned process stacks and
cleans up owned children on timeout. GitHub uploads destination.json, console
logs, runner diagnostics and configuration.xcresult with `always()`, retaining
them for three days. The selected runtime, device, destination, exact checked-out
SHA and dirty-tree status are recorded; the SHA is embedded as HarcBuildSHA.
GitHub PR validation may check out a synthetic merge commit, so this is the
checkout SHA rather than an assumed PR head.

Use a fresh output directory per run because Xcode refuses an existing xcresult.
Optional local cache/output overrides are HARC_MOBILE_CONFIGURATION_DERIVED and
HARC_MOBILE_CONFIGURATION_OUTPUT. They do not change concurrency or test scope.

This lane is simulator configuration validation. It does not qualify physical
capture/codec/transfer, two-network behavior, UI accessibility, signing/export,
App Store submission, or a Mac Sparkle release. Existing safety and codec gates
remain required.

## Reviewed integration provenance

The parent integration includes the reviewed source commits:
- PR106: 60c3e2c44415428c47d9d7fef3d3e3e970a48091
- PR108: 35b272dabeb8f9a23005a3d83eefcfb5a15f263b
- PR109: 224489fd78593a18b209779cab8c4e1f04a4c237

The local combined tree was 61701f057ca85cc25fc29f3b5787f33c53de29a0.
Its source preflight, schema, eight script regressions, strict 31-test package
regression, full package command and 15 simulator configuration tests passed.
These observations establish compatibility of those changes, not release
qualification. This CI change is reviewed separately on that integration.
