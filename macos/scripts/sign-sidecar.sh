#!/usr/bin/env bash
# Sign the Bun-compiled hark-sidecar with the Developer ID identity, hardened
# runtime, secure timestamp, and the sidecar entitlements. Called from
# build-sidecar.sh for Release builds, and from release.sh for explicit
# re-signing.
#
# Why: nested Mach-Os in Hark.app/Contents/Resources/Sidecar/ are NOT signed
# by Xcode's main signing pass. Notarization rejects ANY unsigned executable
# inside the bundle, so we sign the sidecar before Xcode seals the outer
# app's signature.
set -euo pipefail

BIN="${1:?usage: sign-sidecar.sh <path-to-sidecar-binary> [identity]}"
IDENTITY="${2:-Developer ID Application: Noah Milberger (HFBJTWK7B8)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="${ROOT}/Signing/Sidecar.entitlements"

if [ ! -f "$BIN" ]; then
    echo "✗ Sidecar binary not found: $BIN" >&2
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "✗ Entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi

echo "Signing sidecar:"
echo "  Binary:       $BIN"
echo "  Identity:     $IDENTITY"
echo "  Entitlements: $ENTITLEMENTS"

codesign \
    --force \
    --sign "$IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$BIN"

codesign --verify --strict --verbose=2 "$BIN"
echo "✅ Sidecar signed and verified"
