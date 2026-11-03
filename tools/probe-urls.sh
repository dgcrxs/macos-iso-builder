#!/usr/bin/env bash
# Probe every Apple download URL recorded in versions.tsv.
#
# A row sourced straight from a URL (legacy-dmg) is probed at that URL.
# A catalog-base row is probed at each component the installer actually
# needs, because a missing chunklist fails the build just as hard as a
# missing BaseSystem.dmg.
#
# softwareupdate and recovery-protocol rows cannot be checked without macOS,
# so they are reported as skipped rather than counted as failures.
#
# Exit status
#   0  every probeable URL answered
#   1  at least one URL is definitively gone (401/403/404/410)
#   2  only transient failures were seen and --strict was given
#
# Transient failures (timeouts, 408/429, 5xx, 000) do not fail the default run:
# Apple's CDN edge answers 503 under load often enough that gating on it would
# make CI flaky. Use --strict when you want them treated as errors.
#
# Note that a retired object on updates.cdn-apple.com / swcdn.apple.com answers
# 403, not 404, so a plain "status != 200" check would classify a genuinely
# dead link as network noise and let it through.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TABLE="${MKMACISO_DATA:-$ROOT/versions.tsv}"

STRICT=0
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

if [ ! -f "$TABLE" ]; then
    printf 'versions.tsv not found at %s\n' "$TABLE" >&2
    exit 2
fi

# Windows' curl uses schannel and aborts when the revocation check cannot be
# resolved; macOS and Linux curl do not know this flag at all, so add it only
# when the binary advertises it.
CURL_TLS=""
if curl --help all 2>/dev/null | grep -q -- '--ssl-no-revoke'; then
    CURL_TLS="--ssl-no-revoke"
fi
if ! command -v curl >/dev/null 2>&1; then
    printf 'curl is required\n' >&2
    exit 2
fi

CATALOG_FILES="BaseSystem.dmg BaseSystem.chunklist InstallInfo.plist InstallESDDmg.pkg AppleDiagnostics.dmg AppleDiagnostics.chunklist"

reachable=0
gone=0
flaky=0

human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b <= 0) { print "-"; exit }
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, unit[i]
        else printf "%.2f %s", b, unit[i]
    }'
}

probe() {
    local label="$1" url="$2" file="$3"
    local attempt=1 headers code len status size

    while : ; do
        headers=$(curl $CURL_TLS -sS -I -L --max-time 30 "$url" 2>/dev/null) || headers=""
        code=$(printf '%s' "$headers" | awk 'tolower($0) ~ /^http\// { c = $2 } END { print c }')
        case "$code" in
            2*) break ;;
            401|403|404|410) break ;;
            000|"")
                if [ "$attempt" -ge 3 ]; then break; fi
                attempt=$((attempt + 1)); sleep 2 ;;
            408|429|5*)
                if [ "$attempt" -ge 3 ]; then break; fi
                attempt=$((attempt + 1)); sleep 2 ;;
            *) break ;;
        esac
    done

    len=$(printf '%s' "$headers" | awk '
        BEGIN { IGNORECASE = 1 }
        /^content-length:/ { gsub(/\r/, ""); l = $2 }
        END { print l }')
    size=$(human_size "$len")

    case "$code" in
        2*) status="ok"; reachable=$((reachable + 1)) ;;
        401|403|404|410) status="GONE"; gone=$((gone + 1)) ;;
        *) status="flaky"; flaky=$((flaky + 1)) ;;
    esac

    printf '%-6s %-13s %-5s %-10s %s\n' "$status" "$label" "${code:-none}" "$size" "$file"
}

printf '%-6s %-13s %-5s %-10s %s\n' STATUS VERSION HTTP SIZE FILE
printf '%s\n' "------------------------------------------------------------------------"

while IFS=$'\t' read -r codename name version year app kind url board model osflag; do
    case "$codename" in
        ''|'#'*) continue ;;
    esac
    [ -z "${kind:-}" ] && continue

    case "$kind" in
        legacy-dmg)
            if [ -z "${url:-}" ] || [ "$url" = "-" ]; then
                printf '%-6s %-13s %-5s %-10s %s\n' "BAD" "$codename" "-" "-" "legacy-dmg row without url"
                gone=$((gone + 1))
                continue
            fi
            probe "$codename" "$url" "${url##*/}"
            ;;
        catalog-base)
            if [ -z "${url:-}" ] || [ "$url" = "-" ]; then
                printf '%-6s %-13s %-5s %-10s %s\n' "BAD" "$codename" "-" "-" "catalog-base row without url"
                gone=$((gone + 1))
                continue
            fi
            for file in $CATALOG_FILES; do
                probe "$codename" "${url}${file}" "$file"
            done
            ;;
        softwareupdate|recovery-protocol)
            printf '%-6s %-13s %-5s %-10s %s\n' "skip" "$codename" "-" "-" "$kind needs macOS to resolve"
            ;;
        *)
            printf '%-6s %-13s %-5s %-10s %s\n' "BAD" "$codename" "-" "-" "unknown kind $kind"
            gone=$((gone + 1))
            ;;
    esac
done < "$TABLE"

printf '%s\n' "------------------------------------------------------------------------"
printf '%d reachable, %d gone, %d transient\n' "$reachable" "$gone" "$flaky"

if [ "$gone" -gt 0 ]; then
    printf '\nApple has retired at least one URL above. Update the row in versions.tsv.\n' >&2
    exit 1
fi
if [ "$flaky" -gt 0 ] && [ "$STRICT" -eq 1 ]; then
    printf '\nTransient failures seen and --strict was given.\n' >&2
    exit 2
fi
exit 0
