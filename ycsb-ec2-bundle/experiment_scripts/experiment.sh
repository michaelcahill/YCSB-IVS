#!/usr/bin/env bash
#
# experiment.sh — single entry point for the YCSB experiment harness.
#
#   ./experiment.sh <backend> [options]
#
# Examples:
#   ./experiment.sh postgresql_textarray --epochs 2 --steps 2
#   ./experiment.sh postgresql_textarray --config conf/experiments/smoke.env
#   ./experiment.sh postgresql_textarray --var SCALE=light --var RUN=3
#   ./experiment.sh --list-backends
#   ./experiment.sh postgresql_textarray --dry-run
#
# The backend supplies connection/schema behaviour; lib/lifecycle.sh supplies the
# phase engine shared by every backend. Configuration precedence: built-in defaults,
# backend defaults, --config file, environment, then CLI flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LIB_DIR="$SCRIPT_DIR/lib"
CONF_DIR="$SCRIPT_DIR/conf"
# shellcheck disable=SC2155  # the cd cannot fail; assigning first would need a second line
YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export YCSB_HOME
export PATH="$YCSB_HOME/bin:$PATH"
YCSB="../bin/ycsb.sh"

# shellcheck source=lib/registry.sh
source "$LIB_DIR/registry.sh"
# shellcheck source=lib/metrics.sh
source "$LIB_DIR/metrics.sh"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/results.sh
source "$LIB_DIR/results.sh"
# shellcheck source=lib/keysizes.sh
source "$LIB_DIR/keysizes.sh"
# shellcheck source=lib/workload.sh
source "$LIB_DIR/workload.sh"
# shellcheck source=lib/lifecycle.sh
source "$LIB_DIR/lifecycle.sh"

usage() {
    cat <<USAGE
Usage: ./experiment.sh <backend> [options]

Backends:
$(registry::available | sed 's/^/  /')

Old names still resolve (postgresql_array, jsonb, innodb, ...) and print a deprecation line.

Options:
  --config FILE       load KEY=VALUE configuration from FILE before running
  --var KEY=VALUE     override a single configuration variable
  --epochs N          number of epochs
  --steps N           steps (extend+run pairs) per epoch
  --run-id ID         run counter, used in artefact names
  --type NAME         experiment type, prefix of every artefact name
  --scale NAME        scale mode (heavy|light), selects conf/scale.<NAME>.env
  --workload FILE     read-only workload template (never modified)
  --experiment-dir D  root for logs, data and generated workloads
  --dry-run           resolve configuration, print it, do not benchmark
  --check             run the backend's preflight (server reachable, role allowed,
                      build artifacts present) and exit without benchmarking
  --list-backends     list backends and exit
  -h, --help          this help

Workload files are never modified: each YCSB phase gets a generated copy under
$EXPERIMENT_DIR/workloads built from the template plus that phase's settings.

Configuration precedence (later wins): built-in defaults, backend defaults,
conf/db.<backend>.env, --config FILE, environment, CLI flags.
Every setting can also be given as an environment variable (see lib/config.sh).
USAGE
}

BACKEND=""
DRY_RUN=0
CHECK_ONLY=0
CONFIG_FILES=()
declare -a VAR_OVERRIDES=()

# The environment layer is captured before any flag is applied, so that configuration
# files can be parsed without silently overriding what the caller exported.
config::snapshot_env

while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list-backends)
            for b in $(registry::available); do
                printf '%-26s %s\n' "$b" "$(sed -n 's/^display_name=//p' "$BACKENDS_DIR/$b.sh" | head -1)"
            done
            exit 0 ;;
        --config) CONFIG_FILES+=("${2:?--config needs a file}"); shift 2 ;;
        --var) VAR_OVERRIDES+=("${2:?--var needs KEY=VALUE}"); shift 2 ;;
        --epochs) config::set_cli "NUM_EPOCHS=${2:?--epochs needs a number}"; shift 2 ;;
        --steps) config::set_cli "STEPS_PER_EPOCH=${2:?--steps needs a number}"; shift 2 ;;
        --run-id) config::set_cli "RUN=${2:?--run-id needs a value}"; shift 2 ;;
        --type) config::set_cli "TYPE=${2:?--type needs a value}"; shift 2 ;;
        --scale) config::set_cli "SCALE=${2:?--scale needs a name}"; shift 2 ;;
        --workload) config::set_cli "WORKLOAD_FILE=${2:?--workload needs a file}"; shift 2 ;;
        --experiment-dir) config::set_cli "EXPERIMENT_DIR=${2:?--experiment-dir needs a directory}"; shift 2 ;;
        --mode)
            # Baseline mode lands with REFACTOR_PLAN.md step 6.
            [[ "${2:-mainline}" == mainline ]] || { echo "[error] --mode ${2} is not implemented yet" >&2; exit 2; }
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -*) echo "[error] unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -z "$BACKEND" ]] || { echo "[error] unexpected argument: $1" >&2; exit 2; }
            BACKEND="$1"; shift ;;
    esac
done

if [[ -z "$BACKEND" ]]; then
    echo "[error] a backend is required" >&2
    usage >&2
    exit 2
fi

registry::load "$BACKEND"

# Layers below the environment: conf/db.<backend>.env, then conf/scale.<SCALE>.env.
config::load_layered_files
if (( ${#CONFIG_FILES[@]} )); then
    for file in "${CONFIG_FILES[@]}"; do
        config::load_file "$file"
    done
fi

# Old launcher variable names (DIST, WORK, EXPERIMENT_EPOCHS, …) are translated after
# the files, so a preset can never shadow what a launcher exported.
config::apply_legacy_aliases
config::warn_discarded_legacy

if (( ${#VAR_OVERRIDES[@]} )); then
    for assignment in "${VAR_OVERRIDES[@]}"; do
        config::apply_var "$assignment"
    done
fi

config::init_defaults
# Paths are derived last so that any layer above renames every artefact consistently.
config::derive_paths

if (( CHECK_ONLY )); then
    # Exactly the checks run_experiment performs before it touches anything: this is how a
    # test suite or an operator asks "is a server reachable for this backend?" without
    # running a benchmark. The probe databases it creates are dropped again.
    if backend::preflight true "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; then
        echo "[check] $ACTIVE_BACKEND preflight passed"
        exit 0
    fi
    echo "[check] $ACTIVE_BACKEND preflight FAILED (see the messages above)" >&2
    exit 1
fi

if (( DRY_RUN )); then
    cat <<DRYRUN
backend:          $ACTIVE_BACKEND ($(registry::info display_name))
config files:     ${CONFIG_SOURCES[*]:-<none>}
binding:          $YCSB_BINDING
databases:        $DB_NAME (reference: $UNCHANGED_DB_NAME, comparison: $BACKUP_DB_NAME)
endpoint:         $DB_HOST:$DB_PORT user=$DB_USERNAME
workload file:    $WORKLOAD_FILE (sha256 $(workload::hash "$WORKLOAD_FILE" 2>/dev/null))
workload dir:     $WORKLOAD_DIR
experiment dir:   $EXPERIMENT_DIR
results CSV:      $OUTPUT_FILE
epochs x steps:   ${NUM_EPOCHS} x ${STEPS_PER_EPOCH} (comparison every ${COMPARISON_INTERVAL})
vacuum:           $VACUUM_ENABLED
DRYRUN
    exit 0
fi

run_experiment
