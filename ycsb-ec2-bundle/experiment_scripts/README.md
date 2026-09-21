# Experiment Scripts Runbook

This directory contains the YCSB-IVS experiment entrypoints. The current
PostgreSQL JSONB/TOAST experiment entrypoint is:

```bash
cd /path/to/ycsb-ec2-bundle/experiment_scripts
./experiment_postgresql_array_json.sh
```

The instrumented runner preserves the older CSV/log outputs and also writes a
self-contained observability run directory:

```text
benchruns/<run_id>/
```

## Environment Requirements

The frozen full-visibility profile is intended for Linux hosts running the
bundled YCSB-IVS tree and a local PostgreSQL instance. The EC2 runs have used
Ubuntu with the benchmark checked out under either `/home/ycsb` or
`/home/ubuntu`.

Required command-line tools:

- `bash`, `awk`, `sed`, `perl`, `sort`, `comm`, `find`, `tee`, `date`
- Java runtime for YCSB
- PostgreSQL client tools: `psql`, `createdb`, `dropdb`, `pg_dump`
- Python 3 for `benchmark_observability.py`
- `ps`, `df`, and `free` for OS/process sampling
- `tmux` for long EC2 runs

Optional but useful OS tools:

- `vmstat`
- `iostat`
- `pidstat`
- `journalctl`
- AWS CLI, only if you add optional S3 sync around the run directory

PostgreSQL requirements for evidence-producing full-visibility runs:

- PostgreSQL 16+ is preferred because it includes `pg_stat_io`.
- PostgreSQL 15 can run the harness, but `pg_stat_io` is unavailable and the
  summary will mark it expected-missing.
- PostgreSQL 17+ adds `pg_stat_checkpointer`; earlier versions use
  `pg_stat_bgwriter` checkpoint columns where available.
- The benchmark role must be able to drop/create the benchmark databases.
- The extension role, usually the same as `DB_USERNAME`, must be able to create
  or use `pg_buffercache`, `pg_freespacemap`, `pg_stat_statements`, and
  `pg_walinspect`.
- `pg_stat_statements` must be in `shared_preload_libraries`, which requires a
  PostgreSQL restart.
- `track_io_timing` must be `on`.
- `log_checkpoints` must be `on`.

Quick environment check:

```bash
export PGHOST=localhost
export PGPASSWORD='<database-password>'

psql -U ycsb -d postgres -X <<'SQL'
select version();
show shared_preload_libraries;
show track_io_timing;
show log_checkpoints;
select name, default_version, installed_version
from pg_available_extensions
where name in (
  'pg_buffercache',
  'pg_freespacemap',
  'pg_stat_statements',
  'pg_walinspect',
  'pg_prewarm'
)
order by name;
SQL
```

For production/evidence runs, keep `REQUIRE_FULL_VISIBILITY=1` so the launcher
fails early if any required visibility component is missing. Use
`REQUIRE_FULL_VISIBILITY=0` only for local smoke tests or compatibility checks.

## Frozen Full Visibility Profile

For new evidence-producing runs, prefer the frozen launcher:

```bash
cd /path/to/ycsb-ec2-bundle/experiment_scripts
DB_PWD='<database-password>' \
RUN_ID=full_view_run3 \
RUN=3 \
DB_NAME=full_view \
TYPE=full_view \
./run_postgresql_array_json_full_visibility.sh
```

The launcher keeps the core experiment script unchanged and makes future
experiments parameter-only. It creates a clean workload copy, enables every
non-intervention collector, and runs the harness with:

- continuous PostgreSQL/OS sampling
- relation-size snapshots
- `pg_buffercache` relation and page-identity capture
- `pg_freespacemap` summaries
- checkpoint observations and checkpoint log capture
- `pg_stat_statements` phase reset/snapshot
- WAL LSN markers, `pg_stat_wal`, and `pg_walinspect` phase breakdowns
- derived phase deltas and normalized metrics

`pg_prewarm` is intentionally disabled by default because it changes cache
state. Enable it only for an intervention run:

```bash
SPIKE_TRIGGER_PREWARM_ENABLED=1 \
SPIKE_TRIGGER_PREWARM_MODE=toast_index \
DB_PWD='<database-password>' \
RUN_ID=full_view_prewarm_toast_index_run1 \
./run_postgresql_array_json_full_visibility.sh
```

Full visibility mode requires the database to be ready before the benchmark
starts. The launcher defaults to `REQUIRE_FULL_VISIBILITY=1`, so it fails early
instead of silently producing partial visibility. Required PostgreSQL settings:

```sql
SHOW shared_preload_libraries;
-- Preserve any existing entries and append pg_stat_statements if it is absent.
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET track_io_timing = on;
ALTER SYSTEM SET log_checkpoints = on;
```

Restart PostgreSQL after changing `shared_preload_libraries`; reload is enough
for the other two settings. The benchmark role must be able to create or use:

- `pg_buffercache`
- `pg_freespacemap`
- `pg_stat_statements`
- `pg_walinspect`

Common parameter overrides:

```bash
DB_PWD='<database-password>' \
RUN_ID=full_view_run4 \
RUN=4 \
./run_postgresql_array_json_full_visibility.sh --scale heavy
```

For the standard full-view read-after-extend workload:

```bash
DB_PWD='<database-password>' \
RUN_ID=full_view_run4 \
RUN=4 \
EXPERIMENT_EPOCHS=10 \
EXPERIMENT_RUNS_PER_EPOCH=10 \
EXTEND_REQUESTDISTRIBUTION=zipfian \
RUN_REQUESTDISTRIBUTION=uniform \
RUN_READPROPORTION=1 \
RUN_UPDATEPROPORTION=0 \
VACUUM_ENABLED=1 \
./run_postgresql_array_json_full_visibility.sh --scale heavy
```

Useful escape hatches:

```bash
REQUIRE_FULL_VISIBILITY=0 ./run_postgresql_array_json_full_visibility.sh
SAMPLE_INTERVAL_SECONDS=2 ./run_postgresql_array_json_full_visibility.sh
RELATION_SIZE_SAMPLE_INTERVAL_SECONDS=10 ./run_postgresql_array_json_full_visibility.sh
```

## Scale Modes

Use only these two scale modes for evidence-producing experiments. They match
the YCSB-IVS paper's lightweight/heavyweight design and keep comparisons
interpretable across runs.

| Mode | `SCALE` | `RECORDCOUNT` | `OPERATIONCOUNT` | `EXTEND_OPERATIONCOUNT` | Initial field length | Default epochs |
|---|---|---:|---:|---:|---:|---:|
| Lightweight | `light` | 1,000 | 100,000 | 10,000 | 100 bytes | 10 x 10 |
| Heavyweight | `heavy` | 10,000 | 100,000 | 100,000 | 100 bytes | 10 x 10 |

Both modes start with 10 fields of 100 bytes each, so the logical initial
record size is about 1 KB. Each `EXTEND` operation appends 100 bytes to one
field. With 100 total extend/run iterations, the lightweight mode grows from
about 1 MB to about 100 MB logical data, while heavyweight grows from about
10 MB to about 1 GB.

Use the launcher flag instead of setting the count variables by hand:

```bash
./run_postgresql_array_json_full_visibility.sh --scale light
./run_postgresql_array_json_full_visibility.sh --scale heavy
```

`--scale-mode` is accepted as an alias for `--scale`. The flag sets `SCALE`
plus the matching count defaults. Explicit environment values for
`RECORDCOUNT`, `OPERATIONCOUNT`, or `EXTEND_OPERATIONCOUNT` still override the
scale defaults when a custom run is needed.

## Value Variants

The full-visibility launcher now supports the same experiment shape for the
three value representations we compare:

| Variant | YCSB binding | PostgreSQL field type | Default `TYPE` |
|---|---|---|---|
| `jsonb_array` | `jdbc-array-json` | `JSONB` | `full_visibility` |
| `text_array` | `jdbc-array` | `TEXT[]` | `full_visibility_text_array` |
| `text_scalar` | `jdbc` | `TEXT` | `full_visibility_text_scalar` |

`jsonb_array` is the default, so existing commands keep their behavior. Use
`--variant` or `VALUE_VARIANT` to run the TEXT visibility controls:

```bash
DB_PWD='<database-password>' \
RUN_ID=text_array_heavy_run1 \
RUN=1 \
DB_NAME=text_array_full_view \
./run_postgresql_array_json_full_visibility.sh --scale heavy --variant text_array

DB_PWD='<database-password>' \
RUN_ID=text_scalar_heavy_run1 \
RUN=1 \
DB_NAME=text_scalar_full_view \
./run_postgresql_array_json_full_visibility.sh --scale heavy --variant text_scalar
```

The run manifest records `value_variant`, `ycsb_binding`, and `field_sql_type`.
The key-size histogram and value-size CSVs use variant-specific SQL so `JSONB`,
`TEXT[]`, and `TEXT` all report logical value bytes on the same scale.

Lightweight full-visibility run:

```bash
DB_PWD='<database-password>' \
RUN_ID=full_view_light_run1 \
RUN=1 \
DB_NAME=full_view \
TYPE=full_view \
EXPERIMENT_EPOCHS=10 \
EXPERIMENT_RUNS_PER_EPOCH=10 \
./run_postgresql_array_json_full_visibility.sh --scale light
```

Heavyweight full-visibility run:

```bash
DB_PWD='<database-password>' \
RUN_ID=full_view_heavy_run1 \
RUN=1 \
DB_NAME=full_view \
TYPE=full_view \
EXPERIMENT_EPOCHS=10 \
EXPERIMENT_RUNS_PER_EPOCH=10 \
./run_postgresql_array_json_full_visibility.sh --scale heavy
```

## Clean EC2 Full View Run

This is the procedure used for the `full_view` EC2 runs:

- 10,000 starting records
- 100,000 operations per phase
- 10 epochs x 10 run phases
- vacuum enabled
- zipfian extend, uniform read
- pure read workload after extend
- tmux session named `ycsb`

This is the heavyweight scale mode. For lightweight, use 1,000 starting records
and 10,000 extend operations per phase, while keeping 100,000 run operations
per phase.

Use a fresh run id for each run, for example `full_view_run1`,
`full_view_run2`, and so on. The run counter is the `RUN` environment variable.

### Choose The OS User

Most instances use the benchmark OS user:

```bash
ssh -i /path/to/nhan-key.pem ubuntu@<instance-ip>
sudo -iu ycsb
cd /home/ycsb/ycsb-ec2-bundle/experiment_scripts
```

Some instances use the default `ubuntu` OS user:

```bash
ssh -i /path/to/nhan-key.pem ubuntu@<instance-ip>
cd /home/ubuntu/ycsb-ec2-bundle/experiment_scripts
```

Even when the OS user is `ubuntu`, the PostgreSQL role is usually still `ycsb`.
Set `PGHOST=localhost` in that case so `psql`, `createdb`, and `dropdb` use
password auth instead of local socket assumptions.

### Deploy The Current Harness

From the local repository, copy the current harness files to the EC2 bundle.

For `/home/ycsb` bundles:

```bash
scp -i /path/to/nhan-key.pem \
  ycsb-ec2-bundle/experiment_scripts/experiment_postgresql_array_json.sh \
  ycsb-ec2-bundle/experiment_scripts/benchmark_observability.py \
  ubuntu@<instance-ip>:/tmp/

ssh -i /path/to/nhan-key.pem ubuntu@<instance-ip> '
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  sudo -n -u ycsb mkdir -p /home/ycsb/ycsb_harness_backup_${ts}
  sudo -n -u ycsb cp /home/ycsb/ycsb-ec2-bundle/experiment_scripts/experiment_postgresql_array_json.sh /home/ycsb/ycsb_harness_backup_${ts}/
  sudo -n -u ycsb cp /home/ycsb/ycsb-ec2-bundle/experiment_scripts/benchmark_observability.py /home/ycsb/ycsb_harness_backup_${ts}/ 2>/dev/null || true
  sudo install -o ycsb -g ycsb -m 755 /tmp/experiment_postgresql_array_json.sh /home/ycsb/ycsb-ec2-bundle/experiment_scripts/
  sudo install -o ycsb -g ycsb -m 755 /tmp/benchmark_observability.py /home/ycsb/ycsb-ec2-bundle/experiment_scripts/
'
```

For `/home/ubuntu` bundles, install as `ubuntu` instead:

```bash
scp -i /path/to/nhan-key.pem \
  ycsb-ec2-bundle/experiment_scripts/experiment_postgresql_array_json.sh \
  ycsb-ec2-bundle/experiment_scripts/benchmark_observability.py \
  ubuntu@<instance-ip>:/tmp/

ssh -i /path/to/nhan-key.pem ubuntu@<instance-ip> '
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p /home/ubuntu/ycsb_harness_backup_${ts}
  cp /home/ubuntu/ycsb-ec2-bundle/experiment_scripts/experiment_postgresql_array_json.sh /home/ubuntu/ycsb_harness_backup_${ts}/
  cp /home/ubuntu/ycsb-ec2-bundle/experiment_scripts/benchmark_observability.py /home/ubuntu/ycsb_harness_backup_${ts}/ 2>/dev/null || true
  install -m 755 /tmp/experiment_postgresql_array_json.sh /home/ubuntu/ycsb-ec2-bundle/experiment_scripts/
  install -m 755 /tmp/benchmark_observability.py /home/ubuntu/ycsb-ec2-bundle/experiment_scripts/
'
```

After deploying:

```bash
cd /path/to/ycsb-ec2-bundle/experiment_scripts
python3 -m py_compile benchmark_observability.py
bash -n experiment_postgresql_array_json.sh
```

### Create A Clean Launcher

Create one launcher per run. This avoids reusing a workload file that may have
been mutated by an earlier failed attempt.

Set these variables before writing the launcher:

```bash
RUN_NO=2
HOME_DIR=/home/ycsb        # or /home/ubuntu
DB_PASSWORD='<database-password>'
```

Launcher template:

```bash
cat > "${HOME_DIR}/run_full_view_run${RUN_NO}.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

cd ${HOME_DIR}/ycsb-ec2-bundle/experiment_scripts

WORKLOAD_TEMPLATE=${HOME_DIR}/ycsb-ec2-bundle/workloads/workloada-extend
WORKLOAD_CLEAN=${HOME_DIR}/full_view_run${RUN_NO}_workloada-extend

cp "\$WORKLOAD_TEMPLATE" "\$WORKLOAD_CLEAN"
sed -i \\
  -e '/^fieldlengthdistribution=/d' \\
  -e '/^fieldlengthhistogram=/d' \\
  -e 's/^recordcount=.*/recordcount=10000/' \\
  -e 's/^operationcount=.*/operationcount=100000/' \\
  -e 's/^requestdistribution=.*/requestdistribution=uniform/' \\
  -e 's/^readrequestdistribution=.*/readrequestdistribution=uniform/' \\
  -e 's/^updaterequestdistribution=.*/updaterequestdistribution=uniform/' \\
  -e 's/^readproportion=.*/readproportion=1/' \\
  -e 's/^updateproportion=.*/updateproportion=0/' \\
  -e 's/^extendproportion=.*/extendproportion=0/' \\
  "\$WORKLOAD_CLEAN"

for kv in \\
  'recordcount=10000' \\
  'operationcount=100000' \\
  'requestdistribution=uniform' \\
  'readrequestdistribution=uniform' \\
  'updaterequestdistribution=uniform' \\
  'readproportion=1' \\
  'updateproportion=0' \\
  'extendproportion=0'
do
  key=\${kv%%=*}
  if grep -q "^\${key}=" "\$WORKLOAD_CLEAN"; then
    sed -i "s/^\${key}=.*/\${kv}/" "\$WORKLOAD_CLEAN"
  else
    printf '%s\n' "\$kv" >> "\$WORKLOAD_CLEAN"
  fi
done

export PGHOST=localhost
export DB_NAME=full_view
export UNCHANGE_DB_NAME=full_view_unchange
export BACKUP_DB_NAME=full_view_backup
export DB_USERNAME=ycsb
export DB_PWD=${DB_PASSWORD}
export PG_EXTENSION_USERNAME=ycsb
export PG_EXTENSION_PWD=${DB_PASSWORD}
export TYPE=full_view
export DIST=zipfian
export SCALE=heavy
export WORK=pure
export RUN=${RUN_NO}
export WORKLOAD_FILE="\$WORKLOAD_CLEAN"
export EXPERIMENT_EPOCHS=10
export EXPERIMENT_RUNS_PER_EPOCH=10
export EXTEND_OPERATIONCOUNT=100000
export VACUUM_ENABLED=1
export COMPARISON_INTERVAL=0
export BENCHRUN_OUTPUT_DIR=${HOME_DIR}/ycsb-ec2-bundle/experiment_scripts/benchruns
export SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED=1
export SPIKE_TRIGGER_TRACE_ENABLED=1
# Optional cache intervention; leave disabled for baseline/full_view runs.
# export SPIKE_TRIGGER_PREWARM_ENABLED=1
# export SPIKE_TRIGGER_PREWARM_MODE=toast_index

exec ./experiment_postgresql_array_json.sh \\
  --run-id full_view_run${RUN_NO} \\
  --sample-interval-seconds 5 \\
  --relation-size-sample-interval-seconds 30
SCRIPT

chmod 755 "${HOME_DIR}/run_full_view_run${RUN_NO}.sh"
bash -n "${HOME_DIR}/run_full_view_run${RUN_NO}.sh"
```

If you are already inside `sudo -iu ycsb`, use `/home/ycsb` paths and do not
prefix the launch commands with `sudo`. If you are connected as `ubuntu` but
need to run the benchmark as OS user `ycsb`, create the launcher as root or with
`sudo tee`, then `chown ycsb:ycsb` it.

### Start In tmux

For OS user `ycsb` while connected as `ubuntu`:

```bash
sudo -n -u ycsb tmux new-session -d -s ycsb \
  "bash -lc '/home/ycsb/run_full_view_run${RUN_NO}.sh; rc=\$?; echo; echo RUN_EXIT=\$rc; exec bash'"
```

For OS user `ubuntu`:

```bash
tmux new-session -d -s ycsb \
  "bash -lc '/home/ubuntu/run_full_view_run${RUN_NO}.sh; rc=\$?; echo; echo RUN_EXIT=\$rc; exec bash'"
```

Attach:

```bash
tmux attach -t ycsb
```

If the process is running as OS user `ycsb` and you are connected as `ubuntu`:

```bash
sudo -iu ycsb tmux attach -t ycsb
```

## Verify A Run

Check that tmux is printing YCSB output, not sitting blank:

```bash
tmux capture-pane -t ycsb:0.0 -p -S -80 | tail -80
```

For an OS-user `ycsb` run:

```bash
sudo -n -u ycsb tmux capture-pane -t ycsb:0.0 -p -S -80 | tail -80
```

Check the workload was regenerated cleanly:

```bash
grep -E '^(recordcount|operationcount|requestdistribution|readrequestdistribution|updaterequestdistribution|readproportion|updateproportion|extendproportion|fieldlengthdistribution|fieldlengthhistogram)=' \
  "${HOME_DIR}/full_view_run${RUN_NO}_workloada-extend"
```

Expected values:

```text
recordcount=10000
operationcount=100000
readproportion=1
updateproportion=0
extendproportion=0
requestdistribution=uniform
readrequestdistribution=uniform
updaterequestdistribution=uniform
```

There should be no `fieldlengthdistribution` or `fieldlengthhistogram` line in
the workload file.

Check the run directory:

```bash
RUN_DIR="${HOME_DIR}/ycsb-ec2-bundle/experiment_scripts/benchruns/full_view_run${RUN_NO}"
find "$RUN_DIR" -maxdepth 2 -type f | sort | head -80
tail -3 "$RUN_DIR/heartbeat.log"
wc -l "$RUN_DIR"/samples/pg_stat_io.csv \
      "$RUN_DIR"/samples/pg_stat_database.csv \
      "$RUN_DIR"/samples/relation_sizes.csv \
      "$RUN_DIR"/samples/os_process_top.csv
tail -20 "$RUN_DIR"/logs/sampler_errors.log
tail -20 "$RUN_DIR"/logs/observability_errors.log
```

Useful live watch:

```bash
watch -n 5 "tail -40 ${RUN_DIR}/stdout.log"
```

## Extension And Permission Checks

The benchmark resets `full_view` and `full_view_unchange` by dropping and
recreating the databases. The script then recreates optional extensions and
grants access before creating `usertable`.

Use this check after initialization:

```bash
export PGPASSWORD='<database-password>'
export PGHOST=localhost

for db in full_view full_view_unchange; do
  echo "== $db =="
  psql -U ycsb -d "$db" -X --no-align --tuples-only <<'SQL'
select 'extensions', string_agg(extname, ',' order by extname)
from pg_extension
where extname <> 'plpgsql'
union all
select 'buffercache_select',
       has_table_privilege(current_user, 'public.pg_buffercache', 'select')::text
union all
select 'pgss_select',
       has_table_privilege(current_user, 'public.pg_stat_statements', 'select')::text
union all
select 'freespace_execute',
       exists(
         select 1
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'pg_freespace'
           and has_function_privilege(current_user, p.oid, 'execute')
       )::text
union all
select 'prewarm_execute',
       exists(
         select 1
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'pg_prewarm'
           and has_function_privilege(current_user, p.oid, 'execute')
       )::text;
SQL
done
```

Expected core extensions:

- `pg_buffercache`
- `pg_freespacemap`
- `pg_stat_statements`
- `pg_prewarm` when the prewarm intervention is enabled

`pg_stat_statements` can be installed and granted but still not queryable unless
PostgreSQL was started with it in `shared_preload_libraries`. That warning is
expected on hosts where we did not restart PostgreSQL. It does not invalidate
the main TOAST/cache/WAL/latency run.

`pg_walinspect` is optional. It is only needed for deeper WAL-record breakdowns
and is enabled by passing `--inspect-wal-ranges` or setting
`SPIKE_TRIGGER_WALINSPECT_ENABLED=1`.

## pg_prewarm Intervention

`pg_prewarm` support is opt-in because it intentionally changes the cache state
before the measured run phase. Use a separate run id when enabling it:

```bash
export SPIKE_TRIGGER_PREWARM_ENABLED=1
export SPIKE_TRIGGER_PREWARM_MODE=toast_index
./experiment_postgresql_array_json.sh --run-id full_view_prewarm_toast_index
```

You can also use CLI flags:

```bash
./experiment_postgresql_array_json.sh \
  --run-id full_view_prewarm_toast_index \
  --pg-prewarm \
  --pg-prewarm-mode toast_index
```

Supported modes are `heap`, `toast_index`, `toast_heap`, `toast`,
`heap_toast_index`, `heap_toast`, and `all`. The default mode is
`toast_index`, which warms only the TOAST index and is the lowest-overhead first
intervention to test whether TOAST index rewarming explains read-latency
spikes.

When enabled, the harness runs prewarm after extend/vacuum settling and before
the measured `run` phase for each epoch. It records relation-level buffer
snapshots before and after prewarm, writes a `prewarm` phase into the benchrun
snapshots, and appends relation-level results to:

```text
logs/toast_spike_trigger/<run_name>_pg_prewarm.csv
```

The script recreates `pg_prewarm` after database reset when the extension role
can create it. If the extension is unavailable or permissions are insufficient,
the prewarm phase is marked as skipped and the benchmark continues.

## Output Layout

The run directory contains:

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
  phase_metadata.csv
  lsn_markers.csv
  phase_<phase_id>_before/
  phase_<phase_id>_after/
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
derived/
logs/
  toast_spike_trigger/
    <run_name>_pg_prewarm.csv
```

On PostgreSQL 16, `pg_stat_io` should be present. `pg_stat_checkpointer` is
PostgreSQL 17+, so its absence on PostgreSQL 16 is expected; checkpoint deltas
fall back to `pg_stat_bgwriter` where possible.

## Stop Or Restart Cleanly

Stop the run from tmux with `Ctrl-C`. The harness trap should stop samplers and
write `exit_status.txt`.

Then archive the partial run before reusing the same run id:

```bash
RUN_DIR="${HOME_DIR}/ycsb-ec2-bundle/experiment_scripts/benchruns/full_view_run${RUN_NO}"
mv "$RUN_DIR" "${RUN_DIR}_cancelled_$(date -u +%Y%m%dT%H%M%SZ)"
```

Before restarting, confirm no sampler or Java processes are left:

```bash
pgrep -a -f 'experiment_postgresql_array_json|benchmark_observability|vmstat|iostat|java|tmux' || true
```

For OS-user `ycsb` runs:

```bash
sudo -n -u ycsb pgrep -a -f 'experiment_postgresql_array_json|benchmark_observability|vmstat|iostat|java|tmux' || true
```

## Smoke And Preflight

Connection-only preflight:

```bash
DB_NAME=postgres \
DB_USERNAME=ycsb \
DB_PWD='<database-password>' \
PGHOST=localhost \
./experiment_postgresql_array_json.sh \
  --run-id preflight_only \
  --dry-run-preflight
```

Tiny smoke run:

```bash
DB_NAME=ycsb_smoke \
UNCHANGE_DB_NAME=ycsb_smoke_unchange \
BACKUP_DB_NAME=ycsb_smoke_backup \
DB_USERNAME=ycsb \
DB_PWD='<database-password>' \
PGHOST=localhost \
TYPE=postgresql_arrayjson_TOAST_smoke \
DIST=uniform \
SCALE=smoke \
WORK=pure \
RUN=smoke \
EXPERIMENT_EPOCHS=1 \
EXPERIMENT_RUNS_PER_EPOCH=1 \
EXTEND_OPERATIONCOUNT=10 \
COMPARISON_INTERVAL=0 \
./experiment_postgresql_array_json.sh \
  --run-id smoke_observability \
  --sample-interval-seconds 2 \
  --relation-size-sample-interval-seconds 5
```
