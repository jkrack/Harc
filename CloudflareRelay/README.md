# Harc Remote Relay

This isolated Worker project implements the untrusted reachability relay defined
in `docs/specs/2026-08-08-harc-remote-relay-spec.md`.

The relay never receives Harc application plaintext. Paired Harc processes run
their existing pinned TLS and signed gRPC protocol inside the binary WebSocket
tunnel. The Worker sees only encrypted records and minimum opaque routing
metadata; it stores no relayed payload.

Unused sessions close after 120 seconds. Active sessions update only serialized
WebSocket attachments and the Durable Object alarm when payload moves; payload
bytes are never written to Durable Object storage. An absolute 24-hour deadline
still requires a fresh tunnel and Harc's existing idempotent resume behavior.
Each direction also has one Worker-owned outstanding-frame credit. A peer that
sends another binary frame before the receiver acknowledges the prior frame
closes the session with `4429 receiver_overloaded`.

Local validation:

```sh
npm install
npm run types
npm run check
```

From the repository root, the end-to-end inner-TLS gate is:

```sh
./scripts/test-relay-inner-tls-emulator.sh
```

That command starts a fresh loopback Worker emulator and sends the production
pinned TLS 1.3 gRPC channel through it. The scenario covers authenticated
Library access, interrupted-upload reconciliation and resume, and negative
inspection of relay-visible frames for known application plaintext and the
session credential.

The corresponding deployed-staging gate uses the same real application flow
and brackets it with fail-closed deployed-privacy read-backs:

```sh
./scripts/test-relay-inner-tls-staging.sh
```

It accepts only the qualified staging origin and never targets production.

`npm run deploy:dry` creates a local bundle only. The production deployment
uses the exact custom domain `relay.adaptcontext.com`, with
`workers.dev` disabled. Future account, hostname, or quota changes require
separate approval.

The isolated staging environment deploys as `harc-remote-relay-staging` on its
`workers.dev` hostname. Validate its bundle and overload path with:

```sh
npm run deploy:staging:dry
HARC_RELAY_STAGING_ORIGIN=https://harc-remote-relay-staging.jlworker.workers.dev \
  npm run staging:overload
npm run staging:privacy:deployed:check
```

The bounded load harness defaults to 1,000 simultaneous idle Host rendezvous
connections, a 30-second all-connected interval, and a 16 MiB opaque active
transfer using the production one-frame-credit protocol:

```sh
HARC_RELAY_STAGING_ORIGIN=https://harc-remote-relay-staging.jlworker.workers.dev \
  npm run staging:load
```

It refuses the production origin, emits no route or capability values, and
reports only aggregate connection, latency, transfer, and local-generator
memory measurements.

The deployed lifecycle gate exercises Host-offline behavior, a fresh tunnel
after transport interruption, durable Host-control reconnection, revocation,
stale-capability rejection, and replacement authorization. It refuses
production and brackets the exercise with deployed-privacy read-backs:

```sh
./scripts/test-relay-lifecycle-staging.sh
```

This proves the relay-level reconnect/revocation contract on real staging. It
does not substitute for the separate iPhone and Mac qualification across two
unrelated physical networks.

Do not run raw `wrangler tail` against either relay. Cloudflare real-time tails
include request headers and network metadata, including relay capabilities.
Persistent observability remains disabled in staging; any future redaction
exercise must use a purpose-built observer that discards secret headers before
emitting evidence and must be removed after the named exercise.

The bounded, staging-only redaction qualification is:

```sh
npm run staging:redaction
```

It deploys an aggregate-only temporary Tail Worker, attaches it only to staging,
runs synthetic canaries plus overload and pinned-TLS application flows, then
restores staging before deleting the observer. Its cleanup deliberately leaves
the observer deployed if staging detachment fails. The command mutates the
staging deployment and must not be pointed at production.
