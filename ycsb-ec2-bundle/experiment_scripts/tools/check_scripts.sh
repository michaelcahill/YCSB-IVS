#!/usr/bin/env bash
# Syntax and style checks for every shell file in this directory tree.
# Runs in seconds and needs no database, so it is the first gate after any edit.
#   tools/check_scripts.sh              # legacy scripts may warn, everything else must be clean
#   SHELLCHECK_STRICT=1 tools/check_scripts.sh   # fail on every warning, legacy included
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# SC2034/SC2154: these scripts share state through globals in sourced files (lib/*.sh is
# sourced by experiment.sh, watcher.sh receives its variables from the environment). Checked
# per file, shellcheck cannot see the assignment or the use, so both codes are noise here.
SHELLCHECK_EXCLUDE=SC1091,SC2016,SC2029,SC2064,SC2034,SC2154

# Scripts written before the refactor that still have warnings. The list only shrinks: a file
# leaves it when it is ported (step 5), replaced by a shim, or deleted (step 8c). Nothing new
# may be added - files not listed here must be shellcheck-clean.
LEGACY_WITH_WARNINGS=(
    ./experiment_postgresql_array_json.sh
    ./experiment_sample.sh
)

is_legacy() {
    local candidate="$1" f
    for f in "${LEGACY_WITH_WARNINGS[@]}"; do
        [[ "$candidate" == "$f" ]] && return 0
    done
    return 1
}

status=0
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find . -type f \( -name '*.sh' \) \
        -not -path './analysis/*' -not -path '*/node_modules/*' -print0 | sort -z
)

echo "[check] bash -n on ${#files[@]} shell files"
for f in "${files[@]}"; do
    if ! bash -n "$f"; then
        echo "  SYNTAX ERROR: $f"
        status=1
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "[check] shellcheck (strict for the harness, advisory for ${#LEGACY_WITH_WARNINGS[@]} legacy scripts)"
    # The experiment scripts intentionally build SQL/awk programs in variables.
    if [[ "${SHELLCHECK_STRICT:-0}" == 1 ]]; then
        shellcheck -x -S warning -e "$SHELLCHECK_EXCLUDE" "${files[@]}" || status=1
    else
        for f in "${files[@]}"; do
            output=$(shellcheck -x -S warning -e "$SHELLCHECK_EXCLUDE" -f gcc "$f" 2>&1) && continue
            if is_legacy "$f"; then
                printf '[check] %s: %s legacy warning(s), tolerated until step 8c\n' \
                    "$f" "$(printf '%s\n' "$output" | grep -c .)"
            else
                printf '%s\n' "$output"
                echo "  SHELLCHECK WARNINGS in $f (see above)"
                status=1
            fi
        done
    fi
else
    echo "[check] shellcheck not installed - skipped"
fi

if [[ $status -eq 0 ]]; then
    echo "[check] PASS"
else
    echo "[check] FAIL"
fi
exit "$status"
