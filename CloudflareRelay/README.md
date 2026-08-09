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

`npm run deploy:dry` creates a local bundle only. The production deployment
uses the exact custom domain `relay.adaptcontext.com`, with
`workers.dev` disabled. Future account, hostname, or quota changes require
separate approval.
