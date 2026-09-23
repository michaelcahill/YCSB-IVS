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
#   ./experiment.sh postgresql_textarray --mode baseline    # no reference/comparison phases
#   ./experiment.sh --list-backends
#   ./experiment.sh postgresql_textarray --dry-run
#
# The backend supplies connection/schema behaviour; lib/lifecycle.sh supplies the
# phase steps shared by every backend and both modes, and lib/lifecycle_baseline.sh is the
# second (shorter) sequence of them. Configuration precedence: built-in defaults, backend
# defaults, --config file, environment, then CLI flags.
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
# shellcheck source=lib/lifecycle_baseline.sh
source "$LIB_DIR/lifecycle_baseline.sh"

usage() {
    cat <<USAGE
Usage: ./experiment.sh <backend> [options]

Backends:
$(registry::available | sed 's/^/  /')

Backend names are exactly the files in lib/backends/ (see --list-backends); pre-refactor
spellings (postgresql_array, jsonb, innodb, ...) were removed with the legacy scripts.

Options:
  --config FILE       load KEY=VALUE configuration from FILE before running
  --var KEY=VALUE     override a single configuration variable
  --epochs N          number of epochs
  --steps N           steps (extend+run pairs) per epoch
  --run-id ID         run counter, used in artefact names
  --type NAME         experiment type, prefix of every artefact name
  --scale NAME        scale mode (heavy|light), selects conf/scale.<NAME>.env
  --mode NAME         phase sequence: mainline (default) or baseline. A baseline run is
                      load -> [extend -> measure] repeated, without the reference database
                      and the comparison (clean-run / comparison-load / avg-run) phases; its
                      artefact names gain a _baseline suffix.
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
            # Load each backend for its display name rather than grepping its file: inside
            # the generated bundle (tools/bundle.sh) there are no per-backend files to read.
            for b in $(registry::available); do
                registry::load "$b"
                printf '%-26s %s\n' "$b" "$(registry::info display_name)"
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
            case "${2:-}" in
                mainline | baseline) config::set_cli "EXPERIMENT_MODE=$2"; shift 2 ;;
                *) echo "[error] --mode must be mainline or baseline, got: ${2:-<empty>}" >&2; exit 2 ;;
            esac ;;
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
    # running a benchmark. The probe databases it creates are dropped again. A baseline run
    # never dumps a database, so pg_dump is not part of its preflight either.
    needs_dump=true
    if [[ "$EXPERIMENT_MODE" == baseline ]]; then needs_dump=false; fi
    if backend::preflight "$needs_dump" "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; then
        echo "[check] $ACTIVE_BACKEND preflight passed"
        exit 0
    fi
    echo "[check] $ACTIVE_BACKEND preflight FAILED (see the messages above)" >&2
    exit 1
fi

if (( DRY_RUN )); then
    mode_note=""
    databases_note=" (reference: $UNCHANGED_DB_NAME, comparison: $BACKUP_DB_NAME)"
    if [[ "$EXPERIMENT_MODE" == baseline ]]; then
        mode_note=" — no reference and no comparison phases"
        databases_note=" (baseline mode creates no reference/comparison database)"
    fi
    cat <<DRYRUN
backend:          $ACTIVE_BACKEND ($(registry::info display_name))
mode:             $EXPERIMENT_MODE$mode_note
config files:     ${CONFIG_SOURCES[*]:-<none>}
binding:          $YCSB_BINDING
databases:        $DB_NAME$databases_note
endpoint:         $DB_HOST:$DB_PORT user=$DB_USERNAME
workload file:    $WORKLOAD_FILE (sha256 $(workload::hash "$WORKLOAD_FILE" 2>/dev/null))
workload dir:     $WORKLOAD_DIR
experiment dir:   $EXPERIMENT_DIR
results CSV:      $OUTPUT_FILE
epochs x steps:   ${NUM_EPOCHS} x ${STEPS_PER_EPOCH} (comparison every ${COMPARISON_INTERVAL})
phases:           $(experiment::describe_phases)
vacuum:           $VACUUM_ENABLED
DRYRUN
    exit 0
fi

run_experiment
