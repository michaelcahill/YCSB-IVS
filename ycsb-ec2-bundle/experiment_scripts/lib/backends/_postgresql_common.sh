#!/usr/bin/env bash
# Part of a PostgreSQL backend module; sourced by lib/backends/postgresql_*.sh and
# postgrenosql.sh, never run directly and never advertised as a backend itself (the registry
# skips files that start with an underscore).
#
# Everything the PostgreSQL backends have in common: the CLI wrapper, the PG18 statistics
# snapshot, preflight, dump/restore, the idle wait, and the size helpers that are derived from
# backend::size_expression. A backend module supplies what differs — schema DDL, the
# value-size expression, metadata, connection defaults — by defining these contract names
# AFTER sourcing this file (bash keeps the later definition).

PG_MAINTENANCE_DB="${PG_MAINTENANCE_DB:-postgres}"

# ---------------------------------------------------------------------------
# Statistics columns (the results CSV schema for this backend)
#
# PostgreSQL 18 statistics collected for every phase. metric_field_names is the full column
# list of a scope=all snapshot and write_result emits it in this exact order, so adding a
# metric here is what makes it appear in the results CSV.
# ---------------------------------------------------------------------------

global_metric_names=(
    blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated
    tup_deleted deadlocks temp_files temp_bytes checkpoints_timed checkpoints_req
    checkpoints_done buffers_checkpoint buffers_clean buffers_alloc
    checkpoint_write_time checkpoint_sync_time wal_bytes wal_records wal_fpi wal_buffers_full
)

# Per-table counters, collected for the measured table and its TOAST table (one column per
# prefix). n_tup_ins/n_tup_del and autoanalyze_count are what tell an insert-driven phase from
# an update-driven one and an analyze from a vacuum; they come from the same row as the rest.
table_metric_names=(
    n_tup_ins n_tup_upd n_tup_del n_live_tup n_dead_tup n_ins_since_vacuum
    vacuum_count autovacuum_count autoanalyze_count
    total_vacuum_time total_autovacuum_time total_analyze_time total_autoanalyze_time
)

relsize_metric_names=(
    relation_name relation_type relpages raw_rel_size relation_size
)

metric_field_names=("${global_metric_names[@]}")

for prefix in usertable toast; do
    for metric in "${table_metric_names[@]}"; do
        metric_field_names+=("${prefix}_${metric}")
    done
done

# n_tup_ins / n_tup_del arrive with the other per-table counters above, for both prefixes.

metric_field_names+=(
    usertable_heap_blks_read usertable_heap_blks_hit usertable_idx_blks_read usertable_idx_blks_hit
    toast_blks_read toast_blks_hit tidx_blks_read tidx_blks_hit
    # Physical footprint of the measured table and its TOAST table at the snapshot: relpages is
    # what a vacuum's space reclaim shows up in, size_in_bytes is the same number in bytes.
    usertable_relpages usertable_size_in_bytes toast_relpages toast_size_in_bytes
)

# backend::metric_names -> one CSV column per statistics measurement, in snapshot order.
backend::metric_names() {
    printf '%s\n' "${metric_field_names[@]}"
}


pg_cli() {
    local tool="$1"
    shift
    local started=$SECONDS rc=0 arg next_is_db=false next_is_sql=false target_db=unspecified action="$tool"
    for arg in "$@"; do
        if [[ "$next_is_db" == true ]]; then target_db="$arg"; next_is_db=false; fi
        if [[ "$next_is_sql" == true ]]; then
            read -r action _ <<< "${arg#"${arg%%[![:space:]]*}"}"
            next_is_sql=false
        fi
        [[ "$arg" != -c ]] || next_is_sql=true
        [[ "$arg" != -d && "$arg" != --dbname ]] || next_is_db=true
    done
    log "START PostgreSQL operation tool=$tool action=$action database=$target_db"
    # Do not log arguments: JDBC/CLI arguments can contain credentials.
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        "$tool" --host="$DB_HOST" --port="$DB_PORT" --username="$DB_USERNAME" \
        --no-password "$@" || rc=$?
    log "END PostgreSQL operation tool=$tool action=$action database=$target_db status=$rc duration=$((SECONDS-started))s"
    return "$rc"
}

# Build artifacts this backend needs, one glob per line. Derived from the binding so that
# every JDBC-backed module works without repeating itself.
backend::required_artifacts() {
    printf '%s\n' \
        "$YCSB_HOME/core/target/*.jar" \
        "$YCSB_HOME/core/target/dependency/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/dependency/postgresql-*.jar"
}

backend::cli() { pg_cli "$@"; }

# Sum of the ten text-array fields, i.e. the logical value size of a row. The engine
# needs it both per key and as a total, so it lives here once instead of being
# spelled out 34 times.

backend::exec() {
    # Ignore user psqlrc formatting and stop on SQL errors, including stdin/-f.
    pg_cli psql -X -q -v ON_ERROR_STOP=1 "$@"
}

backend::collect_metrics() {
    local db="${1:-$DB_NAME}"
    local scope="${2:-all}" output value field index metric alias
    local extra_select="" extra_joins=""
    local -a values names=("${global_metric_names[@]}")
    local dbmetrics relssizestats relsizes

    if [[ "$scope" == all ]]; then
        names=("${metric_field_names[@]}")
        for alias in u t; do
            for metric in "${table_metric_names[@]}"; do
                extra_select+=", $alias.$metric"
            done
        done

        # toast_* and tidx_* belong to the PARENT row, not the TOAST row.
        extra_select+=", io.heap_blks_read, io.heap_blks_hit, io.idx_blks_read, io.idx_blks_hit,
                         io.toast_blks_read, io.toast_blks_hit, io.tidx_blks_read, io.tidx_blks_hit"
        # Physical size of the measured table and of its TOAST table: relpages is how a vacuum's
        # space reclaim becomes visible, and pg_relation_size is the same heap footprint in
        # bytes (deliberately not pg_*_size: those add indexes and FSM/VM, which would make the
        # two columns disagree).
        extra_select+=", rc.relpages AS usertable_relpages,
                         pg_relation_size(rc.oid) AS usertable_size_in_bytes,
                         rt.relpages AS toast_relpages,
                         pg_relation_size(rt.oid) AS toast_size_in_bytes"
        # Resolve schema-qualified measured table, then follow reltoastrelid. TOAST
        # names/OIDs change when the comparison DB is recreated or restored.
        extra_joins="
        JOIN pg_catalog.pg_class AS rc ON rc.oid = to_regclass('public.${TARGET_TABLE:-usertable}')
        JOIN pg_catalog.pg_stat_all_tables AS u ON u.relid = rc.oid
        JOIN pg_catalog.pg_stat_all_tables AS t ON t.relid = rc.reltoastrelid
        JOIN pg_catalog.pg_statio_all_tables AS io ON io.relid = rc.oid
        JOIN pg_catalog.pg_class AS rt ON rt.oid = rc.reltoastrelid"
    fi
    log "START statistics snapshot database=$db scope=$scope"
    # Capture the exit status BEFORE read: read <<< $(psql ...) hides SQL errors.
    if ! output=$(backend::exec -d "$db" -At -F '|' -c "
        SELECT d.blks_read, d.blks_hit, d.tup_returned, d.tup_fetched,
               d.tup_inserted, d.tup_updated, d.tup_deleted, d.deadlocks,
               d.temp_files, d.temp_bytes, c.num_timed, c.num_requested,
               c.num_done, c.buffers_written, b.buffers_clean, b.buffers_alloc,
               c.write_time, c.sync_time, w.wal_bytes, w.wal_records,
               w.wal_fpi, w.wal_buffers_full $extra_select
        FROM pg_catalog.pg_stat_database AS d
        CROSS JOIN pg_catalog.pg_stat_checkpointer AS c
        CROSS JOIN pg_catalog.pg_stat_bgwriter AS b
        CROSS JOIN pg_catalog.pg_stat_wal AS w
        $extra_joins
        WHERE d.datname = current_database();"); then
        echo "[ERROR] PostgreSQL metrics query failed for $db." >&2
        return 1
    fi
    if [[ -z "$output" || "$output" == *$'\n'* ]]; then
        echo "[ERROR] Expected one metrics row for $db." >&2
        return 1
    fi
    IFS='|' read -r -a values <<< "$output"
    if [[ ${#values[@]} -ne ${#names[@]} ]]; then
        echo "[ERROR] Unexpected metrics column count for $db." >&2
        return 1
    fi
    # Validate everything before publishing any values to the CSV writer.
    for index in "${!names[@]}"; do
        field="${names[$index]}"
        value="${values[$index]}"
        if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
            echo "[ERROR] Missing or invalid metric $field for $db." >&2
            return 1
        fi
    done
   	dbmetrics=""
    for index in "${!names[@]}"; do
        printf -v "${names[$index]}" '%s' "${values[$index]}"
    	dbmetrics+="${names[$index]}=${values[$index]} "
    done
    log "DB statistics $dbmetrics"

	# check for relation sizes too
    if ! size_output=$(backend::exec -d "$db" -At -F '|' -c "
        SELECT c.relname AS relation_name,
 				CASE c.relkind
  			      WHEN 'r' THEN 'table'
  			      WHEN 'i' THEN 'index'
   			      WHEN 't' THEN 'TOAST'
  			      WHEN 'm' THEN 'matview'
   			      WHEN 'S' THEN 'sequence'
  			      WHEN 'p' THEN 'partitioned_table'
  			      WHEN 'I' THEN 'partitioned_index'
   			     ELSE c.relkind::text
  			  END AS relation_type,
   		c.relpages,
    		pg_relation_size(c.oid) raw_rel_size,
		    pg_size_pretty(pg_relation_size(c.oid)) AS relation_size
		FROM pg_catalog.pg_class AS c
		WHERE c.relfilenode > 100000;"); then
        	echo "[ERROR] PostgreSQL relation size query failed for $db." >&2
        	return 1
    fi
    relsizes=0
    if [[ -z "$size_output" ]]; then
        echo "[WARNING] Expected one relation size row for $db." >&2
    else
    	while IFS='|' read -r -a size_values; do
    		relsizes=$((relsizes + 1))
    		relssizestats=""
	    	for index in "${!relsize_metric_names[@]}"; do
    	    	printf -v "${relsize_metric_names[$index]}" '%s' "${size_values[$index]}"
    	    	if [[ "${relsize_metric_names[$index]}" == "raw_rel_size" ]]; then
	    	    	relssizestats+="size: "
    	    	fi
    	    	relssizestats+="${size_values[$index]} "
			done
			log "DB statistics $relssizestats"
		done <<< "$size_output"
	fi

    log "END statistics snapshot database=$db statistics=${#names[@]} relsizes=$relsizes"
}

backend::preflight() {
    local needs_dump="$1"
    shift
    local tool version server_version allowed db owner pattern track_counts seen='|'
    local -a required_tools=(psql createdb dropdb java awk sed grep perl sort comm bc ps tee date mktemp)
    if [[ "$needs_dump" == true ]]; then
        required_tools+=(pg_dump)
    fi
    for tool in "${required_tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "[ERROR] Required executable missing: $tool" >&2
            return 1
        }
    done
    # Workload files are input only: readable, never writable. The per-phase copies the
    # run needs are generated into $WORKLOAD_DIR (checked by workload::init).
    if [[ ! -x "$YCSB" || ! -r "$WORKLOAD_FILE" || ! -r "$JDBC_PROPERTIES" ]]; then
        echo "[ERROR] YCSB launcher/config is missing, or the workload template is not readable: $WORKLOAD_FILE" >&2
        return 1
    fi
    # Which binding module is needed follows from the configured binding (jdbc, jdbc-array,
    # jdbc-array-json, ...), so a backend only overrides backend::required_artifacts when it
    # really differs.
    local -a jar_patterns=()
    mapfile -t jar_patterns < <(backend::required_artifacts)
    for pattern in "${jar_patterns[@]}"; do
        if ! compgen -G "$pattern" >/dev/null; then
            echo "[ERROR] Missing build artifact: $pattern" >&2
            echo "Build from YCSB_HOME: mvn -Psource-run -pl site.ycsb:${YCSB_BINDING}-binding -am package -DskipTests" >&2
            return 1
        fi
    done
    if ! ps -u "${HOST_OS_USER:-postgres}" -o pid= >/dev/null; then
        echo "[ERROR] Cannot sample the ${HOST_OS_USER:-postgres} OS account required by these runners." >&2
        return 1
    fi
    local min_version="${MIN_SERVER_VERSION_NUM:-$(registry::info min_server_version_num)}"
    local major="${min_version:0:2}"
    # pg_dump is only required when the run dumps/restores a comparison database.
    local -a versioned_tools=(psql createdb dropdb)
    [[ "$needs_dump" == true ]] && versioned_tools+=(pg_dump)
    for tool in "${versioned_tools[@]}"; do
        version=$("$tool" --version) || return 1
        if [[ ! "$version" =~ PostgreSQL\)[[:space:]]$major([.]|[[:space:]]|$) ]]; then
            echo "[ERROR] $tool must be PostgreSQL $major: $version" >&2
            return 1
        fi
    done
    server_version=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c 'SHOW server_version_num;') || return 1
    if [[ ! "$server_version" =~ ^[0-9]+$ ]] || (( server_version < min_version )); then
        echo "[ERROR] These runners require PostgreSQL >= ${min_version:0:2}; got $server_version." >&2
        return 1
    fi
    allowed=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c \
        'SELECT rolcanlogin AND (rolcreatedb OR rolsuper) FROM pg_catalog.pg_roles WHERE rolname = current_user;') || return 1
    if [[ "$allowed" != t ]]; then
        echo "[ERROR] Benchmark role requires LOGIN and CREATEDB." >&2
        return 1
    fi
    for db in "$@"; do
        # These names are also interpolated into existing SQL in the runners.
        if [[ ! "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || ${#db} -gt 63 ||
              "$db" == "$PG_MAINTENANCE_DB" || "$db" == postgres ||
              "$db" == template0 || "$db" == template1 || "$seen" == *"|$db|"* ]]; then
            echo "[ERROR] Unsafe or duplicate benchmark database name: $db" >&2
            return 1
        fi
        seen="$seen$db|"
        owner=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c "
            SELECT pg_has_role(current_user, datdba, 'USAGE')
            FROM pg_catalog.pg_database WHERE datname = '$db';") || return 1
        if [[ -n "$owner" && "$owner" != t ]]; then
            echo "[ERROR] Benchmark role does not own existing database $db." >&2
            return 1
        fi
    done
    track_counts=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c 'SHOW track_counts;') || return 1
    if [[ "$track_counts" != on ]]; then
        echo "[ERROR] track_counts must be on to collect table statistics." >&2
        return 1
    fi
    # Probe globals in the maintenance DB; it has no benchmark table yet.
    backend::collect_metrics "$PG_MAINTENANCE_DB" global || return 1
    # Not a failure: a run measures correctly without the server's own log, it just loses the
    # explanation of what the server did during it. Saying it here is what stops that from being
    # discovered in the archived configuration days later. `--init` fixes it.
    if [[ "${ARCHIVE_CONFIGURATION:-1}" == 1 ]]; then
        local log_access
        # verify_log_access prints its reason on stdout and returns non-zero; empty means it is all
        # in place, in which case there is nothing to say.
        log_access=$(postgresql::verify_log_access "$DB_USERNAME") || true
        if [[ -n "$log_access" ]]; then
            echo "[WARNING] Server-side evidence (autovacuum, checkpoints, errors) will NOT be"
            echo "          archived: $log_access"
            echo "          Prepare the server with: ./experiment.sh $ACTIVE_BACKEND --init"
        fi
    fi
    echo "[INFO] PG18 preflight passed on $DB_HOST:$DB_PORT (server_version_num=$server_version)."
}

backend::dump_restore() {
    local source_rows restored_rows
    : > "$RESTORE_LOG"
    source_rows=$(backend::exec -d "$DB_NAME" -At -c 'SELECT count(*) FROM usertable;') || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || return 1
    # A fresh target does not need --clean DROP statements. Keep dump/log on failure.
    if ! pg_cli pg_dump -d "$DB_NAME" > "$BACKUP_FILE" 2>> "$RESTORE_LOG"; then
        echo "[ERROR] Dump failed; see $RESTORE_LOG." >&2
        return 1
    fi
    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$BACKUP_DB_NAME" || return 1
    pg_cli createdb "$BACKUP_DB_NAME" || return 1
    if ! backend::exec -d "$BACKUP_DB_NAME" -f "$BACKUP_FILE" >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] Restore failed; see $RESTORE_LOG. Dump retained at $BACKUP_FILE." >&2
        return 1
    fi
    restored_rows=$(backend::exec -d "$BACKUP_DB_NAME" -At -c 'SELECT count(*) FROM usertable;') || return 1
    if [[ "$restored_rows" != "$source_rows" ]]; then
        echo "[ERROR] Restore row count mismatch: source=$source_rows target=$restored_rows." >&2
        return 1
    fi
    echo "[INFO] Restore verified: $restored_rows rows." >> "$RESTORE_LOG"
}

# Counters describing what the server's own maintenance did to the measured table: vacuum and
# analyze counts, when they last ran, and how many dead tuples are waiting for them.
postgresql::maintenance_snapshot() {
    local db="${1:?database required}"
    backend::exec -d "$db" -At -F '|' -c "
        SELECT coalesce(s.autovacuum_count, 0), coalesce(s.autoanalyze_count, 0),
               coalesce(s.vacuum_count, 0), coalesce(s.n_dead_tup, 0),
               coalesce(to_char(s.last_autovacuum, 'YYYY-MM-DD HH24:MI:SS'), 'none')
        FROM pg_catalog.pg_class AS c
        LEFT JOIN pg_catalog.pg_stat_user_tables AS s ON s.relid = c.oid
        WHERE c.oid = to_regclass('public.${TARGET_TABLE:-usertable}');" 2>/dev/null
}

# What ran during an idle wait. A wait that ended because the server went quiet is only
# evidence of a clean measurement if we also know what the quiet was: an autovacuum that
# finished in this window explains both the wait and the phase timings, so it belongs in the
# run log next to them.
postgresql::report_maintenance() {
    local database="${1:?database required}" before="${2:-}"
    local -a b=() n=()
    local now

    [[ -n "$before" ]] || return 0
    now=$(postgresql::maintenance_snapshot "$database")
    [[ -n "$now" ]] || return 0

    IFS='|' read -r -a b <<< "$before"
    IFS='|' read -r -a n <<< "$now"
    (( ${#n[@]} >= 5 && ${#b[@]} >= 5 )) || return 0

    if [[ "${b[0]}" == "${n[0]}" && "${b[1]}" == "${n[1]}" && "${b[4]}" == "${n[4]}" ]]; then
        log "MAINTENANCE idle window database=$database none=autovacuum,autoanalyze dead_tuples=${n[3]}"
    else
        log "MAINTENANCE idle window database=$database autovacuum_count=${b[0]}->${n[0]} autoanalyze_count=${b[1]}->${n[1]} dead_tuples=${b[3]}->${n[3]} last_autovacuum=${n[4]}"
    fi
}

backend::wait_idle() {
    local database="${1:-$DB_NAME}"
    local interval="${2:-${IDLE_WAIT_INTERVAL:-30}}"
    local timeout="${3:-${IDLE_WAIT_TIMEOUT:-7200}}"
    local started active_backends active_count maintenance_before

    # Wait for backend services (autovacuum, checkpointing) to settle so that a
    # phase is not timed while background work is still running.
    log "START WAIT FOR IDLE POSTGRES database=$database"
    started=$SECONDS
    maintenance_before=$(postgresql::maintenance_snapshot "$database")
    while true; do
        # One row per non-idle backend, excluding this script's own connection.
        active_backends=$(backend::exec -d "$database" -At -c \
            "SELECT backend_type, query, query_start, wait_event, state FROM pg_stat_activity WHERE state != 'idle' AND pid != pg_backend_pid();")

        # An empty result means idle. Do not count lines: printf '%s\n' "" | wc -l
        # reports 1 for the empty string, so every wait ran to its full timeout.
        if [[ -z "${active_backends//[[:space:]]/}" ]]; then
            log "END WAIT FOR IDLE POSTGRES database=$database duration=$((SECONDS-started))s"
            postgresql::report_maintenance "$database" "$maintenance_before"
            break
        fi
        active_count=$(printf '%s\n' "$active_backends" | grep -c .)
        if (( SECONDS - started >= timeout )); then
            log "TIMEOUT WAIT FOR IDLE POSTGRES: $active_count backend(s) are still not idle: $(printf '%s' "$active_backends" | tr '\n' '\t')"
            postgresql::report_maintenance "$database" "$maintenance_before"
            break
        fi
        log "WAITING FOR IDLE POSTGRES - $active_count active processes: $(printf '%s' "$active_backends" | tr '\n' '\t')"
        sleep "$interval"
    done
}

backend::close() {
    log "PostgreSQL backend: no manual DB close required."
}

# ---------------------------------------------------------------------------
# Phase markers, background maintenance and the server's own archive
#
# All three are best-effort by design: a marker the role may not write or a configuration file
# it may not read must never fail a phase or a finished run, so each of them degrades to one
# explanatory log line. They are read through SQL rather than through the OS, because the
# benchmark role is not expected to have any rights on the server's files (the pre-refactor
# runner shelled out with sudo for exactly these three things).
# ---------------------------------------------------------------------------

# Databases this process has installed the marker function in (and, if it failed, why not).
declare -gA PG_LOG_MARKER_STATE=()

# Install `experiment_log(text)`, which raises a message into the server log. The tidy variant
# sets two logging parameters so that an error elsewhere does not add CONTEXT/STATEMENT noise
# around it; only a superuser may grant that, so a plain variant is installed otherwise.
postgresql::install_log_marker() {
    local db="${1:?database required}"
    local privileged=""
    local fn_body="BEGIN RAISE LOG '%', msg; END;"

    # A superuser, or a role --init granted SET on the two logging parameters. Without them a
    # marker arrives with CONTEXT and STATEMENT lines around it, and the archived slice is then
    # three lines per phase instead of one.
    privileged=$(backend::exec -d "$db" -At -c "
        SELECT CASE
            WHEN current_setting('is_superuser') = 'on' THEN 'on'
            WHEN has_parameter_privilege(current_user, 'log_error_verbosity', 'SET') AND
                 has_parameter_privilege(current_user, 'log_min_error_statement', 'SET')
            THEN 'on' ELSE 'off' END;" 2>/dev/null) || privileged=""

    if [[ "$privileged" == "on" ]]; then
        # A superuser grants itself; any other role already holds it from --init, and a failing
        # GRANT here is what falls through to the unadorned variant below.
        backend::exec -d "$db" -q -c "
            GRANT SET ON PARAMETER log_min_error_statement TO \"$DB_USERNAME\";
            GRANT SET ON PARAMETER log_error_verbosity TO \"$DB_USERNAME\";" >/dev/null 2>&1 || true
        backend::exec -d "$db" -q -c "
            CREATE OR REPLACE FUNCTION experiment_log(msg text) RETURNS void
            AS \$\$ $fn_body \$\$ LANGUAGE plpgsql
            SET log_min_error_statement = 'panic'
            SET log_error_verbosity = 'terse';" >/dev/null 2>&1 && return 0
    fi

    backend::exec -d "$db" -q -c "
        CREATE OR REPLACE FUNCTION experiment_log(msg text) RETURNS void
        AS \$\$ $fn_body \$\$ LANGUAGE plpgsql;" >/dev/null 2>&1
}

# One marker line per phase in the server's own log, so that server-side evidence (an
# autovacuum, a checkpoint, a deadlock) can be placed between two phases of a run without
# matching timestamps — and so that exactly that window can be archived, see
# backend::archive_server_state.
backend::mark_run() {
    local db="${1:?database required}" message="${2:?message required}"

    case "${PG_LOG_MARKER_STATE[$db]:-}" in
        failed) return 0 ;;
        installed) ;;
        *)
            if postgresql::install_log_marker "$db"; then
                PG_LOG_MARKER_STATE["$db"]=installed
            else
                PG_LOG_MARKER_STATE["$db"]=failed
                log "WARNING no server-side phase markers in $db: cannot create experiment_log()"
                return 0
            fi
            ;;
    esac

    # The message travels as a psql variable, so psql quotes it and it cannot break out of the
    # statement however it is punctuated. That needs the statement on stdin: psql does not
    # interpolate variables in a -c argument.
    if ! printf "SELECT experiment_log(:'mark');\n" |
        backend::exec -d "$db" -At -v "mark=$message" >/dev/null 2>&1; then
        # Losing the markers must not lose the phase; say it once per database.
        PG_LOG_MARKER_STATE["$db"]=failed
        log "WARNING no server-side phase markers in $db: experiment_log() failed"
    fi
}

# Stop/start the server's background maintenance of the measured table. Phases that must be
# comparable may not have autovacuum cleaning one table and not another; the extend phase, in
# contrast, is measured with maintenance running, because growing values while the database
# cleans up after itself is what the study measures.
backend::maintenance_mode() {
    local mode="${1:?on or off}" db="${2:?database required}"
    local table="${TARGET_TABLE:-usertable}" sql

    case "$mode" in
        on) sql="ALTER TABLE public.$table RESET (autovacuum_enabled);" ;;
        off) sql="ALTER TABLE public.$table SET (autovacuum_enabled = false);" ;;
        *)
            echo "[ERROR] maintenance mode must be on or off, got: $mode" >&2
            return 2
            ;;
    esac

    backend::exec -d "$db" -c "$sql" >/dev/null ||
        log "WARNING could not set autovacuum_enabled ($mode) for $db.$table"
}

# A resumed run continues from data an earlier attempt left, so nothing is created and the
# table only has to be there. reltuples is an estimate — reading the real count here would scan
# the very table the resume is trying to protect.
backend::verify_resume_ready() {
    local db="${1:?database required}" table="${TARGET_TABLE:-usertable}"
    local row

    row=$(backend::exec -d "$db" -At -F '|' -c "
        SELECT to_regclass('public.$table') IS NOT NULL, coalesce(c.reltuples::bigint, -1)
        FROM (SELECT 1) x LEFT JOIN pg_catalog.pg_class AS c ON c.oid = to_regclass('public.$table');" 2>/dev/null) || row=""

    if [[ "$row" != "t|"* ]]; then
        log "ERROR resume: database $db has no table public.$table to continue from"
        return 1
    fi
    log "RESUME verified database=$db table=$table rows~=${row#*|}"
    return 0
}

# Everything the server itself contributes to a run's configuration archive: its configuration
# file, the settings that were actually in force, and the slice of its own log between this
# run's first and last marker.
backend::archive_server_state() {
    local dir="${1:?directory required}"
    local max_bytes="${SERVER_LOG_ARCHIVE_MAX_BYTES:-67108864}"
    local config_file files name size target slice marker

    config_file=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT current_setting('config_file', true);" 2>/dev/null) || config_file=""
    if [[ -z "$config_file" ]]; then
        log 'ARCHIVE server configuration skipped: config_file not visible to this role\n'
    elif backend::exec -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT pg_read_file('$config_file');" > "$dir/postgresql.conf" 2>/dev/null &&
        [[ -s "$dir/postgresql.conf" ]]; then
        log "ARCHIVE server configuration $config_file"
    else
        rm -f "$dir/postgresql.conf"
        log "ARCHIVE server configuration skipped: $config_file not readable (needs pg_read_server_files)"
    fi

    # The effective settings, which is what postgresql.conf does not necessarily say (defaults,
    # ALTER SYSTEM, command line).
    backend::exec -d "$PG_MAINTENANCE_DB" -P footer=off -c "
        SELECT name, setting, source FROM pg_catalog.pg_settings
        WHERE name IN ('server_version_num', 'shared_buffers', 'effective_cache_size',
                       'work_mem', 'maintenance_work_mem', 'max_wal_size', 'checkpoint_timeout',
                       'wal_compression', 'autovacuum', 'autovacuum_enabled',
                       'autovacuum_vacuum_scale_factor', 'track_counts', 'logging_collector',
                       'log_destination', 'log_min_messages')
        ORDER BY name;" > "$dir/server_settings.txt" 2>/dev/null ||
        rm -f "$dir/server_settings.txt"

    # The window of server log this run wrote: every line between its first and its last marker.
    # Whole files would be the alternative, and on a shared server those are not this run's.
    marker="EXEC=${EXECUTION_ID:-none}"
    local log_dir
    log_dir=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT current_setting('log_directory', true);" 2>/dev/null) || log_dir=""
    [[ -n "$log_dir" ]] || {
        log 'ARCHIVE server log skipped: log_directory not visible to this role'
        return 0
    }
    files=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -F '|' -c \
        "SELECT name, size FROM pg_catalog.pg_ls_logdir() ORDER BY modification DESC;" 2>/dev/null) || {
        log 'ARCHIVE server log skipped: log directory not listable (needs pg_monitor)'
        return 0
    }

    while IFS='|' read -r name size; do
        [[ -n "$name" && "$size" =~ ^[0-9]+$ ]] || continue
        if (( size > max_bytes )); then
            log "ARCHIVE server log skipped $name: $size bytes over SERVER_LOG_ARCHIVE_MAX_BYTES"
            continue
        fi
        target="$dir/server_log_$(basename "$name")"
        # EXECUTION_ID is a timestamp and a pid, so it needs no quoting to be embedded in the
        # LIKE pattern below. pg_ls_logdir reports bare names while pg_read_file wants them
        # relative to the data directory, which is what log_directory says (an absolute one is
        # accepted for a superuser too, so this covers both server layouts).
        slice=$(backend::exec -d "$PG_MAINTENANCE_DB" -At -c "
            WITH marked AS (
                SELECT s.ord, s.line,
                       min(CASE WHEN s.line LIKE '%$marker%' THEN s.ord END) OVER (),
                       max(CASE WHEN s.line LIKE '%$marker%' THEN s.ord END) OVER () AS last_ord
                FROM unnest(string_to_array(pg_read_file('${log_dir%/}/$name'), E'\\n'))
                     WITH ORDINALITY AS s(line, ord)
            )
            SELECT string_agg(line, E'\\n')
            FROM marked
            WHERE last_ord IS NOT NULL AND ord BETWEEN (
                SELECT min(CASE WHEN line LIKE '%$marker%' THEN ord END) FROM marked
            ) AND last_ord;
        " 2>/dev/null) || slice=""
        if [[ -n "$slice" ]]; then
            printf '%s\n' "$slice" > "$target"
            log "ARCHIVE server log $name ($(wc -l < "$target") lines of this run)"
        else
            rm -f "$target"
        fi
    done <<< "$files"

    return 0
}

# ---------------------------------------------------------------------------
# Preparing a server for a run (--init)
#
# Whether a run gets its server-side evidence — the autovacuum report, the checkpoints, the
# errors between two phases — is decided by the server, not by the runner: a few grants to the
# benchmark role and a handful of logging settings. --init applies them once, verifies them from
# the benchmark role's point of view, and says what still needs a restart, so a ten-hour run
# never ends by discovering that the evidence was never written or never readable.
#
# What is required is exactly what backend::archive_server_state and mark_run do:
#   pg_monitor             current_setting('log_directory') is only visible with
#                          pg_read_all_settings, and pg_ls_logdir() is only executable by it;
#   pg_read_server_files   the check inside pg_read_file(), which rejects reads even when the
#                          function itself is executable;
#   EXECUTE on pg_read_file(text)  PostgreSQL >= 16 grants no execute on it to anything, and
#                          function privileges live in a database, so this one has to be applied
#                          in $PG_MAINTENANCE_DB — the database the archiver connects to.
# Phase markers are RAISE LOG, and LOG is always logged, so log_min_messages needs no change;
# log_autovacuum_min_duration=0 is what makes an autovacuum appear in the log at all.
# ---------------------------------------------------------------------------

# The administrative connection: init GRANTs and ALTERs SYSTEM, which the benchmark role has no
# reason to be allowed to do while it is measuring. It defaults to the benchmark role itself,
# which is how a single-role server (the usual benchmark machine) is prepared without a second
# password; PG_INIT_ADMIN_USERNAME / PG_INIT_ADMIN_PWD name an administrator instead, and
# PG_INIT_ADMIN_HOST / PG_INIT_ADMIN_PORT reach it on another endpoint.
#
# PG_INIT_ADMIN_CLI_WRAP puts something in front of psql — `sudo -u postgres`, or
# `podman exec -i ycsb_postgres` when the server runs in a container. That is how most
# PostgreSQL installs are administered at all, since the superuser is reachable through the OS
# account (peer/trust on the unix socket) and often through nothing else: pg_hba rarely lets a
# superuser in over TCP with a password. A wrapped command therefore reaches the server as that
# OS user sees it, so the endpoint arguments are dropped — exactly as with the other backends'
# *_CLI_WRAP — and PG_INIT_ADMIN_USERNAME names the role to become there.
pg_cli_admin() {
    local tool="${1:?tool required}"
    shift
    local started=$SECONDS rc=0 db="" arg previous="" sql="" action="$tool"
    for arg in "$@"; do
        [[ "$previous" != -d ]] || db="$arg"
        if [[ "$previous" == -c && -z "$sql" ]]; then
            read -r action _ <<< "${arg#"${arg%%[![:space:]]*}"}"
        fi
        previous="$arg"
    done
    log "START PostgreSQL administration tool=$tool action=$action database=${db:-unspecified}"

    local -a wrap=() conn=(--username="${PG_INIT_ADMIN_USERNAME:-$DB_USERNAME}")
    if [[ -z "${PG_INIT_ADMIN_CLI_WRAP:-}" ]]; then
        conn=(--host="${PG_INIT_ADMIN_HOST-$DB_HOST}" --port="${PG_INIT_ADMIN_PORT-$DB_PORT}" "${conn[@]}")
    else
        read -r -a wrap <<< "$PG_INIT_ADMIN_CLI_WRAP"
    fi
    # Do not log arguments: they can contain credentials. stdin is closed deliberately: a wrapper
    # that attaches it (`podman exec -i …`) would otherwise read the caller's input and leave the
    # rest of a loop unseen.
    PGPASSWORD="${PG_INIT_ADMIN_PWD:-$DB_PWD}" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        "${wrap[@]}" "$tool" --no-password "${conn[@]}" "$@" < /dev/null || rc=$?
    log "END PostgreSQL administration tool=$tool action=$action database=${db:-unspecified} status=$rc duration=$((SECONDS-started))s"
    return "$rc"
}

# The settings that make the server write the evidence, as "name|value|reloadable?". A setting
# whose value already agrees is left alone, so init never rewrites a deliberate choice.
postgresql::init_settings() {
    printf 'autovacuum|on|reload\n'
    printf 'log_destination|stderr|reload\n'
    printf 'logging_collector|on|restart\n'
    printf 'log_autovacuum_min_duration|0|reload\n'
    printf 'log_checkpoints|on|reload\n'
    printf 'log_lock_waits|on|reload\n'
    printf 'max_wal_size|16GB|reload\n'
    printf 'track_counts|on|reload\n'
}

# One setting changed in postgresql.auto.conf. A log_line_prefix is full of brackets and percent
# signs, so the value needs quoting; it must not arrive through a psql variable, because that
# would mean reading stdin (see the function).
postgresql::alter_system() {
    local name="${1:?setting required}" value="${2:?value required}"
    # Quoted by doubling single quotes rather than as a psql variable: psql interpolates variables
    # only from stdin, and an administrator command that reads stdin would steal the input of a
    # wrapped connection (`podman exec -i`) from whatever is really feeding it. Both arguments
    # come from this file's own list, never from configuration.
    pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c \
        "ALTER SYSTEM SET $name = '${value//\'/\'\'}'"
}

# Can $1 (the benchmark role) see, list and read the server's own log? Prints the first thing
# that is missing and returns 1; prints nothing and returns 0 when all three work. Runs as an
# admin but through SET ROLE, so it asks the question the way the run will — and needs no second
# password for the role being tested.
#
# The privilege questions are asked of the catalog first, because they can be answered whatever
# the server is doing; only then come the questions that need a log file to exist. Reporting a
# missing pg_monitor membership as "could not open directory" — or the other way round — sends an
# operator to the wrong machine.
postgresql::verify_log_access() {
    local role="${1:?role required}" missing collector files newest

    missing=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c "
        SELECT CASE
            WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$role')
                THEN 'the role does not exist'
            WHEN NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = '$role') AND NOT (
                     SELECT rolinherit FROM pg_catalog.pg_roles WHERE rolname = '$role')
                THEN 'it is NOINHERIT, so no membership it has takes effect (CREATE ROLE defaults
                      to that; ALTER ROLE ... INHERIT, or the runner must SET ROLE)'
            WHEN NOT pg_has_role('$role', 'pg_monitor', 'USAGE')
                THEN 'it lacks pg_monitor, which is what makes log_directory visible and
                      pg_ls_logdir() executable'
            WHEN NOT (pg_has_role('$role', 'pg_read_server_files', 'USAGE') AND
                      has_function_privilege('$role', 'pg_read_file(text)', 'EXECUTE'))
                THEN 'it lacks pg_read_server_files, or EXECUTE on pg_read_file(text) in this
                      database (a per-database privilege, and the archiver connects to
                      $PG_MAINTENANCE_DB)'
            ELSE 'ok' END;" 2>/dev/null) || missing='the catalog query failed'
    if [[ "$missing" != ok ]]; then
        # The CASE above is written over several lines; the message it returns must not be.
        echo "$role cannot read the server's own log: $(printf '%s' "$missing" | tr '\n\t' '  ' | tr -s ' ')"
        return 1
    fi

    # Privileges are in place; is there a log to read at all? A server that does not collect one
    # sends its log to its own stderr, where no SQL function can reach it.
    collector=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT current_setting('logging_collector');" 2>/dev/null) || collector=''
    [[ "$collector" == on ]] || {
        echo "logging_collector is off, so the server keeps no log files to archive"
        return 1
    }
    # -q because a SET ROLE prints a command tag, and only the query result may reach $files.
    files=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -q -c \
        "SET ROLE \"$role\"; SELECT name FROM pg_catalog.pg_ls_logdir()
         ORDER BY modification DESC;" 2>/dev/null) || {
        echo "$role may not list the log directory (pg_ls_logdir failed)"
        return 1
    }
    [[ -n "$files" ]] || {
        # The usual reason is a destination that bypasses the collector's files entirely.
        local destination
        destination=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
            "SELECT current_setting('log_destination');" 2>/dev/null) || destination='unknown'
        echo "the log directory holds no files (log_destination=$destination): only stderr,"
        echo "csvlog and jsonlog are written where pg_ls_logdir() can see them"
        return 1
    }
    newest=$(printf '%s\n' "$files" | head -1)
    # Log file names come from the server's own directory listing; refuse anything that is not a
    # plain file name rather than interpolating it into SQL.
    [[ "$newest" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "unexpected log file name from pg_ls_logdir(): $newest"
        return 1
    }
    pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -q -c "
        SET ROLE \"$role\";
        SELECT length(pg_read_file(rtrim(current_setting('log_directory'), '/') || '/$newest'));" \
        >/dev/null 2>&1 || {
        echo "$role may not read $newest from the log directory"
        return 1
    }
    return 0
}

# The strongest check there is: write a LOG line now and read it back through the same three
# functions the archiver uses. A message can sit in the collector's queue for a moment, hence
# the short retry.
postgresql::verify_marker_round_trip() {
    local role="${1:?role required}" token attempt hit
    token="YCSB-INIT-CHECK-$$-$RANDOM"

    # No % in the message: PL/pgSQL reads % as a placeholder, and this line is written by the
    # administrator connection, not by the measured role.
    pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c \
        "DO \$\$ BEGIN RAISE LOG 'EXPERIMENT INIT $token'; END \$\$;" || return 1

    for attempt in 1 2 3 4 5;
    do
        sleep 1
        hit=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -q -c "
            SET ROLE \"$role\";
            -- The path is relative to the data directory, exactly as backend::archive_server_state
            -- builds it: pg_ls_logdir reports bare names, pg_read_file wants them prefixed with
            -- log_directory.
            SELECT count(*) FROM (
                SELECT pg_read_file(rtrim(current_setting('log_directory'), '/') || '/' || name) AS body
                FROM (
                    SELECT name FROM pg_catalog.pg_ls_logdir() ORDER BY modification DESC LIMIT 1
                ) newest
            ) recent WHERE position('$token' IN recent.body) > 0;" 2>/dev/null) || hit=0
        [[ "$hit" != 0 && -n "$hit" ]] && return 0
    done
    echo "$role could not read back a LOG line it had just written"
    return 1
}

# Apply everything a run needs from the server. Idempotent: reads first, changes only what
# differs, and reports each change (and what still waits for a restart).
backend::init_access() {
    local role="${PG_INIT_TARGET_ROLE:-$DB_USERNAME}"
    local name value reload current state changed=0 needs_restart=0 missing

    if [[ ! "$role" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "[ERROR] Refusing to prepare grants for an unexpected role name: $role" >&2
        return 1
    fi
    state=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT current_setting('is_superuser'), current_setting('server_version_num')::int;" \
        2>/dev/null) || state=""
    # Nothing above this point touched the server, so refusing here leaves nothing half-applied.
    if [[ -z "$state" ]]; then
        echo "[ERROR] --init cannot connect to $DB_HOST:$DB_PORT as" >&2
        echo "        ${PG_INIT_ADMIN_USERNAME:-$DB_USERNAME} (the administrator role)." >&2
        return 1
    fi
    if [[ "$state" != "on|"* ]]; then
        echo "[ERROR] --init refuses to continue: ${PG_INIT_ADMIN_USERNAME:-$DB_USERNAME} is not a" >&2
        echo "        superuser. It changes server settings as well as grants, so anything less" >&2
        echo "        would leave the preparation half-applied." >&2
        echo "        Point PG_INIT_ADMIN_USERNAME / PG_INIT_ADMIN_PWD at an administrator role;" >&2
        echo "        the run itself needs no more than $role." >&2
        return 1
    fi
    if (( ${state#*|} < 180000 )); then
        echo "[ERROR] --init supports PostgreSQL >= 18; got ${state#*|}." >&2
        return 1
    fi

    echo "[INFO] Preparing $DB_HOST:$DB_PORT so that $role can archive the server's own evidence."

    while IFS='|' read -r name value reload; do
        [[ -n "$name" ]] || continue
        current=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
            "SELECT current_setting('$name');" 2>/dev/null) || current=""
        if [[ "$current" == "$value" ]]; then
            echo "[INFO] setting $name already $value"
            continue
        fi
        # csvlog and jsonlog are readable by the archiver too; only replace a destination that
        # writes nothing the slicer could use.
        if [[ "$name" == log_destination && "$current" =~ ^(stderr|csvlog|jsonlog)$ ]]; then
            echo "[INFO] setting log_destination left at $current (readable by the archiver)"
            continue
        fi
        if postgresql::alter_system "$name" "$value"; then
            echo "[INFO] setting $name = $value (was ${current:-unset}, needs $reload)"
            changed=$((changed + 1))
            [[ "$reload" == restart ]] && needs_restart=1
        else
            echo "[ERROR] Could not set $name=$value with ALTER SYSTEM." >&2
            return 1
        fi
    done < <(postgresql::init_settings)

    # A prefix without a timestamp cannot be aligned with the run log.
    current=$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
        "SELECT current_setting('log_line_prefix');" 2>/dev/null) || current=""
    if [[ "$current" != *%m* && "$current" != *%t* ]]; then
        postgresql::alter_system log_line_prefix '%m [%p] %q%u@%d ' &&
            echo "[INFO] setting log_line_prefix = '%m [%p] %q%u@%d ' (was '${current:-empty}'; it must carry a timestamp)" ||
            return 1
        changed=$((changed + 1))
    fi

    # CREATE ROLE defaults to NOINHERIT (CREATE USER does not), and a NOINHERIT role gets
    # nothing from a membership — the grants below would be granted and useless.
    if [[ "$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
            "SELECT rolinherit FROM pg_catalog.pg_roles WHERE rolname = '$role';" 2>/dev/null)" != t ]]; then
        pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c "ALTER ROLE \"$role\" INHERIT;" || return 1
        echo "[INFO] role $role is now INHERIT (it was NOINHERIT: memberships would not apply)"
    fi

    for name in pg_monitor pg_read_server_files; do
        if [[ "$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
                "SELECT pg_has_role('$role', '$name', 'MEMBER');" 2>/dev/null)" == t ]]; then
            echo "[INFO] role $role already a member of $name"
        elif pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c \
                "GRANT \"$name\" TO \"$role\";"; then
            echo "[INFO] granted $name to $role"
        else
            echo "[ERROR] Could not grant $name to $role." >&2
            return 1
        fi
    done

    # Per-database, and the archiver reads through $PG_MAINTENANCE_DB.
    if [[ "$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
            "SELECT has_function_privilege('$role', 'pg_read_file(text)', 'EXECUTE');" 2>/dev/null)" == t ]]; then
        echo "[INFO] role $role may already execute pg_read_file(text) in $PG_MAINTENANCE_DB"
    elif pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c \
            "GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_file(text) TO \"$role\";"; then
        echo "[INFO] granted EXECUTE on pg_read_file(text) to $role in $PG_MAINTENANCE_DB"
    else
        echo "[ERROR] Could not grant EXECUTE on pg_read_file(text) to $role in $PG_MAINTENANCE_DB." >&2
        return 1
    fi

    # Parameter privileges are cluster-wide, and they are what lets the marker function set the
    # two logging parameters that keep a marker to one line (see postgresql::install_log_marker).
    if [[ "$(pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c \
            "SELECT has_parameter_privilege('$role', 'log_error_verbosity', 'SET');" 2>/dev/null)" == t ]]; then
        echo "[INFO] role $role may already set the two logging parameters of a marker"
    elif pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -q -c "
            GRANT SET ON PARAMETER log_min_error_statement TO \"$role\";
            GRANT SET ON PARAMETER log_error_verbosity TO \"$role\";"; then
        echo "[INFO] granted SET on log_min_error_statement and log_error_verbosity to $role"
    else
        echo "[ERROR] Could not grant SET on the two logging parameters of a marker to $role." >&2
        return 1
    fi

    (( changed )) && pg_cli_admin psql -d "$PG_MAINTENANCE_DB" -At -c 'SELECT pg_reload_conf();' >/dev/null &&
        echo "[INFO] Configuration reloaded."

    if ! missing=$(postgresql::verify_log_access "$role"); then
        # The one expected reason is the restart logging_collector needs: say so instead of
        # reporting an operator error for something they are about to do.
        if (( needs_restart )); then
            echo "[WARNING] Not verified yet: logging_collector was switched on, and it only takes" >&2
            echo "          effect after a server restart ($missing)." >&2
            echo "          Restart the server, then run --init again to verify; the grants" >&2
            echo "          applied above need no restart." >&2
        else
            echo "[ERROR] $role still cannot read the server log: $missing" >&2
        fi
        return 1
    fi
    if ! missing=$(postgresql::verify_marker_round_trip "$role"); then
        echo "[ERROR] $missing — the phase markers and the evidence between them would be archived" >&2
        echo "        as an empty slice." >&2
        return 1
    fi
    echo "[INFO] Verified: $role can list and read the server log, and reads back its own LOG lines."
    return 0
}

# ---------------------------------------------------------------------------
# Operations the phase engine asks for by name (the SQL itself is a PostgreSQL detail)
# ---------------------------------------------------------------------------

backend::sample_key() {
    local db="${1:?database required}"
    backend::exec -d "$db" -At -c "SELECT ycsb_key FROM usertable LIMIT 1;"
}

backend::explain_sql() {
    local db="${1:?database required}" key="${2:?key required}"
    backend::exec -d "$db" -c "
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT * FROM usertable WHERE ycsb_key = '$key';
    "
}

backend::delete_keys() {
    local db="${1:?database required}" file="${2:?key file required}"
    while read -r key; do
        [[ -n "$key" ]] && printf "DELETE FROM usertable WHERE ycsb_key='%s';\n" "$key"
    done < "$file" | backend::exec -d "$db"
}

backend::truncate() {
    local db="${1:?database required}"
    backend::exec -d "$db" -c "TRUNCATE TABLE usertable;"
}

# VACUUM (ANALYZE, VERBOSE) with its progress lines turned into runner log entries. Moved
# verbatim from the phase engine: what a "clean up between phases" step means per database.
backend::vacuum() {
    local db="${1:?database required}"
    local vacuum_started=$SECONDS vacuum_rc=0
    # One directory per kind of artefact, so a run log's neighbours stay readable; the name is
    # derived from LOG_FILE with pure expansion (no subshell in the declaration).
    local vacuum_run_name="${LOG_FILE##*/}"
    local vacuum_detail="$LOG_DIR/vacuum_logs/${vacuum_run_name%.log}_iteration${iteration}_epoch${epoch}_step${step}_vacuum.raw.log"

    mkdir -p "$(dirname "$vacuum_detail")"
    log "START VACUUM ANALYZE database=$db"

    backend::exec -d "$db" \
        -c "VACUUM (ANALYZE, VERBOSE) public.usertable;" 2>&1 |
        tee "$vacuum_detail" |
        perl -ne '
            BEGIN { $| = 1; }

            if (/^INFO:\s+(?:aggressively )?vacuuming "([^"]+)"/) {
                print "START VACUUM table=$1\n";
            }
            elsif (/^INFO:\s+finished vacuuming "([^"]+)"/) {
                print "END VACUUM table=$1\n";
            }
            elsif (/^(?:WARNING|ERROR|FATAL|PANIC):/) {
                print;
            }
        ' |
        while IFS= read -r message; do
            log "$message"
        done || vacuum_rc=$?

    log "END VACUUM ANALYZE database=$db status=$vacuum_rc duration=$((SECONDS-vacuum_started))s"

    if (( vacuum_rc != 0 )); then
        log "ERROR VACUUM failed; details=$vacuum_detail"
        exit "$vacuum_rc"
    fi
}

# ---------------------------------------------------------------------------
# Backend contract
# ---------------------------------------------------------------------------

backend::total_size() {
    local db="${1:?database required}"
    backend::exec -d "$db" -At -F',' -c \
        "SELECT SUM($(backend::size_expression)) FROM usertable;"
}

# Per-key value sizes as "ycsb_key,size" rows written to $2.

backend::key_sizes() {
    local db="${1:?database required}" out="${2:?output file required}"
    echo "ycsb_key,size" > "$out"
    backend::exec -d "$db" -At -F',' -c \
        "SELECT ycsb_key, $(backend::size_expression) AS size FROM usertable;" >> "$out"
}

# All keys currently stored, written to $2.

backend::list_keys() {
    local db="${1:?database required}" out="${2:?output file required}"
    backend::exec -d "$db" -At -F',' -c "SELECT ycsb_key FROM usertable;" > "$out"
}

# ---------------------------------------------------------------------------
# Backend defaults (connection settings and the schema-specific workload template)
# ---------------------------------------------------------------------------

# Connection defaults shared by every PostgreSQL backend. A module calls this from its own
# backend::default_config, optionally with the path of its binding's properties file, and then
# adjusts anything else that differs (schema name, property prefix, ...).
postgresql::base_config() {
    local properties_default="${1:-../jdbc-binding/conf/postgres.properties}"

    DB_NAME="${DB_NAME:-ycsb}"
    BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
    UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
    TARGET_TABLE="${TARGET_TABLE:-usertable}"

    # PostgreSQL endpoint shared by the JDBC binding and the CLI commands
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-5432}"
    DB_USERNAME="${DB_USERNAME:-ycsb}"
    DB_PWD="${DB_PWD:-usyd2026}"

    DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME"
    BACKUP_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$BACKUP_DB_NAME"
    UNCHANGED_DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$UNCHANGED_DB_NAME"
    JDBC_PROPERTIES="${JDBC_PROPERTIES:-$properties_default}"

    # CPU/memory usage is sampled from the server's OS account.
    HOST_OS_USER="${HOST_OS_USER:-$(registry::info host_os_user)}"
    BACKUP_FILE="${BACKUP_FILE:-./ycsb_dump.sql}"
}
