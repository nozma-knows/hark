#!/usr/bin/env bash
# Cut a Hark release: archive → export signed .app → notarize → staple → dmg.
# Upload-to-R2 step is a TODO until the bucket exists.
#
# Usage:  scripts/release.sh <version>     e.g.  scripts/release.sh 0.1.0
#
# Side effects: writes to build/Release/, leaves the archive + .app + .dmg
# in place for inspection / manual upload.
set -euo pipefail

VERSION="${1:?usage: release.sh <version>   e.g. 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build/Release"
ARCHIVE="${BUILD}/Hark-${VERSION}.xcarchive"
EXPORT_DIR="${BUILD}/export-${VERSION}"
APP="${EXPORT_DIR}/Hark.app"
DMG="${BUILD}/Hark-${VERSION}.dmg"

mkdir -p "${BUILD}"
rm -rf "${ARCHIVE}" "${EXPORT_DIR}" "${DMG}"

echo "==> [1/5] Archiving Hark v${VERSION} (Release)"
xcodebuild archive \
    -project "${ROOT}/Hark.xcodeproj" \
    -scheme Hark \
    -configuration Release \
    -archivePath "${ARCHIVE}" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="${VERSION}" \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat) \
    || { echo "✗ Archive failed" >&2; exit 1; }

if [ ! -d "${ARCHIVE}" ]; then
    echo "✗ Archive missing at ${ARCHIVE}" >&2
    exit 1
fi

echo "==> [2/5] Exporting signed .app"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${ROOT}/Signing/ExportOptions.plist"

if [ ! -d "${APP}" ]; then
    echo "✗ Exported .app missing at ${APP}" >&2
    exit 1
fi

echo "==> [3/5] Notarizing"
"${ROOT}/scripts/notarize.sh" "${APP}"

echo "==> [4/5] Building DMG"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "Hark ${VERSION}" \
        --window-size 540 380 \
        --icon-size 96 \
        --icon "Hark.app" 150 200 \
        --app-drop-link 400 200 \
        --hdiutil-quiet \
        "${DMG}" "${APP}"
else
    # Fallback: plain compressed disk image. Works fine, just no styling.
    # `brew install create-dmg` upgrades to a polished drag-to-Applications layout.
    hdiutil create -format UDZO -volname "Hark ${VERSION}" \
        -srcfolder "${APP}" "${DMG}"
fi

DMG_BYTES=$(stat -f%z "${DMG}" 2>/dev/null || stat -c%s "${DMG}")

echo "==> [5/5] Uploading to Cloudflare R2"
# Upload is opt-in: skip cleanly if the user hasn't configured R2 locally
# (still useful to be able to cut a notarized .app + .dmg without publishing).
R2_PROFILE="${R2_PROFILE:-r2}"
R2_BUCKET_NAME="${R2_BUCKET:-hark-releases}"
R2_PUBLIC_BASE_URL="${R2_PUBLIC_BASE:-https://tellhark.com}"

if [ -z "${R2_ACCOUNT_ID:-}" ]; then
    echo "    R2_ACCOUNT_ID not set — skipping upload."
    echo "    To enable: add the env var to your shell + run \`aws configure --profile r2\`."
    UPLOADED=false
elif ! command -v aws >/dev/null 2>&1; then
    echo "    aws CLI not installed — skipping upload (\`brew install awscli\`)."
    UPLOADED=false
else
    ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    aws s3 cp "${DMG}" "s3://${R2_BUCKET_NAME}/Hark-${VERSION}.dmg" \
        --profile "${R2_PROFILE}" \
        --endpoint-url "${ENDPOINT}" \
        --content-type "application/x-apple-diskimage"
    # `latest.dmg` is a stable URL the landing page links to.
    aws s3 cp "${DMG}" "s3://${R2_BUCKET_NAME}/latest.dmg" \
        --profile "${R2_PROFILE}" \
        --endpoint-url "${ENDPOINT}" \
        --content-type "application/x-apple-diskimage"
    UPLOADED=true
fi

echo ""
echo "==> Summary"
echo "    DMG:  ${DMG}"
echo "    Size: $((DMG_BYTES / 1024 / 1024)) MB"
if [ "${UPLOADED}" = "true" ]; then
    echo "    Live: ${R2_PUBLIC_BASE_URL}/Hark-${VERSION}.dmg"
    echo "          ${R2_PUBLIC_BASE_URL}/latest.dmg"
fi
echo ""
echo "✅ Release ${VERSION} built and notarized."
