#!/usr/bin/env bash
# Validate versions.tsv and make sure the workflows agree with it.
#
# Runs on Linux and macOS with no dependencies beyond coreutils/awk, so CI can
# run it on every push. Exit code 1 means something needs fixing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TABLE="$ROOT/versions.tsv"
FULL_WORKFLOW="$ROOT/.github/workflows/build-macos-image.yml"
RECOVERY_WORKFLOW="$ROOT/.github/workflows/build-recovery.yml"

fail=0
err() {
    printf 'FAIL  %s\n' "$*" >&2
    fail=1
}

if [ ! -f "$TABLE" ]; then
    err "versions.tsv not found at $TABLE"
    exit 1
fi

# ---------------------------------------------------------------- table schema
table_errors=$(awk -F'\t' '
function bad(msg) { printf "line %d: %s\n", NR, msg; problems = 1 }
BEGIN {
    split("legacy-dmg recovery-protocol catalog-base softwareupdate", kinds, " ")
    for (k in kinds) valid_kind[kinds[k]] = 1
}
/^#/ || NF == 0 { next }
{
    if (NF != 10) {
        bad("expected 10 tab-separated fields, got " NF)
        next
    }
    if ($1 !~ /^[a-z0-9]+$/) bad("codename must be lower-case alphanumeric, got \"" $1 "\"")
    if ($2 == "" || $2 == "-") bad("name is required")
    if ($3 !~ /^[0-9]+(\.[0-9]+)?$/) bad("version must look like 26 or 10.13, got \"" $3 "\"")
    if ($4 !~ /^[0-9][0-9][0-9][0-9]$/) bad("year must be four digits, got \"" $4 "\"")
    if ($5 !~ /^Install /) bad("app must start with \"Install \", got \"" $5 "\"")
    if (!($6 in valid_kind)) bad("unknown source kind \"" $6 "\"")
    if ($6 == "legacy-dmg" || $6 == "catalog-base") {
        if ($7 == "-" || $7 == "") bad("kind " $6 " needs a URL")
    }
    if (($8 == "-") != ($9 == "-")) bad("recovery board and model must be given together")
    if ($8 != "-" && $8 !~ /^Mac-/) bad("recovery board should look like Mac-XXXXXXXX, got \"" $8 "\"")
    if ($1 in seen_code) bad("duplicate codename \"" $1 "\"")
    if ($3 in seen_ver) bad("duplicate version \"" $3 "\"")
    seen_code[$1] = 1
    seen_ver[$3] = 1
}
END { exit problems ? 1 : 0 }
' "$TABLE" 2>&1)

if [ -n "$table_errors" ]; then
    while IFS= read -r line; do err "$line"; done <<< "$table_errors"
else
    printf 'ok    versions.tsv schema\n'
fi

# ------------------------------------------------------------- option lists
# Pull the choice list for one input out of a workflow file.
workflow_options() {
    local input="$1" file="$2"
    [ -f "$file" ] || return 1
    sed -n "/^      ${input}:/,/^      [a-z_]*:/p" "$file" \
        | sed -n "s/^          - '\(.*\)'\$/\1/p" \
        | while IFS= read -r line; do
            [ -n "$line" ] && printf '%s\n' "$line"
        done
}

table_names() {
    awk -F'\t' '!/^#/ && NF == 10 && $2 != "-" { print $2 }' "$TABLE"
}

table_names_with_recovery() {
    awk -F'\t' '!/^#/ && NF == 10 && $8 != "-" { print $2 }' "$TABLE"
}

report_list_drift() {
    local label="$1" workflow_list="$2" table_list="$3"
    local missing extra
    missing=$(comm -23 <(printf '%s\n' "$workflow_list" | sort) <(printf '%s\n' "$table_list" | sort))
    extra=$(comm -13 <(printf '%s\n' "$workflow_list" | sort) <(printf '%s\n' "$table_list" | sort))

    if [ -n "$missing" ]; then
        err "$label offers versions that versions.tsv does not define: $(printf '%s' "$missing" | tr '\n' ' ')"
    fi
    if [ -n "$extra" ]; then
        err "$label is missing versions defined in versions.tsv: $(printf '%s' "$extra" | tr '\n' ' ')"
    fi
    if [ -z "$missing" ] && [ -z "$extra" ]; then
        printf 'ok    %s matches versions.tsv\n' "$label"
    fi
}

full_options=$(workflow_options macos_version "$FULL_WORKFLOW")
if [ -z "$full_options" ]; then
    err "could not read macos_version options from build-macos-image.yml"
else
    report_list_drift "build-macos-image.yml macos_version" "$full_options" "$(table_names)"
fi

recovery_options=$(workflow_options macos_version "$RECOVERY_WORKFLOW")
if [ -z "$recovery_options" ]; then
    err "could not read macos_version options from build-recovery.yml"
else
    # Read the allowed names once: piping into `grep -q` would let grep exit
    # early, SIGPIPE the producer, and pipefail would report a false miss.
    recovery_names=$(table_names_with_recovery)
    recovery_problems=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if ! grep -Fxq "$name" <<< "$recovery_names"; then
            err "build-recovery.yml offers \"$name\" but versions.tsv has no recovery identifiers for it"
            recovery_problems=1
        fi
    done <<< "$recovery_options"
    if [ "$recovery_problems" -eq 0 ]; then
        printf 'ok    build-recovery.yml options all have recovery identifiers\n'
    fi
fi

# --------------------------------------------------------------- exit status
if [ "$fail" -ne 0 ]; then
    printf '\nversions.tsv is the single source of truth; fix the rows above.\n' >&2
    exit 1
fi

printf '\nall checks passed\n'
