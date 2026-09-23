#!/usr/bin/env bash
# Compatibility entry point.
#
# The MariaDB/InnoDB runner was refactored: the phase engine lives in lib/lifecycle.sh, the
# MariaDB specifics in lib/backends/_mariadb_common.sh plus lib/backends/mariadb_innodb.sh,
# and all configuration is resolved by lib/config.sh. Use the single entry point instead:
#
#   ./experiment.sh mariadb_innodb [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/SCALE variables are
# translated by the alias shim in lib/config.sh). Differences worth knowing before
# reproducing an old run with this script:
#   * artefacts were named after TYPE="innodb"; the new default type is mariadb_innodb, so
#     pass --type innodb to keep the old file names;
#   * the endpoint, role and password come from conf/db.mariadb_innodb.env (see the example)
#     instead of being hardcoded here;
#   * btree_height reports 0 unless INNO_SPACE_TOOL + INNODB_IBD_FILE are configured — this
#     script shelled out to `sudo ../inno_space/inno` inside the measured run;
#   * each phase's database is created and dropped by the runner rather than TRUNCATEd.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" mariadb_innodb "$@"
