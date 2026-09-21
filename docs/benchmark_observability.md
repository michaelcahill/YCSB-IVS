# PostgreSQL Benchmark Observability

The PostgreSQL JSONB experiment entrypoint is:

```bash
cd ycsb-ec2-bundle/experiment_scripts
./experiment_postgresql_array_json.sh
```

Existing environment variables and output paths are preserved. The instrumented
runner additionally creates a self-contained run directory under:

```text
ycsb-ec2-bundle/experiment_scripts/benchruns/<run_id>/
```

## Useful Options

```bash
./experiment_postgresql_array_json.sh \
  --run-id toast_probe_001 \
  --sample-interval-seconds 5 \
  --relation-size-sample-interval-seconds 30
```

Optional controls:

- `--output-dir DIR`: choose the parent directory for `benchruns`.
- `--target-table TABLE`: table to observe; default is `usertable`.
- `--dry-run-preflight`: write manifest/preflight only, then exit.
- `--skip-continuous-sampling`: keep phase snapshots but disable the sampler.
- `--skip-derived-analysis`: skip post-run derived CSV/summary generation.
- `--reset-pg-stats-before-run`: attempt PostgreSQL stats resets and continue if denied.
- `--inspect-wal-ranges`: enable optional `pg_walinspect` phase-range summaries.
- `--disable-os-watchers`: skip `vmstat`/`iostat` background logs.

Passwords are read from the existing environment variables, not written to the
manifest.

## PostgreSQL Version Notes

The harness is version-aware and degrades by server capability:

- PostgreSQL 15: no `pg_stat_io`; checkpoint counters are read from
  `pg_stat_bgwriter`.
- PostgreSQL 16: `pg_stat_io` is collected and derived I/O metrics aggregate the
  `client backend`/`relation` rows; checkpoint counters still come from
  `pg_stat_bgwriter`.
- PostgreSQL 17+: `pg_stat_io` is collected and checkpoint counters prefer
  `pg_stat_checkpointer`, falling back to `pg_stat_bgwriter` if needed.

On PostgreSQL 16, `pg_stat_checkpointer` being unavailable is expected, not a
broken subsystem.

## Output Layout

Each run directory contains:

```text
manifest.json
config_resolved.json
stdout.log
stderr.log
exit_status.txt
heartbeat.log
sql/
  preflight.json
  pg_settings.csv
  postgres_version.txt
  relation_mapping.csv
snapshots/
  phase_<phase_id>_before/
  phase_<phase_id>_after/
  lsn_markers.csv
  phase_metadata.csv
samples/
  pg_stat_database.csv
  pg_stat_user_tables.csv
  pg_statio_user_tables.csv
  pg_stat_user_indexes.csv
  pg_stat_wal.csv
  pg_stat_bgwriter.csv
  pg_stat_checkpointer.csv
  pg_stat_io.csv
  pg_stat_activity_waits.csv
  relation_sizes.csv
  os_process_top.csv
  vmstat.log
  iostat.log
  df_free.log
ycsb/
  per-phase YCSB output copies
derived/
  phase_deltas.csv
  normalized_metrics.csv
  spike_windows.csv
  summary.md
logs/
  existing harness logs and observability warnings
```

## Tiny Smoke Test

Use small existing workload values so the run completes quickly:

```bash
DB_NAME=ycsb_smoke \
UNCHANGE_DB_NAME=ycsb_smoke_unchange \
BACKUP_DB_NAME=ycsb_smoke_backup \
TYPE=postgresql_arrayjson_TOAST_smoke \
DIST=uniform SCALE=smoke WORK=pure RUN=smoke \
EXPERIMENT_EPOCHS=1 \
EXPERIMENT_RUNS_PER_EPOCH=1 \
EXTEND_OPERATIONCOUNT=10 \
COMPARISON_INTERVAL=0 \
./experiment_postgresql_array_json.sh --run-id smoke_observability
```

For a connection-only check:

```bash
DB_NAME=postgres ./experiment_postgresql_array_json.sh \
  --run-id preflight_only \
  --dry-run-preflight
```

## Reading The Derived Metrics

Start with `derived/normalized_metrics.csv`. The most useful columns are:

- `wal_bytes_per_op` and `wal_bytes_per_logical_byte`
- `storage_growth_per_op` and `storage_growth_per_logical_byte`
- `toast_blocks_per_op` and `toast_block_fraction`
- `hot_update_ratio`, `newpage_update_ratio`, and `dead_tuples_per_update`
- `checkpoint_write_time_per_op` and `checkpoint_sync_time_per_op`
- `p99_latency_ms_per_kb`

These are phase-level deltas from cumulative counters. Treat them as evidence
consistent with a mechanism, not causal proof by themselves. When a view is not
available on the PostgreSQL version, the collector logs that in
`sql/preflight.json` and skips or leaves the derived field blank.

`--inspect-wal-ranges` can be useful when checking whether checkpoint/full-page
image behavior aligns with a latency jump, but it is disabled by default because
WAL inspection can scan large ranges.

## Experiment Scale Modes

Evidence-producing runs should use one of the two YCSB-IVS scale modes:

| Mode | `SCALE` | `RECORDCOUNT` | `OPERATIONCOUNT` | `EXTEND_OPERATIONCOUNT` | Initial field length | Default epochs |
|---|---|---:|---:|---:|---:|---:|
| Lightweight | `light` | 1,000 | 100,000 | 10,000 | 100 bytes | 10 x 10 |
| Heavyweight | `heavy` | 10,000 | 100,000 | 100,000 | 100 bytes | 10 x 10 |

Use the full-visibility launcher scale flag:

```bash
./run_postgresql_array_json_full_visibility.sh --scale light
./run_postgresql_array_json_full_visibility.sh --scale heavy
```

`--scale-mode` is accepted as an alias. The flag sets `SCALE` plus matching
record and operation count defaults. Explicit environment values for
`RECORDCOUNT`, `OPERATIONCOUNT`, or `EXTEND_OPERATIONCOUNT` still override the
scale defaults for custom runs.

## Value Variants

The full-visibility harness can run the same workload and observability path
against three PostgreSQL value representations:

| Variant | YCSB binding | PostgreSQL field type | Notes |
|---|---|---|---|
| `jsonb_array` | `jdbc-array-json` | `JSONB` | Default full-view configuration. |
| `text_array` | `jdbc-array` | `TEXT[]` | Uses PostgreSQL array append for `EXTEND`. |
| `text_scalar` | `jdbc` | `TEXT` | Uses scalar string append for `EXTEND`. |

Use `--variant` on the launcher:

```bash
./run_postgresql_array_json_full_visibility.sh --scale heavy --variant jsonb_array
./run_postgresql_array_json_full_visibility.sh --scale heavy --variant text_array
./run_postgresql_array_json_full_visibility.sh --scale heavy --variant text_scalar
```

The default remains `jsonb_array`. Non-default variants receive distinct default
`TYPE` values (`full_visibility_text_array` and
`full_visibility_text_scalar`) unless `TYPE` is set explicitly. The manifest and
`config_resolved.json` record `VALUE_VARIANT`, `YCSB_BINDING`, and
`FIELD_SQL_TYPE`.
