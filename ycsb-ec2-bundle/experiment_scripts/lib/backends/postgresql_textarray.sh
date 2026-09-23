#!/usr/bin/env bash
# PostgreSQL backend — text-array schema (`fieldN TEXT[]`), driven by the jdbc-array
# binding. This is the reference backend of the experiment harness: the schema whose value
# growth the study measures, since an array field can be extended element by element.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not schema-specific
# (CLI wrapper, PG18 statistics, preflight, dump/restore, idle wait, size helpers) comes
# from _postgresql_common.sh.

# shellcheck source=_postgresql_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_postgresql_common.sh"

backend::info() {
    cat <<INFO
display_name=PostgreSQL 18 (text-array schema)
default_type=postgresql_textarrays_autovacuum
default_workload=workloadc-uniform-heavy
default_binding=jdbc-array
default_db=ycsb
min_server_version_num=180000
has_dump_restore=1
supports_idle_wait=1
requires_index_wait=0
supports_vacuum=1
INFO
}

backend::init_db() {
    local db_name="$1"
    log "Initializing PostgreSQL database $db_name..."

    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$db_name"
    pg_cli createdb "$db_name"

    backend::exec -d "$db_name" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 TEXT[], field1 TEXT[], field2 TEXT[], field3 TEXT[], field4 TEXT[],
            field5 TEXT[], field6 TEXT[], field7 TEXT[], field8 TEXT[], field9 TEXT[]
        );"

    log "Done initializing $db_name."
}

# Sum of the ten text-array fields, i.e. the logical value size of a row. Elements are
# concatenated without a separator, matching how the binding writes and extends them.
backend::size_expression() {
    cat <<'SQL'
octet_length(coalesce(array_to_string(field0, ''), '')) + octet_length(coalesce(array_to_string(field1, ''), '')) + octet_length(coalesce(array_to_string(field2, ''), '')) + octet_length(coalesce(array_to_string(field3, ''), '')) + octet_length(coalesce(array_to_string(field4, ''), '')) + octet_length(coalesce(array_to_string(field5, ''), '')) + octet_length(coalesce(array_to_string(field6, ''), '')) + octet_length(coalesce(array_to_string(field7, ''), '')) + octet_length(coalesce(array_to_string(field8, ''), '')) + octet_length(coalesce(array_to_string(field9, ''), ''))
SQL
}

backend::default_config() {
    postgresql::base_config
}
