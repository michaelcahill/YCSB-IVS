#!/usr/bin/env bash
# MariaDB backend — RocksDB (MyRocks) storage engine, driven by the plain jdbc binding with
# the MariaDB JDBC driver. The LSM-tree comparison group of the study: the same relational
# schema and the same workload as mariadb_innodb, but values are stored in an LSM tree with
# SST files, compaction and a block cache instead of B+-tree pages — which is what the
# statistics columns below try to make visible.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not storage-engine
# specific (CLI wrapper, preflight, dump/restore, size helpers) comes from _mariadb_common.sh.
#
# Statistics: the legacy runner grepped `SHOW ENGINE ROCKSDB STATUS` for five phrases
# ("Total Sst files in all levels:", "Total size of all SST files:", "Number of LSM tree
# levels:", "Pending compaction bytes:", "Block cache usage:") and added two numbers read from
# the server's data directory with sudo (`du /var/lib/mysql/#rocksdb/*.sst`). Both halves are
# replaced here:
#   * those phrases only exist in newer MyRocks builds, so on this server every grep produced
#     an empty CSV field — the values now come from information_schema (ROCKSDB_SST_PROPS,
#     ROCKSDB_CFSTATS, ROCKSDB_DBSTATS) and SHOW GLOBAL STATUS 'Rocksdb%';
#   * the .sst/.log sizes need root on the database host, which a benchmark run must not
#     assume; total_sst_size from SST_PROPS covers the same question without it.
# `lsm_levels` is kept as a column and reports 0: MariaDB 10.3 exposes no per-level view (newer
# versions add LEVEL/SIZE to ROCKSDB_SST_PROPS). Same convention as btree_height on InnoDB.
#
# Two deliberate schema differences from mariadb_innodb, both forced by the engine:
#   * the table is `DEFAULT COLLATE=latin1_bin` (as in the legacy script) because MyRocks'
#     maximum index key is 767 bytes and a utf8mb4 VARCHAR(255) primary key needs 1020. YCSB's
#     keys and values are ASCII, so stored bytes — what LENGTHB measures — are unchanged;
#   * ENGINE=RocksDB instead of InnoDB. Everything else is byte-for-byte the same DDL, because
#     the point of the comparison is that only the storage engine differs.

# shellcheck source=_mariadb_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_mariadb_common.sh"

backend::info() {
    cat <<INFO
display_name=MariaDB (RocksDB)
default_type=rocksdb
default_workload=workloada-extend
default_binding=jdbc
default_db=ycsb
min_server_version=10.3
has_dump_restore=1
supports_idle_wait=0
requires_index_wait=0
supports_vacuum=0
supports_query_plan=1
host_os_user=mysql
INFO
}

# The statistics columns of this backend: the five LSM-tree facts the legacy runner wanted
# (now from information_schema), then the Rocksdb_* counters that describe what an LSM tree is
# doing while a phase runs — rows, memtables, block cache, where reads hit (L0/L1/L2+), bytes
# written through WAL/flush/compaction, and write stalls. Values are bytes or counts; the CSV
# column name is the name below.
metric_field_names=(
    sst_files total_sst_size lsm_levels pending_compactions lsm_memory_usage
    rows_inserted rows_updated rows_deleted rows_read queries_point queries_range
    memtable_total memtable_unflushed cur_size_all_mem_tables num_immutable_mem_table
    block_cache_hit block_cache_miss memtable_hit memtable_miss
    get_hit_l0 get_hit_l1 get_hit_l2_and_up
    bytes_read bytes_written wal_bytes flush_write_bytes compact_read_bytes compact_write_bytes
    stall_total_stops stall_total_slowdowns stall_micros
    row_lock_deadlocks no_file_errors background_errors num_snapshots
)

backend::metric_names() {
    printf '%s\n' "${metric_field_names[@]}"
}

# The ten value columns must survive the extend phase; LONGTEXT as on InnoDB, see the header.
backend::create_table_sql() {
    cat <<'SQL'
CREATE TABLE usertable (
    ycsb_key VARCHAR(255) NOT NULL PRIMARY KEY,
    field0 LONGTEXT, field1 LONGTEXT, field2 LONGTEXT, field3 LONGTEXT, field4 LONGTEXT,
    field5 LONGTEXT, field6 LONGTEXT, field7 LONGTEXT, field8 LONGTEXT, field9 LONGTEXT
) ENGINE=RocksDB DEFAULT COLLATE=latin1_bin;
SQL
}

# Byte length of the ten columns — identical to mariadb_innodb, so a size difference between
# the two backends is a storage-engine effect and not a measurement difference.
backend::size_expression() {
    cat <<'SQL'
coalesce(lengthb(field0), 0) + coalesce(lengthb(field1), 0) + coalesce(lengthb(field2), 0) + coalesce(lengthb(field3), 0) + coalesce(lengthb(field4), 0) + coalesce(lengthb(field5), 0) + coalesce(lengthb(field6), 0) + coalesce(lengthb(field7), 0) + coalesce(lengthb(field8), 0) + coalesce(lengthb(field9), 0)
SQL
}

# ---------------------------------------------------------------------------
# Statistics snapshot (RocksDB edition of the InnoDB one in _mariadb_common.sh)
#
# Three server-wide queries, no table required, so preflight can probe with scope=global:
#   1. SHOW GLOBAL STATUS LIKE 'Rocksdb%'      -> counters named Rocksdb_<metric>
#   2. ROCKSDB_CFSTATS + ROCKSDB_DBSTATS       -> STAT_TYPE/VALUE pairs (compaction, memtables,
#                                                 block cache usage, background errors)
#   3. ROCKSDB_SST_PROPS                       -> one row per SST file, aggregated here
# Missing values report 0, exactly as for the InnoDB status variables.
# ---------------------------------------------------------------------------

backend::collect_metrics() {
    local db="${1:-$DB_NAME}" scope="${2:-all}"
    local name value sst_line sst_count sst_bytes
    local -A status=()

    log "START statistics snapshot database=$db scope=$scope"
    local snapshot pairs
    if ! snapshot=$(backend::exec -At -c "SHOW GLOBAL STATUS LIKE 'Rocksdb%';"); then
        echo "[ERROR] RocksDB status query failed for $db." >&2
        return 1
    fi
    while IFS=$'\t' read -r name value; do
        [[ "$name" == Rocksdb_* ]] && status["${name#Rocksdb_}"]="$value"
    done <<< "$snapshot"

    # One column family ('default') holds the benchmark table; the DB rows are server-wide.
    if ! pairs=$(backend::exec -At -c "
        SELECT STAT_TYPE, VALUE FROM information_schema.ROCKSDB_CFSTATS WHERE CF_NAME = 'default'
        UNION ALL
        SELECT STAT_TYPE, VALUE FROM information_schema.ROCKSDB_DBSTATS;"); then
        echo "[ERROR] RocksDB column-family statistics query failed for $db." >&2
        return 1
    fi
    while IFS=$'\t' read -r name value; do
        case "$name" in
            COMPACTION_PENDING)          status[pending_compactions]="$value" ;;
            CUR_SIZE_ALL_MEM_TABLES)     status[cur_size_all_mem_tables]="$value" ;;
            NUM_IMMUTABLE_MEM_TABLE)     status[num_immutable_mem_table]="$value" ;;
            DB_BLOCK_CACHE_USAGE)        status[lsm_memory_usage]="$value" ;;
            DB_BACKGROUND_ERRORS)        status[background_errors]="$value" ;;
            DB_NUM_SNAPSHOTS)            status[num_snapshots]="$value" ;;
        esac
    done <<< "$pairs"

    # On-disk footprint of the LSM tree. MariaDB 10.3 reports no per-file size, so the stored
    # (compressed) block sizes are the closest honest number; all column families count, as
    # they did for the legacy `du` over the engine's data directory.
    if ! sst_line=$(backend::exec -At -F',' -c "
        SELECT COUNT(*),
               COALESCE(SUM(DATA_BLOCK_SIZE + INDEX_BLOCK_SIZE + FILTER_BLOCK_SIZE), 0)
        FROM information_schema.ROCKSDB_SST_PROPS;"); then
        echo "[ERROR] RocksDB SST file statistics query failed for $db." >&2
        return 1
    fi
    IFS=',' read -r sst_count sst_bytes <<< "$sst_line"
    status[sst_files]="$sst_count"
    status[total_sst_size]="$sst_bytes"

    local dbmetrics=""
    for name in "${metric_field_names[@]}"; do
        value="${status[$name]:-0}"
        # A CSV field cannot contain a comma.
        value="${value//,/ }"
        [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || value=0
        printf -v "$name" '%s' "$value"
        dbmetrics+="$name=$value "
    done
    log "DB statistics $dbmetrics"

    # The stored-value size needs the benchmark table, so it is only available once a database
    # exists; preflight probes the server with scope=global.
    if [[ "$scope" != global ]]; then
        local table_size
        table_size=$(backend::total_size "$db") || return 1
        log "DB statistics value size: $table_size database=$db"
    fi
    log "END statistics snapshot database=$db statistics=${#metric_field_names[@]}"
}

backend::default_config() {
    mariadb::base_config
}
