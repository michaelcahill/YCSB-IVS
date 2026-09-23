#!/usr/bin/env bash
# Compatibility entry point.
#
# The Neo4j runner was refactored: the phase engine lives in lib/lifecycle.sh, the Neo4j
# specifics in lib/backends/neo4j.sh, and all configuration is resolved by lib/config.sh.
# Use the single entry point instead:
#
#   ./experiment.sh neo4j [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/SCALE variables are
# translated by the alias shim in lib/config.sh). Differences worth knowing before
# reproducing an old run with this script:
#   * an instance is reset by deleting its nodes, not by stopping the server and wiping its data
#     directory - a benchmark role cannot restart a service, and a run must not need sudo;
#   * the graphml copy to the comparison instance writes into each instance's import directory,
#     so those must be shared (or moved with NEO4J_BACKUP_COPY_CMD). The old script hardcoded
#     /opt/neo4j-instance-main/import -> /opt/neo4j-instance-backup/import with sudo cp/chown;
#   * endpoints come from conf/db.neo4j.env instead of hardcoded bolt://localhost:{7687,7787,
#     7887}, and the three roles are checked up front - two roles on one instance now fail
#     instead of silently comparing a database with itself;
#   * keys and value sizes are read back unquoted. The old script kept cypher-shell's quotes in
#     the key files, so its "delete the keys inserted during the run" step matched nothing and
#     deleted nothing;
#   * preflight requires APOC on the main and comparison instances (the clean-run phase needs
#     it) instead of failing halfway through the first iteration.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" neo4j "$@"
