#!/usr/bin/env bash
# PostgreSQL backend — classic row schema (`fieldN TEXT`), driven by the plain jdbc
# binding. Included as the control group of the study: values cannot grow inside a row, so
# the extend phase shows what the array representation buys.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not schema-specific
# comes from _postgresql_common.sh.

# shellcheck source=_postgresql_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_postgresql_common.sh"

backend::info() {
    cat <<INFO
display_name=PostgreSQL 18 (row schema)
default_type=postgresql
default_workload=workloada-extend
default_binding=jdbc
default_db=ycsb
min_server_version_num=180000
has_dump_restore=1
supports_idle_wait=1
requires_index_wait=0
supports_vacuum=1
host_os_user=postgres
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
            field0 TEXT, field1 TEXT, field2 TEXT, field3 TEXT, field4 TEXT,
            field5 TEXT, field6 TEXT, field7 TEXT, field8 TEXT, field9 TEXT
        );"

    log "Done initializing $db_name."
}

# Sum of the ten text columns. No array indirection: each field holds one value.
backend::size_expression() {
    cat <<'SQL'
coalesce(octet_length(field0), 0) + coalesce(octet_length(field1), 0) + coalesce(octet_length(field2), 0) + coalesce(octet_length(field3), 0) + coalesce(octet_length(field4), 0) + coalesce(octet_length(field5), 0) + coalesce(octet_length(field6), 0) + coalesce(octet_length(field7), 0) + coalesce(octet_length(field8), 0) + coalesce(octet_length(field9), 0)
SQL
}

backend::default_config() {
    postgresql::base_config
}
