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
        backend::total_size backend::list_keys backend::sample_key \
        backend::explain_sql backend::delete_keys backend::truncate
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

# Old launchers (and the old per-script names) call a backend by a name that no longer
# exists. Translating here, once, is what keeps `./experiment.sh postgresql_array` and
# `./experiment.sh jsonb` working without any other code knowing the old spelling. Note that
# `postgresql_array` means the TEXT[] schema, as it did before the jsonb variant existed.
# Removed together with the legacy scripts (REFACTOR_PLAN.md step 8c).
registry::alias() {
    case "${1:-}" in
        postgresql) printf 'postgresql_row\n' ;;
        postgresql_array|postgresql_array-text-autovacuum|textarray) printf 'postgresql_textarray\n' ;;
        jsonb|arrayjson|array_json|postgresql_array_json|postgresql_jsonb) printf 'postgresql_json\n' ;;
        innodb) printf 'mariadb_innodb\n' ;;
        rocksdb) printf 'mariadb_rocksdb\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# registry::resolve NAME -> path, or non-zero and a helpful message.
registry::resolve() {
    local name file
    name="$(registry::alias "${1:-}")"
    if [[ "$name" != "${1:-}" ]]; then
        # stdout carries the resolved path, so the notice must not go there.
        echo "[registry] deprecated backend name '${1:-}' used as '$name' (update the launcher)" >&2
    fi
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

# registry::source_backend TARGET — how a resolved backend gets into this shell. The tree
# sources the file; the generated bundle (tools/bundle.sh) overrides this to call an
# embedded loader function instead. Every other load step stays here so the two cannot drift.
registry::source_backend() {
    local target="${1:?resolved backend required}"
    # shellcheck disable=SC1090  # path supplied by registry::resolve
    source "$target"
}

# Load a backend and verify it implements the contract.
registry::load() {
    local file
    file="$(registry::resolve "${1:-}")" || return 2
    registry::source_backend "$file"
    ACTIVE_BACKEND="$(basename "$file" .sh)"

    local missing=0 fn
    while read -r fn; do
        declare -F "$fn" >/dev/null || { echo "[error] $ACTIVE_BACKEND does not define $fn" >&2; missing=1; }
    done < <(registry::required_functions)
    (( missing == 0 )) || return 2

    # Optional hooks get safe no-op defaults so the engine can call them freely.
    declare -F backend::vacuum      >/dev/null || eval 'backend::vacuum() { :; }'
    declare -F backend::wait_idle   >/dev/null || eval 'backend::wait_idle() { :; }'
    declare -F backend::dump_restore >/dev/null|| eval 'backend::dump_restore() { return 0; }'
    declare -F backend::truncate     >/dev/null|| eval 'backend::truncate() { :; }'
    declare -F backend::close        >/dev/null|| eval 'backend::close() { :; }'
    declare -F backend::parse_args   >/dev/null|| eval 'backend::parse_args() { return 0; }'
    # Extra `-p key=value` properties for every YCSB invocation; only bindings that read more
    # than a connection need it (couchbase2: host, adhoc/kv/boost, insertion retries).
    declare -F backend::extra_binding_params >/dev/null ||
        eval 'backend::extra_binding_params() { :; }'
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
