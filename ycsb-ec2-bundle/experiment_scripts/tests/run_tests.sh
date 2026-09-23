#!/usr/bin/env bash
# Run everything that can be checked without human judgement:
#   tests/run_tests.sh              # static checks + unit tests; smoke only if a DB answers
#   REQUIRE_DB=1 tests/run_tests.sh # also fail if the PostgreSQL smoke run cannot run
#
# The smoke run needs a PostgreSQL 18 server and its role password:
#   DB_PWD=... tests/run_tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
cd "$SCRIPTS_DIR"

# Probed locally and never exported: each backend brings its own endpoint defaults, and an
# exported DB_PORT=5432 would point a MariaDB smoke run at the PostgreSQL server.
PROBE_HOST="${DB_HOST:-127.0.0.1}"
PROBE_PORT="${DB_PORT:-5432}"
PROBE_USER="${DB_USERNAME:-ycsb}"

step() { printf '\n=== %s ===\n' "$*"; }

step "static checks"
bash tools/check_scripts.sh

step "shell unit tests (config, workloads, backend contract)"
if bash tests/test_config_workload.sh; then
    :
else
    echo "[tests] shell unit tests FAILED"
    exit 1
fi

step "python unit tests"
if python3 -m unittest discover -s tests -t tests -v 2>&1 | tail -25; then
    :
else
    echo "[tests] python unit tests FAILED"
    exit 1
fi

db_available() {
    command -v psql >/dev/null 2>&1 || return 1
    [[ -n "${DB_PWD:-}" ]] || return 1
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT=5 psql -h "$PROBE_HOST" -p "$PROBE_PORT" \
        -U "$PROBE_USER" -d "${PG_MAINTENANCE_DB:-postgres}" -At -c 'SELECT 1;' >/dev/null 2>&1
}

# Structural end-to-end check per backend. Every backend listed here runs when a server
# answers for it (./experiment.sh <backend> --check, which reads conf/db.<backend>.env), and
# reports SKIP otherwise - so the list can name backends whose server is a container that is
# not always up. Backends in $REQUIRED_BACKEND_SMOKES additionally fail the suite under
# REQUIRE_DB=1, because there their absence means something broke.
# postgresql_textarray is deliberately not listed: the authoritative smoke run above is a
# textarray run compared against goldens, so it would only duplicate that coverage.
BACKEND_SMOKES="${BACKEND_SMOKES:-postgresql_row postgresql_json postgrenosql mariadb_innodb mongodb neo4j couchbase}"
# The PostgreSQL family shares one server here, so its absence means something broke.
REQUIRED_BACKEND_SMOKES="${REQUIRED_BACKEND_SMOKES:-postgresql_row postgresql_json postgrenosql}"

run_backend_smoke() {
    local backend="$1" out reason
    [[ " $BACKEND_SMOKES " == *" $backend "* ]] || return 0
    out="$(mktemp)"
    if ./experiment.sh "$backend" --check >"$out" 2>&1; then
        bash tests/smoke_backend.sh "$backend"
    else
        reason="$(grep -m1 -E '\[ERROR\]' "$out" || tail -n1 "$out")"
        if [[ " ${REQUIRED_BACKEND_SMOKES:-} " == *" $backend "* && "${REQUIRE_DB:-0}" == 1 ]]; then
            echo "[tests] required backend '$backend' unreachable: $reason"
            rm -f "$out"
            exit 1
        fi
        echo "[tests] $backend SKIPPED - $reason"
    fi
    rm -f "$out"
}

step "PostgreSQL smoke run (goldens)"
if db_available; then
    bash tests/smoke_authoritative.sh
elif [[ "${REQUIRE_DB:-0}" == 1 ]]; then
    echo "[tests] REQUIRE_DB=1 but no PostgreSQL answered at $PROBE_HOST:$PROBE_PORT as $PROBE_USER"
    exit 1
else
    echo "[tests] SKIPPED - set DB_PWD (and optionally REQUIRE_DB=1) to run it"
fi

step "backend structural smokes"
for backend in $BACKEND_SMOKES; do
    run_backend_smoke "$backend"
done

step "all checks passed"
