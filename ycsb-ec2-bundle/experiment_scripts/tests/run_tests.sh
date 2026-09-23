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

export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5432}"
export DB_USERNAME="${DB_USERNAME:-ycsb}"

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
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT=5 psql -h "$DB_HOST" -p "$DB_PORT" \
        -U "$DB_USERNAME" -d "${PG_MAINTENANCE_DB:-postgres}" -At -c 'SELECT 1;' >/dev/null 2>&1
}

step "PostgreSQL smoke run"
if db_available; then
    bash tests/smoke_authoritative.sh
    # Structural check of every backend whose server is reachable here. The PostgreSQL
    # backends are; the others need servers this machine does not run.
    for backend in postgresql_row postgrenosql; do
        bash tests/smoke_backend.sh "$backend"
    done
elif [[ "${REQUIRE_DB:-0}" == 1 ]]; then
    echo "[tests] REQUIRE_DB=1 but no PostgreSQL answered at $DB_HOST:$DB_PORT as $DB_USERNAME"
    exit 1
else
    echo "[tests] SKIPPED - set DB_PWD (and optionally REQUIRE_DB=1) to run it"
fi

step "all checks passed"
