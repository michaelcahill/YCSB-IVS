#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Configuration for an experiment run.
#
# Precedence, later wins:
#   built-in defaults -> backend::default_config -> conf/db.<backend>.env
#                     -> --config FILE (presets such as conf/scale.heavy.env)
#                     -> environment variables   -> CLI flags (--var, --epochs, …)
#
# Every knob is written `${VAR:-default}` so any of those layers can set it.
# Derived paths are computed separately and recomputed after overrides, so a preset
# or flag that changes TYPE/SCALE/RUN also renames the artefacts consistently.
#
# Configuration files are PARSED, not executed: they may contain comments and
# `KEY=VALUE` assignments only. That is what makes "the environment beats a file"
# implementable without snapshotting the whole process environment.

# Names that were already in the environment when the runner started (plus the ones
# set by CLI flags). Layers below the environment must not change them.
declare -gA CONFIG_ENV_NAMES=()
# Files actually applied, for --dry-run and for the run log.
declare -ga CONFIG_SOURCES=()

config::snapshot_env() {
    local name
    while IFS= read -r name; do
        CONFIG_ENV_NAMES["$name"]=1
    done < <(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')
    return 0
}

# Set a variable on behalf of the command line: highest precedence, so the name is
# registered as part of the environment layer.
config::set_cli() {
    local assignment="${1:?KEY=VALUE required}" key
    key="${assignment%%=*}"
    # shellcheck disable=SC2163  # the assignment string itself is what we export
    export "$assignment"
    CONFIG_ENV_NAMES["$key"]=1
}

# config::load_file FILE — apply a KEY=VALUE configuration file.
config::load_file() {
    local file="${1:?configuration file required}" line key value lineno=0 skipped=0
    local subshell='$(' backquote='`'
    [[ -r "$file" ]] || { echo "[error] cannot read config file: $file" >&2; return 2; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" == *=* ]] || {
            echo "[error] $file:$lineno: expected KEY=VALUE, got: $line" >&2
            return 2
        }
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            echo "[error] $file:$lineno: invalid variable name: $key" >&2
            return 2
        }
        if [[ "$value" == *"$subshell"* || "$value" == *"$backquote"* ]]; then
            echo "[error] $file:$lineno: configuration files are parsed, not executed; remove the substitution from $key" >&2
            return 2
        fi
        # Strip one layer of matching quotes.
        if [[ "$value" == \?* && "$value" == *\? && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \"* && "$value" == *\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi
        if [[ -n "${CONFIG_ENV_NAMES[$key]:-}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        export "$key=$value"
    done < "$file"

    CONFIG_SOURCES+=("$file")
    if (( skipped )); then
        echo "[config] $file: $skipped assignment(s) ignored, the environment already sets them"
    fi
}

# Load the per-backend credential/endpoint file when it exists. Everything else in
# conf/ is applied explicitly with --config, because a preset that silently changed the
# dataset size would change what a run measures.
config::load_layered_files() {
    local file="$CONF_DIR/db.$ACTIVE_BACKEND.env"
    [[ -r "$file" ]] && config::load_file "$file"
    return 0
}

# --- legacy launcher compatibility -------------------------------------------
#
# EC2 launchers written against the old scripts export the old variable names. They are
# translated here, before defaults are applied, so an existing launcher keeps working.
# The canonical name always wins when both are present.
#
# Removed one release after the runbook is rewritten (REFACTOR_PLAN.md step 7).
config::legacy_alias() {
    local legacy="$1" canonical="$2"
    local old="${!legacy-}" new="${!canonical-}"
    [[ -n "$old" ]] || return 0
    if [[ -n "$new" ]]; then
        [[ "$old" == "$new" ]] ||
            echo "[config] legacy $legacy=$old ignored, $canonical=$new wins"
        return 0
    fi
    export "$canonical=$old"
    echo "[config] deprecated: $legacy is used as $canonical (update the launcher)"
}

config::apply_legacy_aliases() {
    # identity and naming
    config::legacy_alias DIST EXTEND_DIST
    config::legacy_alias WORK WORKLOAD
    config::legacy_alias UNCHANGE_DB_NAME UNCHANGED_DB_NAME

    # run size
    config::legacy_alias EXPERIMENT_EPOCHS NUM_EPOCHS
    config::legacy_alias EXPERIMENT_RUNS_PER_EPOCH STEPS_PER_EPOCH

    # connection and credentials
    config::legacy_alias DB_PASSWORD DB_PWD

    # schema / workload shape
    config::legacy_alias FIELD_LENGTH_ORIGINAL FIELDLENGTHORIGINAL
    config::legacy_alias EXTENDOPERATIONCOUNT EXTEND_OPERATIONCOUNT
    config::legacy_alias VACUUM VACUUM_ENABLED
    config::legacy_alias vacuum VACUUM_ENABLED

    # Per-phase proportions: EXTEND_<X> drove the extend phase, RUN_<X> the measured
    # (post-extend) phase. Table rows are "<setting> <extend-name> <postextend-name>".
    local setting extend postextend
    while read -r setting extend postextend; do
        [[ -n "$setting" ]] || continue
        config::legacy_alias "EXTEND_$setting" "$extend"
        config::legacy_alias "RUN_$setting" "$postextend"
    done <<'ALIASES'
EXTENDPROPORTION            EXTEND_PROPORTION_EXTEND      EXTEND_PROPORTION_POSTEXTEND
READPROPORTION              READ_PROPORTION_EXTEND        READ_PROPORTION_POSTEXTEND
UPDATEPROPORTION            UPDATE_PROPORTION_EXTEND      UPDATE_PROPORTION_POSTEXTEND
SCANPROPORTION              SCAN_PROPORTION_EXTEND        SCAN_PROPORTION_POSTEXTEND
INSERTPROPORTION            INSERT_PROPORTION_EXTEND      INSERT_PROPORTION_POSTEXTEND
READMODIFYWRITEPROPORTION   READMODIFYWRITE_PROPORTION_EXTEND  READMODIFYWRITE_PROPORTION_POSTEXTEND
REQUESTDISTRIBUTION         REQUESTDISTRIBUTION_EXTEND    REQUESTDISTRIBUTION_POSTEXTEND
READREQUESTDISTRIBUTION     READREQUESTDISTRIBUTION_EXTEND  READREQUESTDISTRIBUTION_POSTEXTEND
UPDATEREQUESTDISTRIBUTION   UPDATEREQUESTDISTRIBUTION_EXTEND  UPDATEREQUESTDISTRIBUTION_POSTEXTEND
ALIASES
    return 0
}

# Legacy knobs that belong to the full-visibility instrumentation module (step 8b).
# They are recognised so a stale launcher fails with a clear message instead of
# silently running without its instrumentation.
config::warn_deferred_legacy() {
    local name value ignored=()
    for name in REQUIRE_FULL_VISIBILITY SAMPLE_INTERVAL_SECONDS \
                RELATION_SIZE_SAMPLE_INTERVAL_SECONDS DETOAST_PROBE_ENABLED \
                TRACE_START_EPOCH_SECONDS BENCHRUN_FULL_VISIBILITY \
                SPIKE_TRIGGER_TRACE_ENABLED SPIKE_TRIGGER_PREWARM_ENABLED \
                SPIKE_TRIGGER_WALINSPECT_ENABLED SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED; do
        value="${!name-}"
        [[ -z "$value" ]] || ignored+=("$name")
    done
    (( ${#ignored[@]} == 0 )) && return 0
    echo "[config] WARNING: instrumentation variables are not supported by experiment.sh yet:" >&2
    printf '[config]            %s\n' "${ignored[@]}" >&2
    echo "[config]            they land with the postgresql_fullview module (REFACTOR_PLAN.md step 8b);" >&2
    echo "[config]            until then use experiment_postgresql_array_json.sh for full-visibility runs." >&2
    return 0
}

config::init_defaults() {
    # Connection / schema settings come from the backend.
    backend::default_config

    # Prefix of the YCSB properties that carry the connection settings. The JDBC bindings
    # read db.url/db.user/db.passwd, other bindings namespace them (postgrenosql.url, …), and
    # some name them without any prefix at all - neo4j reads url/username/password, so the three
    # full names are the contract point and the prefix only supplies their defaults.
    # `${VAR-default}`, not `${VAR:-default}`: a backend may also *remove* one of the three by
    # setting it to the empty string, because the binding has no such property (couchbase2 reads
    # no username - SDK 2.x authenticates as the bucket itself).
    BINDING_PARAM_PREFIX="${BINDING_PARAM_PREFIX:-db}"
    BINDING_PARAM_URL="${BINDING_PARAM_URL-${BINDING_PARAM_PREFIX}.url}"
    BINDING_PARAM_USER="${BINDING_PARAM_USER-${BINDING_PARAM_PREFIX}.user}"
    BINDING_PARAM_PASSWD="${BINDING_PARAM_PASSWD-${BINDING_PARAM_PREFIX}.passwd}"

    # Dialect of the per-second runtime sampler (watcher.sh). It speaks one database's stats
    # views; a backend that does not name one here gets OS-level sampling only, and no
    # statistics file rather than an empty file in another database's shape.
    RUNTIME_DB_DIALECT="${RUNTIME_DB_DIALECT:-$(registry::info runtime_watcher_dialect)}"

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

    # --- workload template overrides (applied by lib/workload.sh) --------------
    # Empty means "whatever the template says"; conf/scale.*.env sets them.
    recordcount_override="${RECORDCOUNT:-}"
    operationcount_override="${OPERATIONCOUNT:-}"
    fieldlengthdistribution="${FIELDLENGTHDISTRIBUTION:-histogram}"

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

    # Generated, immutable workload files (lib/workload.sh). Never write to workloads/.
    WORKLOAD_DIR="${WORKLOAD_DIR:-$EXPERIMENT_DIR/workloads}"

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
    local assignment="${1:?KEY=VALUE required}" key
    [[ "$assignment" == *=* ]] || { echo "[error] --var expects KEY=VALUE, got: $assignment" >&2; return 2; }
    key="${assignment%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "[error] invalid variable name: $key" >&2; return 2; }
    config::set_cli "$assignment"
}
