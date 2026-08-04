# Host Pairing and `harcctl`

`harcctl` is the PR 6 diagnostic client for proving the same discovery,
adoption, authenticated reconnect, and lossless upload path used by Harc
clients. It is not a second Host authority or a database administration tool.

## Pair a client

1. Run Harc in Host mode on the resident Mac.
2. Choose **File > Pair a Device…** (or **Pair a Device…** in the status-item
   menu).
3. Select **Mac client** for the CLI and create the short-lived code.
4. Copy the pairing link and run:

   ```sh
   swift run harcctl pair --ticket 'harc-pair://v1/...' --kind mac
   ```

5. Compare the exact four security words shown by `harcctl` and the Host.
   Approve only when all four words and the device label match.

The client installation key is stored as a non-synchronizing,
device-only Keychain item. The transfer database stores the authenticated Host
authority, signed transport set, and signed device grant. `route.json` stores
only the nonsecret host, port, and TLS SNI route. The ticket URI and ticket
secret are never persisted.

The Host-issued device kind and `--kind` must match. Initial Mac-client grants
contain only `recording.read.own`, `recording.upload.own`, and
`processing.submit.own`; the CLI cannot request library-wide scopes.

## Validate reconnect and upload

```sh
swift run harcctl status
swift run harcctl upload-fixture --seconds 2
```

`status` reauthenticates the exact signed transport and grant objects loaded
from the client store before opening a challenge-response session.
`upload-fixture` creates 16 kHz mono canonical PCM, encodes one independently
decodable CAF/ALAC chunk, uploads it through foreground gRPC, requires a
verified durable receipt, and reads the Host processing state.

Use `--state-dir PATH` on every command to isolate diagnostic client state.
If a previously used installation key is missing, the CLI fails closed instead
of silently creating a new identity.

## Discovery

```sh
swift run harcctl discover --timeout 5
```

Discovery output is explicitly an untrusted route hint. A candidate becomes
usable only after the authority-signed transport set and pinned TLS leaf have
been validated through pairing or an existing adoption.
