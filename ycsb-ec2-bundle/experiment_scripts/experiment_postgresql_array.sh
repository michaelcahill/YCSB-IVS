#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# DB names
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# PostgreSQL endpoint shared by JDBC and CLI commands
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME"
JDBC_PROPERTIES="../jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="usyd2026"
BACKUP_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$BACKUP_DB_NAME"
BACKUP_FILE="./ycsb_dump.sql"
UNCHANGE_DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$UNCHANGE_DB_NAME"

# Change naming parameters here
TYPE="postgresql_array"
DIST="zipfian" # "uniform" OR "zipfian"
SCALE="heavy" # "heavy" OR "light"
WORK="pure" # e.g. "mixed", "pure", or "spreadrun"
RUN="3"

# Define execution ID for this run, based on UTC timestamp and process ID
EXECUTION_ID="$(date -u +%Y%m%dT%H%M%SZ)_$$"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="../analysis/logs/ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Key size gathering
KEY_SIZE_LOG="../analysis/logs/key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv"
HISTOGRAM_FILE="../analysis/logs/histogram.txt"

# VACUUM settings
vacuum=1

# Plan log file
PLAN_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_query_plan.log"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="zipfian"
# Optional specific request distributions for each operation
readrequestdistribution_extend="zipfian"
updaterequestdistribution_extend="zipfian"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"
# Optional specific request distributions for each operation
readrequestdistribution_postextend="uniform"
updaterequestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="100000"

# Begin local PG18 support functions.
PG_MAINTENANCE_DB="${PG_MAINTENANCE_DB:-postgres}"

# PG18 statistics collection
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

binding_field_names=("${global_metric_names[@]}")

for prefix in usertable toast; do
    for metric in "${table_metric_names[@]}"; do
        binding_field_names+=("${prefix}_${metric}")
    done
done

binding_field_names+=(toast_n_tup_ins toast_n_tup_del)

binding_field_names+=(
    usertable_heap_blks_read usertable_heap_blks_hit usertable_idx_blks_read usertable_idx_blks_hit
    toast_blks_read toast_blks_hit tidx_blks_read tidx_blks_hit
)

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

pg_exec() {
    # Ignore user psqlrc formatting and stop on SQL errors, including stdin/-f.
    pg_cli psql -X -q -v ON_ERROR_STOP=1 "$@"
}

collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"
    local scope="${2:-all}" output value field index metric alias
    local extra_select="" extra_joins=""
    local -a values names=("${global_metric_names[@]}")
    if [[ "$scope" == all ]]; then
        names=("${binding_field_names[@]}")
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
    if ! output=$(pg_exec -d "$db" -At -F '|' -c "
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
    for index in "${!names[@]}"; do
        printf -v "${names[$index]}" '%s' "${values[$index]}"
    done
    log "END statistics snapshot database=$db columns=${#names[@]}"
}

postgres_preflight() {
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
    if [[ ! -x "$YCSB" || ! -r "$WORKLOAD_FILE" || ! -w "$WORKLOAD_FILE" || ! -r "$JDBC_PROPERTIES" ]]; then
        echo "[ERROR] YCSB launcher/config is missing, or workload is not readable/writable." >&2
        return 1
    fi
    for pattern in "$YCSB_HOME/core/target/*.jar" \
                   "$YCSB_HOME/core/target/dependency/*.jar" \
                   "$YCSB_HOME/jdbc-array/target/*.jar" \
                   "$YCSB_HOME/jdbc-array/target/dependency/postgresql-*.jar"; do
        if ! compgen -G "$pattern" >/dev/null; then
            echo "[ERROR] Missing build artifact: $pattern" >&2
            echo "Build from YCSB_HOME: mvn -Psource-run -pl site.ycsb:jdbc-array-binding -am package -DskipTests" >&2
            return 1
        fi
    done
    if ! ps -u postgres -o pid= >/dev/null; then
        echo "[ERROR] Cannot sample the postgres OS account required by these runners." >&2
        return 1
    fi
    for tool in psql createdb dropdb; do
        version=$("$tool" --version) || return 1
        if [[ ! "$version" =~ PostgreSQL\)[[:space:]]18([.]|[[:space:]]|$) ]]; then
            echo "[ERROR] $tool must be PostgreSQL 18: $version" >&2
            return 1
        fi
    done
    if [[ "$needs_dump" == true ]]; then
        version=$(pg_dump --version) || return 1
        if [[ ! "$version" =~ PostgreSQL\)[[:space:]]18([.]|[[:space:]]|$) ]]; then
            echo "[ERROR] pg_dump must be PostgreSQL 18: $version" >&2
            return 1
        fi
    fi
    server_version=$(pg_exec -d "$PG_MAINTENANCE_DB" -At -c 'SHOW server_version_num;') || return 1
    if [[ ! "$server_version" =~ ^18[0-9]{4}$ ]]; then
        echo "[ERROR] These runners require a PostgreSQL 18 server; got $server_version." >&2
        return 1
    fi
    allowed=$(pg_exec -d "$PG_MAINTENANCE_DB" -At -c \
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
        owner=$(pg_exec -d "$PG_MAINTENANCE_DB" -At -c "
            SELECT pg_has_role(current_user, datdba, 'USAGE')
            FROM pg_catalog.pg_database WHERE datname = '$db';") || return 1
        if [[ -n "$owner" && "$owner" != t ]]; then
            echo "[ERROR] Benchmark role does not own existing database $db." >&2
            return 1
        fi
    done
    track_counts=$(pg_exec -d "$PG_MAINTENANCE_DB" -At -c 'SHOW track_counts;') || return 1
    if [[ "$track_counts" != on ]]; then
        echo "[ERROR] track_counts must be on to collect table statistics." >&2
        return 1
    fi
    # Probe globals in the maintenance DB; it has no benchmark table yet.
    collect_postgres_metrics "$PG_MAINTENANCE_DB" global || return 1
    echo "[INFO] PG18 preflight passed on $DB_HOST:$DB_PORT (server_version_num=$server_version)."
}

restore_comparison_database() {
    local source_rows restored_rows
    : > "$RESTORE_LOG"
    source_rows=$(pg_exec -d "$DB_NAME" -At -c 'SELECT count(*) FROM usertable;') || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || return 1
    # A fresh target does not need --clean DROP statements. Keep dump/log on failure.
    if ! pg_cli pg_dump -d "$DB_NAME" > "$BACKUP_FILE" 2>> "$RESTORE_LOG"; then
        echo "[ERROR] Dump failed; see $RESTORE_LOG." >&2
        return 1
    fi
    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$BACKUP_DB_NAME" || return 1
    pg_cli createdb "$BACKUP_DB_NAME" || return 1
    if ! pg_exec -d "$BACKUP_DB_NAME" -f "$BACKUP_FILE" >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] Restore failed; see $RESTORE_LOG. Dump retained at $BACKUP_FILE." >&2
        return 1
    fi
    restored_rows=$(pg_exec -d "$BACKUP_DB_NAME" -At -c 'SELECT count(*) FROM usertable;') || return 1
    if [[ "$restored_rows" != "$source_rows" ]]; then
        echo "[ERROR] Restore row count mismatch: source=$source_rows target=$restored_rows." >&2
        return 1
    fi
    echo "[INFO] Restore verified: $restored_rows rows." >> "$RESTORE_LOG"
}
# End local PG18 support functions.
stats_header="CPU,Memory,$(IFS=','; echo "${binding_field_names[*]}")"

# stderr keeps diagnostics out of captured SQL results and raw YCSB CSV.
log() {
    case "$*" in
        "START experiment "*|"END experiment "*|\
        "START preflight"|"END preflight"|\
        "START YCSB "*|"END YCSB "*|\
        "START VACUUM"*|"END VACUUM"*|\
        "Initializing PostgreSQL database "*|"Done initializing "*|\
        "Backing up the database started"|"Backing up the database finished"|\
        "Log file: "*|"Result CSV: "*|"Download this log from EC2: "*|\
        *ERROR*|*WARNING*|Warning:*)
            printf '[epoch=%s run=%s phase=%s] %s\n' \
                "${epoch:-0}" "${run:-0}" "${phase:-setup}" "$*" >&2
            ;;
        *)
            return 0
            ;;
    esac
}

start_logging() {
    EXECUTION_ID="${EXECUTION_ID:-$(date -u +%Y%m%dT%H%M%SZ)_$$}"

    mkdir -p "$(dirname "$LOG_FILE")"
    LOG_FILE="$(cd "$(dirname "$LOG_FILE")" && pwd)/$(basename "$LOG_FILE")"
    : > "$LOG_FILE"

    LOGGER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ycsb-logger.XXXXXX")
    if ! mkfifo "$LOGGER_DIR/stream"; then
        rmdir "$LOGGER_DIR"
        return 1
    fi

    # Save the original terminal output descriptors.
    exec 3>&1 4>&2

    # Start the reader BEFORE redirecting the script's output.
    (
        trap - EXIT ERR INT TERM
        set -o pipefail

        perl -MPOSIX=strftime -ne '
            BEGIN { $| = 1; }
            print strftime("[%Y-%m-%d %H:%M:%S UTC] ", gmtime), $_;
        ' < "$LOGGER_DIR/stream" | tee -a "$LOG_FILE"
    ) &
    LOGGER_PID=$!

    EXPERIMENT_STARTED=$SECONDS
    EXPERIMENT_COMPLETED=0

    exec > "$LOGGER_DIR/stream" 2>&1

    trap 'log "ERROR status=$? line=$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'finish_logging "$?"' EXIT

    log "START experiment execution=$EXECUTION_ID host=$DB_HOST port=$DB_PORT"
    log "Log file: $LOG_FILE"
    log "Result CSV: $OUTPUT_FILE"
}

# Continuous, opt-in monitoring covers extend, VACUUM and comparison preparation.
WATCHER_ENABLED="${WATCHER_ENABLED:-0}"
WATCHER_INTERVAL="${WATCHER_INTERVAL:-5}"
WATCHER_PID=""
watcher_command() {
    PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGUSER="$DB_USERNAME" \
    PGPASSWORD="$DB_PWD" PGDATABASE="$1" \
        python3 "$SCRIPT_DIR/watch_postgresql18.py" "${@:2}"
}
start_runtime_watcher() {
    [[ "$WATCHER_ENABLED" == 1 ]] || return 0
    WATCHER_OUTPUT="${LOG_FILE%.log}_${EXECUTION_ID}_watcher.jsonl"
    PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGUSER="$DB_USERNAME" \
    PGPASSWORD="$DB_PWD" PGDATABASE="$DB_NAME" \
    python3 "$SCRIPT_DIR/watch_postgresql18.py" --interval "$WATCHER_INTERVAL" --output "$WATCHER_OUTPUT" \
        > "${WATCHER_OUTPUT%.jsonl}.log" 2>&1 &
    WATCHER_PID=$!
}
stop_runtime_watcher() {
    [[ -n "$WATCHER_PID" ]] || return 0
    if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
        wait "$WATCHER_PID" || true
        log "ERROR runtime watcher stopped prematurely; inspect ${WATCHER_OUTPUT%.jsonl}.log"
        WATCHER_PID=""
        return 1
    fi
    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" || true
    WATCHER_PID=""
}

finish_logging() {
    local rc="$1"
    local logger_rc=0

    trap - EXIT ERR INT TERM
    stop_runtime_watcher || rc=1

    # Prevent premature exits from being reported as successful.
    if (( rc == 0 )) && [[ "${EXPERIMENT_COMPLETED:-0}" != 1 ]]; then
        rc=1
        log "ERROR experiment exited before its completion marker"
    fi

    log "END experiment status=$rc duration=$((SECONDS-EXPERIMENT_STARTED))s"
    log "Download this log from EC2: $LOG_FILE"

    # Close the pipe's writer, then wait for the logger to finish.
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$LOGGER_PID" || logger_rc=$?

    rm -f "$LOGGER_DIR/stream"
    rmdir "$LOGGER_DIR"

    if (( logger_rc != 0 )); then
        printf 'Log writer failed (status=%s): %s\n' \
            "$logger_rc" "$LOG_FILE" >&2
        if (( rc == 0 )); then
            rc=$logger_rc
        fi
    fi

    exit "$rc"
}

run_ycsb() {
    local label="$1" started=$SECONDS rc=0
    local detail_file
    shift

    detail_file="${LOG_FILE%.log}_epoch${epoch:-0}_step${run:-0}_${label}.raw.log"

    log "START YCSB $label"

    # Preserve raw output for CSV parsing and retain a separate detailed file.
    # Do not copy it into the main experiment log.
    "$YCSB" "$@" 2>&1 |
        tee "$OUTPUT_CSV" "$detail_file" > /dev/null || rc=$?

    log "END YCSB $label status=$rc duration=$((SECONDS-started))s"

    if (( rc != 0 )); then
        log "ERROR YCSB $label failed; details=$detail_file"
    fi

    return "$rc"
}

# Initialize PostgreSQL database
initialize_database() {
    local db_name="$1"
    log "Initializing PostgreSQL database $db_name..."

    pg_cli dropdb --maintenance-db="$PG_MAINTENANCE_DB" --if-exists "$db_name"
    pg_cli createdb "$db_name"

    pg_exec -d "$db_name" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 TEXT[], field1 TEXT[], field2 TEXT[], field3 TEXT[], field4 TEXT[],
            field5 TEXT[], field6 TEXT[], field7 TEXT[], field8 TEXT[], field9 TEXT[]
        );"

    log "Done initializing $db_name."
}

# Function to write results as a csv 
write_result() {
    local first="$1" field_name postgres_stats_csv base_header previous temp_result r
    local -a postgres_stats=("$cpu" "$memory")
    for field_name in "${binding_field_names[@]}"; do
        postgres_stats+=("${!field_name}")
    done
    postgres_stats_csv=$(IFS=','; echo "${postgres_stats[*]}")
    r=$((10 * (${epoch:-1} - 1) + ${run:-0}))
    [[ "$phase" != load ]] || r=0
    base_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,$stats_header,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
    previous="$OUTPUT_FILE"
    [[ "$first" != TRUE ]] || previous=/dev/null
    temp_result=$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")
    log "START CSV write database statistics phase=$phase"
    if ! awk -F, -v OFS=, -v base="$base_header" -v previous="$previous" \
        -v step="$r" -v phase="$phase" -v records="${recordcount:-}" \
        -v allfields="${readallfields:-}" -v distribution="${requestdistribution:-}" \
        -v readdist="${readrequestdistribution:-}" -v updatedist="${updaterequestdistribution:-}" \
        -v stats="$postgres_stats_csv" -v readprop="${readproportion:-}" \
        -v updateprop="${updateproportion:-}" -v scanprop="${scanproportion:-}" \
        -v insertprop="${insertproportion:-}" -v extendprop="${extendproportion:-}" '
        function trim(x) { sub(/^[[:space:]]+/, "", x); sub(/[[:space:]]+$/, "", x); return x }
        BEGIN { base_count=split(base, base_fields, ",") }
        FILENAME == previous {
            if (FNR == 1) {
                for (i=base_count+1; i<=NF; i++) { labels[++nlabels]=$i; known[$i]=1 }
                old_width=NF
            } else { old[++nold]=$0 }
            next
        }
        /^\[(OVERALL|INSERT|READ|UPDATE|SCAN|EXTEND|READ-MODIFY-WRITE)\],/ {
            op=trim($1); gsub(/[][]/, "", op)
            label=trim($2); value=trim($3)
            if (op == "OVERALL") { overall[label]=value; next }
            if (!(op in seen)) { operations[++nops]=op; seen[op]=1 }
            if (!(label in known)) { labels[++nlabels]=label; known[label]=1 }
            measurements[op,label]=value
        }
        END {
            if (!nops || !("RunTime(ms)" in overall) || !("Throughput(ops/sec)" in overall)) {
                print "[ERROR] Missing YCSB operation/overall metrics; CSV left unchanged." > "/dev/stderr"
                exit 1
            }
            printf "%s", base
            for (i=1; i<=nlabels; i++) printf ",%s", labels[i]
            printf "\n"
            for (j=1; j<=nold; j++) {
                printf "%s", old[j]
                for (i=old_width+1; i<=base_count+nlabels; i++) printf ","
                printf "\n"
            }
            for (j=1; j<=nops; j++) {
                op=operations[j]; dist=distribution
                if (op == "READ" && readdist != "") dist=readdist
                if (op == "UPDATE" && updatedist != "") dist=updatedist
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s", \
                    step, phase, records, allfields, dist, op, stats, readprop, updateprop, \
                    scanprop, insertprop, extendprop, overall["RunTime(ms)"], overall["Throughput(ops/sec)"]
                for (i=1; i<=nlabels; i++) printf ",%s", measurements[op,labels[i]]
                printf "\n"
            }
        }
    ' "$previous" "$INPUT_FILE" > "$temp_result"; then
        rm -f "$temp_result"
        return 1
    fi
    mv "$temp_result" "$OUTPUT_FILE"
    log "END CSV write output=$OUTPUT_FILE"
}

# Function to close the PostgreSQL database
close_db() {
    log "PostgreSQL backend: no manual DB close required."
}

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    log "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    log "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

# Generate histogram from key size log
get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    log "Generating histogram from key size log: $key_size_log"

    awk -F, '
        BEGIN {
            block = 100
            OFS = "\t"
        }
        NR == 1 { next }  # Skip header
        {
            size = $2 + 0
            bucket = int(size / (block * 10 ))   #Converting value length to field length as there are 10 fields
            histogram[bucket]++
            if (bucket > max_bucket) max_bucket = bucket
        }
        END {
            print "BlockSize", block > "'"$histogram_file"'"
            for (i = 0; i <= max_bucket; i++) {
                count = (i in histogram) ? histogram[i] : 0
                print i, count >> "'"$histogram_file"'"
            }
        }
    ' "$key_size_log"

    log "Histogram written to $histogram_file (BlockSize = 100)"
}

# All read-only checks must finish before clearing outputs or dropping databases.
start_logging
log "START preflight"
postgres_preflight true "$DB_NAME" "$UNCHANGE_DB_NAME" "$BACKUP_DB_NAME"
if [[ "$WATCHER_ENABLED" == 1 ]]; then
    watcher_command "$PG_MAINTENANCE_DB" --check --interval "$WATCHER_INTERVAL"
fi
log "END preflight"
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$KEY_SIZE_FILE_AFTER_EXTEND")"

# Clear the log file and previous backups
> $PLAN_LOG
> $HISTOGRAM_FILE

rm -rf $KEY_SIZE_LOG
rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"

initialize_database "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"
start_runtime_watcher

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
# Extract workload parameters for load phase
source "$WORKLOAD_FILE"
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readrequestdistribution=${readrequestdistribution:-""}
updaterequestdistribution=${updaterequestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_ycsb "initial-load" load jdbc-array -s \
    -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
    -p db.url="$DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD" \
    -p fieldlengthdistribution=constant \
    -p fieldlength="$fieldlengthoriginal"
total_size_initial_load=$(pg_exec -d "$DB_NAME" -At -F"," -c "SELECT SUM(octet_length(coalesce(array_to_string(field0, ''), '')) + octet_length(coalesce(array_to_string(field1, ''), '')) + octet_length(coalesce(array_to_string(field2, ''), '')) + octet_length(coalesce(array_to_string(field3, ''), '')) + octet_length(coalesce(array_to_string(field4, ''), '')) + octet_length(coalesce(array_to_string(field5, ''), '')) + octet_length(coalesce(array_to_string(field6, ''), '')) + octet_length(coalesce(array_to_string(field7, ''), '')) + octet_length(coalesce(array_to_string(field8, ''), '')) + octet_length(coalesce(array_to_string(field9, ''), ''))) FROM usertable;")
log "Initial-load verification - TotalSize:$total_size_initial_load ExpectedFieldLength:$fieldlengthoriginal"
cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
collect_postgres_metrics $DB_NAME
write_result "TRUE"

# Load unchange value size (reference) DB
phase="reference-load"
run_ycsb "reference-load" load jdbc-array -s \
    -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
    -p db.url="$UNCHANGE_DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD" \
    -p fieldlengthdistribution=constant \
    -p fieldlength="$fieldlengthoriginal"
total_size_reference_load=$(pg_exec -d "$UNCHANGE_DB_NAME" -At -F"," -c "SELECT SUM(octet_length(coalesce(array_to_string(field0, ''), '')) + octet_length(coalesce(array_to_string(field1, ''), '')) + octet_length(coalesce(array_to_string(field2, ''), '')) + octet_length(coalesce(array_to_string(field3, ''), '')) + octet_length(coalesce(array_to_string(field4, ''), '')) + octet_length(coalesce(array_to_string(field5, ''), '')) + octet_length(coalesce(array_to_string(field6, ''), '')) + octet_length(coalesce(array_to_string(field7, ''), '')) + octet_length(coalesce(array_to_string(field8, ''), '')) + octet_length(coalesce(array_to_string(field9, ''), ''))) FROM usertable;")
log "Reference-load verification - TotalSize:$total_size_reference_load ExpectedFieldLength:$fieldlengthoriginal"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Execute the extend phase
        log "=== Executing the extend phase with extendproportion=1 and other proportions=0 ==="
        phase="extend"
        # Capture both stdout and stderr to capture status messages
        run_ycsb "extend" run jdbc-array -s \
            -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
            -p db.url="$DB_URL" \
            -p db.user="$DB_USERNAME" \
            -p db.passwd="$DB_PWD" \
            -p fieldlengthdistribution=constant \
            -p fieldlength="$fieldlengthoriginal"        
        # Extract extend failure count from YCSB output (status messages are in the output)
        extend_failed_count=$(grep -oP 'EXTEND-FAILED: Count=\K\d+' "$OUTPUT_CSV" 2>/dev/null | head -1 || echo "0")
        if [ -n "$extend_failed_count" ] && [ "$extend_failed_count" != "0" ]; then
            log "WARNING: $extend_failed_count EXTEND operations failed during extend phase"
        fi
        
        cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
        memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

        # Key Sizes
        log "Size computation started"
        echo "ycsb_key,size" > "$KEY_SIZE_LOG"
        pg_exec -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key,
            octet_length(coalesce(array_to_string(field0, ''), '')) +
            octet_length(coalesce(array_to_string(field1, ''), '')) +
            octet_length(coalesce(array_to_string(field2, ''), '')) +
            octet_length(coalesce(array_to_string(field3, ''), '')) +
            octet_length(coalesce(array_to_string(field4, ''), '')) +
            octet_length(coalesce(array_to_string(field5, ''), '')) +
            octet_length(coalesce(array_to_string(field6, ''), '')) +
            octet_length(coalesce(array_to_string(field7, ''), '')) +
            octet_length(coalesce(array_to_string(field8, ''), '')) +
            octet_length(coalesce(array_to_string(field9, ''), '')) AS size
            FROM usertable;" \
        >> "$KEY_SIZE_LOG"
        
        # Verify extend operations: check min, max, avg sizes to detect extension failures
        extend_stats=$(awk -F, '
            NR == 1 { next }
            {
                sizes[NR-1] = $2
                sum += $2
                count++
            }
            END {
                if (count > 0) {
                    avg = sum / count
                    min = sizes[1]
                    max = sizes[1]
                    for (i = 2; i <= count; i++) {
                        if (sizes[i] < min) min = sizes[i]
                        if (sizes[i] > max) max = sizes[i]
                    }
                    printf "Min:%d Max:%d Avg:%.0f", min, max, avg
                }
            }
        ' "$KEY_SIZE_LOG")
        log "Extend verification - $extend_stats (Expected avg per record: ~$((10 * fieldlengthoriginal)) bytes initially)"

        log "END size computation database=$DB_NAME"

        get_key_sizes $KEY_SIZE_LOG $HISTOGRAM_FILE

        # Check if the output file exists, if not, create it with headers
        iteration=$((10*($epoch-1)+$run))

        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            # Add header row
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # If it's the first iteration, append keys and sizes for the first run
        if [[ "$iteration" -eq 1 ]]; then
            append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        else
            append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        fi

        if [[ $vacuum -eq 1 ]]; then
            vacuum_started=$SECONDS
            vacuum_rc=0
            vacuum_detail="${LOG_FILE%.log}_epoch${epoch}_step${run}_vacuum.raw.log"

            log "START VACUUM ANALYZE database=$DB_NAME"

            pg_exec -d "$DB_NAME" \
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

            log "END VACUUM ANALYZE database=$DB_NAME status=$vacuum_rc duration=$((SECONDS-vacuum_started))s"

            if (( vacuum_rc != 0 )); then
                log "ERROR VACUUM failed; details=$vacuum_detail"
                exit "$vacuum_rc"
            fi
        fi

        phase="run-setup"
        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Save the existing keys in the database
        pg_exec -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Log query plan before run phase
        log "Checking query plan before run phase"

        TEST_KEY=$(pg_exec -d "$DB_NAME" -At -c \
        "SELECT ycsb_key FROM usertable LIMIT 1;")

        {
            echo "========================================"
            echo "Epoch=$epoch Run=$run Phase=run Time=$(date)"
            echo "DB=$DB_NAME"
            echo "Key=$TEST_KEY"
            echo "----------------------------------------"

            pg_exec -d "$DB_NAME" -c "
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT * FROM usertable WHERE ycsb_key = '$TEST_KEY';
            "

            echo
        } >> "$PLAN_LOG"
        log "END query plan"

        # Execute the run phase
        log "Preparing run workload: read=$readproportion update=$updateproportion extend=$extendproportion"
        phase="run"
        run_ycsb "run" run jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE"
        cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
        memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        pg_exec -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | pg_exec -d "$DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        pg_exec -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Reference workload with unchanging value sizes
        phase="reference"
        run_ycsb "reference" run jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$UNCHANGE_DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE"
        cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
        memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
        collect_postgres_metrics $UNCHANGE_DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        pg_exec -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | pg_exec -d "$UNCHANGE_DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt
    
        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"
            
            log "Backing up the database started"
            RESTORE_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_epoch${epoch}_step${run}_restore.log"
            restore_comparison_database
            log "Backing up the database finished"

            run_ycsb "clean-run" run jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE"
            cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
            memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
            collect_postgres_metrics $BACKUP_DB_NAME
            rm -rf "$BACKUP_FILE"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            log "Size computation started"
            echo "ycsb_key,size" > "$KEY_SIZE_LOG"
            pg_exec -d "$BACKUP_DB_NAME" -At -F"," \
            -c "SELECT ycsb_key,
                octet_length(coalesce(array_to_string(field0, ''), '')) +
                octet_length(coalesce(array_to_string(field1, ''), '')) +
                octet_length(coalesce(array_to_string(field2, ''), '')) +
                octet_length(coalesce(array_to_string(field3, ''), '')) +
                octet_length(coalesce(array_to_string(field4, ''), '')) +
                octet_length(coalesce(array_to_string(field5, ''), '')) +
                octet_length(coalesce(array_to_string(field6, ''), '')) +
                octet_length(coalesce(array_to_string(field7, ''), '')) +
                octet_length(coalesce(array_to_string(field8, ''), '')) +
                octet_length(coalesce(array_to_string(field9, ''), '')) AS size
                FROM usertable;" \
            >> "$KEY_SIZE_LOG"
            
            log "END size computation database=$BACKUP_DB_NAME"

            # Check if the output file exists, if not, create it with headers
            iteration=$((10*($epoch-1)+$run))
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                # Add header row
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # If it's the first iteration, append keys and sizes for the first run
            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            else
                append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # PostgreSQL query to get the total size of all records
            total_size=$(pg_exec -d "$BACKUP_DB_NAME" -At -F"," \
            -c "SELECT SUM(
                octet_length(coalesce(array_to_string(field0, ''), '')) +
                octet_length(coalesce(array_to_string(field1, ''), '')) +
                octet_length(coalesce(array_to_string(field2, ''), '')) +
                octet_length(coalesce(array_to_string(field3, ''), '')) +
                octet_length(coalesce(array_to_string(field4, ''), '')) +
                octet_length(coalesce(array_to_string(field5, ''), '')) +
                octet_length(coalesce(array_to_string(field6, ''), '')) +
                octet_length(coalesce(array_to_string(field7, ''), '')) +
                octet_length(coalesce(array_to_string(field8, ''), '')) +
                octet_length(coalesce(array_to_string(field9, ''), ''))
            ) FROM usertable;")

            # Set average field length
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            log "Total size: $total_size, Field length average: $fieldlengthaverage"

            # Changing the value size for comparison
            if grep -q '^fieldlength=' "$WORKLOAD_FILE"; then
                perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            else
                echo "fieldlength=$fieldlengthaverage" >> "$WORKLOAD_FILE"
            fi
            source "$WORKLOAD_FILE"
            # Verify fieldlength was set correctly
            actual_fieldlength=$(grep -E '^fieldlength=' "$WORKLOAD_FILE" | cut -d'=' -f2)
            log "Workload file fieldlength set to: $actual_fieldlength (expected: $fieldlengthaverage)"

            pg_exec -d "$BACKUP_DB_NAME" \
            -c "TRUNCATE TABLE usertable;"

            # Resetting the database with new data load
            phase="comparison-load"
            log "=== Executing the load phase for the comparison study ==="
            run_ycsb "comparison-load" load jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD"
            total_size_comparison_load=$(pg_exec -d "$BACKUP_DB_NAME" -At -F"," -c "SELECT SUM(octet_length(coalesce(array_to_string(field0, ''), '')) + octet_length(coalesce(array_to_string(field1, ''), '')) + octet_length(coalesce(array_to_string(field2, ''), '')) + octet_length(coalesce(array_to_string(field3, ''), '')) + octet_length(coalesce(array_to_string(field4, ''), '')) + octet_length(coalesce(array_to_string(field5, ''), '')) + octet_length(coalesce(array_to_string(field6, ''), '')) + octet_length(coalesce(array_to_string(field7, ''), '')) + octet_length(coalesce(array_to_string(field8, ''), '')) + octet_length(coalesce(array_to_string(field9, ''), ''))) FROM usertable;")
            log "Comparison-load verification - Epoch:$epoch Run:$run TotalSize:$total_size_comparison_load ExpectedFieldLength:$fieldlengthaverage"

            # Verify record sizes after avg-run load
            iteration=$((10*($epoch-1)+$run))
            total_size_avg_run=$(pg_exec -d "$BACKUP_DB_NAME" -At -F"," -c "SELECT SUM(octet_length(coalesce(array_to_string(field0, ''), '')) + octet_length(coalesce(array_to_string(field1, ''), '')) + octet_length(coalesce(array_to_string(field2, ''), '')) + octet_length(coalesce(array_to_string(field3, ''), '')) + octet_length(coalesce(array_to_string(field4, ''), '')) + octet_length(coalesce(array_to_string(field5, ''), '')) + octet_length(coalesce(array_to_string(field6, ''), '')) + octet_length(coalesce(array_to_string(field7, ''), '')) + octet_length(coalesce(array_to_string(field8, ''), '')) + octet_length(coalesce(array_to_string(field9, ''), ''))) FROM usertable;")
            log "Avg-run verification - Epoch:$epoch Run:$run Iteration:$iteration TotalSize:$total_size_avg_run ExpectedFieldLength:$fieldlengthaverage"
            
            # Chainging the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "Preparing run workload: read=$readproportion update=$updateproportion extend=$extendproportion"
            phase="avg-run"
            run_ycsb "avg-run" run jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD"
            cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
            memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
            collect_postgres_metrics $BACKUP_DB_NAME
            write_result "FALSE"
        fi
        log "END iteration"
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
EXPERIMENT_COMPLETED=1
