#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Backend registry: discovers lib/backends/*.sh, loads one by name and checks that
# it provides the backend contract. Engines branch on capabilities only, never on a
# backend name, so adding a database means adding one file here.

REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKENDS_DIR="$REGISTRY_DIR/backends"

# Function names every backend must define (backend::info and init_db are mandatory;
# the rest have defaults below).
registry::required_functions() {
    printf '%s\n' backend::info backend::default_config backend::preflight \
        backend::init_db backend::collect_metrics backend::key_sizes \
        backend::total_size backend::list_keys
}

# Backends are discovered by filename. Files starting with an underscore are shared code
# that a backend sources (for example _postgresql_common.sh), not backends themselves.
registry::available() {
    local f base
    for f in "$BACKENDS_DIR"/*.sh; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f" .sh)"
        [[ "$base" == _* ]] && continue
        printf '%s\n' "$base"
    done | sort
}

# registry::resolve NAME -> path, or non-zero and a helpful message.
registry::resolve() {
    local name="${1:-}" file
    [[ -n "$name" && "$name" != _* ]] || {
        echo "[error] unknown backend: ${name:-<none>} (names starting with '_' are shared code, not backends)" >&2
        registry::available | sed 's/^/  /' >&2
        return 2
    }
    file="$BACKENDS_DIR/$name.sh"
    if [[ -f "$file" ]]; then
        printf '%s\n' "$file"
        return 0
    fi
    {
        echo "[error] unknown backend: ${name:-<none>}"
        echo "available backends:"
        registry::available | sed 's/^/  /'
    } >&2
    return 2
}

# Load a backend and verify it implements the contract.
registry::load() {
    local file
    file="$(registry::resolve "${1:-}")" || return 2
    # shellcheck disable=SC1090
    source "$file"
    ACTIVE_BACKEND="$(basename "$file" .sh)"

    local missing=0 fn
    while read -r fn; do
        declare -F "$fn" >/dev/null || { echo "[error] $ACTIVE_BACKEND does not define $fn" >&2; missing=1; }
    done < <(registry::required_functions)
    (( missing == 0 )) || return 2

    # Optional hooks get safe no-op defaults so the engine can call them freely.
    declare -F backend::wait_idle   >/dev/null || eval 'backend::wait_idle() { :; }'
    declare -F backend::dump_restore >/dev/null|| eval 'backend::dump_restore() { return 0; }'
    declare -F backend::truncate     >/dev/null|| eval 'backend::truncate() { :; }'
    declare -F backend::close        >/dev/null|| eval 'backend::close() { :; }'
    declare -F backend::parse_args   >/dev/null|| eval 'backend::parse_args() { return 0; }'
}

# registry::info KEY -> value from the active backend's metadata.
registry::info() {
    local key="${1:?key required}"
    backend::info | sed -n "s/^${key}=//p" | head -1
}

# registry::capability KEY -> 0 (true) / 1 (false). Unknown capability is false.
registry::capability() {
    [[ "$(registry::info "${1:?capability required}")" == 1 ]]
}
