#!/bin/bash

######Change database functions to work with a new database here######

drop_database() {
    PGPASSWORD="$DB_PWD" dropdb --if-exists "$DB_NAME" -U "$DB_USERNAME"
}

create_database() {
    PGPASSWORD="$DB_PWD" createdb "$DB_NAME" -U "$DB_USERNAME"
}

create_table() {
    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 TEXT, field1 TEXT, field2 TEXT, field3 TEXT, field4 TEXT,
            field5 TEXT, field6 TEXT, field7 TEXT, field8 TEXT, field9 TEXT
        );"
}

# Define database-specific binding field names (metrics collected from the database)
# These should match the variable names set by collect_metrics() function
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

# Function to close the PostgreSQL database
close_db() {
    log "PostgreSQL backend: no manual DB close required."
}

# Function to extract PostgreSQL database and background writer statistics
collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"

    # database-level stats - use -t for tuples only, convert pipes to spaces and trim
    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # bgwriter (checkpoints etc.)
    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # wal metrics if available
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
    local db="${1:-$DB_NAME}"
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
    collect_postgres_metrics "$db"
}

# Field arrays will be populated dynamically in write_result function

run_ycsb_load() {
    $YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV 
}

run_ycsb_run() {
    $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

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
SCALE="light" # "heavy" OR "light"
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
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"

#----------------------------------------------------------#

######Helper functions######

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

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        dynamic_fields_header=$(extract_dynamic_fields "$filtered_output")
        if [ -n "$dynamic_fields_header" ]; then
            header="$common_header,$stats_header,$prop_header,$runtime_header,$dynamic_fields_header"
        else
            header="$common_header,$stats_header,$prop_header,$runtime_header"
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Set default values for epoch and run if not set (e.g., during load phase)
    epoch=${epoch:-0}
    run=${run:-0}
    # Sanitize epoch and run to ensure they're single integers (take first line only, remove whitespace)
    epoch=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    run=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    # Handle load phase: use 0 instead of negative value
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * (epoch - 1) + run))
    fi

    # Set default values for workload parameters if not set
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

        # Populate field arrays dynamically
        common_fields=(
            "$r"
            "$phase"
            "$recordcount"
            "$readallfields"
            "$requestdistribution"
            "$operation"
        )

        # Populate binding_fields from database-specific metrics using binding_field_names
        binding_fields=("$cpu" "$memory")
        for field_name in "${binding_field_names[@]}"; do
            # Use indirect variable reference to get the value
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

        # Append to the values variable
        if [ $k -eq 1 ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )

            # join with commas (use subshell to avoid affecting global IFS)
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

            # join with commas (use subshell to avoid affecting global IFS)
            values_2=$(IFS=','; echo "${row_fields[*]}")

            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file (only if not empty)
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    echo "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Initialize database
initialize_database() {
    echo "Initializing database $DB_NAME..."

    drop_database

    create_database

    create_table

    echo "Done initializing."
}

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}


#----------------------------------------------------------#

######Main block of code######

initialize_database

# Clear the log file
> $LOG_FILE

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

run_ycsb_load
cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
collect_postgres_metrics $DB_NAME
write_result "TRUE"

# Experiment parameters
# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

for epoch in $(seq 1 3); do
    for run in $(seq 1 3); do

        # Set proportions for insert mode
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        
        # Extract the recordcount from the workload file (before modifying operationcount)
        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
        # Compute the new record number to be added
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        # Change operation count for insert mode (extend phase)
        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        run_ycsb_run

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

        # Compute new record count
        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)

        # Setting parameter values for read phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" $WORKLOAD_FILE
        # Change operation count back to original value for run phase
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE" 

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        run_ycsb_run
        cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
        memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

    done
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
