#!/usr/bin/env bash
# Submit a signed Hark.app to Apple Notary Service, wait for the ticket,
# then staple it to the bundle. The keychain profile `hark-notary-api`
# stores the App Store Connect API key (see reference_apple_developer.md).
#
# Usage: notarize.sh <path-to-Hark.app>
set -euo pipefail

APP="${1:?usage: notarize.sh <path-to-Hark.app>}"
PROFILE="${NOTARY_PROFILE:-hark-notary-api}"

if [ ! -d "$APP" ]; then
    echo "✗ App bundle not found: $APP" >&2
    exit 1
fi

# Verify the app is actually signed before bothering Apple's servers — saves
# 5-15 minutes per failed submission.
echo "==> Pre-flight: verifying outer signature"
codesign --verify --deep --strict --verbose=2 "$APP" || {
    echo "✗ App is not properly signed. Build with Release config first." >&2
    exit 1
}

ZIP="${APP%/}.zip"
echo "==> Zipping bundle → $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple Notary Service (this takes 1-15 min)…"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$PROFILE" \
    --wait

echo "==> Stapling notarization ticket to bundle"
xcrun stapler staple "$APP"

echo "==> Verifying stapled bundle"
xcrun stapler validate "$APP"

# What a user on a fresh Mac would actually see when they double-click.
echo "==> Gatekeeper assessment"
spctl --assess --verbose=4 --type execute "$APP"

rm -f "$ZIP"
echo "✅ Notarized + stapled: $APP"
