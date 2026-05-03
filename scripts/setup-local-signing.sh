#!/usr/bin/env bash
#
# One-time setup: create a self-signed code-signing identity in the user's
# login keychain so `scripts/build-local.sh` can sign Harc with a stable
# name across rebuilds.
#
# Why: ad-hoc (`-`) signing means TCC tracks the binary by `cdhash`. Every
# rebuild changes the binary content → new cdhash → TCC treats it as a
# different app and re-prompts for Microphone / Screen Recording. With a
# named self-signed identity that has a stable Common Name, TCC may
# persist grants by identity instead of cdhash. (Empirically: helps for
# many TCC services; not guaranteed for ScreenCapture, which can still
# require Developer ID. If the prompts persist after this, the only real
# fix is enrolling in the Apple Developer Program for a notarizable cert.)
#
# Run this once. Then re-run `scripts/build-local.sh` — it picks up the
# identity by name from the env var the new line sets.
#
# Idempotent: if the identity already exists in the keychain, this is a
# no-op.

set -euo pipefail

IDENTITY_NAME="Harc Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "${IDENTITY_NAME}"; then
  echo "==> Identity '${IDENTITY_NAME}' already in keychain — nothing to do."
  echo "    To recreate: delete it from Keychain Access, then re-run this script."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap "rm -rf '${WORKDIR}'" EXIT

KEY="${WORKDIR}/key.pem"
CSR="${WORKDIR}/req.csr"
CRT="${WORKDIR}/cert.pem"
P12="${WORKDIR}/identity.p12"

# OpenSSL config: codeSigning EKU + the identifier macOS expects.
cat > "${WORKDIR}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = ${IDENTITY_NAME}
[v3]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

echo "==> Generating private key"
openssl genrsa -out "${KEY}" 2048

echo "==> Self-signing certificate"
openssl req -new -x509 -days 3650 \
  -key "${KEY}" \
  -out "${CRT}" \
  -config "${WORKDIR}/openssl.cnf" \
  -extensions v3

echo "==> Bundling key + cert into PKCS#12 (legacy algorithms — Keychain can't verify the OpenSSL 3 defaults)"
P12_PASS="harc-local"
openssl pkcs12 -export -legacy \
  -out "${P12}" \
  -inkey "${KEY}" \
  -in "${CRT}" \
  -name "${IDENTITY_NAME}" \
  -passout pass:"${P12_PASS}"

echo "==> Importing into login keychain"
echo "    macOS may ask for your login password to allow keychain modification."
security import "${P12}" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASS}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
# Trust the cert as a code-signing identity inside the user's trust settings.
# This avoids the "unsigned by an untrusted authority" rejection on launch.
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "${KEYCHAIN}" "${CRT}" 2>/dev/null || true

echo
echo "==> Done."
echo "    Identity '${IDENTITY_NAME}' is now available to codesign."
echo "    'scripts/build-local.sh' will pick it up automatically on next run."
echo
echo "    Verify:"
echo "      security find-identity -v -p codesigning | grep '${IDENTITY_NAME}'"
