#!/usr/bin/env bash
# Reset macOS TCC (privacy) grants for Hark so local testing starts clean.
#
# Why you'd need this:
#   TCC ties a permission grant to (bundle id + code signature). During local
#   development a grant can get "stuck" — System Settings shows Hark toggled
#   on, but AXIsProcessTrusted()/IOHIDCheckAccess() still report denied because
#   the running binary's signature no longer matches what was granted (ad-hoc
#   rebuild => new cdhash, or a dev build colliding with an installed Release
#   build). When that happens the onboarding wizard can't auto-advance because
#   the permission genuinely reads as not-granted. Resetting clears the slate
#   so the next launch re-prompts cleanly.
#
# The Debug build uses the bundle id `co.milbo.hark.dev`; Release uses
# `co.milbo.hark`. By default this resets BOTH so you don't have to remember
# which one wedged. Pass a bundle id to scope it.
#
# Usage:
#   ./scripts/reset-tcc.sh              # reset dev + release
#   ./scripts/reset-tcc.sh co.milbo.hark.dev   # reset just the dev build
set -euo pipefail

# TCC service names for the three permissions Hark needs. "ListenEvent" is the
# internal name for Input Monitoring.
SERVICES=(Accessibility ListenEvent Microphone)

if [ "$#" -gt 0 ]; then
    BUNDLE_IDS=("$@")
else
    BUNDLE_IDS=(co.milbo.hark.dev co.milbo.hark)
fi

for bundle in "${BUNDLE_IDS[@]}"; do
    echo "Resetting TCC grants for ${bundle}…"
    for service in "${SERVICES[@]}"; do
        # tccutil exits non-zero if there's no existing grant for that
        # service/bundle pair — harmless, so don't let it abort the loop.
        if tccutil reset "${service}" "${bundle}" >/dev/null 2>&1; then
            echo "  ✓ ${service}"
        else
            echo "  – ${service} (no existing grant)"
        fi
    done
done

echo ""
echo "Done. Quit any running Hark instances, rebuild, and relaunch to re-prompt:"
echo "    pkill -9 -f 'Hark.app/Contents/MacOS/Hark'"
