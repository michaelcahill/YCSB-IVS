#!/usr/bin/env bash
# Syntax and style checks for every shell file in this directory tree.
# Runs in seconds and needs no database, so it is the first gate after any edit.
#   tools/check_scripts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

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
    echo "[check] shellcheck"
    # The experiment scripts intentionally build SQL/awk programs in variables.
    if ! shellcheck -x -S warning -e SC1091,SC2016,SC2029,SC2064 \
        "${files[@]}"; then
        echo "  SHELLCHECK WARNINGS (see above)"
        status=1
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
