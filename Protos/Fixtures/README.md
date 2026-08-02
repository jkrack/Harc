# Protocol fixtures

`harc-sas-words-v1.txt` is the exact 2,048-entry English word ordering published
with [BIP 39](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt),
retrieved on 2026-08-02. Harc uses it only as a human-comparison dictionary for
the pairing short-authentication string.

The protocol hash is:

```text
2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda
```

Do not reorder, normalize, translate, or regenerate the file. The normative
bit-to-index mapping is in the implementation specification.
