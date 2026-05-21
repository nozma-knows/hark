#!/usr/bin/env bash
# Create a stable self-signed code-signing identity for Hark so macOS TCC
# (Accessibility, Microphone, etc.) remembers grants across rebuilds.
#
# Why this is needed:
#   Ad-hoc signing (`codesign -s -`) produces a new cdhash on every build,
#   and TCC ties trust to cdhash when there's no signing authority.
#   Every rebuild => stale TCC entry => user re-grants.
#
#   With a stable self-signed cert in the login keychain, codesign uses
#   the cert's identity in the Designated Requirements, and TCC trusts
#   the bundle id + signing identity across rebuilds.
#
# Idempotent: safe to re-run.
set -euo pipefail

CERT_NAME="${HARK_SIGNING_IDENTITY:-Hark Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALID_DAYS=3650  # ~10 years

# Need OpenSSL 3+ for `-legacy` (which writes a PKCS#12 MAC macOS Security
# can read). Anaconda's bundled 1.1 and system LibreSSL both lack it.
OPENSSL=""
for candidate in /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if [ -x "$candidate" ] && "$candidate" pkcs12 -help 2>&1 | grep -q legacy; then
        OPENSSL="$candidate"
        break
    fi
done
if [ -z "$OPENSSL" ]; then
    echo "✗ Couldn't find an OpenSSL 3+ binary with -legacy support."
    echo "  Install via Homebrew: brew install openssl@3" >&2
    exit 1
fi
echo "Using $OPENSSL ($("$OPENSSL" version | head -1))"

if security find-identity -v -p codesigning | grep -qE "\"${CERT_NAME}\""; then
    echo "✓ Code-signing identity '${CERT_NAME}' already in login keychain."
    security find-identity -v -p codesigning | grep -E "\"${CERT_NAME}\""
    exit 0
fi

echo "Creating self-signed code-signing certificate '${CERT_NAME}'…"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/cert.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req

[ req_distinguished_name ]
CN = ${CERT_NAME}

[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

"$OPENSSL" genrsa -out "${WORK}/key.pem" 2048 >/dev/null 2>&1
"$OPENSSL" req -new -x509 -days "${VALID_DAYS}" \
    -key "${WORK}/key.pem" \
    -out "${WORK}/cert.pem" \
    -config "${WORK}/cert.cnf" >/dev/null 2>&1

# Use -legacy so macOS's Security framework can verify the PKCS#12 MAC.
# (OpenSSL 3.x defaults to a newer MAC that older Security can't parse.)
# Empty passwords fail macOS's MAC verification in some configurations, so
# we use a one-shot transit password — it's discarded once the cert is in
# the keychain.
P12_PASS="hark-dev"
"$OPENSSL" pkcs12 -export -legacy \
    -inkey "${WORK}/key.pem" \
    -in "${WORK}/cert.pem" \
    -out "${WORK}/cert.p12" \
    -passout "pass:${P12_PASS}" \
    -name "${CERT_NAME}" >/dev/null 2>&1

echo "Importing into login keychain (may prompt for your login password)…"
security import "${WORK}/cert.p12" \
    -k "${KEYCHAIN}" \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild >/dev/null

# Allow codesign to use the private key without an interactive prompt on
# every build. Asks for the login password once.
echo "Granting codesign non-interactive access to the key…"
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:,productbuild:" \
    -s \
    -k "" \
    "${KEYCHAIN}" >/dev/null 2>&1 || {
    echo "  (set-key-partition-list returned non-zero; this is OK if you're prompted on the first build)"
}

echo ""
echo "✅ '${CERT_NAME}' is now in your login keychain."
security find-identity -v -p codesigning | grep -E "\"${CERT_NAME}\"" || true
echo ""
echo "Next: regenerate the Xcode project so it picks up the new identity:"
echo "    xcodegen generate"
echo ""
echo "Then rebuild Hark. The first build may prompt to 'Always Allow' Keychain"
echo "access for the codesign tool — accept it."
