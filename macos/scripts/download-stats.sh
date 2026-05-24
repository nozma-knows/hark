#!/usr/bin/env bash
# Summarise R2 access logs for the Hark releases bucket.
#
# Prerequisite: enable R2 access logging on the `hark-releases` bucket
# pointing at a separate log bucket. One-time setup via either:
#
#   wrangler r2 bucket logging enable hark-releases \
#       --destination-bucket hark-releases-logs
#
# or via the Cloudflare dashboard:
#   R2 → hark-releases → Settings → Logging → "Add log destination"
#   target bucket: hark-releases-logs (create if it doesn't exist).
#
# Logs land as gzipped JSON-lines files in the destination bucket; this
# script downloads recent ones, decompresses, parses, and prints a per-
# object summary table.
#
# Usage:
#   scripts/download-stats.sh                 # last 7 days
#   scripts/download-stats.sh 30d             # last 30 days
#   scripts/download-stats.sh 24h             # last 24 hours
#   R2_LOG_BUCKET=other-bucket scripts/download-stats.sh
#
# Requires `aws` CLI configured for the `r2` profile (same setup the
# release script uses) and `jq`.

set -euo pipefail

LOG_BUCKET="${R2_LOG_BUCKET:-hark-releases-logs}"
WINDOW="${1:-7d}"
R2_PROFILE="${R2_PROFILE:-r2}"

if [ -z "${R2_ACCOUNT_ID:-}" ]; then
    echo "✗ R2_ACCOUNT_ID not set in env." >&2
    echo "  Export it (the same value scripts/release.sh uses) and retry." >&2
    exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
    echo "✗ aws CLI not installed (\`brew install awscli\`)" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq not installed (\`brew install jq\`)" >&2
    exit 1
fi

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
TMP="$(mktemp -d -t hark-stats)"
trap 'rm -rf "${TMP}"' EXIT

# Convert window to seconds-ago. Accept formats like "7d" / "24h" / "30m".
seconds_ago() {
    local raw="$1" num unit
    num="${raw%[dhms]}"
    unit="${raw: -1}"
    case "${unit}" in
        d) echo $((num * 86400)) ;;
        h) echo $((num * 3600)) ;;
        m) echo $((num * 60)) ;;
        s) echo "${num}" ;;
        *) echo "Bad window format: ${raw} (expected e.g. 7d, 24h, 30m)" >&2; exit 1 ;;
    esac
}

WINDOW_SECONDS=$(seconds_ago "${WINDOW}")
CUTOFF_EPOCH=$(($(date +%s) - WINDOW_SECONDS))
# ISO8601 cutoff for the human-readable header.
if date -r "${CUTOFF_EPOCH}" -u "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    # macOS / BSD date: -r treats arg as epoch seconds.
    CUTOFF_ISO=$(date -r "${CUTOFF_EPOCH}" -u "+%Y-%m-%dT%H:%M:%SZ")
else
    # GNU date.
    CUTOFF_ISO=$(date -u -d "@${CUTOFF_EPOCH}" "+%Y-%m-%dT%H:%M:%SZ")
fi

echo "Fetching ${LOG_BUCKET} access logs since ${CUTOFF_ISO} (last ${WINDOW})…"

# List every log object in the bucket. R2 access logs are pushed every
# few minutes; the key format is service-defined but cumulative scans
# are cheap because the bucket only holds logs.
aws s3 ls "s3://${LOG_BUCKET}/" \
    --recursive \
    --profile "${R2_PROFILE}" \
    --endpoint-url "${ENDPOINT}" \
    | awk '{print $NF}' \
    > "${TMP}/keys.txt"

KEY_COUNT=$(wc -l < "${TMP}/keys.txt" | tr -d ' ')
if [ "${KEY_COUNT}" = "0" ]; then
    echo "No log objects found in s3://${LOG_BUCKET}/ — has logging been enabled yet?"
    echo "See the comment at the top of this script for the one-time setup."
    exit 0
fi
echo "Found ${KEY_COUNT} log object(s). Downloading + parsing…"

# Download every object, decompress (if gzipped), concat. Skip objects
# whose key suggests they're older than the cutoff if R2 uses date-
# prefixed keys (best-effort optimization; we'd still filter line-by-line).
mkdir -p "${TMP}/logs"
while read -r key; do
    [ -z "${key}" ] && continue
    local_path="${TMP}/logs/$(basename "${key}")"
    aws s3 cp "s3://${LOG_BUCKET}/${key}" "${local_path}" \
        --profile "${R2_PROFILE}" \
        --endpoint-url "${ENDPOINT}" \
        --quiet
done < "${TMP}/keys.txt"

# Decompress anything that looks gzipped.
find "${TMP}/logs" -name "*.gz" -exec gunzip -f {} \;

# Concatenate every JSONL line and filter to objects we care about
# (DMG downloads + appcast hits). Each log line is a JSON object with
# fields like Bucket, ObjectKey, BytesSent, RequestDateTime, etc. The
# exact schema is Cloudflare's R2 access logs spec.
cat "${TMP}/logs/"* 2>/dev/null \
    | jq -c --arg cutoff "${CUTOFF_ISO}" '
        select(
            .RequestDateTime >= $cutoff
            and (.ObjectKey | type == "string")
            and (.ObjectKey | test("\\.(dmg|xml)$"))
            and (.HttpStatusCode == null or .HttpStatusCode == 200 or .HttpStatusCode == 206)
        )
    ' \
    > "${TMP}/relevant.jsonl" || true

RELEVANT_COUNT=$(wc -l < "${TMP}/relevant.jsonl" | tr -d ' ')
echo "Relevant requests in window: ${RELEVANT_COUNT}"
echo

if [ "${RELEVANT_COUNT}" = "0" ]; then
    echo "No DMG/appcast requests in the window."
    exit 0
fi

# Per-object summary: count + total bytes.
echo "Object                              Requests   Bytes served"
echo "----------------------------------- --------   ------------"
jq -r '[.ObjectKey, .BytesSent // 0] | @tsv' "${TMP}/relevant.jsonl" \
    | sort \
    | awk '
        { count[$1]++; bytes[$1] += $2 }
        END {
            for (k in count) printf "%-35s   %6d   %12d\n", k, count[k], bytes[k]
        }
    ' \
    | sort \
    | awk '
        {
            # Pretty-print bytes (GB / MB / KB)
            b = $NF
            if (b > 1073741824)      sz = sprintf("%.1f GB", b/1073741824)
            else if (b > 1048576)    sz = sprintf("%.1f MB", b/1048576)
            else if (b > 1024)       sz = sprintf("%.1f KB", b/1024)
            else                     sz = sprintf("%d B", b)
            $NF = sz
            print
        }
    '

echo
echo "Total bytes served:"
jq -r '.BytesSent // 0' "${TMP}/relevant.jsonl" \
    | awk '{s+=$1} END {
        if (s > 1073741824)   printf "  %.2f GB\n", s/1073741824
        else if (s > 1048576) printf "  %.2f MB\n", s/1048576
        else                  printf "  %d B\n", s
    }'
