#!/bin/bash

###### Neo4j-specific helpers and database functions ######

assert_bolt_uri() {
    if [[ -z "$1" || "$1" != bolt://* ]]; then
        echo "ERROR: invalid or empty Bolt URI: '$1'" >&2
        return 1
    fi
}

assert_neo4j_uri() {
    if [[ -z "$1" || "$1" != neo4j://* ]]; then
        echo "ERROR: invalid or empty Neo4j URI: '$1'" >&2
        return 1
    fi
}

# Run a Cypher statement against a specific Neo4j database
run_cypher() {
    local bolt_uri="$1"
    local query="$2"
    local database="$3"

    assert_bolt_uri "$bolt_uri" || return 1

    if [[ -n "$database" ]]; then
        cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            -d "$database" \
            --format plain \
            --non-interactive \
            "$query"
    else
        cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            --format plain \
            --non-interactive \
            "$query"
    fi
}

get_field() {
    local value="$1"
    local idx="$2"
    echo "$value" | tr '|' ',' | cut -d',' -f"$idx"
}

get_default_database() {
    local bolt_uri="$1"

    run_cypher "$bolt_uri" \
        "SHOW DATABASES YIELD name, default WHERE default = true RETURN name;" \
        system \
    | tail -n +2 | head -1 | tr -d ' "'
}

assert_apoc_available() {
    local bolt_uri="$1"
    local apoc_output

    assert_bolt_uri "$bolt_uri" || return 1

    local db=$(get_default_database "$bolt_uri")
    if [[ -z "$db" ]]; then
        echo "ERROR: Could not determine default database on $bolt_uri" >&2
        return 1
    fi

    apoc_output=$(run_cypher "$bolt_uri" "RETURN apoc.version();" "$db" 2>&1)
    log "APOC output: $apoc_output"
    if [[ $? -ne 0 || -z "$apoc_output" || "$apoc_output" == *"There is no procedure"* || "$apoc_output" == *"Failed to invoke procedure"* ]]; then
        echo "ERROR: APOC is not available on $bolt_uri. Ensure apoc.* is installed and enabled." >&2
        return 1
    fi
}

# Create the main YCSB label + constraint on a given instance
create_table() {
    local bolt_uri="$1"

    run_cypher "$bolt_uri" \
        "CREATE CONSTRAINT usertable_id IF NOT EXISTS
         FOR (n:usertable)
         REQUIRE n.id IS UNIQUE;" \
        >/dev/null 2>&1 || true
}

# Define database-specific binding field names (metrics collected from Neo4j)
# These should match the variable names set by collect_neo4j_metrics() function
binding_field_names=(
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
    "log_rotation_total_time"
    "transaction_started"
    "transaction_peak_concurrent"
    "transaction_active"
    "transaction_terminated"
)

# Function to close the database
close_db() {
    log "Neo4j backend: no manual DB close required."
}

# Function to extract Neo4j database statistics
# For simplicity and robustness, if any metric query fails, we default to 0.
collect_neo4j_metrics() {
    local bolt_uri="${1:-$MAIN_BOLT_URI}"

    # ---- defaults ----
    transaction_commits="0"
    transaction_rollbacks="0"
    transaction_peak_concurrent="0"
    transaction_active="0"
    nodes_created="0"
    nodes_deleted="0"
    relationships_created="0"
    relationships_deleted="0"
    properties_set="0"
    index_hits="0"
    index_misses="0"
    lock_acquisition_time="0"
    lock_wait_time="0"
    checkpoint_total_time="0"
    checkpoint_total_events="0"
    log_rotation_events="0"
    log_rotation_total_time="0"
    transaction_started="0"
    transaction_terminated="0"


    # ---- TRANSACTION COUNTS ----
    tx_active_raw=$(run_cypher "$bolt_uri" \
        "SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$tx_active_raw" ]]; then
        transaction_active="$tx_active_raw"
    else
        log "[METRIC-ERR] SHOW TRANSACTIONS failed on $bolt_uri"
    fi


    # ---- GRAPH COUNTS (nodes, rels, props) ----
    graph_counts_raw=$(run_cypher "$bolt_uri" \
        "CALL db.stats.retrieve('GRAPH COUNTS')
         YIELD section, data
         UNWIND data AS row
         RETURN
           reduce(total = 0, x IN row.nodes | total + x.count) AS nodes,
           reduce(total = 0, x IN row.relationships | total + x.count) AS relationships,
           reduce(total = 0, x IN row.properties | total + x.count) AS properties;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$graph_counts_raw" && "$graph_counts_raw" != "NULL|NULL|NULL" ]]; then
        nodes_created=$(get_field "$graph_counts_raw" 1)
        relationships_created=$(get_field "$graph_counts_raw" 2)
        properties_set=$(get_field "$graph_counts_raw" 3)
    else
        log "[METRIC-ERR] Graph counts unavailable on $bolt_uri"
    fi




    # ---- INDEX STATS (best-effort) ----
    index_stats_raw=$(run_cypher "$bolt_uri" \
        "SHOW INDEXES YIELD readCount, trackedSince
         RETURN sum(readCount) AS reads;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$index_stats_raw" && "$index_stats_raw" != "NULL" ]]; then
        index_hits="$index_stats_raw"
    else
        log "[METRIC-ERR] Index stats unavailable on $bolt_uri"
    fi


    # ---- COMMIT / ROLLBACK COUNTS (approx via logs) ----
    tx_counts_raw=$(run_cypher "$bolt_uri" \
        "SHOW TRANSACTIONS YIELD status
         RETURN
           sum(CASE WHEN status = 'Committed' THEN 1 ELSE 0 END) AS commits,
           sum(CASE WHEN status = 'RolledBack' THEN 1 ELSE 0 END) AS rollbacks;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$tx_counts_raw" && "$tx_counts_raw" != "NULL|NULL" ]]; then
        transaction_commits=$(get_field "$tx_counts_raw" 1)
        transaction_rollbacks=$(get_field "$tx_counts_raw" 2)
    else
        log "[METRIC-ERR] Transaction commit/rollback stats unavailable on $bolt_uri"
    fi
}

# Database-specific function to get key sizes (appends to file, caller should create header)
get_key_sizes_from_db() {
    local bolt_uri="$1"
    local key_size_log="$2"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable)
         RETURN n.id AS ycsb_key,
                reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
                    total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END) AS size
         ORDER BY n.id;" \
        2>/dev/null | tail -n +2 | sed 's/|/,/' >> "$key_size_log"
}

# Database-specific function to get total size
get_total_size_from_db() {
    local bolt_uri="$1"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable)
         RETURN sum(reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
            total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END)) AS total;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' '
}

# Database-specific function to get keys from database
get_keys_from_db() {
    local bolt_uri="$1"
    local output_file="$2"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable) RETURN n.id AS ycsb_key;" \
        2>/dev/null | tail -n +2 | sed 's/|//' > "$output_file"
}

# Database-specific function to delete keys
delete_batch_neo4j() {
    local bolt_uri="$1"
    local batch_file="$2"

    # Convert batch file → JSON array ["k1","k2",...]
    local keys_json
    keys_json=$(jq -R . < "$batch_file" | jq -s .)

    cypher-shell \
        -u "$DB_USERNAME" \
        -p "$DB_PWD" \
        -a "$bolt_uri" \
        --fail-at-end \
        <<EOF
UNWIND $keys_json AS k
MATCH (n:usertable {id: k})
DETACH DELETE n;
EOF
}

# Database-specific function to backup database
backup_instance() {
    local source_bolt_uri="$1"
    local target_bolt_uri="$2"
    local source_db
    local target_db
    local target_count

    assert_apoc_available "$source_bolt_uri" || return 1
    assert_apoc_available "$target_bolt_uri" || return 1

    source_db=$(get_default_database "$source_bolt_uri")
    target_db=$(get_default_database "$target_bolt_uri")
    if [[ -z "$source_db" || -z "$target_db" ]]; then
        echo "ERROR: Could not determine default database for APOC backup." >&2
        return 1
    fi

    log "Exporting database via APOC from $source_bolt_uri..."
    export_result=$(run_cypher "$source_bolt_uri" \
        "CALL apoc.export.graphml.all('$APOC_BACKUP_PATH', {useTypes: true});" \
        "$source_db" \
        2>&1) || return 1
    log "APOC export result: $export_result"

    if ! sudo cp "/opt/neo4j-instance-main/import/$APOC_BACKUP_PATH" "/opt/neo4j-instance-backup/import/$APOC_BACKUP_PATH"; then
        echo "ERROR: Failed to copy APOC export file to backup import dir." >&2
        return 1
    fi
    sudo chown neo4j:neo4j "/opt/neo4j-instance-backup/import/$APOC_BACKUP_PATH"

    log "Clearing target database on $target_bolt_uri..."
    run_cypher "$target_bolt_uri" \
        "CALL apoc.periodic.iterate('MATCH (n) RETURN n', 'DETACH DELETE n', {batchSize: 10000, parallel: false});" \
        "$target_db" \
        >/dev/null || return 1

    log "Importing database via APOC into $target_bolt_uri..."
    import_result=$(run_cypher "$target_bolt_uri" \
        "CALL apoc.import.graphml('$APOC_BACKUP_PATH', {useTypes: true});" \
        "$target_db" \
        2>&1) || return 1
    log "APOC import result: $import_result"

    # GraphML import does not preserve labels reliably; restore the usertable label.
    run_cypher "$target_bolt_uri" \
        "MATCH (n) SET n:usertable;" \
        "$target_db" \
        >/dev/null || return 1

    target_count=$(run_cypher "$target_bolt_uri" "MATCH (n:usertable) RETURN count(n);" "$target_db" \
        | tail -n +2 | head -1 | tr -d ' ')
    total_count=$(run_cypher "$target_bolt_uri" "MATCH (n) RETURN count(n);" "$target_db" \
        | tail -n +2 | head -1 | tr -d ' ')
    log "BACKUP CHECK usertable_count=$target_count total_count=$total_count"
    if [[ -z "$total_count" || "$total_count" == "0" ]]; then
        echo "ERROR: APOC import produced empty backup (total_count=$total_count)." >&2
        return 1
    fi
    if [[ -z "$target_count" || "$target_count" == "0" ]]; then
        echo "ERROR: APOC import produced no :usertable nodes (usertable_count=$target_count)." >&2
        return 1
    fi
}

measure_stats() {
    local bolt_uri="${1:-$MAIN_BOLT_URI}"
    local pid

    assert_bolt_uri "$bolt_uri" || return 1

    pid=$(lsof -iTCP -sTCP:LISTEN -P \
        | awk -v port="${bolt_uri##*:}" '$0 ~ port {print $2; exit}')

    if [[ -z "$pid" ]]; then
        echo "WARN: Could not resolve PID for $bolt_uri" >&2
        cpu=0
        memory=0
    else
        cpu=$(ps -p "$pid" -o %cpu= | tr -d ' ')
        memory=$(ps -p "$pid" -o %mem= | tr -d ' ')
    fi

    collect_neo4j_metrics "$bolt_uri"
}

run_ycsb_load() {
    local neo4j_uri="${1:-$MAIN_NEO4J_URI}"

    assert_neo4j_uri "$neo4j_uri" || return 1

    $YCSB load neo4j -s -P "$WORKLOAD_FILE" \
        -p url="$neo4j_uri" \
        -p username="$DB_USERNAME" \
        -p password="$DB_PWD" \
        > "$OUTPUT_CSV"
}

run_ycsb_run() {
    local neo4j_uri="${1:-$MAIN_NEO4J_URI}"
    local extra_params="${2:-}"

    assert_neo4j_uri "$neo4j_uri" || return 1

    $YCSB run neo4j -s -P "$WORKLOAD_FILE" \
        -p url="$neo4j_uri" \
        -p username="$DB_USERNAME" \
        -p password="$DB_PWD" \
        $extra_params \
        > "$OUTPUT_CSV"
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

# Logical roles (each = separate Neo4j instance)
MAIN_NAME="ycsb"
BACKUP_NAME="ycsb-backup"
UNCHANGE_NAME="ycsb-unchange"

# Ports per instance
MAIN_BOLT_PORT=7687
BACKUP_BOLT_PORT=7787
UNCHANGE_BOLT_PORT=7887

# HTTP ports (optional, for browser/debug)
MAIN_HTTP_PORT=7474
BACKUP_HTTP_PORT=7574
UNCHANGE_HTTP_PORT=7674

# Credentials
DB_USERNAME="neo4j"
DB_PWD="password"

# Bolt URIs
MAIN_BOLT_URI="bolt://localhost:${MAIN_BOLT_PORT}"
BACKUP_BOLT_URI="bolt://localhost:${BACKUP_BOLT_PORT}"
UNCHANGE_BOLT_URI="bolt://localhost:${UNCHANGE_BOLT_PORT}"

# Neo4j URIs (for drivers that require neo4j://)
MAIN_NEO4J_URI="neo4j://localhost:${MAIN_BOLT_PORT}"
BACKUP_NEO4J_URI="neo4j://localhost:${BACKUP_BOLT_PORT}"
UNCHANGE_NEO4J_URI="neo4j://localhost:${UNCHANGE_BOLT_PORT}"

# Change naming parameters here
TYPE="neo4j"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="light" # "heavy" OR "light"
WORK="mixed" # e.g. "mixed", "pure", or "spreadrun"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
QUERY_PLAN_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_query_plan.log"
APOC_BACKUP_PATH="tmp/ycsb_neo4j_backup.graphml"
DATASET_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_dataset.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv"
HISTOGRAM_FILE="histogram.txt"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
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
extendoperationcount="5000"

#----------------------------------------------------------#

######Helper functions######

# Generate stats_header from binding_field_names
stats_header="CPU,Memory,$(IFS=','; echo "${binding_field_names[*]}")"

# Constant headers (not database-specific)
common_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation"
prop_header="Readprop,Updateprop,Scanprop,Insertprop,Extendprop"
runtime_header="Runtime(ms),Throughput(ops/sec)"
expected_dynamic_cols=(
    "Operations"
    "AverageLatency(us)"
    "MinLatency(us)"
    "MaxLatency(us)"
    "95thPercentileLatency(us)"
    "99thPercentileLatency(us)"
    "Return=OK"
    "Return=NOT_FOUND"
)
expected_dynamic_cols_csv=$(IFS=','; echo "${expected_dynamic_cols[*]}")

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
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\], (Operations|AverageLatency\(us\)|MinLatency\(us\)|MaxLatency\(us\)|95thPercentileLatency\(us\)|99thPercentileLatency\(us\)|Return=OK|Return=NOT_FOUND),/' "$INPUT_FILE")
    overall_output=$(awk '/^\[OVERALL\], (RunTime\(ms\)|Throughput\(ops\/sec\)),/' "$INPUT_FILE")

    # Extract Return=ERROR lines
    return_error_output=$(awk '/Return=ERROR/' "$INPUT_FILE" 2>/dev/null || echo "")

    if [ "$first" == "TRUE" ]; then
        header="$common_header,$stats_header,$prop_header,$runtime_header,RETURN=ERROR,$expected_dynamic_cols_csv"
        echo "$header" > "$OUTPUT_FILE"
        log_dataset "=== HEADER epoch=${epoch:-} run=${run:-} phase=${phase:-} ==="
        log_dataset "$header"
        log_dataset ""
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
    # Ensure only runtime + throughput are kept
    if [ "${#run_specific[@]}" -gt 2 ]; then
        run_specific=("${run_specific[@]:0:2}")
    fi
    log_dataset "=== INPUTS epoch=$epoch run=$run phase=$phase ==="
    log_dataset "[overall_output]"
    if [ -n "$overall_output" ]; then
        while IFS= read -r inner_line; do
            log_dataset "$inner_line"
        done <<< "$overall_output"
    else
        log_dataset "<empty>"
    fi
    log_dataset "[filtered_output]"
    if [ -n "$filtered_output" ]; then
        while IFS= read -r inner_line; do
            log_dataset "$inner_line"
        done <<< "$filtered_output"
    else
        log_dataset "<empty>"
    fi
    log_dataset "run_specific=${run_specific[*]}"

    # Extract Return=ERROR value (third field from Return=ERROR line)
    return_error_value=""
    if [ -n "$return_error_output" ]; then
        return_error_value=$(echo "$return_error_output" | awk '{print $3}' | sed 's/,$//' | head -1)
    fi
    return_error_value=${return_error_value:-"0"}
    log_dataset "return_error_value=$return_error_value"

    # Collect metrics per operation
    values_1=""
    values_2=""
    declare -A op_metric_values
    op_list=()
    while IFS= read -r line; do
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        metric=$(echo "$line" | awk '{print $2}' | sed 's/,$//')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        if [ -z "${op_metric_values["$operation|__seen"]+x}" ]; then
            op_list+=("$operation")
            op_metric_values["$operation|__seen"]=1
        fi
        op_metric_values["$operation|$metric"]="$third_value"
    done <<< "$filtered_output"

    # Build rows with fixed metric ordering (fill missing values with 0)
    for idx in "${!op_list[@]}"; do
        operation="${op_list[$idx]}"

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

        dynamic_fields=("${run_specific[@]}" "$return_error_value")
        for metric_name in "${expected_dynamic_cols[@]}"; do
            key="$operation|$metric_name"
            dynamic_fields+=("${op_metric_values[$key]:-0}")
        done
        log_dataset "op=$operation prop_fields=${prop_fields[*]}"
        log_dataset "op=$operation dynamic_fields=${dynamic_fields[*]}"

        row_fields=(
            "${common_fields[@]}"
            "${binding_fields[@]}"
            "${prop_fields[@]}"
            "${dynamic_fields[@]}"
        )

        row_value=$(IFS=','; echo "${row_fields[*]}")
        # Column index dump to help debug alignment issues
        idx_log=""
        for idx_i in "${!row_fields[@]}"; do
            idx_log+="$((idx_i + 1))=${row_fields[$idx_i]} "
        done
        log_dataset "op=$operation col_dump=$idx_log"
        if [ "$idx" -eq 0 ]; then
            values_1="$row_value"
        elif [ "$idx" -eq 1 ]; then
            values_2="$row_value"
        fi
    done

    # Print the values to the output file (only if not empty)
    if [ -n "$values_1" ]; then
        echo "$values_1" >> "$OUTPUT_FILE"
        log_dataset "[row1] $values_1"
    fi
    if [ -n "$values_2" ]; then
        echo "$values_2" >> "$OUTPUT_FILE"
        log_dataset "[row2] $values_2"
    fi
    log_dataset ""

    # Print completion message
    echo "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    echo "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    echo "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    echo "Generating histogram from key size log: $key_size_log"

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

    echo "Histogram written to $histogram_file (BlockSize = 100)"
}

delete_new_keys() {
    local bolt_uri="$1"

    if [[ -z "$bolt_uri" ]]; then
        echo "ERROR: delete_new_keys requires a Bolt URI" >&2
        return 1
    fi

    local keys_before_file="keys.txt"
    local keys_after_file="keys_after_run.txt"
    local keys_to_delete_file="keys_to_delete.txt"

    # Sort the key files
    sort "$keys_before_file" > keys_sorted.txt
    sort "$keys_after_file" > keys_after_sorted.txt

    # Find keys that are only in keys_after_run.txt
    comm -13 keys_sorted.txt keys_after_sorted.txt > "$keys_to_delete_file"

    local delete_count
    delete_count=$(wc -l < "$keys_to_delete_file" | tr -d ' ')

    echo "Deleting $delete_count new keys from Neo4j instance at '$bolt_uri'..."

    # Delete those keys
    local BATCH_SIZE=1000

    if [ ! -s "$keys_to_delete_file" ]; then
        echo "No new keys to delete."
    else
        split -l "$BATCH_SIZE" "$keys_to_delete_file" keys_batch_
        for f in keys_batch_*; do
            echo "Deleting batch: $f"
            delete_batch_neo4j "$bolt_uri" "$f"
        done
    fi

    if [ -s "$keys_to_delete_file" ]; then
        rm -f keys_batch_*
    fi

    rm -rf \
        "$keys_after_file" \
        "$keys_before_file" \
        keys_sorted.txt \
        keys_after_sorted.txt \
        "$keys_to_delete_file"

    echo "✅ Deletion complete for instance $bolt_uri."
}

# Initialize database
initialize_database() {
    local db_name="$1"

    local bolt_uri
    local data_dir
    local neo4j_home

    case "$db_name" in
        ycsb)
            bolt_uri="$MAIN_BOLT_URI"
            data_dir="data-main"
            neo4j_home="/opt/neo4j-instance-main"
            ;;
        ycsb-backup)
            bolt_uri="$BACKUP_BOLT_URI"
            data_dir="data-backup"
            neo4j_home="/opt/neo4j-instance-backup"
            ;;
        ycsb-unchange)
            bolt_uri="$UNCHANGE_BOLT_URI"
            data_dir="data-unchange"
            neo4j_home="/opt/neo4j-instance-unchange"
            ;;
        *)
            echo "ERROR: Unknown DB role: $db_name" >&2
            return 1
            ;;
    esac

    initialize_database_instance "$bolt_uri" "$db_name" "$data_dir" "$neo4j_home"
}

initialize_database_instance() {
    local bolt_uri="$1"
    local instance_name="$2"
    local data_dir="$3"
    local neo4j_home="$4"

    echo "Initializing Neo4j instance '$instance_name' at $bolt_uri..."

    sudo -u neo4j "$neo4j_home/bin/neo4j" stop || true
    sudo -u neo4j rm -rf "$neo4j_home/$data_dir"/*

    # Seed auth
    sudo -u neo4j "$neo4j_home/bin/neo4j-admin" dbms set-initial-password "$DB_PWD"

    sudo -u neo4j "$neo4j_home/bin/neo4j" start

    echo "Waiting for Neo4j ($instance_name) to become ready..."
    for i in {1..30}; do
        if run_cypher "$bolt_uri" "RETURN 1;" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    create_table "$bolt_uri"

    echo "✅ Done initializing $instance_name."
}

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

log_dataset() {
    echo "$1" >> "$DATASET_LOG"
}

get_workload_param() {
    local key="$1"
    local default_value="$2"
    local value

    value=$(grep -E "^${key}=" "$WORKLOAD_FILE" | tail -n 1 | cut -d= -f2)
    if [[ -z "$value" ]]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

log_keyspace_params() {
    local recordcount
    local insertstart
    local insertcount
    local insertorder

    recordcount=$(get_workload_param "recordcount" "")
    insertstart=$(get_workload_param "insertstart" "0")
    insertcount=$(get_workload_param "insertcount" "")
    insertorder=$(get_workload_param "insertorder" "hashed")

    if [[ -z "$insertcount" && -n "$recordcount" ]]; then
        insertcount=$((recordcount - insertstart))
    fi

    log "KEYSPACE recordcount=$recordcount insertstart=$insertstart insertcount=$insertcount insertorder=$insertorder"
    log_dataset "KEYSPACE recordcount=$recordcount insertstart=$insertstart insertcount=$insertcount insertorder=$insertorder"
}

log_query_plan() {
    local bolt_uri="$1"
    local phase_label="$2"
    local instance_label="$3"
    local ts
    local test_key
    local escaped_key
    local profile_output

    assert_bolt_uri "$bolt_uri" || return 1

    ts=$(date -Iseconds)
    test_key=$(run_cypher "$bolt_uri" \
        "MATCH (n:usertable) RETURN n.id AS id LIMIT 1;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$test_key" && "$test_key" != "NULL" ]]; then
        escaped_key=${test_key//\'/\\\'}
        profile_output=$(cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            --format verbose \
            "PROFILE MATCH (n:usertable {id: '$escaped_key'}) RETURN n LIMIT 1;" \
            2>/dev/null)
    else
        profile_output=$(cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            --format verbose \
            "PROFILE MATCH (n:usertable) RETURN n LIMIT 1;" \
            2>/dev/null)
    fi

    {
        echo "=== QUERY PLAN $ts | epoch=$epoch run=$run phase=$phase_label instance=$instance_label uri=$bolt_uri ==="
        echo "$profile_output"
        echo
    } >> "$QUERY_PLAN_LOG"
}

#----------------------------------------------------------#

######Main block of code######

# Initialize all three PHYSICAL databases
initialize_database "$MAIN_NAME"
initialize_database "$UNCHANGE_NAME"
initialize_database "$BACKUP_NAME"

# Clear the log file and previous backups
> $LOG_FILE
> $QUERY_PLAN_LOG
> $DATASET_LOG
rm -rf $KEY_SIZE_LOG
# Clear the value size files to start fresh
> "$KEY_SIZE_FILE_AFTER_EXTEND"
> "$KEY_SIZE_FILE_AFTER_RUN"

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
# Extract workload parameters for load phase
source "$WORKLOAD_FILE"
log_keyspace_params
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_ycsb_load "$MAIN_NEO4J_URI"
measure_stats "$MAIN_BOLT_URI"
write_result "TRUE"

# Load unchange value size (reference) DB
run_ycsb_load "$UNCHANGE_NEO4J_URI"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 1); do
    for run in $(seq 1 1); do
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"
        log_keyspace_params
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0.2 and other proportions=0 ==="
        phase="extend"
        run_ycsb_run "$MAIN_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$MAIN_BOLT_URI"
        write_result "FALSE"

        # Key Sizes
        echo "Size computation started"
        echo "ycsb_key,size" > "$KEY_SIZE_LOG"
        get_key_sizes_from_db "$MAIN_BOLT_URI" "$KEY_SIZE_LOG"
        get_key_sizes "$KEY_SIZE_LOG" "$HISTOGRAM_FILE"

        # Sanitize epoch and run for iteration calculation
        epoch_iter=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        run_iter=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        iteration=$((10 * (epoch_iter - 1) + run_iter))

        if [[ "$iteration" -eq 1 ]]; then
            # First iteration: (re)create file with header and initial data
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
            append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
        else
            append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"
        log_keyspace_params
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Save the existing keys in the database
        get_keys_from_db "$MAIN_BOLT_URI" "keys.txt"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        log_query_plan "$MAIN_BOLT_URI" "$phase" "$MAIN_NAME"
        run_ycsb_run "$MAIN_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$MAIN_BOLT_URI"
        write_result "FALSE"

        # Delete new keys that were inserted during the run
        get_keys_from_db "$MAIN_BOLT_URI" "keys_after_run.txt"
        delete_new_keys "$MAIN_BOLT_URI"

        # Workload with unchanging value sizes
        get_keys_from_db "$UNCHANGE_BOLT_URI" "keys.txt"
        phase="reference"
        run_ycsb_run "$UNCHANGE_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$UNCHANGE_BOLT_URI"
        write_result "FALSE"

        # Delete new keys from unchange database
        get_keys_from_db "$UNCHANGE_BOLT_URI" "keys_after_run.txt"
        delete_new_keys "$UNCHANGE_BOLT_URI"
    
        # Sanitize epoch and run for condition check
        epoch_check=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        run_check=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        if (( $((10 * (epoch_check - 1) + run_check)) % 1 == 0 )); then
            phase="clean-run"
            
            echo "Backing up the database started"

            if ! backup_instance "$MAIN_BOLT_URI" "$BACKUP_BOLT_URI"; then
                log "ERROR: APOC-based backup failed. Aborting clean-run."
                exit 1
            fi

            echo "Waiting for backup Neo4j to become ready..."
            for i in {1..30}; do
                if run_cypher "$BACKUP_BOLT_URI" "RETURN 1;" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done

            echo "Backing up the database finished"

            log_query_plan "$BACKUP_BOLT_URI" "$phase" "$BACKUP_NAME"
            run_ycsb_run "$BACKUP_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
            measure_stats "$BACKUP_BOLT_URI"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            echo "Size computation started"
            echo "ycsb_key,size" > "$KEY_SIZE_LOG"
            get_key_sizes_from_db "$BACKUP_BOLT_URI" "$KEY_SIZE_LOG"
            
            # Sanitize epoch and run for iteration calculation
            epoch_iter2=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
            run_iter2=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
            iteration=$((10 * (epoch_iter2 - 1) + run_iter2))

            if [[ "$iteration" -eq 1 ]]; then
                # First iteration: (re)create file with header and initial data
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
                append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            else
                append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # PostgreSQL query to get the total size of all records
            total_size=$(get_total_size_from_db "$BACKUP_BOLT_URI")

            # Set average field length (with error handling)
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "[FIELDLEN]   Cannot calculate average field length"
                log "[FIELDLEN]   total_size=$total_size"
                log "[FIELDLEN]   recordcount=$recordcount"
                log "[FIELDLEN]   fallback=fieldlengthoriginal=$fieldlengthoriginal"

                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)

                log "[FIELDLEN] Computed average field length"
                log "[FIELDLEN]   total_size_bytes=$total_size"
                log "[FIELDLEN]   recordcount=$recordcount"
                log "[FIELDLEN]   fields_per_record=10"
                log "[FIELDLEN]   fieldlengthaverage=$fieldlengthaverage"
            fi

            # Change the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            initialize_database "$BACKUP_NAME"
            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            run_ycsb_load "$BACKUP_NEO4J_URI"
            
            # Change the value size back for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"
            log_query_plan "$BACKUP_BOLT_URI" "$phase" "$BACKUP_NAME"
            run_ycsb_run "$BACKUP_NEO4J_URI"
            measure_stats "$BACKUP_BOLT_URI"
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
