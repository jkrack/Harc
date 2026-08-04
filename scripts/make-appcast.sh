#!/usr/bin/env bash
set -euo pipefail

# Sign a release DMG with the Sparkle EdDSA key (login Keychain) and print
# the appcast <item> to insert at the TOP of appcast.xml's <channel>.
#
# Usage:
#   ./scripts/make-appcast.sh <marketing-version> <build-number> <path-to-dmg>
# Example:
#   ./scripts/make-appcast.sh 0.6.0 24 build/local-dist/Harc-local.dmg
#
# Release ritual (see AGENTS.md): build → sign here → paste the item into
# appcast.xml → commit + push appcast.xml with (or before) the gh release,
# using the SAME DMG bytes you upload as the release asset.
#
# The private key lives in the login Keychain (service
# "https://sparkle-project.org", account "ed25519") — created once by
# Sparkle's generate_keys. sign_update may prompt for Keychain access on
# first use; click "Always Allow".

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <marketing-version> <build-number> <path-to-dmg>" >&2
  exit 1
fi

VERSION="$1"
BUILD="$2"
DMG="$3"

[[ -f "$DMG" ]] || { echo "error: no such file: $DMG" >&2; exit 1; }

SPARKLE_VERSION="2.9.5"
TOOLS="$HOME/Library/Caches/Harc/sparkle-tools/$SPARKLE_VERSION"

if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
  echo "==> Fetching Sparkle $SPARKLE_VERSION tools"
  mkdir -p "$TOOLS"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    -o "$TOOLS/sparkle.tar.xz"
  tar -xf "$TOOLS/sparkle.tar.xz" -C "$TOOLS"
fi

SIG_LINE="$("$TOOLS/bin/sign_update" "$DMG")"
PUB_DATE="$(LC_ALL=en_US date -u "+%a, %d %b %Y %H:%M:%S +0000")"

cat <<ITEM

Insert at the top of <channel> in appcast.xml:

    <item>
      <title>Harc v$VERSION</title>
      <link>https://github.com/jkrack/Harc/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="https://github.com/jkrack/Harc/releases/download/v$VERSION/Harc-local.dmg"
        $SIG_LINE
        type="application/octet-stream"/>
    </item>

Then: commit + push appcast.xml, and upload THIS EXACT dmg as the
release asset Harc-local.dmg on the v$VERSION GitHub release.
ITEM
