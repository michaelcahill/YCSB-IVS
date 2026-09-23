#!/usr/bin/env bash
# Compatibility entry point.
#
# The row-schema runner was refactored: the phase engine lives in lib/lifecycle.sh, the
# PostgreSQL specifics in lib/backends/_postgresql_common.sh plus
# lib/backends/postgresql_row.sh, and all configuration is resolved by lib/config.sh.
# Use the single entry point instead:
#
#   ./experiment.sh postgresql_row [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/vacuum variables are
# translated by the alias shim in lib/config.sh). Note that settings the old script
# hardcoded for everyone — its workload file, proportions and paths — now come from the
# configuration layer, so pass --workload/--var when reproducing an old run.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" postgresql_row "$@"
