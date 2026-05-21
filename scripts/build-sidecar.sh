#!/usr/bin/env bash
# Build the Bun sidecar into a single static binary and stage it inside the
# Hark target's resources so Xcode copies it into Hark.app/Contents/Resources.
#
# Invoked manually (`./scripts/build-sidecar.sh`) and as a pre-build Run
# Script phase. Bun's `build --compile` produces a self-contained binary
# with the runtime embedded — ~90 MB; no node_modules to ship.
set -euo pipefail

# Prefer Xcode's $SRCROOT when invoked as a build phase; fall back to walking
# up from the script's own location when run manually from the CLI.
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SIDECAR="${ROOT}/Sidecar"
OUT_DIR="${ROOT}/Hark/Resources/Sidecar"
OUT_BIN="${OUT_DIR}/hark-sidecar"

if ! command -v bun >/dev/null 2>&1; then
    echo "✗ bun not installed. Install via: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
fi

if [ ! -d "${SIDECAR}/node_modules" ]; then
    echo "Installing sidecar dependencies…"
    (cd "${SIDECAR}" && bun install --silent)
fi

mkdir -p "${OUT_DIR}"

echo "Compiling sidecar → ${OUT_BIN}"
(cd "${SIDECAR}" && bun build src/index.ts --compile --outfile "${OUT_BIN}" --minify 2>&1) \
    | grep -vE '^bundle|^compile|^Bun ' || true

if [ ! -x "${OUT_BIN}" ]; then
    echo "✗ Compiled binary missing or not executable: ${OUT_BIN}" >&2
    exit 1
fi

# Quick liveness check — pipe a ping and verify we get a pong.
PING='{"kind":"request","id":"build-check","method":"ping"}'
RESP="$(echo "${PING}" | "${OUT_BIN}" | head -1 || true)"
if ! echo "${RESP}" | grep -q '"ok":true'; then
    echo "✗ Liveness check failed; sidecar did not respond to ping" >&2
    echo "  Output: ${RESP}" >&2
    exit 1
fi

SIZE_BYTES=$(stat -f%z "${OUT_BIN}" 2>/dev/null || stat -c%s "${OUT_BIN}")
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
echo "✅ Sidecar built — ${SIZE_MB} MB, ping round-trip OK"
