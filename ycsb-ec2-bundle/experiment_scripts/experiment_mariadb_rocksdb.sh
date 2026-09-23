#!/usr/bin/env bash
# Compatibility entry point.
#
# The MariaDB/RocksDB runner was refactored: the phase engine lives in lib/lifecycle.sh, the
# MariaDB specifics in lib/backends/_mariadb_common.sh plus lib/backends/mariadb_rocksdb.sh,
# and all configuration is resolved by lib/config.sh. Use the single entry point instead:
#
#   ./experiment.sh mariadb_rocksdb [options]
#
# This wrapper keeps existing launchers working (the legacy DIST/WORK/SCALE variables are
# translated by the alias shim in lib/config.sh) and keeps artefact names, since TYPE="rocksdb"
# is still the default type. Differences worth knowing before reproducing an old run:
#   * endpoint, role and password come from conf/db.mariadb_rocksdb.env (see the example)
#     instead of being hardcoded to localhost:3306 / ycsb_user;
#   * each phase's database is created and dropped by the runner - this script required all
#     three plus their tables to exist beforehand and only deleted rows;
#   * it needed `mysql -u root --password=` and `sudo du` on the server's data directory. The
#     benchmark role now does everything, so those two columns (SSTsize, LOGsize) are gone:
#     total_sst_size from information_schema.ROCKSDB_SST_PROPS answers the same question
#     without root;
#   * its five LSM-tree columns were grepped out of SHOW ENGINE ROCKSDB STATUS with phrases that
#     only exist in newer MyRocks builds, so on this server they were always empty. They are
#     real now (sst_files, total_sst_size, pending_compactions, lsm_memory_usage) and joined by
#     31 more RocksDB counters; lsm_levels reports 0 because MariaDB 10.3 has no per-level view;
#   * the statistics columns follow the shared position (after CPU,Memory), not this script's
#     SSTsize,LOGsize before CPU,Memory.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/experiment.sh" mariadb_rocksdb "$@"
