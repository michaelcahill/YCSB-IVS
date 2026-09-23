#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# The experiment engine: load -> extend -> run -> reference -> clean-run -> avg-run.
#
# This is backend-independent apart from calls through the backend contract and the
# legacy aliases that still wrap it (removed in step 5). It reads its configuration
# from the globals prepared by lib/config.sh, never writes to a workload file: every
# YCSB invocation gets an immutable generated file from lib/workload.sh, and writes its
# artefacts under $EXPERIMENT_DIR.

run_ycsb() {
    local label="$1" started=$SECONDS rc=0
    local detail_file
    shift

    detail_file="${LOG_FILE%.log}_epoch${epoch:-0}_step${step:-0}_${label}.raw.log"

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

# Point the binding at one database. The property NAMES are a binding detail: the JDBC
# bindings read db.url/db.user/db.passwd, PostgreNoSQL reads postgrenosql.url/…, so the
# prefix is configured per backend (BINDING_PARAM_PREFIX) instead of hardcoded here.
# Sets the global DB_PARAMS array; every YCSB invocation expands it.
binding_db_params() {
    local url="${1:?database url required}" prefix="${BINDING_PARAM_PREFIX:-db}"
    DB_PARAMS=(
        -p "${prefix}.url=$url"
        -p "${prefix}.user=$DB_USERNAME"
        -p "${prefix}.passwd=$DB_PWD"
    )
}

run_with_metrics() {
    local db_name=$1
    local phase=$2
    local epoch=$3
    local output_csv=$4
    shift 4

    local started=$SECONDS status=0 saved_traps=""
    local pg_1s_file=""
    local os_1s_file=""

    metrics_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.metrics"
    db_stats_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.dbstats"

    echo "Starting metrics collection for $db_name"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${LOG_DIR}/javagc"

    # Snapshot the runner's own traps so they survive this function; clearing
    # them here used to remove finish_logging, so the log was never finalised.
    saved_traps=$(trap -p EXIT INT TERM)
    # shellcheck disable=SC2034  # re-assigned just before the watcher trap below
    # Start watcher
    setsid env \
        DB_PWD="$DB_PWD" \
        DB_USERNAME="$DB_USERNAME" \
        db_name="$db_name" \
        phase="$phase" \
        epoch="$epoch" \
        metrics_file="$metrics_file" \
        DB_STATS_FILE="$db_stats_file" \
        PG_1S_FILE="$pg_1s_file" \
        OS_1S_FILE="$os_1s_file" \
        OS_DISK_DEVICE_FILE="" \
        OS_DISK_DEVICES="$OS_DISK_DEVICES" \
        DB_STATS_TABLE="$TARGET_TABLE" \
        DB_STATS_INTERVAL="$DB_STATS_INTERVAL" \
        INTERVAL=1 \
        ./watcher.sh &
    RUNTIME_WATCHER_PGID=$!

    # Never leave the watcher's process group behind, even on interrupt.
    saved_traps=$(trap -p EXIT INT TERM)
    trap 'stop_runtime_watcher' EXIT INT TERM

    # execute ycsb program including JAVA_OPTS to log garbage collector
    log "START YCSB $phase"
    set +e
    JAVA_OPTS="-Xlog:gc*,safepoint:file=${LOG_DIR}/javagc/javagc-run${RUN}-${phase}-${epoch}.log:time,uptime,level,tags:filecount=10,filesize=1M" \
    "$@" > "$output_csv"
    status=$?
    set -e

    stop_runtime_watcher

    # Restore the runner's traps instead of clearing them.
    if [[ -n "$saved_traps" ]]; then
        eval "$saved_traps"
    else
        trap - EXIT INT TERM
    fi

    log "END YCSB $phase status=$status duration=$((SECONDS-started))s"
    echo "Finished $db_name phase=$phase epoch=$epoch (exit=$status)"

    # A failed phase must not be reported as a successful measurement.
    if (( status != 0 )); then
        log "ERROR YCSB $phase failed with status=$status; output=$output_csv"
        return "$status"
    fi
    return 0
}

# Run the whole experiment. Assumes libs + a backend are sourced and config has been
# applied (experiment.sh does both).
run_experiment() {
local -a DB_PARAMS=()

# All read-only checks must finish before clearing outputs or dropping databases.
start_logging
log "START preflight"
backend::preflight true "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"
workload::init
log "END preflight"
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$KEY_SIZE_FILE_AFTER_EXTEND")"

# Clear the log file and previous backups
: > "$PLAN_LOG"
: > "$HISTOGRAM_FILE"

rm -rf "$KEY_SIZE_LOG"
rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"

backend::init_db "$DB_NAME"
backend::init_db "$UNCHANGED_DB_NAME"

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
step=0
iteration=0

# Values later phases need from the template, before any overlay is applied.
original_operationcount="${operationcount_override:-$(workload::get_value "$WORKLOAD_FILE" operationcount)}"

WORKLOAD_PHASE="$(workload::generate load 0)"
workload::apply_context "$WORKLOAD_PHASE"
binding_db_params "$DB_URL"

run_with_metrics "$DB_NAME" "$phase" "$step" "$OUTPUT_CSV" \
	"$YCSB" load "$YCSB_BINDING" -s \
    -P "$WORKLOAD_PHASE" \
    -P "$JDBC_PROPERTIES" \
    "${DB_PARAMS[@]}" \
    -p fieldlengthdistribution=constant \
    -p fieldlength="$fieldlengthoriginal"
total_size_initial_load=$(backend::total_size "$DB_NAME")
log "Initial-load verification - TotalSize:$total_size_initial_load ExpectedFieldLength:$fieldlengthoriginal"
collect_cpu_memory_metrics
backend::collect_metrics $DB_NAME
write_result "TRUE"

# Load unchange value size (reference) DB
phase="reference-load"
WORKLOAD_PHASE="$(workload::generate reference-load 0)"
workload::apply_context "$WORKLOAD_PHASE"
binding_db_params "$UNCHANGED_DB_URL"
run_with_metrics "$UNCHANGED_DB_NAME" "$phase" "$step" "$OUTPUT_CSV" \
	"$YCSB" load "$YCSB_BINDING" -s \
    -P "$WORKLOAD_PHASE" -P "$JDBC_PROPERTIES" \
    "${DB_PARAMS[@]}" \
    -p fieldlengthdistribution=constant \
    -p fieldlength="$fieldlengthoriginal"
total_size_reference_load=$(backend::total_size "$UNCHANGED_DB_NAME")
log "Reference-load verification - TotalSize:$total_size_reference_load ExpectedFieldLength:$fieldlengthoriginal"

# Experiment parameters
for epoch in $(seq 1 "$NUM_EPOCHS"); do
    for step in $(seq 1 "$STEPS_PER_EPOCH"); do
        
        iteration=$((STEPS_PER_EPOCH*($epoch-1)+$step))
        
        # Extend phase settings go into a generated workload file, never back into
        # the template.
        log "=== Generating the extend workload ==="
        phase="extend"
        WORKLOAD_PHASE="$(workload::generate extend "$iteration")"
        workload::apply_context "$WORKLOAD_PHASE"

        # Execute the extend phase
        log "=== Executing the extend phase with extendproportion=1 and other proportions=0 ==="
        # Capture both stdout and stderr to capture status messages
        binding_db_params "$DB_URL"
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
            "$YCSB" run "$YCSB_BINDING" -s \
            -P "$WORKLOAD_PHASE" -P "$JDBC_PROPERTIES" \
            "${DB_PARAMS[@]}" \
            -p fieldlengthdistribution=constant \
            -p fieldlength="$fieldlengthoriginal"

        # Extract extend failure count from YCSB output (status messages are in the output)
        extend_failed_count=$(grep -oP 'EXTEND-FAILED: Count=\K\d+' "$OUTPUT_CSV" 2>/dev/null | head -1 || echo "0")
        if [ -n "$extend_failed_count" ] && [ "$extend_failed_count" != "0" ]; then
            log "WARNING: $extend_failed_count EXTEND operations failed during extend phase"
        fi
        
        collect_cpu_memory_metrics
        backend::collect_metrics $DB_NAME
        write_result "FALSE"

        # Key Sizes
        log "Size computation started"
        backend::key_sizes "$DB_NAME" "$KEY_SIZE_LOG"
        
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
        iteration=$((STEPS_PER_EPOCH*($epoch-1)+$step))

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
            vacuum_detail="${LOG_FILE%.log}_iteration${iteration}_epoch${epoch}_step${step}_vacuum.raw.log"

            log "START VACUUM ANALYZE database=$DB_NAME"

            backend::exec -d "$DB_NAME" \
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
        log "=== Generating the measured workload ==="
        WORKLOAD_PHASE="$(workload::generate run "$iteration")"
        workload::apply_context "$WORKLOAD_PHASE"

        # Save the existing keys in the database
        backend::list_keys "$DB_NAME" keys_before_run.txt

        # Log query plan before run phase
        log "Checking query plan before run phase"

        TEST_KEY=$(backend::exec -d "$DB_NAME" -At -c \
        "SELECT ycsb_key FROM usertable LIMIT 1;")

        {
            echo "========================================"
            echo "Epoch=$epoch Step=$step Phase=run Time=$(date)"
            echo "DB=$DB_NAME"
            echo "Key=$TEST_KEY"
            echo "----------------------------------------"

            backend::exec -d "$DB_NAME" -c "
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT * FROM usertable WHERE ycsb_key = '$TEST_KEY';
            "

            echo
        } >> "$PLAN_LOG"
        log "END query plan"

        # Execute the run phase
        log "Preparing run workload: read=$readproportion update=$updateproportion extend=$extendproportion"
        phase="run"
        binding_db_params "$DB_URL"
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        "$YCSB" run "$YCSB_BINDING" -s \
        -P "$WORKLOAD_PHASE" \
        -P "$JDBC_PROPERTIES" \
        "${DB_PARAMS[@]}" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE"

        collect_cpu_memory_metrics
        backend::collect_metrics $DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        backend::list_keys "$DB_NAME" keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | backend::exec -d "$DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        backend::list_keys "$UNCHANGED_DB_NAME" keys_before_run.txt

		# wait for all backend processes to finish before doing clean run (max 20 mins)
		backend::wait_idle "$DB_NAME" 20 1200

        # Reference workload with unchanging value sizes
        phase="reference"
        WORKLOAD_PHASE="$(workload::generate reference "$iteration")"
        workload::apply_context "$WORKLOAD_PHASE"
        binding_db_params "$UNCHANGED_DB_URL"
        run_with_metrics "$UNCHANGED_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        "$YCSB" run "$YCSB_BINDING" -s \
        -P "$WORKLOAD_PHASE" \
        -P "$JDBC_PROPERTIES" \
        "${DB_PARAMS[@]}" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        collect_cpu_memory_metrics
        backend::collect_metrics $UNCHANGED_DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        backend::list_keys "$UNCHANGED_DB_NAME" keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | backend::exec -d "$UNCHANGED_DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt
    
        # if (( $((STEPS_PER_EPOCH*($epoch-1)+$step)) % 1 == 0 )); then
        if (( COMPARISON_INTERVAL > 0 && iteration % COMPARISON_INTERVAL == 0 )); then
            phase="clean-run"
            
            log "Backing up the database started"
            RESTORE_LOG="./${EXPERIMENT_NAME}_iteration${iteration}_epoch${epoch}_step${step}_restore.log"
            backend::dump_restore
            log "Backing up the database finished"

			# wait for all backend processes to finish before doing clean run (max 20 mins)
			backend::wait_idle "$DB_NAME" 20 1200

			WORKLOAD_PHASE="$(workload::generate clean-run "$iteration")"
                workload::apply_context "$WORKLOAD_PHASE"
			binding_db_params "$BACKUP_URL"
			run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                "$YCSB" run "$YCSB_BINDING" -s \
                -P "$WORKLOAD_PHASE" \
                -P "$JDBC_PROPERTIES" \
                "${DB_PARAMS[@]}" \
                -p fieldlengthhistogram="$HISTOGRAM_FILE"
                
			collect_cpu_memory_metrics
            backend::collect_metrics $BACKUP_DB_NAME
            rm -rf "$BACKUP_FILE"
            write_result "FALSE"

            # Key Sizes
            log "Size computation started"
            backend::key_sizes "$BACKUP_DB_NAME" "$KEY_SIZE_LOG"
            
            log "END size computation database=$BACKUP_DB_NAME"

            # Check if the output file exists, if not, create it with headers
            iteration=$((STEPS_PER_EPOCH*($epoch-1)+$step))
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
            recordcount="$(workload::get_value "$WORKLOAD_PHASE" recordcount)"

            # PostgreSQL query to get the total size of all records
            total_size=$(backend::total_size "$BACKUP_DB_NAME")

            # Set average field length
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            log "Total size: $total_size, Field length average: $fieldlengthaverage"

            # The comparison database is reloaded at the measured average value size.
            WORKLOAD_PHASE="$(workload::generate comparison-load "$iteration")"
            actual_fieldlength="$(workload::get_value "$WORKLOAD_PHASE" fieldlength)"
            log "Workload file fieldlength set to: $actual_fieldlength (expected: $fieldlengthaverage)"

            backend::exec -d "$BACKUP_DB_NAME" \
            -c "TRUNCATE TABLE usertable;"

            # Resetting the database with new data load
            phase="comparison-load"
            log "=== Executing the load phase for the comparison study ==="
            binding_db_params "$BACKUP_URL"
            run_ycsb "comparison-load" load "$YCSB_BINDING" -s -P "$WORKLOAD_PHASE" -P "$JDBC_PROPERTIES" "${DB_PARAMS[@]}"
            total_size_comparison_load=$(backend::total_size "$BACKUP_DB_NAME")
            log "Comparison-load verification - Epoch:$epoch Step:$step TotalSize:$total_size_comparison_load ExpectedFieldLength:$fieldlengthaverage"

            # Verify record sizes after avg-run load
            iteration=$((STEPS_PER_EPOCH*($epoch-1)+$step))
            total_size_avg_run=$(backend::total_size "$BACKUP_DB_NAME")
            log "Avg-run verification - Epoch:$epoch Step:$step Iteration:$iteration TotalSize:$total_size_avg_run ExpectedFieldLength:$fieldlengthaverage"
            
            # The avg-run compares at the original value size again.
            WORKLOAD_PHASE="$(workload::generate avg-run "$iteration")"
            workload::apply_context "$WORKLOAD_PHASE"

			# wait for all backend processes to finish before doing clean run (max 20 mins)
			backend::wait_idle "$DB_NAME" 20 1200

            # Execute the run phase
            log "Preparing run workload: read=$readproportion update=$updateproportion extend=$extendproportion"
            phase="avg-run"
            binding_db_params "$BACKUP_URL"
            run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                "$YCSB" run "$YCSB_BINDING" -s \
                -P "$WORKLOAD_PHASE" \
                -P "$JDBC_PROPERTIES" \
                "${DB_PARAMS[@]}"

            collect_cpu_memory_metrics
            backend::collect_metrics $BACKUP_DB_NAME
            write_result "FALSE"
        fi
        log "END iteration"
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf "$KEY_SIZE_LOG"

log "=== All steps completed. Results are logged in $LOG_FILE ==="
EXPERIMENT_COMPLETED=1
}
