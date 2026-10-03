#!/usr/bin/env bash
# Part of a MariaDB backend module; sourced by lib/backends/mariadb_*.sh, never run directly
# and never advertised as a backend itself (the registry skips files starting with '_').
#
# Everything the MariaDB backends have in common: the admin CLI wrapper, the statistics
# snapshot (SHOW GLOBAL STATUS), preflight, dump/restore, and the size helpers derived from
# backend::size_expression. A storage-engine module supplies what differs - metadata, the
# CREATE TABLE statement, the value-size expression, connection defaults - by defining those
# contract names AFTER sourcing this file (bash keeps the later definition).
#
# The admin CLI is reachable in two ways and both must work unchanged:
#   * on the benchmark host: MARIADB_CLI=mysql, MARIADB_DUMP_CLI=mysqldump, connected over
#     DB_HOST/DB_PORT;
#   * when the server runs in a container on this machine: set MARIADB_CLI_WRAP to the
#     container command prefix. The wrapped client talks to the server through the container's
#     own socket, so host and port are not passed to it, and MariaDB 11 images only ship the
#     mariadb-* names. The password travels in MYSQL_PWD, which a container runtime does not
#     carry into the container by itself, so the wrap has to forward it explicitly:
#       MARIADB_CLI_WRAP='podman exec -i -e MYSQL_PWD ycsb-mariadb'
#       MARIADB_CLI=mariadb MARIADB_DUMP_CLI=mariadb-dump

MARIADB_CLI="${MARIADB_CLI:-mysql}"
MARIADB_DUMP_CLI="${MARIADB_DUMP_CLI:-mysqldump}"

# ---------------------------------------------------------------------------
# Statistics columns (the results CSV schema for this backend)
#
# One column per InnoDB status variable, in the order the legacy runners wrote them: the
# column name is the status variable with the Innodb_ prefix removed and lower-cased.
# btree_height is not a status variable (see backend::btree_height). Status variables that a
# newer MariaDB removed (the change-buffer and defragment counters) keep their column and
# report 0, so results stay comparable across server versions.
# ---------------------------------------------------------------------------

metric_field_names=(
    btree_height adaptive_hash_hash_searches adaptive_hash_non_hash_searches background_log_sync
    buffer_pool_dump_status buffer_pool_load_status buffer_pool_resize_status buffer_pool_load_incomplete
    buffer_pool_pages_data buffer_pool_bytes_data buffer_pool_pages_dirty buffer_pool_bytes_dirty
    buffer_pool_pages_flushed buffer_pool_pages_free buffer_pool_pages_made_not_young buffer_pool_pages_made_young
    buffer_pool_pages_misc buffer_pool_pages_old buffer_pool_pages_total buffer_pool_pages_lru_flushed
    buffer_pool_pages_lru_freed buffer_pool_pages_split buffer_pool_read_ahead_rnd buffer_pool_read_ahead
    buffer_pool_read_ahead_evicted buffer_pool_read_requests buffer_pool_reads buffer_pool_wait_free
    buffer_pool_write_requests checkpoint_age checkpoint_max_age data_fsyncs
    data_pending_fsyncs data_pending_reads data_pending_writes data_read
    data_reads data_writes data_written dblwr_pages_written
    dblwr_writes deadlocks history_list_length ibuf_discarded_delete_marks
    ibuf_discarded_deletes ibuf_discarded_inserts ibuf_free_list ibuf_merged_delete_marks
    ibuf_merged_deletes ibuf_merged_inserts ibuf_merges ibuf_segment_size
    ibuf_size log_waits log_write_requests log_writes
    lsn_current lsn_flushed lsn_last_checkpoint master_thread_active_loops
    master_thread_idle_loops max_trx_id mem_adaptive_hash mem_dictionary
    os_log_written page_size pages_created pages_read
    pages_written row_lock_current_waits row_lock_time row_lock_time_avg
    row_lock_time_max row_lock_waits num_open_files truncated_status_writes
    available_undo_logs undo_truncations page_compression_saved num_pages_page_compressed
    num_page_compressed_trim_op num_pages_page_decompressed num_pages_page_compression_error num_pages_encrypted
    num_pages_decrypted have_lz4 have_lzo have_lzma
    have_bzip2 have_snappy have_punch_hole defragment_compression_failures
    defragment_failures defragment_count instant_alter_column onlineddl_rowlog_rows
    onlineddl_rowlog_pct_used onlineddl_pct_progress encryption_rotation_pages_read_from_cache encryption_rotation_pages_read_from_disk
    encryption_rotation_pages_modified encryption_rotation_pages_flushed encryption_rotation_estimated_iops encryption_n_merge_blocks_encrypted
    encryption_n_merge_blocks_decrypted encryption_n_rowlog_blocks_encrypted encryption_n_rowlog_blocks_decrypted encryption_n_temp_blocks_encrypted
    encryption_n_temp_blocks_decrypted encryption_num_key_requests
)

# backend::metric_names -> one CSV column per statistics measurement, in snapshot order.
backend::metric_names() {
    printf '%s\n' "${metric_field_names[@]}"
}

# ---------------------------------------------------------------------------
# Admin CLI
# ---------------------------------------------------------------------------

# mariadb_cli <tool> [args...] - runs a MariaDB admin tool with the benchmark role.
# Arguments are never logged (they can carry credentials); the password travels in MYSQL_PWD.
mariadb_cli() {
    local tool="${1:?mysql or mysqldump}"
    shift
    local started=$SECONDS rc=0 arg action="snapshot" target_db=unspecified next_is_db=false
    for arg in "$@"; do
        if [[ "$next_is_db" == true ]]; then target_db="$arg"; next_is_db=false; fi
        [[ "$arg" != -D && "$arg" != --database ]] || next_is_db=true
    done
    case "$tool" in
        *dump*) action="dump" ;;
        *)
            for arg in "$@"; do
                case "$arg" in
                    -e) action="sql" ;;
                    [A-Z]*|select*|SELECT*) action="$arg" ;;
                esac
            done
            ;;
    esac
    log "START MariaDB operation tool=$tool action=$action database=$target_db"

    local -a wrap=() conn=(--user="$DB_USERNAME")
    [[ -z "${MARIADB_CLI_WRAP:-}" ]] || read -r -a wrap <<< "$MARIADB_CLI_WRAP"
    if [[ -z "${MARIADB_CLI_WRAP:-}" ]]; then
        conn+=(--host="$DB_HOST" --port="$DB_PORT" --protocol=TCP)
    fi
    MYSQL_PWD="$DB_PWD" "${wrap[@]}" "$tool" "${conn[@]}" "$@" || rc=$?
    log "END MariaDB operation tool=$tool action=$action database=$target_db status=$rc duration=$((SECONDS-started))s"
    return "$rc"
}

backend::cli() { mariadb_cli "$@"; }

# The runner's SQL calls use a small psql-style interface, so that the phase engine does not
# need one spelling per database: -d DB, -c SQL (otherwise read SQL from stdin), -At
# (unchanged output, no column names) and -F SEP. MariaDB's batch mode is tab separated, so a
# different separator is translated afterwards; values never contain tabs.
backend::exec() {
    local db="" sql="" sep="" arg
    local -a extra=() cli_args=()
    while (($#)); do
        case "$1" in
            -d) db="${2:?-- -d needs a database}"; shift 2 ;;
            -c) sql="${2:?-- -c needs SQL}"; shift 2 ;;
            -F) sep="${2:?-- -F needs a separator}"; shift 2 ;;
            -F?*) sep="${1#-F}"; shift ;;
            # psql's unaligned/no-header flags have one MariaDB spelling (added above), so the
            # combinations the runner uses are accepted and dropped here rather than passed on
            # - in particular '-t' would force table output back on.
            -A|-t|-n|-N|-B|--batch|--raw|-q|--no-align|-At|-tA|-Atq) shift ;;
            *) extra+=("$1"); shift ;;
        esac
    done
    cli_args=(--batch --skip-column-names)
    [[ -z "$db" ]] || cli_args+=(-D "$db")
    if [[ -n "$sql" ]]; then
        cli_args+=(-e "$sql")
    fi
    if [[ -n "$sep" && "$sep" != $'\t' ]]; then
        mariadb_cli "$MARIADB_CLI" "${cli_args[@]}" "${extra[@]}" | tr '\t' "$sep"
    else
        mariadb_cli "$MARIADB_CLI" "${cli_args[@]}" "${extra[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Statistics snapshot
# ---------------------------------------------------------------------------

backend::collect_metrics() {
    local db="${1:-$DB_NAME}" scope="${2:-all}"
    local name value status_name
    local -A status=()

    log "START statistics snapshot database=$db scope=$scope"
    local snapshot
    if ! snapshot=$(backend::exec -At -c 'SHOW GLOBAL STATUS;'); then
        echo "[ERROR] MariaDB statistics query failed for $db." >&2
        return 1
    fi
    while IFS=$'\t' read -r name value; do
        [[ -n "$name" ]] && status["$name"]="$value"
    done <<< "$snapshot"
    if (( ${#status[@]} == 0 )); then
        echo "[ERROR] No statistics returned for $db." >&2
        return 1
    fi

    local dbmetrics=""
    for name in "${metric_field_names[@]}"; do
        if [[ "$name" == btree_height ]]; then
            value="$(backend::btree_height)"
        else
            status_name="Innodb_$name"
            value="${status[$status_name]:-0}"
        fi
        # A CSV field cannot contain a comma; a few status values are sentences.
        value="${value//,/ }"
        printf -v "$name" '%s' "$value"
        dbmetrics+="$name=$value "
    done
    log "DB statistics $dbmetrics"

    # The stored-value size needs the benchmark table, so it is only available once a
    # database exists; preflight probes the server with scope=global.
    if [[ "$scope" != global ]]; then
        local table_size
        table_size=$(backend::total_size "$db") || return 1
        log "DB statistics value size: $table_size database=$db"
    fi
    log "END statistics snapshot database=$db statistics=${#metric_field_names[@]}"
}

# The legacy runners read the B-tree height from the tablespace file with the inno_space tool
# (sudo, plus the server's data directory). Neither is available to a benchmark run, so the
# column reports 0 unless both paths are configured explicitly.
backend::btree_height() {
    local tool="${INNO_SPACE_TOOL:-}" ibd="${INNODB_IBD_FILE:-}"
    if [[ -n "$tool" && -n "$ibd" && -x "$tool" ]]; then
        # "Btree hight" is the tool's own spelling.
        "$tool" -f "$ibd" -c index-summary 2>/dev/null |
            awk -F: '/Btree hight/ {gsub(/[[:space:]]/, "", $2); print $2; found=1}
                      END {if (!found) print 0}'
        return
    fi
    printf '0\n'
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

backend::preflight() {
    local needs_dump="$1"
    shift
    local tool version db pattern
    local seen='|'
    local -a required_tools=(java awk sed grep perl sort comm bc ps tee date mktemp "$MARIADB_CLI")
    [[ "$needs_dump" == true ]] && required_tools+=("$MARIADB_DUMP_CLI")
    for tool in "${required_tools[@]}"; do
        # A wrapped CLI (container) is checked by connecting below, not on this PATH.
        [[ -n "${MARIADB_CLI_WRAP:-}" ]] || command -v "$tool" >/dev/null 2>&1 || {
            echo "[ERROR] Required executable missing: $tool" >&2
            return 1
        }
    done
    if [[ ! -x "$YCSB" || ! -r "$WORKLOAD_FILE" || ! -r "$JDBC_PROPERTIES" ]]; then
        echo "[ERROR] YCSB launcher/config is missing, or the workload template is not readable: $WORKLOAD_FILE" >&2
        return 1
    fi
    local -a jar_patterns=()
    mapfile -t jar_patterns < <(backend::required_artifacts)
    for pattern in "${jar_patterns[@]}"; do
        if ! compgen -G "$pattern" >/dev/null; then
            echo "[ERROR] Missing build artifact: $pattern" >&2
            echo "Build from YCSB_HOME: mvn -Psource-run -pl site.ycsb:${YCSB_BINDING}-binding -am package -DskipTests, and place the MariaDB JDBC driver in $YCSB_BINDING/target/dependency/" >&2
            return 1
        fi
    done
    local account="${HOST_OS_USER:-}"
    if [[ -n "$account" ]] && ! ps -u "$account" -o pid= >/dev/null; then
        echo "[ERROR] Cannot sample the $account OS account required by these runners." >&2
        return 1
    fi

    version=$(backend::exec -At -c 'SELECT VERSION();') || return 1
    if [[ "$version" != *"MariaDB"* ]]; then
        echo "[ERROR] These runners expect a MariaDB server; got: $version" >&2
        return 1
    fi
    local min="${MIN_SERVER_VERSION:-$(registry::info min_server_version)}"
    local numeric="${version%%[!0-9.]*}"
    if [[ -z "$numeric" ]] || [[ "$(printf '%s\n%s\n' "$min" "$numeric" | sort -V | head -1)" != "$min" ]]; then
        echo "[ERROR] These runners require MariaDB >= $min; got $version." >&2
        return 1
    fi
    # Every layer of the privilege model that reports this (SHOW GRANTS,
    # information_schema.USER_PRIVILEGES) spells "ALL PRIVILEGES ON *.*" differently across
    # MariaDB versions, so the role is tested by doing the one thing the run needs. The probe
    # database is created and dropped again here; it never holds data.
    for db in "$@"; do
        if [[ ! "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || ${#db} -gt 63 ||
              "$db" == mysql || "$db" == information_schema || "$db" == performance_schema ||
              "$db" == sys || "$seen" == *"|$db|"* ]]; then
            echo "[ERROR] Unsafe or duplicate benchmark database name: $db" >&2
            return 1
        fi
        seen="$seen$db|"
    done
    local probe="${DB_NAME}_probe"
    if ! mariadb_cli "$MARIADB_CLI" -e \
        "DROP DATABASE IF EXISTS \`$probe\`; CREATE DATABASE \`$probe\`; DROP DATABASE \`$probe\`;"; then
        echo "[ERROR] Benchmark role cannot create and drop databases; each phase recreates its own." >&2
        return 1
    fi
    backend::collect_metrics "$DB_NAME" global >/dev/null || return 1
    echo "[INFO] MariaDB preflight passed on $DB_HOST:$DB_PORT (server=$version)."
}

# ---------------------------------------------------------------------------
# Databases, dump/restore
# ---------------------------------------------------------------------------

backend::init_db() {
    local db_name="$1"
    log "Initializing MariaDB database $db_name..."
    [[ "$db_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
        echo "[ERROR] Unsafe database name: $db_name" >&2
        return 1
    }
    mariadb_cli "$MARIADB_CLI" -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    mariadb_cli "$MARIADB_CLI" -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    backend::exec -d "$db_name" -c "$(backend::create_table_sql)"
    log "Done initializing $db_name."
}

backend::dump_restore() {
    local source_rows restored_rows
    : > "$RESTORE_LOG"
    source_rows=$(backend::exec -d "$DB_NAME" -At -c 'SELECT count(*) FROM usertable;') || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || return 1
    # The dump file is written by this process, never by the client's own -r: when the admin
    # CLI is wrapped in a container runtime that option writes into the container and leaves
    # the runner with nothing to restore. --single-transaction snapshots InnoDB without
    # locking tables; the dump names no database, so it can be loaded into the backup DB.
    if ! mariadb_cli "$MARIADB_DUMP_CLI" --single-transaction --skip-lock-tables \
        "$DB_NAME" > "$BACKUP_FILE" 2>> "$RESTORE_LOG"; then
        echo "[ERROR] Dump failed; see $RESTORE_LOG." >&2
        return 1
    fi
    mariadb_cli "$MARIADB_CLI" -e \
        "DROP DATABASE IF EXISTS \`$BACKUP_DB_NAME\`; CREATE DATABASE \`$BACKUP_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" || return 1
    if ! mariadb_cli "$MARIADB_CLI" -D "$BACKUP_DB_NAME" < "$BACKUP_FILE" >> "$RESTORE_LOG" 2>&1; then
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

backend::close() {
    log "MariaDB backend: no manual DB close required."
}

# ---------------------------------------------------------------------------
# Size helpers (standard SQL, shared by every MariaDB storage engine)
# ---------------------------------------------------------------------------

backend::total_size() {
    local db="${1:?database required}"
    backend::exec -d "$db" -At -F',' -c \
        "SELECT SUM($(backend::size_expression)) FROM usertable;"
}

backend::key_sizes() {
    local db="${1:?database required}" out="${2:?output file required}"
    echo "ycsb_key,size" > "$out"
    backend::exec -d "$db" -At -F',' -c \
        "SELECT ycsb_key, $(backend::size_expression) AS size FROM usertable;" >> "$out"
}

backend::list_keys() {
    local db="${1:?database required}" out="${2:?output file required}"
    backend::exec -d "$db" -At -F',' -c "SELECT ycsb_key FROM usertable;" > "$out"
}

backend::sample_key() {
    local db="${1:?database required}"
    backend::exec -d "$db" -At -c "SELECT ycsb_key FROM usertable LIMIT 1;"
}

# MariaDB spells "run it and show the real plan" as ANALYZE <statement> (10.1+); there is no
# BUFFERS option, so the timings and row counts are all this backend can report.
backend::explain_sql() {
    local db="${1:?database required}" key="${2:?key required}"
    backend::exec -d "$db" -c "ANALYZE SELECT * FROM usertable WHERE ycsb_key = '$key';"
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

# ---------------------------------------------------------------------------
# Backend defaults
# ---------------------------------------------------------------------------

mariadb::base_config() {
    local properties_default="${1:-../jdbc-binding/conf/db.properties}"

    DB_NAME="${DB_NAME:-ycsb}"
    BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
    UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
    TARGET_TABLE="${TARGET_TABLE:-usertable}"

    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-3306}"
    DB_USERNAME="${DB_USERNAME:-ycsb}"
    DB_PWD="${DB_PWD:-}"

    # MariaDB Connector/J 3.x only accepts jdbc:mariadb://; with the 2.x driver the EC2
    # runners used, set MARIADB_JDBC_SCHEME=jdbc:mysql.
    local scheme="${MARIADB_JDBC_SCHEME:-jdbc:mariadb}"
    DB_URL="$scheme://$DB_HOST:$DB_PORT/$DB_NAME"
    BACKUP_URL="$scheme://$DB_HOST:$DB_PORT/$BACKUP_DB_NAME"
    UNCHANGED_DB_URL="$scheme://$DB_HOST:$DB_PORT/$UNCHANGED_DB_NAME"
    JDBC_PROPERTIES="${JDBC_PROPERTIES:-$properties_default}"

    # The MariaDB JDBC driver is not part of the YCSB build; see conf/README.md.
    BACKEND_DRIVER_JAR="${BACKEND_DRIVER_JAR:-mariadb-java-client-*.jar}"

    # CPU/memory are sampled from the server's OS account. When the admin CLI is wrapped in a
    # container runtime the server is not a local process, so there is nothing to sample and
    # the two columns report 0 (they are real on the EC2 host).
    if [[ -n "${MARIADB_CLI_WRAP:-}" ]]; then
        HOST_OS_USER="${HOST_OS_USER:-}"
    else
        HOST_OS_USER="${HOST_OS_USER:-$(registry::info host_os_user)}"
    fi
    BACKUP_FILE="${BACKUP_FILE:-./ycsb_dump.sql}"
}

# The JDBC binding needs the MariaDB driver next to the binding's own jars.
backend::required_artifacts() {
    printf '%s\n' \
        "$YCSB_HOME/core/target/*.jar" \
        "$YCSB_HOME/core/target/dependency/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/dependency/$BACKEND_DRIVER_JAR"
}
