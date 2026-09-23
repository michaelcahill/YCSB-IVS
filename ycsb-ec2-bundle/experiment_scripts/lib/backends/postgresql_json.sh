#!/usr/bin/env bash
# PostgreSQL backend — jsonb-array schema (`fieldN JSONB`, one JSON array of strings per
# field), driven by the forked jdbc-array-json binding. This is the storage-format variant
# that the study compares against `postgresql_textarray`: the same logical value (a list of
# elements that grows element by element) stored as JSONB instead of `TEXT[]`, so TOAST and
# detoasting behaviour differ while the workload does not.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not schema-specific
# (CLI wrapper, PG18 statistics, preflight, dump/restore, idle wait, size helpers) comes from
# _postgresql_common.sh, exactly like the other PostgreSQL backends.
#
# This module is the *data model* of the legacy experiment_postgresql_array_json.sh and
# nothing else: its phase loop, watcher, statistics columns, key-size
# pipeline and results CSV are the shared ones, so runs are directly comparable with the
# sibling backends. The two deliberate differences from that script are
#   * the results CSV carries the full PostgreSQL statistics column set instead of its
#     smaller subset (same deviation postgresql_row / postgresql_textarray / postgrenosql
#     ship, so `../analysis_scripts/` sees one schema for every PostgreSQL backend);
#   * none of its observability runs — no WAL / `pg_stat_statements` / buffer-residency /
#     `pg_prewarm` / checkpoint-log capture, no read sampling (`jdbc.readsample.*` is never
#     passed to a binding), no detoast probes, no extension-creation identity. That machinery
#     is discarded rather than deferred; the legacy script and the pre-refactor tag remain
#     its record.

# shellcheck source=_postgresql_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_postgresql_common.sh"

backend::info() {
    cat <<INFO
display_name=PostgreSQL 18 (jsonb-array schema)
default_type=postgresql_arrayjson_TOAST
default_workload=workloada-extend
default_binding=jdbc-array-json
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
    log "Initializing PostgreSQL database $db_name..."

    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$db_name"
    pg_cli createdb "$db_name"

    backend::exec -d "$db_name" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 JSONB, field1 JSONB, field2 JSONB, field3 JSONB, field4 JSONB,
            field5 JSONB, field6 JSONB, field7 JSONB, field8 JSONB, field9 JSONB
        );"

    log "Done initializing $db_name."
}

# Sum of the elements of the ten JSON arrays, i.e. the logical value size of a row — the same
# quantity postgresql_textarray measures, deliberately excluding JSON syntax so that the two
# storage formats are compared on content rather than on encoding overhead. A NULL field and
# an empty array both count as zero.
backend::size_expression() {
    cat <<'SQL'
COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)
SQL
}

backend::default_config() {
    postgresql::base_config
}
