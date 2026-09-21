#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

######Change database functions to work with a new database here######

drop_database() {
    # Neo4j: Delete all nodes with the usertable label
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "MATCH (n:usertable) DETACH DELETE n;" 2>/dev/null || true
}

create_database() {
    # Verify connection
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "RETURN 1;" > /dev/null 2>&1 || echo "Warning: Could not connect to Neo4j"
}

create_table() {
    # Verify we can run a query
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "RETURN 1;" > /dev/null 2>&1 || true

    # Create index on ycsb_key
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "CREATE INDEX usertable_id IF NOT EXISTS FOR (n:usertable) ON (n.id);" > /dev/null 2>&1 || true
    
    # Show indexes
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "SHOW INDEXES;"

    # Profile query
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$DB_URL" "PROFILE MATCH (n:usertable {id: 'user00000042'}) RETURN n;"
}

# Define database-specific binding field names (metrics collected from the database)
# These should match the variable names set by collect_metrics() function
binding_field_names=(
    "page_cache_hits"
    "page_cache_faults"
    "transaction_commits"
    "transaction_rollbacks"
    "nodes_created"
    "nodes_deleted"
    "relationships_created"
    "relationships_deleted"
    "properties_set"
    "index_hits"
    "index_misses"
    "lock_acquisition_time"
    "lock_wait_time"
    "checkpoint_total_time"
    "checkpoint_total_events"
    "log_rotation_events"
    "log_appended_bytes"
    "log_rotation_total_time"
    "transaction_started"
    "transaction_peak_concurrent"
    "transaction_active"
    "transaction_terminated"
)

# Function to close the Neo4j database
close_db() {
    log "Neo4j backend: no manual DB close required."
}

# Function to extract Neo4j database statistics (Neo4j 5.x)
collect_neo4j_metrics() {
    local db_url="${1:-$DB_URL}"
    
    # Neo4j 5.x metrics collection using latest procedures
    # Using dbms.queryJmx for comprehensive metrics
    
    # Get page cache metrics
    page_cache_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Page cache') YIELD attributes
         RETURN attributes['hits'].value AS hits, attributes['faults'].value AS faults;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$page_cache_metrics" ]; then
        page_cache_hits=$(echo "$page_cache_metrics" | cut -d'|' -f1)
        page_cache_faults=$(echo "$page_cache_metrics" | cut -d'|' -f2)
    else
        page_cache_hits="0"
        page_cache_faults="0"
    fi
    
    # Get transaction metrics
    tx_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Transactions') YIELD attributes
         RETURN attributes['NumberOfCommittedTransactions'].value AS commits,
                attributes['NumberOfRolledBackTransactions'].value AS rollbacks,
                attributes['PeakNumberOfConcurrentTransactions'].value AS peak_concurrent;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$tx_metrics" ]; then
        transaction_commits=$(echo "$tx_metrics" | cut -d'|' -f1)
        transaction_rollbacks=$(echo "$tx_metrics" | cut -d'|' -f2)
        transaction_peak_concurrent=$(echo "$tx_metrics" | cut -d'|' -f3)
    else
        transaction_commits="0"
        transaction_rollbacks="0"
        transaction_peak_concurrent="0"
    fi
    
    # Get current transaction count
    tx_active=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    transaction_active="${tx_active:-0}"
    
    # Get database operations metrics
    db_ops=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Primitive count') YIELD attributes
         RETURN attributes['NumberOfNodeIdsInUse'].value AS nodes,
                attributes['NumberOfRelationshipIdsInUse'].value AS relationships,
                attributes['NumberOfPropertyIdsInUse'].value AS properties;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$db_ops" ]; then
        nodes_created=$(echo "$db_ops" | cut -d'|' -f1)
        relationships_created=$(echo "$db_ops" | cut -d'|' -f2)
        properties_set=$(echo "$db_ops" | cut -d'|' -f3)
    else
        nodes_created="0"
        relationships_created="0"
        properties_set="0"
    fi
    
    # Get index metrics
    index_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Index sampling') YIELD attributes
         RETURN attributes['IndexSamplingJobCount'].value AS sampling_count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    # Try to get index hits/misses from index statistics
    index_stats=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "SHOW INDEXES YIELD name, state, type, populationPercent;" \
        2>/dev/null | wc -l)
    index_hits="0"
    index_misses="0"
    
    # Get lock metrics
    lock_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Locking') YIELD attributes
         RETURN attributes['NumberOfLockedEntities'].value AS locked;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    lock_acquisition_time="0"
    lock_wait_time="0"
    
    # Get checkpoint metrics
    checkpoint_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Check pointing') YIELD attributes
         RETURN attributes['CheckPointTotalTime'].value AS total_time,
                attributes['NumberOfCheckPointEvents'].value AS events;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$checkpoint_metrics" ]; then
        checkpoint_total_time=$(echo "$checkpoint_metrics" | cut -d'|' -f1)
        checkpoint_total_events=$(echo "$checkpoint_metrics" | cut -d'|' -f2)
    else
        checkpoint_total_time="0"
        checkpoint_total_events="0"
    fi
    
    # Get log rotation metrics
    log_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Log rotation') YIELD attributes
         RETURN attributes['LogRotationEvents'].value AS events,
                attributes['LogRotationTotalTime'].value AS total_time;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$log_metrics" ]; then
        log_rotation_events=$(echo "$log_metrics" | cut -d'|' -f1)
        log_rotation_total_time=$(echo "$log_metrics" | cut -d'|' -f2)
    else
        log_rotation_events="0"
        log_rotation_total_time="0"
    fi
    
    # Get log appended bytes
    log_appended_bytes=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Store file sizes') YIELD attributes
         RETURN attributes['LogFileSize'].value AS size;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    log_appended_bytes="${log_appended_bytes:-0}"
    
    # Set defaults for metrics that might not be available
    nodes_deleted="0"
    relationships_deleted="0"
    transaction_started="0"
    transaction_terminated="0"
}

measure_stats() {
    local db_url="${1:-$DB_URL}"
    cpu=$(ps -u neo4j -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    memory=$(ps -u neo4j -o %mem= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    collect_neo4j_metrics "$db_url"
}

run_ycsb_load() {
    $YCSB load neo4j -s -P $WORKLOAD_FILE -p url="$DB_URL" -p username="$DB_USERNAME" -p password="$DB_PWD" > $OUTPUT_CSV 
}

run_ycsb_run() {
    $YCSB run neo4j -s -P $WORKLOAD_FILE -p url="$DB_URL" -p username="$DB_USERNAME" -p password="$DB_PWD" > $OUTPUT_CSV
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

# DB names (Neo4j uses a single database, but we can use different labels or instances)
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the Neo4j database
# Neo4j connection URL format: bolt://host:port or neo4j://host:port
DB_URL="bolt://localhost:7687"
DB_USERNAME="neo4j"
DB_PWD="password"

# Change naming parameters here
TYPE="neo4j"
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
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="50000"

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
    echo "Initializing Neo4j database..."

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
log "=== Load phase completed ==="
cpu=$(ps -u neo4j -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
memory=$(ps -u neo4j -o %mem= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
collect_neo4j_metrics "$DB_URL"
write_result "TRUE"
log "=== Load phase results written ==="

# Experiment parameters
# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

for epoch in $(seq 1 10); do
    log "=== Starting epoch $epoch ==="
    for run in $(seq 1 10); do
        log "=== Starting epoch $epoch, run $run ==="

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

        # Execute the extend phase
        log "=== Executing the extend phase (epoch=$epoch, run=$run) ==="
        phase="extend"
        run_ycsb_run
        cpu=$(ps -u neo4j -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
        memory=$(ps -u neo4j -o %mem= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
        collect_neo4j_metrics "$DB_URL"
        write_result "FALSE"

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
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 (epoch=$epoch, run=$run) ==="
        phase="spread-run"
        run_ycsb_run
        cpu=$(ps -u neo4j -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
        memory=$(ps -u neo4j -o %mem= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
        collect_neo4j_metrics "$DB_URL"
        write_result "FALSE"
        
        log "=== Completed epoch $epoch, run $run ==="

    done
    log "=== Completed epoch $epoch ==="
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
