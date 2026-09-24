#!/usr/bin/env bash
# PostgreNoSQL backend — the same PostgreSQL server used as a document store: one JSONB
# document per record (`YCSB_KEY`, `YCSB_VALUE`) driven by the postgrenosql binding.
#
# Included as the document-oriented comparison group for the array backends: values live in
# one JSONB value, so growth is measured as document size rather than array growth.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not schema-specific
# (CLI wrapper, PG18 statistics, preflight, dump/restore, idle wait, size helpers) comes from
# _postgresql_common.sh, exactly like the two relational PostgreSQL backends.
#
# Two deliberate changes compared with the legacy experiment_postgrenosql.sh:
#   * the results CSV carries the same PostgreSQL statistics columns as the other backends
#     (the legacy script collected a smaller set), which is what makes the runs comparable;
#   * that shared query uses pg_stat_checkpointer, so PostgreSQL >= 18 is required where the
#     legacy script still had pre-17 fallbacks.
#
# extend() is not overridden by the binding, so it runs through core's generic implementation
# (read, concatenate client-side, update); the values grow inside the JSON document.

# shellcheck source=_postgresql_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_postgresql_common.sh"

backend::info() {
    cat <<INFO
display_name=PostgreSQL 18 (JSONB document store)
default_type=postgrenosql
default_workload=workloada-extend
default_binding=postgrenosql
default_db=ycsb
min_server_version_num=180000
has_dump_restore=1
supports_idle_wait=1
requires_index_wait=0
supports_vacuum=1
supports_query_plan=1
runtime_watcher_dialect=postgresql
host_os_user=postgres
INFO
}

backend::init_db() {
    local db_name="$1"
    log "Initializing PostgreNoSQL database $db_name..."

    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$db_name"
    pg_cli createdb "$db_name"

    # The binding expects exactly this two-column document schema.
    backend::exec -d "$db_name" -c \
        "CREATE TABLE usertable (
            YCSB_KEY VARCHAR(255) PRIMARY KEY NOT NULL,
            YCSB_VALUE JSONB NOT NULL
        );"

    log "Done initializing $db_name."
}

# Size of the stored JSON document. Unlike the row backends this includes the JSON syntax
# (field names, quotes, braces), so the extend verification expects >= 10 * fieldlength.
backend::size_expression() {
    cat <<'SQL'
coalesce(octet_length(ycsb_value::text), 0)
SQL
}

backend::default_config() {
    # The document binding reads its own properties file and namespaces its connection
    # settings as postgrenosql.url / .user / .passwd instead of db.*.
    postgresql::base_config ../postgrenosql/conf/postgrenosql.properties
    BINDING_PARAM_PREFIX="${BINDING_PARAM_PREFIX:-postgrenosql}"
}
