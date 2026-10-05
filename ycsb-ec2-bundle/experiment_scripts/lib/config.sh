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
#
# A backend may name a family (conf_family in its info block): db.<family>.env carries the
# settings several backends share on one server — the four PostgreSQL schemas share
# db.postgresql.env, which is also where the --init administrator connection lives. The
# per-backend file loads after it and wins on a clash; both lose to the environment.
config::load_layered_files() {
    local file family
    family="$(registry::info conf_family)"
    if [[ -n "$family" ]]; then
        file="$CONF_DIR/db.$family.env"
        [[ -r "$file" ]] && config::load_file "$file"
    fi
    file="$CONF_DIR/db.$ACTIVE_BACKEND.env"
    [[ -r "$file" ]] && config::load_file "$file"
    return 0
}

# Synonyms for the variable names used by the last pre-refactor runners (the postgrenosql and
# array-text experiment scripts on master). They are accepted so an old invocation line still
# describes the same experiment; the canonical name always wins, so `--var`, a preset or the
# environment setting NUM_EPOCHS is never overruled by EPOCHS. Unlike the deleted backend-name
# aliases these names never select *what* runs, only how large it is.
config::apply_legacy_names() {
    local -A legacy_names=(
        [EPOCHS]=NUM_EPOCHS                       # master: epochs
        [RUNS_PER_EPOCH]=STEPS_PER_EPOCH          # master: steps per epoch
        [EXTENDOPERATIONCOUNT]=EXTEND_OPERATIONCOUNT
        [DIST]=EXTEND_DIST                        # master: extend request distribution
        [WORK]=WORKLOAD                           # master: workload name part
        # master's RESUME_FROM_EPOCH was compared against the global iteration, so it resumes
        # by iteration; its -1 (and 0) meant "run everything", which is RESUME_FROM_ITERATION=0.
        [RESUME_FROM_EPOCH]=RESUME_FROM_ITERATION
    )
    local legacy canonical
    for legacy in "${!legacy_names[@]}"; do
        canonical="${legacy_names[$legacy]}"
        [[ -z "${!legacy:-}" ]] && continue       # not given under the old name either
        [[ -n "${!canonical:-}" ]] && continue    # canonical name already set: it wins
        printf -v "$canonical" '%s' "${!legacy}"
        # shellcheck disable=SC2163  # the canonical name is what we export
        export "$canonical"
        echo "[config] $legacy=${!legacy} is a synonym for $canonical=${!canonical}" >&2
    done
    return 0
}

config::init_defaults() {
    # Old (master) names are folded in before any default reads a canonical name.
    config::apply_legacy_names

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

    # --- experiment mode -------------------------------------------------------
    # mainline: the full phase sequence, including both comparison databases.
    # baseline: load -> [extend -> measure] only (lib/lifecycle_baseline.sh).
    EXPERIMENT_MODE="${EXPERIMENT_MODE:-mainline}"
    case "$EXPERIMENT_MODE" in
        mainline) MODE_SUFFIX="" ;;
        baseline)
            # Artefacts of a baseline run must never overwrite the mainline run they are
            # compared with, so the mode is part of every generated name.
            MODE_SUFFIX="_baseline"
            # Not merely unused: a baseline run has nothing to compare against, and an
            # interval left at 1 would suggest phases that were silently skipped.
            COMPARISON_INTERVAL=0
            ;;
        *)
            echo "[error] unknown experiment mode: $EXPERIMENT_MODE (expected mainline or baseline)" >&2
            return 2
            ;;
    esac

    # --- VACUUM ----------------------------------------------------------------
    VACUUM_ENABLED="${VACUUM_ENABLED:-0}"
    vacuum="$VACUUM_ENABLED"                    # legacy name still used by the engine

    # --- RESUME ----------------------------------------------------------------
    # Resume an interrupted run at a global iteration instead of starting over: iterations
    # below this number are skipped and the initial load / reference-load phases do not run,
    # so the databases must already hold the state the run left behind. 0 (or 1) runs every
    # iteration and both load phases.
    # Artefacts are appended to, never truncated (see experiment::resume_active).
    RESUME_FROM_ITERATION="${RESUME_FROM_ITERATION:-0}"
    [[ "$RESUME_FROM_ITERATION" =~ ^-?[0-9]+$ ]] || {
        echo "[error] RESUME_FROM_ITERATION must be a number of iterations, got: $RESUME_FROM_ITERATION" >&2
        return 2
    }
    (( RESUME_FROM_ITERATION < 0 )) && RESUME_FROM_ITERATION=0   # master's -1 meant "no resume"
    if (( RESUME_FROM_ITERATION > NUM_EPOCHS * STEPS_PER_EPOCH )); then
        echo "[error] RESUME_FROM_ITERATION=$RESUME_FROM_ITERATION is past the last iteration"
        echo "        of this run (NUM_EPOCHS*STEPS_PER_EPOCH=$((NUM_EPOCHS * STEPS_PER_EPOCH)));"
        echo "        it would execute nothing." >&2
        return 2
    fi

    # --- background maintenance between phases ---------------------------------
    # Turn the database's own background maintenance (PostgreSQL: autovacuum on the measured
    # table) off before the phases that must be quiet and back on before the extend phase that
    # is measured with it. 0 leaves the server's settings untouched.
    PAUSE_MAINTENANCE="${PAUSE_MAINTENANCE:-1}"

    # --- waiting for the server to settle --------------------------------------
    # How long a phase waits for background work to finish before it is measured, and how often
    # it asks. One pair for every wait of every phase: an autovacuum on a heavily extended
    # table can run for well over an hour, and a wait that gives up early measures the phase
    # while that work is still running.
    IDLE_WAIT_INTERVAL="${IDLE_WAIT_INTERVAL:-30}"
    IDLE_WAIT_TIMEOUT="${IDLE_WAIT_TIMEOUT:-7200}"

    # --- pausing between iterations --------------------------------------------
    # `touch PAUSE_SCRIPT` in the runner's directory stops the experiment after the current
    # iteration (it never interrupts a phase); removing the file continues it. The path is
    # relative to the runner's working directory unless it is absolute.
    PAUSE_FILE="${PAUSE_FILE:-PAUSE_SCRIPT}"
    PAUSE_CHECK_INTERVAL="${PAUSE_CHECK_INTERVAL:-30}"

    # --- what a run records about itself ---------------------------------------
    # SERVER_LOG_MARKS: write a marker for every phase into the database server's own log, so
    #   server-side evidence (autovacuum, checkpoints) can be aligned with the run log.
    # ARCHIVE_CONFIGURATION: at the end of a successful run, copy the resolved configuration,
    #   the workload template and whatever the backend can archive of its server state into
    #   $EXPERIMENT_DIR/config.
    SERVER_LOG_MARKS="${SERVER_LOG_MARKS:-1}"
    ARCHIVE_CONFIGURATION="${ARCHIVE_CONFIGURATION:-1}"

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
    # Per-second host sampling (watcher.sh): the .osstats rates CSV, whose columns include the
    # block-I/O and pressure-stall numbers, plus the .diskstats device-selection record. It is
    # /proc-only, so it costs one sampler per phase for every backend; 0 writes neither file.
    OS_STATS_ENABLED="${OS_STATS_ENABLED:-1}"
}

# Derive every path from the experiment identity. Must run AFTER all configuration
# layers (defaults, backend, --config, environment, CLI) so that overriding TYPE,
# SCALE or RUN renames every artefact consistently.
config::derive_paths() {
    EXPERIMENT_NAME="${EXPERIMENT_NAME_OVERRIDE:-${TYPE}_${SCALE}_extend-${EXTEND_DIST}_${WORKLOAD}_run${RUN}${MODE_SUFFIX:-}}"

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

# Mask anything that looks like a credential so a run's configuration archive can be shared
# with the results. Property-style (`pass=…`, `password = …`) and shell-style (`DB_PWD=…`,
# `export COUCHBASE_PASSWORD="…"`) both occur in the files a run reads, including inside JDBC
# URLs (`jdbc:postgresql://h/db?user=u&password=p`).
config::redact_file() {
    local file="${1:?file required}"
    sed -E \
        -e 's/([?&](pass|password)[a-zA-Z_]*)=[^&[:space:]]*/\1=<REDACTED>/Ig' \
        -e 's/^([[:space:]]*(export[[:space:]]+)?[A-Za-z_.]*([Pp][Aa][Ss][Ss]|[Pp]assword|[Pp][Ww][Dd]|[Ss]ecret|[Tt]oken)[A-Za-z_.]*)[[:space:]]*=[[:space:]]*.*/\1=<REDACTED>/' \
        "$file"
}

# The resolved configuration of this run, as one text artefact for the run directory. Values
# that carry credentials are never printed, only their presence; everything else is written in
# full, because "which run was this?" is the question an archive has to answer months later.
config::describe() {
    printf '# YCSB experiment configuration\n'
    printf '# generated: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf '# execution: %s\n' "${EXECUTION_ID:-not started}"
    printf '# host: %s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf '# harness: %s\n' "$(config::harness_version)"
    printf '\n# --- identity ---\n'
    printf 'backend=%s\n' "${ACTIVE_BACKEND:-?}"
    printf 'mode=%s\n' "${EXPERIMENT_MODE:-mainline}"
    printf 'experiment_name=%s\n' "${EXPERIMENT_NAME:-?}"
    printf 'type=%s\nscale=%s\nextend_dist=%s\nworkload=%s\nrun=%s\n' \
        "${TYPE:-?}" "${SCALE:-?}" "${EXTEND_DIST:-?}" "${WORKLOAD:-?}" "${RUN:-?}"
    printf 'binding=%s\n' "${YCSB_BINDING:-?}"
    printf '\n# --- run size and behaviour ---\n'
    printf 'epochs=%s\nsteps_per_epoch=%s\ncomparison_interval=%s\n' \
        "${NUM_EPOCHS:-?}" "${STEPS_PER_EPOCH:-?}" "${COMPARISON_INTERVAL:-?}"
    printf 'resume_from_iteration=%s\nvacuum_enabled=%s\npause_maintenance=%s\n' \
        "${RESUME_FROM_ITERATION:-0}" "${VACUUM_ENABLED:-?}" "${PAUSE_MAINTENANCE:-?}"
    printf 'idle_wait_interval=%s\nidle_wait_timeout=%s\npause_file=%s\n' \
        "${IDLE_WAIT_INTERVAL:-?}" "${IDLE_WAIT_TIMEOUT:-?}" "${PAUSE_FILE:-?}"
    printf 'server_log_marks=%s\nos_stats_enabled=%s\ndb_stats_interval=%s\narchive_configuration=%s\n' \
        "${SERVER_LOG_MARKS:-?}" "${OS_STATS_ENABLED:-?}" "${DB_STATS_INTERVAL:-?}" "${ARCHIVE_CONFIGURATION:-?}"
    printf '\n# --- endpoint (credentials never written) ---\n'
    printf 'endpoint=%s:%s\nusername=%s\n' "${DB_HOST:-?}" "${DB_PORT:-?}" "${DB_USERNAME:-?}"
    printf 'password_set=%s\n' "$([[ -n "${DB_PWD:-}" ]] && printf yes || printf no)"
    printf 'database=%s\nunchanged_database=%s\nbackup_database=%s\n' \
        "${DB_NAME:-?}" "${UNCHANGED_DB_NAME:-?}" "${BACKUP_DB_NAME:-?}"
    printf '\n# --- workload ---\n'
    printf 'workload_template=%s\n' "${WORKLOAD_FILE:-?}"
    printf 'workload_template_sha256=%s\n' "$(workload::hash "$WORKLOAD_FILE" 2>/dev/null || printf unavailable)"
    printf 'fieldlengthoriginal=%s\nextend_operationcount=%s\n' \
        "${fieldlengthoriginal:-?}" "${extendoperationcount:-?}"
    printf '\n# --- paths ---\n'
    printf 'experiment_dir=%s\nlog_file=%s\nresults_csv=%s\nworkload_dir=%s\n' \
        "${EXPERIMENT_DIR:-?}" "${LOG_FILE:-?}" "${OUTPUT_FILE:-?}" "${WORKLOAD_DIR:-?}"
    printf '\n# --- configuration files applied (in order, credentials masked) ---\n'
    if (( ${#CONFIG_SOURCES[@]} )); then
        printf '%s\n' "${CONFIG_SOURCES[@]}"
    else
        printf '<none>\n'
    fi
}

# Which build of the harness produced a run: the git commit when the tree has one, and the
# mtime of the entry point otherwise (a deployed bundle has no .git).
config::harness_version() {
    local dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local commit
    commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" && {
        printf '%s%s\n' "$commit" "$(git -C "$dir" status --porcelain --quiet 2>/dev/null || printf -- '-dirty')"
        return 0
    }
    printf 'no git metadata; %s modified %s\n' "$(basename "${BASH_SOURCE[1]:-$dir}")" \
        "$(date -u -r "$dir/experiment.sh" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)"
}

# Apply KEY=VALUE overrides coming from --var on the command line.
config::apply_var() {
    local assignment="${1:?KEY=VALUE required}" key
    [[ "$assignment" == *=* ]] || { echo "[error] --var expects KEY=VALUE, got: $assignment" >&2; return 2; }
    key="${assignment%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "[error] invalid variable name: $key" >&2; return 2; }
    config::set_cli "$assignment"
}
