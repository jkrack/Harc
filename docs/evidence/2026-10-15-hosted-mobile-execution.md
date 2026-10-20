# Hosted mobile execution evidence

The preserved `configuration.xcresult` summaries and XCTest output establish
executed tests, separately from compilation. Both runs passed **32 tests, zero
failed, zero skipped, zero expected failures** on an arm64 **iPhone 17 simulator**,
iOS 26.5 (23F77), UUID `10B884BF-749F-4E8B-AFCD-26AB8F1DBD01`. Neither is a
physical-phone or release qualification.

| Run | Exact checked-out source | App tests | UI tests | Result |
| --- | --- | --- | --- | --- |
| [PR118 / 38679550499](https://github.com/jkrack/Harc/actions/runs/38679550499) | `fc79722f14fd15a20df78d142c88a756e3c3ceed`, clean | 31 | 1 | 32 passed |
| [main / 38679133157](https://github.com/jkrack/Harc/actions/runs/38679133157) | `8b0c74f0bfc585731b377fcd84beadb6f9f60dc4`, clean | 31 | 1 | 32 passed |

PR118's run advertises PR head `12386660de418c5c2ffe11f8257b3b192e9e2c55`;
its actual clean checkout is the synthetic merge `fc79722...`, with parents
`8b0c74f0bfc585731b377fcd84beadb6f9f60dc4` and
`12386660de418c5c2ffe11f8257b3b192e9e2c55`, tree
`84178c66fb36acf8df40f6c180aa5b1a8a3793b6`. `destination.json`, the result bundle,
and GitHub commit metadata preserve that distinction.

Each run executed 15 configuration, four finalization-recovery, four local-library,
eight playback-session, and one Library-reachability UI test. All four named
recovery regressions passed in each:

- `testDeactivationFailureCannotPreventDurableOutboxRegistration`
- `testFailedOutboxCallbackStillDeactivatesAndRelaunchRecoversMaster`
- `testMixedOrphansPreserveHealthyLibraryAndCaptureReadiness`
- `testRelaunchRegistersFinalizedMasterAfterCallbackWasNeverRunExactlyOnce`

PR118's mixed-orphan test includes the added reversed-discontinuity domain case.
The earlier main run executes the earlier mixed-orphan version and does not
establish that new case. These two runs predate PR119's six composition tests.

The `mobile-configuration-evidence` artifact identities and SHA-256 digests are:

- [PR118 artifact 11950897146](https://github.com/jkrack/Harc/actions/runs/38679550499/artifacts/11950897146):
  `872c1443ad0ffcfc74148cacd8c6f7bc642897c159527df07e17c444e736cc36`
- [main artifact 11949916251](https://github.com/jkrack/Harc/actions/runs/38679133157/artifacts/11949916251):
  `6a7c11129848012b2d6f126957d6e27aa6ae8c2e9a7256c991a01e0d731daffb`

Local preserved bundles/logs are under `/tmp/harc-ci38679550499-mobile` and
`/tmp/harc-ci38679133157-mobile`. Extracted `xcresulttool get test-results summary`
JSON is under `/tmp/harc-sync-evidence`, using the prefixes
`pr118-ci38679550499` and `main-ci38679133157`. Test-output logs independently
confirm the suite totals and each named result. No phone operation was needed
to retrieve or inspect this evidence.
