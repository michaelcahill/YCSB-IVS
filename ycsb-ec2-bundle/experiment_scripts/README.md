# Experiment Scripts Runbook

One runner for every database backend:

```bash
cd /path/to/ycsb-ec2-bundle/experiment_scripts
./experiment.sh <backend> [options]
```

`lib/backends/<backend>.sh` supplies connection/schema behaviour, `lib/lifecycle.sh`
supplies the phase steps every backend shares, and `conf/` supplies parameters. There is
no per-database experiment script any more — the pre-refactor `experiment_*.sh` entrypoints
were deleted with refactor step 8c (recoverable from the `pre-refactor-scripts` tag).

## Quick Start

```bash
./experiment.sh --list-backends                 # what exists here
./experiment.sh postgresql_textarray --check    # is the server reachable / role allowed?
./experiment.sh postgresql_textarray --dry-run  # resolved config, phases, paths — runs nothing
DB_PWD='***' ./experiment.sh postgresql_textarray --config conf/experiments/smoke.env
```

`--check` runs the backend's preflight (server reachable, role may create/drop the probe
databases, build artifacts present) and exits. It is the fastest way to separate "not
installed here" from "broken", and it is what `tests/run_tests.sh` uses to decide what to
smoke.

## Backends

| Backend | Display name | Binding | Notes |
| --- | --- | --- | --- |
| `postgresql_textarray` | PostgreSQL 18 text-array (`TEXT[]`) | `jdbc-array` | the reference backend of this harness |
| `postgresql_json` | PostgreSQL 18 jsonb-array (`JSONB`) | `jdbc-array-json` | the former array_json schema, standard engine |
| `postgresql_row` | PostgreSQL 18 row schema (`TEXT`) | `jdbc` | |
| `postgrenosql` | PostgreSQL 18 JSONB document store | `postgrenosql` | value size includes JSON syntax, deliberately |
| `mariadb_innodb` | MariaDB (InnoDB) | `jdbc` | needs the MariaDB JDBC driver (see conf example) |
| `mariadb_rocksdb` | MariaDB (RocksDB) | `jdbc` | needs a server built with MyRocks; see its conf example |
| `mongodb` | MongoDB | `mongodb` | admin tools may run via `MONGO_CLI_WRAP=podman exec -i <ctn>` |
| `neo4j` | Neo4j (property graph) | `neo4j` | Community = one user database per instance, so three endpoints |
| `couchbase` | Couchbase (document store, SDK 2.x) | `couchbase2` | one bucket + same-named user per database role |

Backend names are exactly the table above — the pre-refactor spellings
(`postgresql_array`, `jsonb`, `innodb`, …) were aliases for the deleted legacy launchers
and no longer resolve. PostgreSQL backends require PostgreSQL ≥ 18
(`pg_stat_checkpointer`).

## Host Requirements

`bash`, `awk`, `sed`, `perl`, a Java runtime for YCSB, plus the admin CLI of each backend
you run: `psql`/`createdb`/`dropdb`/`pg_dump` (PostgreSQL family), `mysql`/`mysqldump`
(MariaDB), `mongosh`/`mongodump`/`mongorestore` (MongoDB), `cypher-shell` (Neo4j), `curl`
(Couchbase REST). `tmux` for long EC2 runs. PostgreSQL backends require the PostgreSQL 18
client tools; each `conf/db.<backend>.env.example` documents its backend's exact needs,
including how to run admin CLIs through a container (`*_CLI_WRAP`).

## Modes and Phases

| Mode | Phase sequence |
| --- | --- |
| `mainline` (default) | `load → reference-load → (extend → run → reference → clean-run → comparison-load → avg-run) × epochs×steps` |
| `--mode baseline` | `load → (extend → run) × epochs×steps` |

Both sequences are built from the same phase-step functions; a baseline run creates only
the main database, skips pg_dump in preflight, and every artefact name gains a
`_baseline` suffix so it can never overwrite the mainline run it is compared with. The
CSV schema is identical between modes.

## Configuration

Precedence (later wins): built-in defaults → backend defaults → `conf/db.<backend>.env`
→ `--config FILE` → environment → CLI flags. Config files are **parsed, not executed**
(comments + `KEY=VALUE` only). Details and parsing rules: `conf/README.md`.

```bash
cp conf/db.postgresql.env.example conf/db.postgresql_textarray.env   # endpoint + credentials, 0600
./experiment.sh postgresql_textarray --scale heavy --config conf/scale.heavy.env \
    --epochs 10 --steps 10 --run-id 3 --var VACUUM_ENABLED=1
```

- `conf/db.<backend>.env` is loaded automatically when present and holds endpoint, role,
  credentials — it is gitignored; start from the `.example`, which documents every
  backend-specific knob (container wrappers, driver jars, bucket users).
- Scale presets are applied explicitly with `--config conf/scale.heavy.env` or
  `--config conf/scale.light.env` (an auto-loaded preset could silently resize a
  dataset). `--scale NAME` only selects the name used in artefact names.
- Anything can be set with `--var KEY=VALUE`; common knobs: `TYPE`, `RUN`,
  `EXTEND_DIST` (zipfian|uniform), `WORKLOAD` (name part, e.g. `readonly-uniform`),
  `VACUUM_ENABLED`, `COMPARISON_INTERVAL` (0 disables the comparison phases in
  mainline), `DB_NAME`/`UNCHANGED_DB_NAME`/`BACKUP_DB_NAME`, `EXPERIMENT_DIR`,
  `OS_STATS_ENABLED` (0 skips the per-second `.osstats`/`.diskstats` files).
- The names the last pre-refactor runners used are accepted as synonyms of the canonical
  ones, so an old invocation line still runs the same experiment: `EPOCHS` → `NUM_EPOCHS`,
  `RUNS_PER_EPOCH` → `STEPS_PER_EPOCH`, `EXTENDOPERATIONCOUNT` → `EXTEND_OPERATIONCOUNT`,
  `DIST` → `EXTEND_DIST`, `WORK` → `WORKLOAD`. The canonical name always wins, and using a
  synonym is reported as `[config] EPOCHS=3 is a synonym for NUM_EPOCHS=3`.
- Workload files are **read-only templates** (`../workloads/`). Every phase gets an
  immutable, provenance-tagged copy under `$EXPERIMENT_DIR/workloads/`; a run never
  writes to `workloads/`.

## Options

```
--config FILE         load KEY=VALUE configuration (repeatable)
--var KEY=VALUE       override one variable
--epochs N            epochs                       --steps N        steps per epoch
--run-id ID           run counter in artefact names
--type NAME           artefact-name prefix         --scale NAME     heavy|light (name only)
--mode NAME           mainline|baseline
--workload FILE       read-only workload template
--experiment-dir DIR  root for logs, data and generated workloads
--dry-run             print resolved configuration and exit
--check               run preflight and exit
--list-backends       list backends and exit
```

## Deploying to EC2

Two paths; both verify the harness after installing it.

**1. Directory deploy (primary): `tools/deploy.sh`.** Packages the tracked
`experiment_scripts/` tree and extracts it over the bundle checkout on the target — an
overlay, so untracked server files (`conf/db.*.env`, `analysis/` outputs, built jars)
survive, and the current directory is first backed up remotely.

```bash
tools/deploy.sh --host ubuntu@<instance-ip> --key /path/to/key.pem \
    --remote-dir /home/ycsb/ycsb-ec2-bundle            # default remote dir
tools/deploy.sh --host ... --dry-run                   # just print the payload
tools/deploy.sh --host ... --include-config            # also ship conf/db.*.env (credentials!)
```

The ssh user must be able to write `--remote-dir`; for a tree owned by another user, log
in as that user (e.g. `--host ycsb@…`) rather than sudo-installing.

**2. Single-file deploy: `tools/bundle.sh`.** Generates `experiment.bundle.sh` — the
whole harness (runner + `lib/` + backend modules) inlined into one executable file, with
generation timestamp and git commit in the header. This preserves the old
scp-one-script workflow:

```bash
tools/bundle.sh                                   # writes experiment.bundle.sh (gitignored)
scp -i /path/to/key.pem experiment.bundle.sh \
    ubuntu@<instance-ip>:/tmp/
ssh -i /path/to/key.pem ubuntu@<instance-ip> '
  d=/home/ycsb/ycsb-ec2-bundle/experiment_scripts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  tar czf "$HOME/ycsb_bundle_backup_$ts.tgz" -C "$d" experiment.sh lib watcher.sh
  install -m 755 /tmp/experiment.bundle.sh "$d/"
  cd "$d" && ./experiment.bundle.sh --list-backends >/dev/null && echo BUNDLE_OK'
```

The bundle must live in `experiment_scripts/` (it finds `../bin`, `conf/`, `workloads/`
and `watcher.sh` relative to itself) and it updates the harness code only — use path 1
when the tree may be out of date. `tests/test_bundle.sh` asserts tree/bundle equivalence,
and `run_tests.sh` runs a full benchmark through the bundle, so the two cannot drift.

After deploying, verify:

```bash
cd /home/ycsb/ycsb-ec2-bundle/experiment_scripts
./experiment.sh --list-backends
./experiment.sh postgresql_textarray --check
```

## Clean EC2 Run

Procedure for an evidence-producing run (heavyweight scale, vacuum enabled, zipfian
extend, uniform pure-read measurement, tmux):

1. Deploy (above) and `--check` the backend.
2. Create a launcher per run so no state is reused — configuration is just environment:

```bash
cat > "$HOME/run_textarray_run3.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
cd /home/ycsb/ycsb-ec2-bundle/experiment_scripts
export PGHOST=localhost
export DB_PWD='<database-password>'
exec ./experiment.sh postgresql_textarray \
  --config conf/scale.heavy.env \
  --type postgresql_textarrays_autovacuum --scale heavy --run-id 3 \
  --epochs 10 --steps 10 \
  --var EXTEND_DIST=zipfian --var WORKLOAD=readonly-uniform \
  --var VACUUM_ENABLED=1
SCRIPT
chmod 700 "$HOME/run_textarray_run3.sh"   # it embeds no secret, but keep it private
bash -n "$HOME/run_textarray_run3.sh"
```

No workload copying or sedding: the runner generates one immutable workload file per
phase from the read-only template, so a launcher cannot inherit a mutated file.

3. Run in tmux and attach:

```bash
tmux new-session -d -s ycsb \
  "bash -lc '$HOME/run_textarray_run3.sh; rc=\$?; echo RUN_EXIT=\$rc; exec bash'"
tmux attach -t ycsb        # sudo -iu ycsb tmux attach -t ycsb when attached as ubuntu
```

Use a fresh `--run-id` for every run; never reuse a directory an interrupted run left.

## Verify A Run

Live: `tmux capture-pane -t ycsb:0.0 -p -S -40`. After (or during) completion, with
`EXP=../analysis/experiments/ycsb_<type>_heavy_extend-<dist>_<workload>_run<N>`:

```bash
tail "$EXP/logs/"*_results.log          # must end with: END experiment status=0
grep -c 'START YCSB' "$EXP/logs/"*_results.log   # phases executed
ls "$EXP/logs/"*.osstats | wc -l        # one per-second I/O sample per measured phase
head -2 "$EXP/data/workload_data/"*.csv # one row per measured phase, standard columns
ls "$EXP/data/value_size_data/"         # value sizes before/after extend (mainline: 2 files)
ls "$EXP/logs/histogram.txt"
ls "$EXP/workloads/"                    # one generated workload per phase
git -C .. status --porcelain workloads  # empty: templates were never touched
```

The results CSV keeps the authoritative column schema (base columns + the backend's
statistics columns), so `../analysis_scripts/` parse every backend's output. A row whose
`Return=` is non-zero, or a missing completion marker, means the run is not evidence.

## Output Layout

Everything goes under one experiment directory
(default `../analysis/experiments/ycsb_<EXPERIMENT_NAME>`; `--experiment-dir` moves it):

```text
<EXPERIMENT_DIR>/
├── logs/
│   ├── ycsb_<name>_results.log          # the run log (phases, markers, YCSB echoes)
│   ├── <type>_output.csv                # intermediate per-phase YCSB CSVs are written here too
│   ├── histogram.txt                    # key-size histogram
│   ├── <name>_query_plan.log            # single-key query plans (PostgreSQL family)
│   ├── <db>_<name>_<phase>.metrics      # per-phase OS metrics
│   ├── <db>_<name>_<phase>.dbstats      # per-phase database statistics (PostgreSQL dialect)
│   ├── <db>_<name>_<phase>.osstats      # per-second rates: disk, CPU iowait, PSI (OS_STATS_ENABLED)
│   ├── <db>_<name>_<phase>.diskstats    # which devices those rates cover
│   ├── restore_logs/                    # dump/restore of the comparison database, per iteration
│   ├── vacuum_logs/                     # raw VACUUM (ANALYZE, VERBOSE) output, per phase
│   └── javagc/                          # YCSB JVM GC logs
├── data/
│   ├── workload_data/<name>.csv         # the results CSV (analysis input)
│   ├── key_sizes_<name>.csv
│   └── value_size_data/value_sizes_*.csv
└── workloads/                           # generated, immutable, provenance-tagged
```

`EXPERIMENT_NAME` = `<type>_<scale>_extend-<dist>_<workload>_run<N>` plus a `_baseline`
suffix in baseline mode.

## Stop Or Restart Cleanly

`Ctrl-C` in tmux: the runner's trap stops the watcher process group and finalises the
log. Before reusing anything, confirm no leftovers:

```bash
pgrep -a -f 'experiment.sh|watcher.sh|ycsb|java' || true
mv <EXPERIMENT_DIR>{,_cancelled_$(date -u +%Y%m%dT%H%M%SZ)}   # archive the partial run
```

## Tests And Preflight

```bash
bash tools/check_scripts.sh                    # bash -n + shellcheck ratchet, no DB
bash tests/test_config_workload.sh             # config layer + workload generation, no DB
bash tests/test_bundle.sh                      # bundle build + tree/bundle equivalence, no DB
python3 -m unittest discover -s tests -t tests # mock runner tests, no DB
DB_PWD=*** REQUIRE_DB=1 bash tests/run_tests.sh   # everything incl. end-to-end smokes
DB_PWD=*** bash tests/smoke_authoritative.sh   # PostgreSQL goldens run
DB_PWD=*** bash tests/smoke_backend.sh mongodb            # structural smoke, any reachable backend
DB_PWD=*** bash tests/smoke_backend.sh postgresql_row baseline
```

`run_tests.sh` runs the authoritative goldens smoke, the baseline-mode smoke, a full run
through the generated bundle, and one structural smoke per backend whose `--check`
passes.

## Historical Scripts (deleted at refactor step 8c)

The pre-refactor world — per-database `experiment_*.sh` runners, the `*_baseline.sh`
family, `experiment_sample.sh`, and the array_json full-visibility stack
(`run_postgresql_array_json_full_visibility.sh`, `experiment_postgresql_array_json.sh`,
`benchmark_observability.py`) — is gone from the tree after an EC2 acceptance run of this
runbook. Its instrumentation (WAL / `pg_stat_statements` / buffer-residency / prewarm
capture) was discarded by design, not ported — the harness deliberately has no code path for
it; the jsonb schema it benchmarked is `./experiment.sh postgresql_json`.

An old run can still be reproduced from the annotated tag `pre-refactor-scripts`
(`git worktree add ../pre-refactor pre-refactor-scripts`); existing full-visibility
evidence keeps that provenance. Do not resurrect or adapt the scripts in this tree.
