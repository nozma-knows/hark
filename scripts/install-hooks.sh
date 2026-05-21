#!/usr/bin/env bash
# Point git at the in-repo hooks. Run once after cloning.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
git -C "$ROOT" config core.hooksPath .githooks
chmod +x "$ROOT/.githooks/"*
echo "Installed hooks from .githooks/"
echo ""
echo "Next: set up stable dev signing so macOS TCC permissions persist"
echo "across rebuilds:"
echo "    ./scripts/setup-dev-signing.sh"
