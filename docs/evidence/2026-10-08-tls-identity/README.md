# TLS certificate-store leak audit — 2026-10-08

Status: source repair implemented; not installed or fully qualified. Root-cause findings and option-b recommendation were reported before edits.

## Root cause and trigger inventory

`Sources/HarcIdentity/HostTLSServerIdentity.swift` was the only production X.509 issuer with the subject/issuer `CN=Harc Local Host`. Its identity resolver called `SecItemAdd` every time, then used `SecIdentityCreateWithCertificate` to search the keychain. The certificate write was unnecessary. macOS gives these certificates the label `Harc Local Host` even when the add dictionary requests `Harc TLS server certificate`; this was reproduced in a disposable keychain.

| Path | Trigger and storage effect before the patch |
|---|---|
| `HostTLSSigningIdentity.issueServerCertificate` | Constructs and signs DER; by itself does not insert a certificate. |
| `HostTLSSigningIdentity.resolveServerIdentity` → `installAndResolveIdentityLocked` | Installs DER into the selected keychain. Production uses the legacy login keychain. Exact duplicates were accepted, but different serials/DER create new items. |
| `Sources/HarcHost/HostTransportLifecycle.swift:resolveOrCreateLeaf` | Serving startup, renewal, and transport-set/key changes. Already-persisted DER was reused on ordinary restarts. New epochs could add leaves without removing older certificates. No per-connection issuance was found. |
| `HostTLSSigningIdentity.issueServerIdentity` compatibility helper | Issues a fresh leaf then installs it; used by identity and transport fixtures, not the production lifecycle. |
| `Tests/HarcIdentityTests/HostTLSServerIdentityTests.swift` | Fresh fixture identities; cleanup was best-effort and cannot run after process termination. |
| `Tests/HarcHostTests/HostTransportLifecycleTests.swift` and `HostTransportDeferredStartupTests.swift` | Exercise lifecycle issuance with permanent test keys; not every exceptional/interrupted path can clean installed leaves. |
| `Tests/HarcHostTransportTests/PinnedGRPCLoopbackIntegrationTests.swift` and `Support/PairingLifecycleLoopbackFixture.swift` | Explicit fixture issuance; defer cleanup can be bypassed by a killed test process. |
| `HostSecurityP256SigningKey.swift` | The only `SecKeyCreateRandomKey` path. Stable application tags, durable creation intent, and duplicate-winner lookup already exist. Other `SecItemAdd` calls in installation/Host state stores and `HarcHostRuntimeConfigurationFactory.swift` store keys or generic-password state, not X.509 leaves. |
| `Sources/HarcMCP/` | Stdio server; routes Host operations through local IPC. No certificate issuer, TLS listener, OpenSSL invocation, or credential ownership found. Spawning MCP does not mint a TLS identity. |
| Client trust parsing and `TransportTrustAdapterTests.swift` | `SecCertificateCreateWithData` parses public bytes without installing them. |
| `scripts/setup-local-signing.sh` | Manually invoked OpenSSL code-signing setup for **Harc Local Dev**, not Harc Local Host. Not run or changed in this task. Its existing code-signing trust-setting operation is unrelated. |

The current source establishes an accumulation mechanism, not the historical origin of each of the reported 1,978 items. They were absent before this task's first successful read-only query. The installed application's exact source revision and any historical crash/restart loop were not established.

## Storage decision and repair

Option **b**, an in-memory `SecIdentity`, is implemented using public `SecIdentityCreate(certificate, privateKey)`. The certificate remains persisted as exact authenticated DER in HostDB, and the existing protected private key retains its application tag and access policy. No certificate is installed in any keychain. No new entitlement, authentication prompt, or trust-setting change is introduced.

Plaintext loopback is not appropriate for the real Host transport. Option b preserves LAN TLS without putting public certificates in the login keychain's enumerable certificate store. The data-protection alternative would require provisioning/access changes for this Developer ID app; the in-memory identity does not. There is no third-party-client requirement for a login-keychain certificate.

Lookup and signing now occur within the same SQLite writer transaction. Concurrent issuers reuse the stored winner without generating a second serial. Existing permanent-key duplicate handling remains reuse. Renewal starts 30 days before expiry. A changed authenticated transport set still needs matching certificate bytes because the certificate embeds that exact signed set; reusing an incompatible old leaf would violate the protocol.

The zero-or-one invariant is **zero installed Harc TLS certificates**. It does not mean deleting active/staged/retiring Host private keys on every certificate renewal. Those keys are pairing authority, and the existing journaled rotation protocol retains/removes them deliberately. Certificate renewal ordinarily reuses the protected key.

The one-time app-launch migration runs off MainActor, sets its completion marker only after success, and retries on the next launch after failure. It matches either known label AND exact DER subject/issuer, verifies the Harc extension/profile and self-signature, and removes matching public leaves from the explicit login keychain. It deletes associated keys only when the Harc key label/application tag/public key match and no Host authority reference or unrelated certificate retains them. Missing/unreadable/unknown authority is handled conservatively. Unattributable keys are preserved. Keys are deleted before certificates so an interrupted cleanup can retry against remaining certificates; Security.framework does not provide an atomic transaction spanning both classes. Counts are logged on successful completion.

## Listeners

The two observed wildcard listeners belong to the resident LAN Host: gRPC HTTP/2 control and HTTP/1.1 background audio upload. They support adopted secondary Macs and iPhones, including Bonjour discovery. Their factories are `HarcGRPCNWListenerFactory.swift` and `HarcHTTP11UploadTransportAPI.swift`; configuration chooses initial high ports and reuses persisted `HarcHostListenerPorts`. Restricting them to 127.0.0.1 would break the approved LAN Host/Client/Mobile architecture. Their bindings were therefore retained. MCP remains stdio/local IPC.

## Local evidence

- Login keychain before: **0 Harc Local Host certificates**. A second query enumerated actual keychain certificate metadata, confirming read access.
- Migration run: **0 certificates removed, 0 orphan keys removed**. This task did not perform a 1,978 → 0 cleanup.
- Login keychain after: **0 Harc Local Host**, **0 Harc TLS server certificate**.
- Identity/migration suite: **14 tests passed**, including parameterized retained/orphan-key cases and selective/idempotent deletion in disposable keychains. The real-listener test was explicitly excluded from that passing run.
- Two independent Swift Testing processes each performed 50 identity resolutions, reporting **0 → 0**. They were launched through `swiftpm-testing-helper`, bypassing SwiftPM's process-serialization lock. This is not an app-plus-MCP launch test.
- `swift build --build-system native --target HarcHost --jobs 2`: passed.
- `swift build --build-system native --target HarcHostTests --jobs 2`: passed. The new concurrent leaf-issuance test compiled but was not executed in this run.
- Diff whitespace checks passed.

Reproduce the dependency-minimal passing check with `python3 scripts/qualify-tls-identity.py --identity-only`. Omit `--identity-only` to include the 50-cycle actual listener test. The script uses the repository's real identity sources/tests and disposable build files, not alternate implementations.

## Outstanding qualification

The actual 50-listener restart regression was added but fails here on the first Network.framework start with `POSIXErrorCode(22)` (EINVAL). A minimal **plaintext** NWListener failed identically, both under Xcode and the installed Command Line Tools. This establishes an environment/baseline blocker; it does not qualify the new TLS listener or prove the SDK is the cause.

The normal package test build failed in MLX Metal compilation. `xcrun metal --version` confirms that the Metal Toolchain component is missing. Installing that toolchain was not part of this source repair. The default Host-only build failed signing a generated SwiftProtobuf resource bundle with Finder metadata; the native build engine passed. The Xcode app build stopped because the existing resolved-package state lacks Sparkle when automatic dependency resolution is disabled; Xcode also reported CoreDevice/CoreSimulator version mismatch diagnostics. Existing user dependency changes were preserved.

No replacement application was installed or launched. Full app compilation, installed launch migration, actual app + harc-mcp concurrent launch, successful TLS handshakes, and the real 50-listener test remain unqualified. The running installed Harc still uses its previously installed executable.
