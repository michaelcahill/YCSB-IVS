#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# DB names
DB_NAME="ycsb"
UNCHANGE_DB_NAME="ycsb_unchange"

# DB URLs
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME"
UNCHANGE_DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$UNCHANGE_DB_NAME"
JDBC_PROPERTIES="../jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="USyd2025"

# Change naming parameters here
TYPE="postgresql_array"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="heavy" # "heavy" OR "light"
WORK="spreadrun" # e.g. "mixed", "pure", or "spreadrun"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Baseline_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Extend phase experiment parameters
extendproportion_extend="0"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="1"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"

# Begin local PG18 support functions.
PG_MAINTENANCE_DB="${PG_MAINTENANCE_DB:-postgres}"

# Keep legacy column names for analysis consumers; the removed backend counter
# is explicitly NA. checkpoints_done is PG18's count of completed checkpoints.
binding_field_names=(
    blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated
    tup_deleted deadlocks temp_files temp_bytes checkpoints_timed checkpoints_req
    checkpoints_done buffers_checkpoint buffers_clean buffers_backend buffers_alloc
    checkpoint_write_time checkpoint_sync_time wal_bytes wal_records wal_fpi wal_buffers_full
)

pg_cli() {
    local tool="$1"
    shift
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        "$tool" --host="$DB_HOST" --port="$DB_PORT" --username="$DB_USERNAME" \
        --no-password "$@"
}

pg_exec() {
    # Ignore user psqlrc formatting and stop on SQL errors, including stdin/-f.
    pg_cli psql -X -v ON_ERROR_STOP=1 "$@"
}

collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"
    local output value field index
    local -a values
    # Capture the exit status BEFORE read: read <<< $(psql ...) hides SQL errors.
    if ! output=$(pg_exec -d "$db" -At -F '|' -c "
        SELECT d.blks_read, d.blks_hit, d.tup_returned, d.tup_fetched,
               d.tup_inserted, d.tup_updated, d.tup_deleted, d.deadlocks,
               d.temp_files, d.temp_bytes, c.num_timed, c.num_requested,
               c.num_done, c.buffers_written, b.buffers_clean, 'NA', b.buffers_alloc,
               c.write_time, c.sync_time, w.wal_bytes, w.wal_records,
               w.wal_fpi, w.wal_buffers_full
        FROM pg_catalog.pg_stat_database AS d
        CROSS JOIN pg_catalog.pg_stat_checkpointer AS c
        CROSS JOIN pg_catalog.pg_stat_bgwriter AS b
        CROSS JOIN pg_catalog.pg_stat_wal AS w
        WHERE d.datname = current_database();"); then
        echo "[ERROR] PostgreSQL metrics query failed for $db." >&2
        return 1
    fi
    if [[ -z "$output" || "$output" == *$'\n'* ]]; then
        echo "[ERROR] Expected one metrics row for $db." >&2
        return 1
    fi
    IFS='|' read -r -a values <<< "$output"
    if [[ ${#values[@]} -ne ${#binding_field_names[@]} ]]; then
        echo "[ERROR] Unexpected metrics column count for $db." >&2
        return 1
    fi
    # Validate everything before publishing any values to the CSV writer.
    for index in "${!binding_field_names[@]}"; do
        field="${binding_field_names[$index]}"
        value="${values[$index]}"
        if [[ "$field" == buffers_backend ]]; then
            [[ "$value" == NA ]] || return 1
        elif [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "[ERROR] Missing or invalid metric $field for $db." >&2
            return 1
        fi
    done
    for index in "${!binding_field_names[@]}"; do
        printf -v "${binding_field_names[$index]}" '%s' "${values[$index]}"
    done
}

postgres_preflight() {
    local needs_dump="$1"
    shift
    local tool version server_version allowed db owner pattern seen='|'
    local -a required_tools=(psql createdb dropdb java awk sed grep perl sort comm bc ps)
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
    # Read-only probe of the exact metrics query, before any database is dropped.
    collect_postgres_metrics "$PG_MAINTENANCE_DB" || return 1
    echo "[INFO] PG18 preflight passed on $DB_HOST:$DB_PORT (server_version_num=$server_version)."
}
# End local PG18 support functions.

log() {
    echo "$1" | tee -a $LOG_FILE
}

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

close_db() {
    log "PostgreSQL backend: no manual DB close required."
}


measure_stats() {
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum+0}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum+0}')
    collect_postgres_metrics "$DB_NAME"
}

run_ycsb_load() {
    $YCSB load jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
        -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > "$OUTPUT_CSV"
}

run_ycsb_run() {
    $YCSB run jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
        -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > "$OUTPUT_CSV"
}

# Generate stats_header from binding_field_names
stats_header="CPU,Memory,$(IFS=','; echo "${binding_field_names[*]}")"

# Constant headers (not database-specific)
common_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation"
prop_header="Readprop,Updateprop,Scanprop,Insertprop,Extendprop"
runtime_header="Runtime(ms),Throughput(ops/sec)"

extract_dynamic_fields() {
    local filtered_output="$1"
    awk '{print $2}' <<< "$filtered_output" \
    | sed 's/,$//' \
    | uniq \
    | awk '{ORS=","; print}' \
    | sed 's/,$//'
}

write_result() {
    local first="$1"
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then
        dynamic_fields_header=$(extract_dynamic_fields "$filtered_output")
        if [ -n "$dynamic_fields_header" ]; then
            header="$common_header,$stats_header,$prop_header,$runtime_header,$dynamic_fields_header"
        else
            header="$common_header,$stats_header,$prop_header,$runtime_header"
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    epoch=${epoch:-0}
    run=${run:-0}
    epoch=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    run=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * (epoch - 1) + run))
    fi

    recordcount=${recordcount:-""}
    readallfields=${readallfields:-""}
    requestdistribution=${requestdistribution:-""}
    readproportion=${readproportion:-""}
    updateproportion=${updateproportion:-""}
    scanproportion=${scanproportion:-""}
    insertproportion=${insertproportion:-""}
    extendproportion=${extendproportion:-""}

    run_specific=()
    while IFS= read -r inner_line; do
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    operation=""
    while IFS= read -r line; do
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        common_fields=(
            "$r"
            "$phase"
            "$recordcount"
            "$readallfields"
            "$requestdistribution"
            "$operation"
        )

        binding_fields=("$cpu" "$memory")
        for field_name in "${binding_field_names[@]}"; do
            binding_fields+=("${!field_name}")
        done

        prop_fields=(
            "$readproportion"
            "$updateproportion"
            "$scanproportion"
            "$insertproportion"
            "$extendproportion"
        )

        dynamic_fields=("${run_specific[@]}" "$third_value")

        if [ $k -eq 1 ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )
            values_1=$(IFS=','; echo "${row_fields[*]}")
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )
            values_2=$(IFS=','; echo "${row_fields[*]}")
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"
    log "Arrangement completed. Output saved to $OUTPUT_FILE"
}

#----------------------------------------------------------#

# All read-only checks must finish before clearing outputs or dropping databases.
postgres_preflight false "$DB_NAME" "$UNCHANGE_DB_NAME"
mkdir -p "$(dirname "$OUTPUT_FILE")"
> "$LOG_FILE"
initialize_database "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"

log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
source "$WORKLOAD_FILE"
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_ycsb_load
measure_stats
write_result "TRUE"

$YCSB load jdbc-array -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" \
    -p db.url="$UNCHANGE_DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > "$OUTPUT_CSV"

original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" "$WORKLOAD_FILE"

        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        log "=== Executing the extend phase (epoch=$epoch, run=$run) ==="
        phase="extend"
        run_ycsb_run
        measure_stats
        write_result "FALSE"

        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        run_ycsb_run
        measure_stats
        write_result "FALSE"
    done
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
