#!/usr/bin/env bash
# Compatibility entry point.
#
# The MongoDB runner was refactored: the phase engine lives in lib/lifecycle.sh, the MongoDB
# specifics in lib/backends/mongodb.sh, and all configuration is resolved by lib/config.sh.
# Use the single entry point instead:
#
#   ./experiment.sh mongodb [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/SCALE variables are
# translated by the alias shim in lib/config.sh). Differences worth knowing before
# reproducing an old run with this script:
#   * the comparison database is a third database on the SAME server, reached by renaming the
#     namespaces during the restore. The old script needed a second mongod on 28018 and could
#     only restore into a database of the same name;
#   * the endpoint comes from conf/db.mongodb.env (see the example) instead of being hardcoded
#     to mongodb://localhost:27017, and it is passed per phase because every phase targets its
#     own database;
#   * artefacts were named after TYPE="mongodb", which is still the default, so names match;
#   * the results CSV has no database statistics columns - exactly like the old header; CPU and
#     Memory sample the OS account running mongod (HOST_OS_USER, empty when it is a container);
#   * no query-plan log: this runner never wrote one, so there is nothing to compare against.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" mongodb "$@"
