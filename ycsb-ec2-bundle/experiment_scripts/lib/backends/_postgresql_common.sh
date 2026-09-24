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

table_metric_names=(
    n_tup_upd n_live_tup n_dead_tup n_ins_since_vacuum vacuum_count autovacuum_count
    total_vacuum_time total_autovacuum_time total_analyze_time total_autoanalyze_time
)

relsize_metric_names=(
    relation_name relation_type raw_rel_size relation_size
)

metric_field_names=("${global_metric_names[@]}")

for prefix in usertable toast; do
    for metric in "${table_metric_names[@]}"; do
        metric_field_names+=("${prefix}_${metric}")
    done
done

metric_field_names+=(toast_n_tup_ins toast_n_tup_del)

metric_field_names+=(
    usertable_heap_blks_read usertable_heap_blks_hit usertable_idx_blks_read usertable_idx_blks_hit
    toast_blks_read toast_blks_hit tidx_blks_read tidx_blks_hit
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

        extra_select+=", t.n_tup_ins, t.n_tup_del"
        
        # toast_* and tidx_* belong to the PARENT row, not the TOAST row.
        extra_select+=", io.heap_blks_read, io.heap_blks_hit, io.idx_blks_read, io.idx_blks_hit,
                         io.toast_blks_read, io.toast_blks_hit, io.tidx_blks_read, io.tidx_blks_hit"
        # Resolve schema-qualified usertable, then follow reltoastrelid. TOAST
        # names/OIDs change when the comparison DB is recreated or restored.
        extra_joins="
        JOIN pg_catalog.pg_class AS r ON r.oid = to_regclass('public.usertable')
        JOIN pg_catalog.pg_stat_all_tables AS u ON u.relid = r.oid
        JOIN pg_catalog.pg_stat_all_tables AS t ON t.relid = r.reltoastrelid
        JOIN pg_catalog.pg_statio_all_tables AS io ON io.relid = r.oid"
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

backend::wait_idle() {
    local database="${1:-$DB_NAME}"
    local interval="${2:-20}"
    local timeout="${3:-1200}"
    local started active_backends active_count

    # Wait for backend services (autovacuum, checkpointing) to settle so that a
    # phase is not timed while background work is still running.
    log "START WAIT FOR IDLE POSTGRES database=$database"
    started=$SECONDS
    while true; do
        # One row per non-idle backend, excluding this script's own connection.
        active_backends=$(backend::exec -d "$database" -At -c \
            "SELECT backend_type, query, query_start, wait_event, state FROM pg_stat_activity WHERE state != 'idle' AND pid != pg_backend_pid();")

        # An empty result means idle. Do not count lines: printf '%s\n' "" | wc -l
        # reports 1 for the empty string, so every wait ran to its full timeout.
        if [[ -z "${active_backends//[[:space:]]/}" ]]; then
            log "END WAIT FOR IDLE POSTGRES database=$database duration=$((SECONDS-started))s"
            break
        fi
        active_count=$(printf '%s\n' "$active_backends" | grep -c .)
        if (( SECONDS - started >= timeout )); then
            log "TIMEOUT WAIT FOR IDLE POSTGRES: $active_count backend(s) are still not idle: $(printf '%s' "$active_backends" | tr '\n' '\t')"
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
