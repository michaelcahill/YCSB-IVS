#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# Ensure core dependencies are staged for source-run
ensure_core_dependencies() {
    if [ ! -d "$YCSB_HOME/core/target/dependency" ]; then
        echo "[WARN] core/target/dependency missing; building core with -Psource-run..."
        mvn -Psource-run -pl site.ycsb:core -am package -DskipTests
    fi
}

# DB names
DB_NAME="ycsb"
UNCHANGE_DB_NAME="ycsb_unchange"

# DB URLs
DB_URL="jdbc:postgresql://localhost:5432/$DB_NAME"
UNCHANGE_DB_URL="jdbc:postgresql://localhost:5432/$UNCHANGE_DB_NAME"
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

# Define database-specific binding field names (metrics collected from PostgreSQL)
binding_field_names=(
    "blks_read"
    "blks_hit"
    "tup_returned"
    "tup_fetched"
    "tup_inserted"
    "tup_updated"
    "tup_deleted"
    "deadlocks"
    "temp_files"
    "temp_bytes"
    "checkpoints_timed"
    "checkpoints_req"
    "buffers_checkpoint"
    "buffers_clean"
    "buffers_backend"
    "buffers_alloc"
    "checkpoint_write_time"
    "checkpoint_sync_time"
    "wal_bytes"
    "wal_records"
    "wal_fpi"
    "wal_buffers_full"
)

log() {
    echo "$1" | tee -a $LOG_FILE
}

initialize_database() {
    local db_name="$1"
    log "Initializing PostgreSQL database $db_name..."

    PGPASSWORD="$DB_PWD" dropdb --if-exists "$db_name" -U "$DB_USERNAME"
    PGPASSWORD="$DB_PWD" createdb "$db_name" -U "$DB_USERNAME"

    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -c \
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

collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"

    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    if PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -c "\d pg_stat_wal" &>/dev/null; then
        read wal_bytes wal_records wal_fpi wal_buffers_full <<< \
            $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
                SELECT wal_bytes, wal_records, wal_fpi, wal_buffers_full
                FROM pg_stat_wal;
            " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    else
        wal_bytes="0"; wal_records="0"; wal_fpi="0"; wal_buffers_full="0"
    fi
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

ensure_core_dependencies
initialize_database "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"

> $LOG_FILE

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
