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

# --- legacy launcher aliases --------------------------------------------------

# env -i: a launcher's environment contains only the legacy names. Without isolation a
# canonical name inherited from the caller (DB_PWD, for instance) would legitimately win
# and the assertions below would depend on who runs the tests.
check_alias() {
    (
        set -euo pipefail
        env -i PATH="$PATH" HOME="$HOME" \
            DIST=uniform WORK=pure UNCHANGE_DB_NAME=legacy_unch \
            EXPERIMENT_EPOCHS=3 EXPERIMENT_RUNS_PER_EPOCH=4 \
            DB_PASSWORD=s3cret FIELD_LENGTH_ORIGINAL=250 \
            EXTEND_READPROPORTION=0.5 RUN_UPDATEPROPORTION=0.25 vacuum=1 \
            bash -c '
                set -euo pipefail
                source "'"$SCRIPTS_DIR"'/lib/config.sh"
                config::apply_legacy_aliases >/dev/null
                [[ "$EXTEND_DIST" == uniform ]] &&
                [[ "$WORKLOAD" == pure ]] &&
                [[ "$UNCHANGED_DB_NAME" == legacy_unch ]] &&
                [[ "$NUM_EPOCHS" == 3 ]] &&
                [[ "$STEPS_PER_EPOCH" == 4 ]] &&
                [[ "$DB_PWD" == s3cret ]] &&
                [[ "$FIELDLENGTHORIGINAL" == 250 ]] &&
                [[ "$READ_PROPORTION_EXTEND" == 0.5 ]] &&
                [[ "$UPDATE_PROPORTION_POSTEXTEND" == 0.25 ]] &&
                [[ "$VACUUM_ENABLED" == 1 ]]'
    )
}
check_alias >/dev/null 2>&1 && ok || bad "legacy launcher variables were not translated (rc=$?)"

check_alias_canonical_wins() {
    (
        set -euo pipefail
        env -i PATH="$PATH" HOME="$HOME" DIST=uniform EXTEND_DIST=zipfian bash -c '
            set -euo pipefail
            source "'"$SCRIPTS_DIR"'/lib/config.sh"
            config::apply_legacy_aliases 2>/dev/null
            [[ "$EXTEND_DIST" == zipfian ]]'
    )
}
check_alias_canonical_wins >/dev/null 2>&1 && ok || bad "the canonical name must win over the legacy one (rc=$?)"

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
for backend in $(registry::available); do
    if (set -euo pipefail; source "$BACKENDS_DIR/$backend.sh"; while read -r fn; do
            declare -F "$fn" >/dev/null || { echo "missing $fn in $backend" >&2; exit 1; }
        done < <(registry::required_functions)); then
        ok
    else
        bad "backend $backend does not implement the contract (rc=$?)"
    fi
done

# The engine must stay backend-independent: no PostgreSQL spellings, and no writes to
# workload files (the two things that made the legacy scripts unmaintainable).
engine_hygiene() {
    local file="lib/lifecycle.sh" hits
    hits=$(grep -nE '\b(pg_exec|pg_cli|collect_postgres_metrics|postgres_preflight|initialize_database|close_db|wait_for_idle_postgres|restore_comparison_database)\b' "$file") || true
    [[ -z "$hits" ]] || { echo "engine calls backend internals: $hits" >&2; return 1; }
    hits=$(grep -nE 'perl -i|>[[:space:]]*"?\$\{?WORKLOAD_FILE' "$file") || true
    [[ -z "$hits" ]] || { echo "engine writes to a workload file: $hits" >&2; return 1; }
}
(cd "$SCRIPTS_DIR" && engine_hygiene) && ok || bad "engine hygiene (rc=$?)"

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
