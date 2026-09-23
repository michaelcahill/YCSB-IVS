#!/usr/bin/env bash
# Structural end-to-end check for one backend: does a full phase sequence run, and does it
# produce the standard artefacts? Unlike tests/smoke_authoritative.sh this compares no
# goldens, so it can be pointed at any backend that has a reachable server:
#
#   DB_PWD=... bash tests/smoke_backend.sh postgresql_row
#   BACKEND=mongodb URI=... bash tests/smoke_backend.sh mongodb     # when a server exists
#   DB_PWD=... bash tests/smoke_backend.sh postgresql_row baseline  # the --mode baseline engine
#
# What it asserts (all backends and both modes must satisfy this):
#   * exit status 0 and the completion marker in the log
#   * every phase of the mode present, and - for baseline - that the reference and comparison
#     phases are absent and their databases were never created
#   * a results CSV whose header is exactly the base columns with this backend's statistics
#     columns spliced in (identical between modes), one row per measured phase,
#     and one row per reported operation
#   * value-size artefacts and a histogram
#   * one generated workload per phase inside the experiment directory
#   * no tracked workload file was modified
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BACKEND="${1:-${BACKEND:?usage: smoke_backend.sh <backend> [mode]}}"
MODE="${2:-${SMOKE_MODE:-mainline}}"

# The two engines differ in their phase sequence and nothing else, so that is the one thing
# this script parameterises.
case "$MODE" in
    mainline)
        PHASES=(load reference-load extend run reference clean-run comparison-load avg-run)
        # reference-load and comparison-load prepare data (run_ycsb), they are not
        # measurements, so they never reach write_result.
        CSV_PHASES="avg-run clean-run extend load reference run "
        CSV_MIN_ROWS=6    # eight phases, minus the two that only prepare data
        SIZE_FILES=2      # before extend, and after the comparison copy was restored
        ;;
    baseline)
        PHASES=(load extend run)
        CSV_PHASES="extend load run "
        CSV_MIN_ROWS=3    # all three phases are measurements
        SIZE_FILES=1      # no comparison copy, so no "after" file
        ;;
    *)
        echo "[backend-smoke] usage: smoke_backend.sh <backend> [mainline|baseline]" >&2
        exit 2
        ;;
esac

# Endpoint and role come from the backend's own defaults, so this script must not set them;
# export DB_HOST/DB_PORT/DB_USERNAME to point a run somewhere else.
# Some deployments have no password (MongoDB in its default configuration authenticates through
# the URI at most), so an unset DB_PWD is allowed - with a warning for the credential-carrying
# backends, whose preflight will fail loudly anyway. It is deliberately NOT exported when empty:
# exporting it would claim the environment layer and silently win over conf/db.<backend>.env.
[[ -n "${DB_PWD-}" ]] || echo "[backend-smoke] note: DB_PWD is not set; expecting conf/db.$BACKEND.env or a backend without credentials"

# Dedicated databases so a smoke run can never destroy an experiment.
suffix="_smoke_$(basename "$BACKEND" | tr -cd 'a-z0-9' | cut -c1-8)"
export DB_NAME="${DB_NAME:-ycsb${suffix}}"
export UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb${suffix}_unch}"
export BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb${suffix}_bak}"

export TYPE="${TYPE:-smoke_${BACKEND}}"
export RUN="1"
export EXPERIMENT_MODE="$MODE"
export NUM_EPOCHS=1
export STEPS_PER_EPOCH=1
export COMPARISON_INTERVAL=1        # baseline mode forces it to 0, by design
export EXTEND_OPERATIONCOUNT="${EXTEND_OPERATIONCOUNT:-300}"
export DB_STATS_INTERVAL=1

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ycsb-backend-smoke.XXXXXX")"
trap '[[ "${SMOKE_KEEP:-0}" == 1 ]] || rm -rf "$WORKDIR"' EXIT

WORKLOAD="$WORKDIR/workload-smoke"
cat > "$WORKLOAD" <<'WLEOF'
recordcount=200
operationcount=400
workload=site.ycsb.workloads.CoreWorkload
fieldlength=100
readallfields=true
writeallfields=false
readproportion=1
updateproportion=0
scanproportion=0
insertproportion=0
readmodifywriteproportion=0
requestdistribution=uniform
readrequestdistribution=uniform
updaterequestdistribution=uniform
extendproportion=1
extendfieldlength=100
WLEOF
export WORKLOAD_FILE="$WORKLOAD"
export EXPERIMENT_DIR="$WORKDIR/experiment"

# Start from a known state where the backend's admin tools allow it. The dropping below is
# PostgreSQL-only (dropdb + PGPASSWORD), so ask the backend which server it talks to first -
# running it against MongoDB's port would hang waiting for a password that does not exist.
# shellcheck source=lib/registry.sh
source "$SCRIPTS_DIR/lib/registry.sh"
# shellcheck source=lib/metrics.sh
source "$SCRIPTS_DIR/lib/metrics.sh"      # for metrics::header, the expected CSV schema
registry::load "$BACKEND" >/dev/null
DB_DIALECT="$(registry::info runtime_watcher_dialect)"

if [[ "$DB_DIALECT" == postgresql ]] && command -v dropdb >/dev/null 2>&1; then
    for db in "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; do
        PGPASSWORD="${DB_PWD:-}" dropdb --if-exists --host="${DB_HOST:-127.0.0.1}" \
            --port="${DB_PORT:-5432}" --username="${DB_USERNAME:-ycsb}" "$db" >/dev/null 2>&1 || true
    done
fi

# Baseline mode owns one database; the two comparison databases must stay as they were,
# which after the drop above means: still absent.
baseline_databases_untouched() {
    [[ "$MODE" == baseline && "$DB_DIALECT" == postgresql ]] || return 0
    local db
    for db in "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; do
        if PGPASSWORD="${DB_PWD:-}" PGCONNECT_TIMEOUT=10 psql -h "${DB_HOST:-127.0.0.1}" \
                -p "${DB_PORT:-5432}" -U "${DB_USERNAME:-ycsb}" -d postgres -At \
                -c "SELECT 1 FROM pg_database WHERE datname = '$db';" 2>/dev/null | grep -q 1; then
            fail "baseline mode created the comparison database $db"
        fi
    done
    echo "[backend-smoke] baseline mode touched neither $UNCHANGED_DB_NAME nor $BACKUP_DB_NAME"
}

echo "[backend-smoke] backend=$BACKEND endpoint=${DB_HOST:-<backend default>:${DB_PORT:-?}} user=${DB_USERNAME:-<backend default>}"
# "the run created nothing under ../workloads" has to be a before/after comparison: untracked
# leftovers of earlier manual runs are dirt in the working tree, not a regression of this run.
WORKLOAD_UNTRACKED_BEFORE="$(git -C "$SCRIPTS_DIR" ls-files --others --exclude-standard -- ../workloads | sort)"

echo "[backend-smoke] workdir=$WORKDIR"

set +e
# RUNNER lets the suite drive a different entrypoint with the same contract - currently
# only the generated single-file bundle (tests/run_tests.sh, step "bundle harness smoke").
RUNNER="${RUNNER:-$SCRIPTS_DIR/experiment.sh}"
"$RUNNER" "$BACKEND" > "$WORKDIR/run.out" 2>&1
rc=$?
set -e
tail -15 "$WORKDIR/run.out" | sed 's/^/[run] /'

fail() { echo "[backend-smoke] FAIL: $*" >&2; exit 1; }
(( rc == 0 )) || fail "experiment.sh exited with status $rc"

LOG="$(find "$EXPERIMENT_DIR/logs" -name '*_results.log' | head -1)"
[[ -n "$LOG" ]] || fail "no results log under $EXPERIMENT_DIR/logs"
grep -q 'END experiment status=0' "$LOG" || fail "completion marker missing from $LOG"

for phase in "${PHASES[@]}"; do
    grep -q "phase=$phase\] START YCSB $phase" "$LOG" || fail "phase '$phase' never started"
done
# A mode that silently ran the other sequence would still produce a plausible log, so the
# phases it must not run are checked too.
if [[ "$MODE" == baseline ]]; then
    for phase in reference-load reference clean-run comparison-load avg-run; do
        if grep -qE "START YCSB ${phase}$" "$LOG"; then
            fail "baseline mode ran the '$phase' phase"
        fi
    done
fi
# A phase that hits database-side errors is not a measurement, and YCSB still exits 0: the JDBC
# binding logs "Error in processing update..." / "Data too long for column" on stderr and carries
# on, and the Neo4j binding does the same with "Error updating Neo4j: ...". Those lines only reach
# the run log, so this is where a wrong schema shows up.
if errors=$(grep -nE 'Error in processing|Data too long|SQLSyntaxErrorException|java\.sql\.|Exceptions occurred|Error (inserting|reading|updating) |Duplicate key detected|Failed to invoke procedure' "$LOG"); then
    echo "$errors" | head -5 | sed 's/^/[error] /' >&2
    fail "the run reported database-side errors (see above)"
fi
echo "[backend-smoke] all ${#PHASES[@]} phases ran, no database-side errors in the log"

CSV="$(find "$EXPERIMENT_DIR/data/workload_data" -name '*.csv' | head -1)"
[[ -n "$CSV" ]] || fail "no results CSV under $EXPERIMENT_DIR/data/workload_data"
header="$(head -1 "$CSV")"
# The exact expected header, derived from the same two library functions that produce it:
# write_result's base columns with metrics::header (CPU, Memory and this backend's statistics)
# between Operation and Readprop. Asserting the whole prefix rather than a handful of names is
# what proves both modes - and every backend - write one comparable schema.
expected_header_prefix="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,$(metrics::header),Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
[[ "$header" == "$expected_header_prefix,"* ]] || fail "results CSV header is not the standard schema:
  expected prefix: $expected_header_prefix
  got            : $header"
# One row per measured phase (the load-preparing phases of each mode record nothing).
rows=$(( $(wc -l < "$CSV") - 1 ))
(( rows >= CSV_MIN_ROWS )) || fail "expected at least one row per measured phase, got $rows"
[[ "$(awk -F, 'NR>1 {print tolower($2)}' "$CSV" | sort -u | tr '\n' ' ')" == \
   "$CSV_PHASES" ]] || fail "unexpected phase set in CSV"
echo "[backend-smoke] mode=$MODE: ${#PHASES[@]} phases, CSV header matches the standard schema"
echo "[backend-smoke] results CSV: $rows rows, $(head -1 "$CSV" | awk -F, '{print NF}') columns"
# The other half of the assertion above, on the measurement side: YCSB only emits a Return=ERROR
# row when an operation actually failed, and write_result turns it into a column. A run whose
# rows carry a non-zero count there measured failures, so it is not comparable with earlier ones.
failed_rows=$(awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "Return=ERROR") col = i; next }
    col && $col+0 != 0 { print $2 " Return=ERROR=" $col }' "$CSV")
[[ -z "$failed_rows" ]] || {
    echo "$failed_rows" | sed 's/^/[error] /' >&2
    fail "the results CSV records failed operations (Return=ERROR)"
}

mapfile -t size_files < <(find "$EXPERIMENT_DIR/data/value_size_data" -name '*.csv' 2>/dev/null | sort)
(( ${#size_files[@]} == SIZE_FILES )) || fail "expected $SIZE_FILES value-size CSV(s), found ${#size_files[@]}"
for f in "${size_files[@]}"; do
    [[ -s "$f" ]] || fail "value-size artefact is empty: $f"
done
[[ -s "$EXPERIMENT_DIR/logs/histogram.txt" ]] || fail "histogram not written"

for phase in "${PHASES[@]}"; do
    compgen -G "$EXPERIMENT_DIR/workloads/$phase-iter*.workload" >/dev/null \
        || fail "no generated workload for phase $phase"
done
echo "[backend-smoke] generated workloads: $(find "$EXPERIMENT_DIR/workloads" -name '*.workload' | wc -l) files"

git -C "$SCRIPTS_DIR" diff --quiet -- ../workloads \
    || fail "tracked files under ../workloads were modified"
if [[ "$(git -C "$SCRIPTS_DIR" ls-files --others --exclude-standard -- ../workloads | sort)" != \
      "$WORKLOAD_UNTRACKED_BEFORE" ]]; then
    fail "new files appeared under ../workloads"
fi

baseline_databases_untouched

echo "[backend-smoke] PASS — $BACKEND completed the standard phase sequence ($MODE mode)"
