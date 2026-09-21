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
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the PostgreSQL data directory
DB_URL="jdbc:postgresql://localhost:5432/$DB_NAME"
JDBC_PROPERTIES="../jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="USyd2025"

# Change naming parameters here
TYPE="postgresql"
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

# Initialize PostgreSQL database
initialize_database() {
    echo "Initializing PostgreSQL database $DB_NAME..."

    PGPASSWORD="$DB_PWD" dropdb --if-exists "$DB_NAME" -U "$DB_USERNAME"
    PGPASSWORD="$DB_PWD" createdb "$DB_NAME" -U "$DB_USERNAME"

    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 TEXT, field1 TEXT, field2 TEXT, field3 TEXT, field4 TEXT,
            field5 TEXT, field6 TEXT, field7 TEXT, field8 TEXT, field9 TEXT
        );"

    echo "Done initializing."
}

ensure_core_dependencies
initialize_database

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file
> $LOG_FILE

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Filter for inserts, reads, updates, scans, and extends
    # Also catch the overall output
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Create header
        header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}' | sed 's/,$//')"
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Set default values for epoch and run if not set
    epoch=${epoch:-0}
    run=${run:-0}
    # Load phase counts as 0
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * ($epoch - 1) + $run))
    fi

    # Set default values for workload parameters
    recordcount=${recordcount:-""}
    readallfields=${readallfields:-""}
    requestdistribution=${requestdistribution:-""}
    readproportion=${readproportion:-""}
    updateproportion=${updateproportion:-""}
    scanproportion=${scanproportion:-""}
    insertproportion=${insertproportion:-""}
    extendproportion=${extendproportion:-""}

    # Extract runtime and throughput from overall output
    run_specific=()
    while IFS= read -r inner_line; do
        # Extract third value (the metric value)
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    # Initialize operation to empty in case filtered_output is empty
    operation=""
    while IFS= read -r line; do
        # Extract operation and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        # Build CSV row
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    echo "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to close the PostgreSQL database
close_db() {
    log "PostgreSQL backend: no manual DB close required."
}

# Function to extract PostgreSQL database and background writer statistics
collect_postgres_metrics() {
    local db="$DB_NAME"

    # database-level stats
    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # bgwriter
    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # wal metrics
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
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

$YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV 
cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
collect_postgres_metrics $DB_NAME
write_result "TRUE"

# Experiment parameters
# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Set proportions for insert mode
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        
        # Extract the recordcount from the workload file
        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
        # Compute the update operation count
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        # Change operation count for insert mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        # Compute update record count
        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE" 

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
        cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
        memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

    done
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
