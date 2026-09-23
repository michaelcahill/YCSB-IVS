#!/usr/bin/env bash
# End-to-end smoke run of an experiment script against a real PostgreSQL 18
# server using a tiny workload, compared against stored goldens.
#
#   tests/smoke_authoritative.sh              # run and compare with goldens
#   tests/smoke_authoritative.sh --update     # run and store new goldens
#
# Goldens hold *structure*, not measurements: phase markers, log line shapes,
# CSV column names, row/operation shape and operation counts. Every volatile
# value (timings, throughput, latencies, PostgreSQL counters, relation OIDs,
# execution ids, timestamps, credentials) is masked so runs are comparable.
#
# Requires a reachable PostgreSQL 18 server whose role has LOGIN + CREATEDB:
#   DB_PWD=... tests/smoke_authoritative.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GOLDEN_DIR="$TESTS_DIR/golden/smoke"

TARGET_SCRIPT="${TARGET_SCRIPT:-$SCRIPTS_DIR/experiment_postgresql_array-text-autovacuum.sh}"

UPDATE_GOLDEN=0
[[ "${1:-}" != "--update" ]] || UPDATE_GOLDEN=1

# --- smoke configuration -----------------------------------------------------
export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5432}"
export DB_USERNAME="${DB_USERNAME:-ycsb}"
export DB_PWD="${DB_PWD:?Set DB_PWD to the benchmark role password}"
export PG_MAINTENANCE_DB="${PG_MAINTENANCE_DB:-postgres}"

# Dedicated databases so a smoke run can never destroy an existing experiment.
export DB_NAME="${SMOKE_DB_NAME:-ycsb_smoke}"
export UNCHANGED_DB_NAME="${SMOKE_UNCHANGED_DB_NAME:-ycsb_smoke_unch}"
export BACKUP_DB_NAME="${SMOKE_BACKUP_DB_NAME:-ycsb_smoke_bak}"

export TYPE="${TYPE:-smoke_textarray}"
export RUN="1"
export NUM_EPOCHS=1
export STEPS_PER_EPOCH=1
export COMPARISON_INTERVAL=1
export EXTEND_OPERATIONCOUNT=300
export DB_STATS_INTERVAL=1

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ycsb-smoke.XXXXXX")"
KEEP="${SMOKE_KEEP:-0}"
cleanup() {
    if [[ "$KEEP" == 1 ]]; then
        echo "[smoke] workdir kept at $WORKDIR"
    else
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# Tiny self-contained workload. Experiment scripts rewrite their workload file
# in place today, so it must never be a file under version control.
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

# Start from a known database state: leftover smoke databases change the runner's
# output (dropdb emits "NOTICE: database ... does not exist, skipping" only when the
# database is absent), which would make the goldens depend on history.
echo "[smoke] dropping any leftover smoke databases"
for db in "$DB_NAME" "$UNCHANGED_DB_NAME" "$BACKUP_DB_NAME"; do
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT=10 psql -h "$DB_HOST" -p "$DB_PORT" \
        -U "$DB_USERNAME" -d "$PG_MAINTENANCE_DB" -q -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" >/dev/null 2>&1 \
        || echo "[smoke] warning: could not drop $db"
done

echo "[smoke] target=$TARGET_SCRIPT"
echo "[smoke] database=$DB_HOST:$DB_PORT user=$DB_USERNAME (dbs: $DB_NAME, $UNCHANGED_DB_NAME, $BACKUP_DB_NAME)"
echo "[smoke] workdir=$WORKDIR"

set +e
bash -c "${TARGET_CMD:-bash "$TARGET_SCRIPT"}" > "$WORKDIR/run.out" 2>&1
rc=$?
set -e
sed 's/^/[run] /' "$WORKDIR/run.out" | tail -20
echo "[smoke] experiment exit status=$rc"

# --- normalisation -----------------------------------------------------------
# Mask everything that legitimately differs between runs, including the DB
# password that YCSB echoes back in its "Command line:" banner.
normalize_log() {
    sed -E \
        -e 's/-p db\.passwd=[^ ]*/-p db.passwd=<REDACTED>/g' \
        -e 's/[0-9]{8}T[0-9]{6}Z_[0-9]+/<EXECUTION_ID>/g' \
        -e 's/\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}( UTC)?\]/[<TIMESTAMP>]/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[:.][0-9]+/<DATETIME>/g' \
        -e 's/pg_toast_[0-9]+/pg_toast_<OID>/g' \
        -e 's/DB statistics .*/DB statistics <METRICS>/' \
        -e 's/\b(duration|statistics|relsizes|columns)=[0-9]+/\1=<N>/g' \
        -e 's/[0-9]{4,}/<N>/g' \
        -e "s#$WORKDIR#<WORKDIR>#g"
}

# Keep the structural log lines: everything emitted by the runner's own log()
# plus its two unmarked progress echoes. YCSB's own chatter is excluded.
markers_only() {
    # "WAITING FOR IDLE POSTGRES" lines appear only when the server happens to be
    # busy (autovacuum/checkpointer from earlier runs), so they are environment
    # noise; the START/END WAIT pair around them is kept.
    grep -E '\[epoch=|Starting metrics collection for |Finished [^ ]+ phase=' "$1" \
        | grep -v 'WAITING FOR IDLE POSTGRES' || true
}

normalize_stderr() {
    # Raw stdout/stderr of the run, minus YCSB measurement noise.
    grep -vE 'sec: [0-9]+ operations|DBWrapper: report latency|^Loading workload|^Starting test|^Command line:|^YCSB Client|^[[:space:]]*$' "$1" || true
    echo "exit=$2"
}

# Mask volatile CSV columns: the database statistics block (everything between
# 'Operation' and 'Readprop'), runtime/throughput, and any latency measurement.
normalize_csv() {
    awk -F, -v OFS=, '
        NR==1 {
            for (i = 1; i <= NF; i++) {
                name = $i
                if (name == "CPU") stats_start = i
                if (name == "Readprop") stats_end = i
                if (name ~ /[Ll]atency/ || name ~ /[Pp]ercentile/ ||
                    name ~ /[Rr]un[Tt]ime/ || name ~ /[Tt]hroughput/) volatile[i] = 1
            }
            print
            next
        }
        {
            line = ""
            for (i = 1; i <= NF; i++) {
                v = $i
                if (volatile[i] || (stats_start && i >= stats_start && i < stats_end)) v = "<N>"
                line = (line == "" ? v : line OFS v)
            }
            print line
        }
    ' "$1"
}

csv_shape() {
    awk -F, 'NR==1 { print NF " columns"; next } { print $1 "," $2 "," $6 }' "$1"
}

OUT="$WORKDIR/golden"
mkdir -p "$OUT"

LOG_FILE="$(find "$EXPERIMENT_DIR/logs" -name '*_results.log' | head -1)"
RESULT_CSV="$(find "$EXPERIMENT_DIR/data/workload_data" -name '*.csv' | head -1)"
if [[ -z "$LOG_FILE" || -z "$RESULT_CSV" ]]; then
    echo "[smoke] FATAL: no results log / workload CSV under $EXPERIMENT_DIR" >&2
    tail -30 "$WORKDIR/run.out" >&2
    exit 1
fi

markers_only "$LOG_FILE" | normalize_log > "$OUT/results.markers.txt"
normalize_stderr "$WORKDIR/run.out" "$rc" | normalize_log > "$OUT/run.out.txt"
normalize_csv "$RESULT_CSV" > "$OUT/workload_data.csv"
csv_shape "$RESULT_CSV" > "$OUT/workload_data.shape.txt"

for f in $(find "$EXPERIMENT_DIR/data/value_size_data" -name '*.csv' | sort); do
    base="$(basename "$f")"
    # Row counts and headers only: the per-key sizes depend on random choices.
    { head -1 "$f"; echo "rows=$(( $(wc -l < "$f") - 1 ))"; } > "$OUT/$base.shape.txt"
done

HISTOGRAM="$(find "$EXPERIMENT_DIR" -name 'histogram.txt' | head -1)"
if [[ -n "$HISTOGRAM" ]]; then
    # Bucket counts depend on the random key choices, so record presence only.
    echo "histogram present" > "$OUT/histogram.txt"
else
    echo "histogram missing" > "$OUT/histogram.txt"
fi

grep -hE 'ERROR|WARNING' "$LOG_FILE" | normalize_log | sort | uniq -c > "$OUT/diagnostics.txt" || true
echo "exit=$rc" > "$OUT/exit-status.txt"

if (( UPDATE_GOLDEN )); then
    mkdir -p "$GOLDEN_DIR"
    rm -rf "${GOLDEN_DIR:?}/"* 2>/dev/null || true
    cp "$OUT"/* "$GOLDEN_DIR"/
    echo "[smoke] goldens written to $GOLDEN_DIR"
    exit 0
fi

fail=0
for f in "$GOLDEN_DIR"/*; do
    name="$(basename "$f")"
    if [[ ! -f "$OUT/$name" ]]; then
        echo "[smoke] MISSING output for golden: $name"
        fail=1
        continue
    fi
    if ! diff -u "$f" "$OUT/$name" > "$WORKDIR/$name.diff"; then
        echo "[smoke] DIFF in $name:"
        head -30 "$WORKDIR/$name.diff"
        fail=1
    fi
done
for f in "$OUT"/*; do
    name="$(basename "$f")"
    [[ -f "$GOLDEN_DIR/$name" ]] || { echo "[smoke] UNEXPECTED output not in goldens: $name"; fail=1; }
done

if (( fail )); then
    echo "[smoke] FAILED"
    exit 1
fi
echo "[smoke] PASS — output matches goldens in tests/golden/smoke"
