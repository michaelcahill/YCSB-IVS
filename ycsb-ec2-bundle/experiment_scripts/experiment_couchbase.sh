#!/usr/bin/env bash
# Compatibility entry point.
#
# The Couchbase runner was refactored: the phase engine lives in lib/lifecycle.sh, the Couchbase
# specifics in lib/backends/couchbase.sh, and all configuration is resolved by lib/config.sh.
# Use the single entry point instead:
#
#   ./experiment.sh couchbase [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/SCALE variables are
# translated by the alias shim in lib/config.sh). Differences worth knowing before reproducing an
# old run with this script:
#   * a bucket that cannot be flushed is emptied with DELETE FROM instead of shifting
#     insertstart/recordcount into the workload - moving the key range changes what is measured;
#   * one bucket password (DB_PWD) for all three roles. COUCHBASE_PASSWORD_PRIMARY/_BACKUP/_UNCHANGE
#     all defaulted to the same value, and one password per phase is all the engine can express;
#   * the copy into the comparison bucket is verified by document count (the legacy
#     INSERT ... SELECT was not checked at all, and index reads lag behind writes);
#   * missing buckets - and the local users named after them that SDK 2.x authenticates as - are
#     created when COUCHBASE_CREATE_MISSING_BUCKETS=1 (the default), so a fresh cluster works;
#   * endpoints come from conf/db.couchbase.env instead of a hardcoded 127.0.0.1;
#   * the 22 statistics columns are the legacy list, still all zero: Couchbase has no equivalent
#     counters. The bucket's own numbers (documents, disk/data/RAM bytes) are logged per phase,
#     and CPU/Memory sample HOST_OS_USER (empty for a container or remote server).
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" couchbase "$@"
