#!/usr/bin/env bash
# Point git at the in-repo hooks. Run once after cloning.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
git -C "$ROOT" config core.hooksPath .githooks
chmod +x "$ROOT/.githooks/"*
echo "Installed hooks from .githooks/"
