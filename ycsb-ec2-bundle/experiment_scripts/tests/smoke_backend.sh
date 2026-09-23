#!/usr/bin/env bash
# Structural end-to-end check for one backend: does a full phase sequence run, and does it
# produce the standard artefacts? Unlike tests/smoke_authoritative.sh this compares no
# goldens, so it can be pointed at any backend that has a reachable server:
#
#   DB_PWD=... bash tests/smoke_backend.sh postgresql_row
#   BACKEND=mongodb URI=... bash tests/smoke_backend.sh mongodb     # when a server exists
#
# What it asserts (all backends must satisfy this):
#   * exit status 0 and the completion marker in the log
#   * all eight phases present: load, reference-load, extend, run, reference,
#     clean-run, comparison-load, avg-run
#   * a results CSV with the standard base columns and one row per reported operation
#   * value-size artefacts (before/after) and a histogram
#   * one generated workload per phase inside the experiment directory
#   * no tracked workload file was modified
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BACKEND="${1:-${BACKEND:?usage: smoke_backend.sh <backend>}}"

export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5432}"
export DB_USERNAME="${DB_USERNAME:-ycsb}"
export DB_PWD="${DB_PWD:?Set DB_PWD to the benchmark role password}"

# Dedicated databases so a smoke run can never destroy an experiment.
suffix="_smoke_$(basename "$BACKEND" | tr -cd 'a-z0-9' | cut -c1-8)"
export DB_NAME="${DB_NAME:-ycsb${suffix}}"
export UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb${suffix}_unch}"
export BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb${suffix}_bak}"

export TYPE="${TYPE:-smoke_${BACKEND}}"
export RUN="1"
export NUM_EPOCHS=1
export STEPS_PER_EPOCH=1
export COMPARISON_INTERVAL=1
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

# Start from a known state where the backend's admin tools allow it (PostgreSQL only).
if command -v dropdb >/dev/null 2>&1; then
    for db in "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; do
        PGPASSWORD="$DB_PWD" dropdb --if-exists --host="$DB_HOST" --port="$DB_PORT" \
            --username="$DB_USERNAME" "$db" >/dev/null 2>&1 || true
    done
fi

echo "[backend-smoke] backend=$BACKEND host=$DB_HOST:$DB_PORT user=$DB_USERNAME"
echo "[backend-smoke] workdir=$WORKDIR"

set +e
"$SCRIPTS_DIR/experiment.sh" "$BACKEND" > "$WORKDIR/run.out" 2>&1
rc=$?
set -e
tail -15 "$WORKDIR/run.out" | sed 's/^/[run] /'

fail() { echo "[backend-smoke] FAIL: $*" >&2; exit 1; }
(( rc == 0 )) || fail "experiment.sh exited with status $rc"

LOG="$(find "$EXPERIMENT_DIR/logs" -name '*_results.log' | head -1)"
[[ -n "$LOG" ]] || fail "no results log under $EXPERIMENT_DIR/logs"
grep -q 'END experiment status=0' "$LOG" || fail "completion marker missing from $LOG"

for phase in load reference-load extend run reference clean-run comparison-load avg-run; do
    grep -q "phase=$phase\] START YCSB $phase" "$LOG" || fail "phase '$phase' never started"
done
echo "[backend-smoke] all 8 phases ran"

CSV="$(find "$EXPERIMENT_DIR/data/workload_data" -name '*.csv' | head -1)"
[[ -n "$CSV" ]] || fail "no results CSV under $EXPERIMENT_DIR/data/workload_data"
header="$(head -1 "$CSV")"
for column in Epoch Phase Recordcount Readallfields Requestdist Operation CPU Memory \
              Readprop Updateprop Scanprop Insertprop Extendprop 'Runtime(ms)' 'Throughput(ops/sec)'; do
    [[ ",$header," == *",$column,"* ]] || fail "results CSV lacks column '$column'"
done
# Six of the eight phases record a row: reference-load and comparison-load exist to prepare
# data (run_ycsb), they are not measurements, so they never reach write_result.
rows=$(( $(wc -l < "$CSV") - 1 ))
(( rows >= 6 )) || fail "expected at least one row per measured phase, got $rows"
[[ "$(awk -F, 'NR>1 {print tolower($2)}' "$CSV" | sort -u | tr '\n' ' ')" == \
   "avg-run clean-run extend load reference run " ]] || fail "unexpected phase set in CSV"
echo "[backend-smoke] results CSV: $rows rows, $(head -1 "$CSV" | awk -F, '{print NF}') columns"

mapfile -t size_files < <(find "$EXPERIMENT_DIR/data/value_size_data" -name '*.csv' 2>/dev/null | sort)
(( ${#size_files[@]} == 2 )) || fail "expected before/after value-size CSVs, found ${#size_files[@]}"
for f in "${size_files[@]}"; do
    [[ -s "$f" ]] || fail "value-size artefact is empty: $f"
done
[[ -s "$EXPERIMENT_DIR/logs/histogram.txt" ]] || fail "histogram not written"

for phase in load reference-load extend run reference clean-run comparison-load avg-run; do
    compgen -G "$EXPERIMENT_DIR/workloads/$phase-iter*.workload" >/dev/null \
        || fail "no generated workload for phase $phase"
done
echo "[backend-smoke] generated workloads: $(find "$EXPERIMENT_DIR/workloads" -name '*.workload' | wc -l) files"

git -C "$SCRIPTS_DIR" diff --quiet -- ../workloads \
    || fail "tracked files under ../workloads were modified"
[[ -z "$(git -C "$SCRIPTS_DIR" ls-files --others --exclude-standard -- ../workloads)" ]] \
    || fail "new files appeared under ../workloads"

echo "[backend-smoke] PASS — $BACKEND completed the standard phase sequence"
