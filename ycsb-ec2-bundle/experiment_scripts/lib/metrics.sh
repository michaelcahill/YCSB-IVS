#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# PostgreSQL 18 statistics columns collected for every phase.
#
# binding_field_names is the full CSV column list for a scope=all snapshot and
# the runner's write_result() emits them in this exact order, so adding a metric
# here is what makes it appear in the results CSV.
global_metric_names=(
    blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated
    tup_deleted deadlocks temp_files temp_bytes checkpoints_timed checkpoints_req
    checkpoints_done buffers_checkpoint buffers_clean buffers_alloc
    checkpoint_write_time checkpoint_sync_time wal_bytes wal_records wal_fpi wal_buffers_full
)

table_metric_names=(
    n_tup_upd n_live_tup n_dead_tup n_ins_since_vacuum vacuum_count autovacuum_count
    total_vacuum_time total_autovacuum_time total_analyze_time total_autoanalyze_time
)

relsize_metric_names=(
    relation_name relation_type raw_rel_size relation_size
)

binding_field_names=("${global_metric_names[@]}")

for prefix in usertable toast; do
    for metric in "${table_metric_names[@]}"; do
        binding_field_names+=("${prefix}_${metric}")
    done
done

binding_field_names+=(toast_n_tup_ins toast_n_tup_del)

binding_field_names+=(
    usertable_heap_blks_read usertable_heap_blks_hit usertable_idx_blks_read usertable_idx_blks_hit
    toast_blks_read toast_blks_hit tidx_blks_read tidx_blks_hit
)

# Sample the PostgreSQL OS account's CPU and memory share; cheap enough to run
# around every phase (watcher.sh does the time-series version).
collect_cpu_memory_metrics() {
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum + 0}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum + 0}')
}

stats_header="CPU,Memory,$(IFS=','; echo "${binding_field_names[*]}")"

