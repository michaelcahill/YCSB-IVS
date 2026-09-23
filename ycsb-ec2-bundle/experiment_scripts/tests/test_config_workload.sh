#!/usr/bin/env bash
# Unit tests for the configuration layer and workload generation.
# No database and no YCSB run are needed:
#
#   bash tests/test_config_workload.sh
#
# shellcheck disable=SC1090  # backends are sourced by discovered name, not by a constant path
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
CONF_DIR="$SCRIPTS_DIR/conf"

# shellcheck source=lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"

pass=0 fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }
eq()   { [[ "$2" == "$3" ]] && ok || bad "$1: expected [$3], got [$2]"; }
has()  { [[ "$2" == *"$3"* ]] && ok || bad "$1: expected to contain [$3], got [$2]"; }

# Every test runs in a private sandbox with a pristine environment, so variables set by
# one case cannot leak into the next.
sandbox() {
    local dir="$1"
    rm -rf "$dir" && mkdir -p "$dir/workloads" || return 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ycsb-config-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The tests below assert what a preset file applies, so the canonical names it sets must
# not be inherited from whoever runs the suite.
unset TYPE SCALE RUN EXTEND_DIST EMPTY_OK

# --- configuration files ------------------------------------------------------

cat > "$TMP/preset.env" <<'EOF'
# a comment line

  TYPE=preset_type
export SCALE=light
RUN="7"
EXTEND_DIST=uniform
EMPTY_OK=
PATH_SHOULD_BE_IGNORED=/not/from/a/file
EOF

check_config_file() {
    (
        set -euo pipefail
        PATH="/usr/bin:/bin"
        export PATH
        config::snapshot_env
        config::load_file "$TMP/preset.env"
        [[ "$TYPE" == preset_type ]] || exit 11
        [[ "$SCALE" == light ]] || exit 12
        [[ "$RUN" == 7 ]] || exit 13                       # quotes stripped
        [[ "$EXTEND_DIST" == uniform ]] || exit 14
        [[ -z "${EMPTY_OK:-}" ]] || exit 15
        [[ "$PATH" != /not/from/a/file* ]] || exit 16       # env beats the file
    )
}
check_config_file && ok || bad "config file: values not applied as documented (rc=$?)"

check_env_beats_file() {
    (
        set -euo pipefail
        TYPE=from_env
        export TYPE
        config::snapshot_env
        config::load_file "$TMP/preset.env" >/dev/null
        [[ "$TYPE" == from_env ]] || exit 21
    )
}
check_env_beats_file && ok || bad "config file: environment must win over a preset (rc=$?)"

check_cli_beats_file() {
    (
        set -euo pipefail
        config::snapshot_env
        config::set_cli "TYPE=from_cli"
        config::load_file "$TMP/preset.env" >/dev/null
        [[ "$TYPE" == from_cli ]] || exit 31
    )
}
check_cli_beats_file && ok || bad "--var/CLI flags must win over a preset (rc=$?)"

cat > "$TMP/bad.env" <<'EOF'
TYPE=ok
run_it() { echo nope; }
EOF
config::load_file "$TMP/bad.env" >/dev/null 2>&1 && bad "non-assignment lines must be rejected" || ok

cat > "$TMP/eval.env" <<'EOF'
TYPE=$(echo executed)
EOF
out="$(config::load_file "$TMP/eval.env" 2>&1)" && bad "command substitution must be rejected" || ok
has "config is not executed" "$out" "substitution"

# --- legacy launcher aliases: gone (step 8c) ------------------------------------

# The DIST/WORK/EXPERIMENT_EPOCHS-style variable shim and the deprecated backend-name
# aliases existed to keep pre-refactor launchers working. The EC2 acceptance run used the
# rewritten runbook, step 8c deleted the legacy scripts, and with them both shims: an old
# name must now fail loudly instead of silently running something.

# --- experiment mode ----------------------------------------------------------

# There are two engines (lib/lifecycle.sh, lib/lifecycle_baseline.sh) and they share every phase
# step. What the mode may change in the configuration layer is therefore exactly three things:
# which engine runs, that a baseline run cannot overwrite the mainline artefacts it is compared
# with, and that comparison phases are off rather than silently skipped.
mode_config() {   # <mode> -> "<EXPERIMENT_NAME>|<COMPARISON_INTERVAL>"
    local mode="$1"
    (
        set -euo pipefail
        backend::default_config() { :; }      # the backend's own defaults are not under test here
        registry::info() { printf '\n'; }
        TYPE=t SCALE=light RUN=2 EXTEND_DIST=d WORKLOAD=w
        EXPERIMENT_MODE="$mode"
        COMPARISON_INTERVAL=1                 # a caller asking for comparisons is overruled
        # Explicit || exit, not bare calls: bash suppresses errexit inside the condition of an
        # if/&& (and a subshell inherits that suppression), so `config::init_defaults` alone
        # would run on to the printf below when this helper is used as a condition.
        config::init_defaults || exit 1
        config::derive_paths || exit 1
        printf '%s|%s\n' "$EXPERIMENT_NAME" "$COMPARISON_INTERVAL"
    )
}
eq "mainline artefact names carry no mode suffix" "$(mode_config mainline)" "t_light_extend-d_w_run2|1"
eq "baseline artefacts get their own names" "$(mode_config baseline)" "t_light_extend-d_w_run2_baseline|0"
eq "an explicit name override still wins" "$(EXPERIMENT_NAME_OVERRIDE=custom mode_config baseline)" "custom|0"
if mode_config bogus >/dev/null 2>&1; then
    bad "an unknown mode must be rejected"
else
    ok
fi

# --- workload generation ------------------------------------------------------

sandbox "$TMP/wl" || exit 1
WORKLOAD_DIR="$TMP/wl/workloads"
export WORKLOAD_DIR
cat > "$TMP/template" <<'EOF'
recordcount=200
operationcount=400
workload=site.ycsb.workloads.CoreWorkload
fieldlength=100
readallfields=true
readproportion=1
updateproportion=0
scanproportion=0
insertproportion=0
readmodifywriteproportion=0
requestdistribution=uniform
extendproportion=1
extendfieldlength=100
EOF
WORKLOAD_FILE="$TMP/template"
export WORKLOAD_FILE

# Values the overlays are built from (normally prepared by config::init_defaults).
extendproportion_extend=1; readproportion_extend=0; updateproportion_extend=0
scanproportion_extend=0; insertproportion_extend=0; readmodifywriteproportion_extend=0
requestdistribution_extend=zipfian; readrequestdistribution_extend=zipfian
updaterequestdistribution_extend=zipfian; extendoperationcount=300
extendproportion_postextend=0; readproportion_postextend=1; updateproportion_postextend=0
scanproportion_postextend=0; insertproportion_postextend=0
readmodifywriteproportion_postextend=0
requestdistribution_postextend=uniform; readrequestdistribution_postextend=uniform
updaterequestdistribution_postextend=uniform
fieldlengthoriginal=100; fieldlengthaverage=420
fieldlengthdistribution=histogram
recordcount_override=""; operationcount_override=""
original_operationcount=400

hash_before="$(sha256sum "$WORKLOAD_FILE" | cut -d' ' -f1)"

# lib/workload.sh logs through the common logger; a stub keeps this test standalone.
log() { :; }

# shellcheck source=lib/workload.sh
source "$SCRIPTS_DIR/lib/workload.sh"

workload::init >/dev/null || bad "workload::init failed on a valid template"

extend_file="$(workload::generate extend 7)"
eq "extend file name" "$(basename "$extend_file")" "extend-iter07.workload"
has "extend provenance" "$(head -3 "$extend_file" | tr '\n' '|')" "# backend="
has "extend template hash" "$(head -3 "$extend_file" | tr '\n' '|')" "sha256="
eq "extend operationcount" "$(workload::get_value "$extend_file" operationcount)" "300"
eq "extend requestdistribution" "$(workload::get_value "$extend_file" requestdistribution)" "zipfian"
eq "extend readproportion" "$(workload::get_value "$extend_file" readproportion)" "0"
eq "extend keeps template keys" "$(workload::get_value "$extend_file" extendfieldlength)" "100"

run_file="$(workload::generate run 7)"
eq "run operationcount" "$(workload::get_value "$run_file" operationcount)" "400"
eq "run readproportion" "$(workload::get_value "$run_file" readproportion)" "1"
eq "run histogram appended" "$(workload::get_value "$run_file" fieldlengthdistribution)" "histogram"

avg_file="$(workload::generate avg-run 7)"
eq "avg-run restores fieldlength" "$(workload::get_value "$avg_file" fieldlength)" "100"
cmp -s <(grep -v '^#' "$run_file") <(grep -v '^#' "$avg_file") \
    && bad "avg-run must differ from run" || ok

comparison_file="$(workload::generate comparison-load 7)"
eq "comparison-load uses the measured size" \
    "$(workload::get_value "$comparison_file" fieldlength)" "420"

# Extra KEY=VALUE arguments win over the phase overlay.
eq "extra overlay wins" \
    "$(workload::get_value "$(workload::generate run 8 fieldlength=9)" fieldlength)" "9"

# Keys absent from the template are appended, keys present are replaced in place:
# never duplicated, whatever the number of generations.
eq "upsert does not duplicate keys" \
    "$(grep -c '^operationcount=' "$run_file")" "1"

# recordcount overrides resize a dataset without touching the template.
recordcount_override=50
eq "recordcount override" \
    "$(workload::get_value "$(workload::generate load 0)" recordcount)" "50"
recordcount_override=""

# The template is never modified, and neither is any previously generated file.
hash_after="$(sha256sum "$WORKLOAD_FILE" | cut -d' ' -f1)"
eq "template unchanged" "$hash_after" "$hash_before"
run_body_before="$(grep -v '^#' "$run_file")"
workload::generate run 7 >/dev/null
eq "regenerating a phase is idempotent" "$(grep -v '^#' "$run_file")" "$run_body_before"

# apply_context publishes exactly the settings write_result records.
workload::apply_context "$extend_file"
eq "context recordcount" "${recordcount:-}" "200"
eq "context readproportion" "${readproportion:-}" "0"
eq "context extendproportion" "${extendproportion:-}" "1"
eq "context requestdistribution" "${requestdistribution:-}" "zipfian"

# An unknown phase must fail loudly instead of running YCSB with the wrong workload.
workload::generate bogus-phase 1 >/dev/null 2>&1 && bad "unknown phase must fail" || ok

# --- backend contract and engine hygiene --------------------------------------

# shellcheck source=lib/registry.sh
source "$SCRIPTS_DIR/lib/registry.sh"

# Deleted aliases must stay dead: none of the pre-refactor spellings may resolve, and
# none of them is advertised as a backend.
for old_name in postgresql postgresql_array postgresql_array-text-autovacuum textarray \
                jsonb arrayjson array_json postgresql_array_json postgresql_jsonb \
                innodb rocksdb; do
    if registry::resolve "$old_name" >/dev/null 2>&1; then
        bad "removed alias $old_name still resolves"
    elif [[ " $(registry::available) " == *" $old_name "* ]]; then
        bad "$old_name must not be advertised as a backend"
    else
        ok "$old_name is gone"
    fi
done
registry::resolve _postgresql_common >/dev/null 2>&1 && bad "shared modules are not backends" || ok

for backend in $(registry::available); do
    if (set -euo pipefail; source "$BACKENDS_DIR/$backend.sh"; while read -r fn; do
            declare -F "$fn" >/dev/null || { echo "missing $fn in $backend" >&2; exit 1; }
        done < <(registry::required_functions)); then
        ok
    else
        bad "backend $backend does not implement the contract (rc=$?)"
    fi
done

# Statistics columns are a backend's results-CSV schema, and the whole point of keeping them is
# comparability with the runs made before the refactor, so the legacy headers are the
# specification. They are kept here as data (tests/golden/legacy_csv_columns.txt) because the
# scripts they were read from are gone: step 6 deleted the nine legacy *_baseline.sh runners
# once --mode baseline replaced them. Backends whose legacy header did not survive parsing, or
# whose statistics set was deliberately redesigned with the port (postgresql_*: PG18 views;
# mariadb_rocksdb: information_schema instead of greps that matched nothing; neo4j) are listed
# in that file's history rather than asserted here.
legacy_header_matches() {
    local backend names legacy
    while IFS=$'\t' read -r backend legacy; do
        [[ -n "$backend" && ! "$backend" == \#* ]] || continue
        names=$(cd "$SCRIPTS_DIR" && source "lib/backends/$backend.sh" && backend::metric_names | paste -sd, -)
        if [[ "$names" != "$legacy" ]]; then
            echo "backend $backend changed its statistics columns" >&2
            echo "  new   : $names" >&2
            echo "  legacy: $legacy" >&2
            return 1
        fi
    done < "$SCRIPTS_DIR/tests/golden/legacy_csv_columns.txt"
}
(cd "$SCRIPTS_DIR" && legacy_header_matches) && ok || bad "statistics columns still match the legacy headers (rc=$?)"

# The engines must stay backend-independent: no PostgreSQL spellings, and no writes to
# workload files (the two things that made the legacy scripts unmaintainable).
engine_hygiene() {
    local file hits
    for file in lib/lifecycle.sh lib/lifecycle_baseline.sh; do
        hits=$(grep -nE '\b(pg_exec|pg_cli|collect_postgres_metrics|postgres_preflight|initialize_database|close_db|wait_for_idle_postgres|restore_comparison_database)\b' "$file") || true
        [[ -z "$hits" ]] || { echo "engine calls backend internals: $hits" >&2; return 1; }
        hits=$(grep -nE 'perl -i|>[[:space:]]*"?\$\{?WORKLOAD_FILE' "$file") || true
        [[ -z "$hits" ]] || { echo "engine writes to a workload file: $hits" >&2; return 1; }
    done
}
(cd "$SCRIPTS_DIR" && engine_hygiene) && ok || bad "engine hygiene (rc=$?)"

# A mode is a sequence of shared steps, never a second copy of them: the baseline engine may not
# invoke YCSB, sample metrics or write a result row itself. That is what keeps its numbers
# comparable with the mainline ones, and it is the duplication that the nine legacy
# *_baseline.sh scripts each carried.
baseline_engine_reuses_the_steps() {
    local hits
    hits=$(grep -nE 'run_with_metrics|run_ycsb|write_result|\$YCSB|collect_metrics|workload::generate|backend::' \
        lib/lifecycle_baseline.sh | grep -vE '^[0-9]+:[[:space:]]*#') || true
    [[ -z "$hits" ]] || { echo "baseline engine re-implements a step: $hits" >&2; return 1; }
    grep -q 'run_experiment_baseline' lib/lifecycle.sh \
        || { echo "run_experiment does not dispatch to the baseline engine" >&2; return 1; }
}
(cd "$SCRIPTS_DIR" && baseline_engine_reuses_the_steps) && ok || bad "baseline mode reuses the phase steps (rc=$?)"

# The core must stay database-independent: no PostgreSQL column names outside the
# PostgreSQL module, or a MongoDB/MariaDB results CSV would inherit them.
core_hygiene() {
    local hits
    hits=$(grep -nE 'blks_read|tup_returned|usertable_|pg_stat|postgres' lib/metrics.sh lib/results.sh) || true
    [[ -z "$hits" ]] || { echo "core knows about PostgreSQL: $hits" >&2; return 1; }
}
(cd "$SCRIPTS_DIR" && core_hygiene) && ok || bad "core database-independence (rc=$?)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
(( fail == 0 ))
