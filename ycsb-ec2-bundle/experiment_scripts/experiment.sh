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
export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
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
# shellcheck source=lib/lifecycle.sh
source "$LIB_DIR/lifecycle.sh"

usage() {
    cat <<USAGE
Usage: ./experiment.sh <backend> [options]

Backends:
$(registry::available | sed 's/^/  /')

Options:
  --config FILE       load KEY=VALUE configuration from FILE before running
  --var KEY=VALUE     override a single configuration variable
  --epochs N          number of epochs
  --steps N           steps (extend+run pairs) per epoch
  --run-id ID         run counter, used in artefact names
  --type NAME         experiment type, prefix of every artefact name
  --dry-run           resolve configuration, run preflight only, do not benchmark
  --list-backends     list backends and exit
  -h, --help          this help

Environment overrides are honoured for every setting (see lib/config.sh).
USAGE
}

BACKEND=""
DRY_RUN=0
CONFIG_FILES=()
declare -a VAR_OVERRIDES=()

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
        --epochs) export NUM_EPOCHS="${2:?--epochs needs a number}"; shift 2 ;;
        --steps) export STEPS_PER_EPOCH="${2:?--steps needs a number}"; shift 2 ;;
        --run-id) export RUN="${2:?--run-id needs a value}"; shift 2 ;;
        --type) export TYPE="${2:?--type needs a value}"; shift 2 ;;
        --mode)
            # Baseline mode lands with REFACTOR_PLAN.md step 6.
            [[ "${2:-mainline}" == mainline ]] || { echo "[error] --mode ${2} is not implemented yet" >&2; exit 2; }
            shift 2 ;;
        --instrument)
            # Instrumentation modules land with REFACTOR_PLAN.md step 8b.
            [[ "${2:-none}" == none ]] || { echo "[error] --instrument is not implemented yet" >&2; exit 2; }
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
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
config::init_defaults

if (( ${#CONFIG_FILES[@]} )); then
    for file in "${CONFIG_FILES[@]}"; do
        [[ -n "$file" && -r "$file" ]] || { echo "[error] cannot read config file: $file" >&2; exit 2; }
        # shellcheck disable=SC1090
        source "$file"
    done
fi
if (( ${#VAR_OVERRIDES[@]} )); then
    for assignment in "${VAR_OVERRIDES[@]}"; do
        config::apply_var "$assignment"
    done
fi
# Paths are derived last so that any layer above renames every artefact consistently.
config::derive_paths

if (( DRY_RUN )); then
    cat <<DRYRUN
backend:          $ACTIVE_BACKEND ($(registry::info display_name))
binding:          $YCSB_BINDING
databases:        $DB_NAME (reference: $UNCHANGED_DB_NAME, comparison: $BACKUP_DB_NAME)
endpoint:         $DB_HOST:$DB_PORT user=$DB_USERNAME
workload file:    $WORKLOAD_FILE
experiment dir:   $EXPERIMENT_DIR
results CSV:      $OUTPUT_FILE
epochs x steps:   ${NUM_EPOCHS} x ${STEPS_PER_EPOCH} (comparison every ${COMPARISON_INTERVAL})
vacuum:           $VACUUM_ENABLED
DRYRUN
    exit 0
fi

run_experiment
