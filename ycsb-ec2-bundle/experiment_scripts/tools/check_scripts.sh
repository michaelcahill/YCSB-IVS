#!/usr/bin/env bash
# Syntax and style checks for every shell file in this directory tree.
# Runs in seconds and needs no database, so it is the first gate after any edit.
#   tools/check_scripts.sh              # every shell file must pass bash -n and shellcheck
#   SHELLCHECK_STRICT=1 tools/check_scripts.sh   # additionally keep the excluded codes enabled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# SC2034/SC2154: these scripts share state through globals in sourced files (lib/*.sh is
# sourced by experiment.sh, watcher.sh receives its variables from the environment). Checked
# per file, shellcheck cannot see the assignment or the use, so both codes are noise here.
SHELLCHECK_EXCLUDE=SC1091,SC2016,SC2029,SC2064,SC2034,SC2154

# Since step 8c deleted the last pre-refactor script there is no tolerated-warnings list
# any more: every shell file in this tree must be shellcheck-clean (with the exclusions above).

status=0
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
    # Generated bundles are excluded: they are rebuilds of files checked here, and their
# registry overrides would only add noise (tools/bundle.sh is the source of truth).
find . -type f \( -name '*.sh' \) \
        -not -path './analysis/*' -not -path '*/node_modules/*' \
        -not -name 'experiment.bundle*.sh' -print0 | sort -z
)

echo "[check] bash -n on ${#files[@]} shell files"
for f in "${files[@]}"; do
    if ! bash -n "$f"; then
        echo "  SYNTAX ERROR: $f"
        status=1
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "[check] shellcheck (every file must be clean)"
    # The experiment scripts intentionally build SQL/awk programs in variables.
    if [[ "${SHELLCHECK_STRICT:-0}" == 1 ]]; then
        shellcheck -x -S warning "${files[@]}" || status=1
    else
        for f in "${files[@]}"; do
            output=$(shellcheck -x -S warning -e "$SHELLCHECK_EXCLUDE" -f gcc "$f" 2>&1) && continue
            printf '%s\n' "$output"
            echo "  SHELLCHECK WARNINGS in $f (see above)"
            status=1
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
