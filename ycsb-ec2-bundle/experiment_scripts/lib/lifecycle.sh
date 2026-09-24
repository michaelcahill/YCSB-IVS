#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# The experiment engines.
#
#   mainline (default)  load -> reference-load -> [extend -> measure -> reference
#                       -> comparison] x (epochs x steps)
#   baseline            load -> [extend -> measure] x (epochs x steps)
#                       — lib/lifecycle_baseline.sh, selected with `--mode baseline`
#
# Everything below is therefore shared by both modes: the YCSB invocation helpers and one
# function per phase step. A mode is a *sequence of steps*, never a copy of them, which is
# what makes a baseline measurement comparable with a mainline measurement of the same
# workload — the difference between the modes is the phases they run, not how those phases
# are executed or measured.
#
# This is backend-independent apart from calls through the backend contract. It reads its
# configuration from the globals prepared by lib/config.sh, never writes to a workload file:
# every YCSB invocation gets an immutable generated file from lib/workload.sh, and writes its
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
# bindings read db.url/db.user/db.passwd, PostgreNoSQL reads postgrenosql.url/…, Neo4j reads
# url/username/password with no prefix at all, and MongoDB has no credential properties
# (everything is in the URI). BINDING_PARAM_URL/USER/PASSWD come from the backend (via the
# prefix) and BINDING_PARAM_CREDENTIALS says whether to send any. Sets the global DB_PARAMS
# array; every YCSB invocation expands it.
binding_db_params() {
    local url="${1:?database url required}" extra
    DB_PARAMS=(-p "${BINDING_PARAM_URL:-db.url}=$url")
    if [[ "${BINDING_PARAM_CREDENTIALS:-1}" == 1 ]]; then
        # A property name may be empty when the binding has no such property: couchbase2 sends no
        # username at all (SDK 2.x authenticates as the bucket), so only its password goes out.
        [[ -n "${BINDING_PARAM_USER-db.user}" ]] && DB_PARAMS+=(-p "${BINDING_PARAM_USER-db.user}=$DB_USERNAME")
        [[ -n "${BINDING_PARAM_PASSWD-db.passwd}" ]] && DB_PARAMS+=(-p "${BINDING_PARAM_PASSWD-db.passwd}=$DB_PWD")
    fi
    # Optional hook: further `-p key=value` properties a binding needs to be told about on every
    # invocation (couchbase2: host, adhoc/kv/boost, core's insertion retries). Empty by default,
    # so for every other backend the command line is unchanged.
    while IFS= read -r extra; do
        [[ -n "$extra" ]] && DB_PARAMS+=(-p "$extra")
    done < <(backend::extra_binding_params)
    return 0
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
    local os_disk_device_file=""

    metrics_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.metrics"
    db_stats_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.dbstats"
    # Per-second host sampling: the .osstats rates CSV (disk rates, CPU iowait, block-I/O
    # pressure stall information) and the .diskstats record of which devices those rates cover.
    # Both are read from /proc only, so every backend gets them; OS_STATS_ENABLED=0 skips the
    # sampler's per-phase files (the .metrics summary is always written).
    if [[ "${OS_STATS_ENABLED:-1}" == 1 ]]; then
        os_1s_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.osstats"
        os_disk_device_file="${LOG_DIR}/${db_name}_${EXPERIMENT_NAME}_${phase}.diskstats"
    fi

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
        OS_DISK_DEVICE_FILE="$os_disk_device_file" \
        OS_DISK_DEVICES="$OS_DISK_DEVICES" \
        DB_STATS_TABLE="$TARGET_TABLE" \
        DB_DIALECT="${RUNTIME_DB_DIALECT:-}" \
        OS_PROCESS_USER="${HOST_OS_USER:-}" \
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

# ---------------------------------------------------------------------------
# Shared setup and phase steps
#
# Each step is one YCSB invocation plus the measurements that belong to it. Both engines
# call them, so a step behaves identically in every mode and no mode can drift from another.
# ---------------------------------------------------------------------------

# experiment_bootstrap NEEDS_DUMP DATABASE...
#
# All read-only checks must finish before clearing outputs or dropping databases. NEEDS_DUMP
# tells preflight whether this mode dumps and restores a comparison database (pg_dump is only
# required then); DATABASE names the databases the mode creates, all three configured names are
# always validated so that a collision fails before any work is thrown away.
experiment_bootstrap() {
    local needs_dump="${1:-true}"
    shift

    start_logging
    log "START preflight"
    backend::preflight "$needs_dump" "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"
    workload::init
    log "END preflight"
    mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$KEY_SIZE_FILE_AFTER_EXTEND")"

    # Clear the log file and previous backups
    : > "$PLAN_LOG"
    : > "$HISTOGRAM_FILE"

    rm -rf "$KEY_SIZE_LOG"
    rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"

    local database
    for database in "$@"; do
        backend::init_db "$database"
    done
}

# The initial load of the measured database. It also writes the results CSV header, so every
# mode calls it exactly once, before its loop.
run_load_phase() {
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
}

# The reference database keeps the original value size for the reference phases. It is
# prepared, not measured, so its rows never reach the results CSV.
run_reference_load_phase() {
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
}

# Grow the values of the measured database, then measure it. The per-key sizes gathered here
# feed both the histogram that gives later phases extended-size values and the value-size CSV
# that is one of this harness's two primary artefacts.
run_extend_phase() {
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
            }
        }
    ' "$KEY_SIZE_LOG")
    log "Extend verification - $extend_stats (Expected avg per record: ~$((10 * fieldlengthoriginal)) bytes initially)"

    log "END size computation database=$DB_NAME"

    get_key_sizes $KEY_SIZE_LOG $HISTOGRAM_FILE

    merge_value_sizes "$KEY_SIZE_FILE_AFTER_EXTEND"
}

# Merge a $KEY_SIZE_LOG snapshot into the wide per-iteration value-size CSV, creating its
# header on the first iteration and adding one Run<iteration> column afterwards. The caller
# decides which database was snapshotted (the measured one after extend, the comparison copy
# after clean-run), because that is the only difference between the two call sites.
merge_value_sizes() {
    local file="${1:?target CSV required}"
    if [[ ! -f "$file" ]]; then
        # Add header row
        echo "Key,Run$iteration" > "$file"
    fi

    # If it's the first iteration, append keys and sizes for the first run
    if [[ "$iteration" -eq 1 ]]; then
        append_first_iteration "$KEY_SIZE_LOG" "$file"
    else
        append_subsequent_iterations "$KEY_SIZE_LOG" "$file"
    fi
}

# Reclaim space and refresh planner statistics between phases, for backends where that is a
# manual operation (PostgreSQL). What it means is a backend detail; whether the run asks for
# it at all is the VACUUM setting.
vacuum_if_enabled() {
    if (( vacuum == 1 )) && registry::capability supports_vacuum; then
        backend::vacuum "$DB_NAME"
    fi
}

# Remember which keys exist now, so that the inserts of a measured phase can be removed after
# it: every phase must measure the same key space.
snapshot_keys() {
    backend::list_keys "${1:?database required}" keys_before_run.txt
}

# Delete every key that appeared since snapshot_keys.
remove_new_keys() {
    local database="${1:?database required}"

    # Save keys to remove duplicates later
    backend::list_keys "$database" keys_after_run.txt

    # Sort both files
    sort keys_before_run.txt > keys_before_sorted.txt
    sort keys_after_run.txt > keys_after_sorted.txt

    # Get keys that are in keys_after_run.txt but not in keys.txt
    comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

    backend::delete_keys "$database" keys_to_delete.txt

    rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt
}

# The measured phase: read/update/extend the extended database at its real value sizes.
run_measured_phase() {
    phase="run-setup"
    log "=== Generating the measured workload ==="
    WORKLOAD_PHASE="$(workload::generate run "$iteration")"
    workload::apply_context "$WORKLOAD_PHASE"

    # Save the existing keys in the database
    snapshot_keys "$DB_NAME"

    # Log the plan of a single-key lookup before the measured phase, for backends that
    # can explain one. The statement text and its output format are backend details.
    log "Checking query plan before run phase"
    if registry::capability supports_query_plan; then
        TEST_KEY="$(backend::sample_key "$DB_NAME")"
        {
            echo "========================================"
            echo "Epoch=$epoch Step=$step Phase=run Time=$(date)"
            echo "DB=$DB_NAME"
            echo "Key=$TEST_KEY"
            echo "----------------------------------------"

            backend::explain_sql "$DB_NAME" "$TEST_KEY"

            echo
        } >> "$PLAN_LOG"
    fi
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

    remove_new_keys "$DB_NAME"
}

# The same measured workload against the reference database, whose values never grew: that
# difference is the cost of value growth itself.
run_reference_phase() {
    snapshot_keys "$UNCHANGED_DB_NAME"

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

    remove_new_keys "$UNCHANGED_DB_NAME"
}

# The comparison study on a snapshot of the measured database: clean-run (a freshly restored
# copy at the current sizes), then a reload at the measured average value size and avg-run,
# which compares at the original value size again.
run_comparison_phases() {
    phase="clean-run"

    log "Backing up the database started"
    # Under $LOG_DIR (not the current directory): a run's artefacts are all in one place, and
    # dump_restore expects the directory to exist before it writes the log.
    RESTORE_LOG="$LOG_DIR/restore_logs/${EXPERIMENT_NAME}_iteration${iteration}_epoch${epoch}_step${step}_restore.log"
    mkdir -p "$(dirname "$RESTORE_LOG")"
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

    merge_value_sizes "$KEY_SIZE_FILE_AFTER_RUN"

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

    backend::truncate "$BACKUP_DB_NAME"

    # Resetting the database with new data load
    phase="comparison-load"
    log "=== Executing the load phase for the comparison study ==="
    binding_db_params "$BACKUP_URL"
    run_ycsb "comparison-load" load "$YCSB_BINDING" -s -P "$WORKLOAD_PHASE" -P "$JDBC_PROPERTIES" "${DB_PARAMS[@]}"
    total_size_comparison_load=$(backend::total_size "$BACKUP_DB_NAME")
    log "Comparison-load verification - Epoch:$epoch Step:$step TotalSize:$total_size_comparison_load ExpectedFieldLength:$fieldlengthaverage"

    # Verify record sizes after avg-run load
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
}

# The completion marker finish_logging requires: a run that returns without it is reported as
# a failure, whatever its exit status says.
experiment_complete() {
    log "=== All steps completed. Results are logged in $LOG_FILE ==="
    EXPERIMENT_COMPLETED=1
}

# The phase sequence of the selected mode, spelled out for --dry-run. It lives next to the
# engines that run it, so the summary cannot promise phases no engine executes.
experiment::describe_phases() {
    case "${EXPERIMENT_MODE:-mainline}" in
        baseline)
            printf 'load -> (extend -> run) x epochs*steps\n' ;;
        *)
            printf 'load -> reference-load -> (extend -> run -> reference -> clean-run -> comparison-load -> avg-run) x epochs*steps\n' ;;
    esac
}

# Run the whole experiment. Assumes libs + a backend are sourced and config has been
# applied (experiment.sh does both). The mode selects the phase sequence, never the way a
# phase is executed: see lib/lifecycle_baseline.sh for the other engine.
run_experiment() {
    case "${EXPERIMENT_MODE:-mainline}" in
        mainline) run_experiment_mainline ;;
        baseline) run_experiment_baseline ;;
        *)
            echo "[error] unknown experiment mode: ${EXPERIMENT_MODE} (expected mainline or baseline)" >&2
            return 2
            ;;
    esac
}

run_experiment_mainline() {
    local -a DB_PARAMS=()

    # The comparison database is created by backend::dump_restore, not here.
    experiment_bootstrap true "$DB_NAME" "$UNCHANGED_DB_NAME"

    # Execute the load phase
    run_load_phase

    # Load unchange value size (reference) DB
    run_reference_load_phase

    # Experiment parameters
    for epoch in $(seq 1 "$NUM_EPOCHS"); do
        for step in $(seq 1 "$STEPS_PER_EPOCH"); do

            iteration=$((STEPS_PER_EPOCH * ($epoch - 1) + $step))

            run_extend_phase
            vacuum_if_enabled
            run_measured_phase
            run_reference_phase

            # if (( $((STEPS_PER_EPOCH*($epoch-1)+$step)) % 1 == 0 )); then
            if (( COMPARISON_INTERVAL > 0 && iteration % COMPARISON_INTERVAL == 0 )); then
                run_comparison_phases
            fi
            log "END iteration"
        done
    done

    # Delete intermediate temp files
    # rm -rf $LOG_FILE
    # rm -rf $OUTPUT_CSV
    # rm -rf "$KEY_SIZE_LOG"

    experiment_complete
}
