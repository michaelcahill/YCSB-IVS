#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Configuration for an experiment run.
#
# Precedence, later wins:
#   built-in defaults -> backend::default_config -> conf/ preset (--config)
#                     -> environment variables    -> CLI flags (--var, --epochs, …)
#
# Every knob is written `${VAR:-default}` so any of those layers can set it.
# Derived paths are computed separately and recomputed after overrides, so a preset
# or flag that changes TYPE/SCALE/RUN also renames the artefacts consistently.

config::init_defaults() {
    # Connection / schema settings come from the backend.
    backend::default_config

    # --- experiment identity ---------------------------------------------------
    TYPE="${TYPE:-$(registry::info default_type)}"
    YCSB_BINDING="${YCSB_BINDING:-$(registry::info default_binding)}"
    SCALE="${SCALE:-heavy}"                     # "heavy" OR "light"
    EXTEND_DIST="${EXTEND_DIST:-zipfian}"       # "uniform" OR "zipfian"
    WORKLOAD="${WORKLOAD:-readonly-uniform}"    # e.g. "readonly-uniform", "mixed", "pure"
    RUN="${RUN:-1}"

    # --- run size --------------------------------------------------------------
    NUM_EPOCHS="${NUM_EPOCHS:-10}"
    STEPS_PER_EPOCH="${STEPS_PER_EPOCH:-10}"
    COMPARISON_INTERVAL="${COMPARISON_INTERVAL:-1}"   # 0 disables clean-run/avg-run

    # --- VACUUM ----------------------------------------------------------------
    VACUUM_ENABLED="${VACUUM_ENABLED:-0}"
    vacuum="$VACUUM_ENABLED"                    # legacy name still used by the engine

    # --- workload phases -------------------------------------------------------
    # Extend phase: grow the values, nothing else.
    extendproportion_extend="${EXTEND_PROPORTION_EXTEND:-1}"
    readproportion_extend="${READ_PROPORTION_EXTEND:-0}"
    updateproportion_extend="${UPDATE_PROPORTION_EXTEND:-0}"
    scanproportion_extend="${SCAN_PROPORTION_EXTEND:-0}"
    insertproportion_extend="${INSERT_PROPORTION_EXTEND:-0}"
    readmodifywriteproportion_extend="${READMODIFYWRITE_PROPORTION_EXTEND:-0}"
    requestdistribution_extend="${REQUESTDISTRIBUTION_EXTEND:-$EXTEND_DIST}"
    readrequestdistribution_extend="${READREQUESTDISTRIBUTION_EXTEND:-$EXTEND_DIST}"
    updaterequestdistribution_extend="${UPDATEREQUESTDISTRIBUTION_EXTEND:-$EXTEND_DIST}"

    # After extend: the measured workload (default: pure reads, uniform).
    extendproportion_postextend="${EXTEND_PROPORTION_POSTEXTEND:-0}"
    readproportion_postextend="${READ_PROPORTION_POSTEXTEND:-1}"
    updateproportion_postextend="${UPDATE_PROPORTION_POSTEXTEND:-0}"
    scanproportion_postextend="${SCAN_PROPORTION_POSTEXTEND:-0}"
    insertproportion_postextend="${INSERT_PROPORTION_POSTEXTEND:-0}"
    readmodifywriteproportion_postextend="${READMODIFYWRITE_PROPORTION_POSTEXTEND:-0}"
    requestdistribution_postextend="${REQUESTDISTRIBUTION_POSTEXTEND:-uniform}"
    readrequestdistribution_postextend="${READREQUESTDISTRIBUTION_POSTEXTEND:-uniform}"
    updaterequestdistribution_postextend="${UPDATEREQUESTDISTRIBUTION_POSTEXTEND:-uniform}"

    fieldlengthoriginal="${FIELDLENGTHORIGINAL:-100}"
    extendoperationcount="${EXTEND_OPERATIONCOUNT:-100000}"

    # --- watcher.sh parameters -------------------------------------------------
    DB_STATS_INTERVAL="${DB_STATS_INTERVAL:-60}"
    OS_DISK_DEVICES="${OS_DISK_DEVICES:-auto}"
}

# Derive every path from the experiment identity. Must run AFTER all configuration
# layers (defaults, backend, --config, environment, CLI) so that overriding TYPE,
# SCALE or RUN renames every artefact consistently.
config::derive_paths() {
    EXPERIMENT_NAME="${EXPERIMENT_NAME_OVERRIDE:-${TYPE}_${SCALE}_extend-${EXTEND_DIST}_${WORKLOAD}_run${RUN}}"

    # Define input and output filenames
    WORKLOAD_FILE="${WORKLOAD_FILE:-../workloads/$(registry::info default_workload)}"
    EXPERIMENT_DIR="${EXPERIMENT_DIR:-../analysis/experiments/ycsb_${EXPERIMENT_NAME}}"
    LOG_DIR="$EXPERIMENT_DIR/logs"
    LOG_FILE="$LOG_DIR/ycsb_${EXPERIMENT_NAME}_results.log"
    OUTPUT_CSV="$LOG_DIR/${TYPE}_output.csv"
    INPUT_FILE="$LOG_DIR/${TYPE}_output.csv"
    OUTPUT_FILE="$EXPERIMENT_DIR/data/workload_data/${EXPERIMENT_NAME}.csv"

    # Key size gathering
    KEY_SIZE_LOG="$EXPERIMENT_DIR/data/key_sizes_${EXPERIMENT_NAME}.csv"
    KEY_SIZE_FILE_AFTER_EXTEND="$EXPERIMENT_DIR/data/value_size_data/value_sizes_${TYPE}_${SCALE}_run${RUN}_extend-${EXTEND_DIST}_before_${WORKLOAD}.csv"
    KEY_SIZE_FILE_AFTER_RUN="$EXPERIMENT_DIR/data/value_size_data/value_sizes_${TYPE}_${SCALE}_run${RUN}_extend-${EXTEND_DIST}_after_${WORKLOAD}.csv"
    HISTOGRAM_FILE="$LOG_DIR/histogram.txt"

    # Query plan log
    PLAN_LOG="$LOG_DIR/${EXPERIMENT_NAME}_query_plan.log"
}

# Apply KEY=VALUE overrides coming from --var on the command line.
config::apply_var() {
    local assignment="${1:?KEY=VALUE required}" key value
    [[ "$assignment" == *=* ]] || { echo "[error] --var expects KEY=VALUE, got: $assignment" >&2; return 2; }
    key="${assignment%%=*}"
    value="${assignment#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "[error] invalid variable name: $key" >&2; return 2; }
    export "$key=$value"
}
