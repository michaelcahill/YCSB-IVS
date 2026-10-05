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
./experiment.sh postgresql_row --init           # prepare the server for its own evidence
DB_PWD='***' ./experiment.sh postgresql_textarray --config conf/experiments/smoke.env
```

Endpoint and role come from the committed `conf/db.postgresql.env` (shared by all four
PostgreSQL backends) or a per-backend `conf/db.<backend>.env`; exported variables always win,
so a machine-specific password is an environment variable, not an edit.

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
client tools; each committed `conf/db.<backend>.env` documents its backend's exact needs,
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

Precedence (later wins): built-in defaults → backend defaults → `conf/db.<family>.env` →
`conf/db.<backend>.env` → `--config FILE` → environment → CLI flags. Config files are
**parsed, not executed** (comments + `KEY=VALUE` only). Details and parsing rules:
`conf/README.md`.

```bash
./experiment.sh postgresql_textarray --scale heavy --config conf/scale.heavy.env \
    --epochs 10 --steps 10 --run-id 3 --var VACUUM_ENABLED=1
```

- `conf/db.<family>.env` and `conf/db.<backend>.env` are loaded automatically when present
  and hold endpoint, role and credentials with working defaults plus commented options (the
  four PostgreSQL backends share `db.postgresql.env`, which also carries the `--init` admin
  connection). Machine-specific values — especially real passwords — go in exported
  environment variables, which beat the file.
- Scale presets are applied explicitly with `--config conf/scale.heavy.env` or
  `--config conf/scale.light.env` (an auto-loaded preset could silently resize a
  dataset). `--scale NAME` only selects the name used in artefact names.
- Anything can be set with `--var KEY=VALUE`; common knobs: `TYPE`, `RUN`,
  `EXTEND_DIST` (zipfian|uniform), `WORKLOAD` (name part, e.g. `readonly-uniform`),
  `VACUUM_ENABLED`, `COMPARISON_INTERVAL` (0 disables the comparison phases in
  mainline), `DB_NAME`/`UNCHANGED_DB_NAME`/`BACKUP_DB_NAME`, `EXPERIMENT_DIR`,
  `OS_STATS_ENABLED` (0 skips the per-second `.osstats`/`.diskstats` files).
- How a run behaves between measurements:

| Knob | Default | Meaning |
| --- | --- | --- |
| `PAUSE_MAINTENANCE` | `1` | Switch the database's background maintenance of the measured table off before the reference/clean-run phases and on again before extend, so no phase is timed while the server cleans up one table and not another. Backends without such a switch ignore it. `VACUUM_ENABLED=1` still runs an explicit `VACUUM ANALYZE`; the two are independent. |
| `IDLE_WAIT_INTERVAL`, `IDLE_WAIT_TIMEOUT` | `30`, `7200` | How often, and for how long at most, a phase waits for the server to go quiet before it is measured. One pair for every wait: an autovacuum on a heavily extended table can run for over an hour, and a wait that gives up early charges that work to the phase. |
| `PAUSE_FILE` | `PAUSE_SCRIPT` | `touch PAUSE_SCRIPT` holds the run at the next iteration boundary (never inside a phase); removing the file continues it. `PAUSE_CHECK_INTERVAL` is how often it looks. |
| `SERVER_LOG_MARKS` | `1` | Write a marker for every phase into the database server's own log, so server-side evidence lines up with the run log without matching timestamps (PostgreSQL family; other backends have no such hook and write nothing). |
| `ARCHIVE_CONFIGURATION` | `1` | At the end of a successful run, write `$EXPERIMENT_DIR/config`: resolved configuration (credentials masked), applied config files, workload template, plus the server's own configuration file and its slice of the server log (PostgreSQL family). |
| `RESUME_FROM_ITERATION` | `0` | Same as `--resume-from`, below. |
- The names the last pre-refactor runners used are accepted as synonyms of the canonical
  ones, so an old invocation line still runs the same experiment: `EPOCHS` → `NUM_EPOCHS`,
  `RUNS_PER_EPOCH` → `STEPS_PER_EPOCH`, `EXTENDOPERATIONCOUNT` → `EXTEND_OPERATIONCOUNT`,
  `DIST` → `EXTEND_DIST`, `WORK` → `WORKLOAD`. The canonical name always wins, and using a
  synonym is reported as `[config] EPOCHS=3 is a synonym for NUM_EPOCHS=3`. The old
  `RESUME_FROM_EPOCH` name means `RESUME_FROM_ITERATION` (it always counted global
  iterations), and its `-1` still means "do not resume".
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
--resume-from N       continue an interrupted run at global iteration N (see "Pause, Resume")
--dry-run             print resolved configuration and exit
--check               run preflight and exit
--init                prepare the server for a backend and exit (see "Server-Side Evidence")
--list-backends       list backends and exit
```

## Server-Side Evidence

A PostgreSQL run archives more than its own numbers: `$EXPERIMENT_DIR/config/` holds the
server's `postgresql.conf`, the settings that were in force, and the slice of the server's own
log between this run's first and last phase marker — which is where the autovacuum report, the
checkpoints and the errors between two phases live.

Whether that archive has anything in it is a property of the **server**, not of the run, so it is
prepared once with:

```bash
./experiment.sh postgresql_row --init
```

The administrator connection ships in `conf/db.postgresql.env`, where the default is the usual
case — most PostgreSQL installs admit the superuser only through the OS account (peer or trust
on the unix socket, often nothing else), so the admin `psql` is wrapped:

```bash
PG_INIT_ADMIN_CLI_WRAP=sudo -u postgres
PG_INIT_ADMIN_USERNAME=postgres
```

A wrapped `psql` reaches the server as that OS user sees it, so `--host`/`--port` are not passed at
all and no password is needed; `PG_INIT_ADMIN_USERNAME` only names the role to become. Point the
wrap elsewhere when the server lives in a container on this machine:
`PG_INIT_ADMIN_CLI_WRAP='podman exec -i ycsb_postgres'`. Without any wrap the admin connection
goes to `$DB_HOST:$DB_PORT`, or to `PG_INIT_ADMIN_HOST` / `PG_INIT_ADMIN_PORT` (set
`PG_INIT_ADMIN_HOST=` empty for a local socket on this host), with `PG_INIT_ADMIN_PWD`. Either way
the run itself still connects as `DB_USERNAME@DB_HOST:DB_PORT`: all of this affects `--init`
alone.

`--init` needs a superuser connection and **fails rather than doing half of it** — the run itself
never does, and neither does anything else in the harness. The benchmark role keeps LOGIN +
CREATEDB only; when it *is* a superuser, `--init` uses it directly and none of the
`PG_INIT_ADMIN_*` settings are consulted.

What it applies, in `$PG_MAINTENANCE_DB` (default `postgres`):

| What | Why the run needs it |
| --- | --- |
| `log_autovacuum_min_duration = 0` | **the setting that decides whether an autovacuum appears in the log at all** — the default `-1`/10 min hides exactly the report a measurement wants explained |
| `logging_collector = on` | without a collector the server writes its log to its own stderr, where no SQL function can reach it. Needs a **restart**, so `--init` reports it and asks to be re-run afterwards |
| `log_checkpoints`, `log_lock_waits`, `autovacuum`, `track_counts` | the other server-side events a phase can be delayed by, and the counters the results CSV reports |
| `log_line_prefix` carrying `%m` | a server-side line that cannot be timestamped cannot be aligned with the run log |
| `GRANT pg_monitor` | `log_directory` is not visible, and `pg_ls_logdir()` not executable, without it |
| `GRANT pg_read_server_files` + `EXECUTE ON FUNCTION pg_read_file(text)` | what `pg_read_file()` checks internally. The function privilege is **per database** and lives in `$PG_MAINTENANCE_DB`, the database the archiver connects to — granting it in a benchmark database does nothing |
| `GRANT SET ON PARAMETER log_min_error_statement, log_error_verbosity` | keeps a phase marker to one line instead of three (`CONTEXT:`/`STATEMENT:` around it) |
| `ALTER ROLE … INHERIT` when needed | `CREATE ROLE` defaults to `NOINHERIT`, and a `NOINHERIT` role gets nothing from any membership: the grants would exist and do nothing |

Everything is read before it is written, so `--init` is idempotent — run it again after a restart,
a configuration-management pass or a `pg_resetwal`, and it reports what (if anything) drifted:

```
[INFO] setting log_autovacuum_min_duration = 0 (was 10min, needs reload)
[INFO] granted pg_read_server_files to ycsb
[INFO] Verified: ycsb can list and read the server log, and reads back its own LOG lines.
[init] postgresql_row prepared for server-side evidence
```

The verification is not a privilege query: `--init` writes a `LOG` line and reads it back through
the same three functions the archiver uses (`log_directory`, `pg_ls_logdir()`, `pg_read_file()`),
as the benchmark role via `SET ROLE`. That is the difference between "the grants look right" and
"this run's evidence will be in the archive".

`--check` then reports the state on every later run, so a server that drifted back is noticed
before a ten-hour run finishes rather than after it:

```
[WARNING] Server-side evidence (autovacuum, checkpoints, errors) will NOT be
          archived: ycsb cannot read the server's own log: it lacks pg_monitor, ...
          Prepare the server with: ./experiment.sh postgresql_row --init
```

It stays a warning: a run measures correctly without the server's own log, it only loses the
explanation of what the server did during it.

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
grep -c 'MAINTENANCE mode=' "$EXP/logs/"*_results.log   # maintenance switched off/on, never left off
grep -c 'ARCHIVE server' "$EXP/logs/"*_results.log      # what the run could archive of the server
ls "$EXP/config/"                       # resolved configuration (+ server state where readable)
git -C .. status --porcelain workloads  # empty: templates were never touched
```

The results CSV keeps the authoritative column schema (base columns + the backend's
statistics columns), so `../analysis_scripts/` parse every backend's output. A row whose
`Return=` is non-zero, or a missing completion marker, means the run is not evidence.

### Reading a run log

Every line is prefixed with where it sits in the experiment:

```text
[2026-10-03 08:40:52 UTC] [epoch=2 run=3 phase=clean-run] START YCSB clean-run
                           │       │      └─ phase being executed
                           │       └─ step *within* that epoch — NOT the --run-id counter,
                           │          which appears once, in "START experiment … run=<N>"
                           └─ epoch (the outer loop)
```

- `epoch=0 run=0` means "before any iteration": `phase=setup`, `load`, `reference-load`.
- `phase=iteration-end` and `phase=complete` are the boundaries between and after iterations,
  not measurements; anything else names a phase from the sequence table above.
- The **results CSV `Epoch` column is the global iteration**
  (`steps_per_epoch * (epoch - 1) + step`), and so is the `<K>` in
  `javagc_run<N>_<phase>_epoch<K>.log` — both inherited from the runners this harness replaced,
  where they were used as an x-axis. That is why `--resume-from N` speaks iterations too.
  `tests/smoke_backend.sh` fails a run whose log lines report an epoch or step outside the
  loop bounds of that run.

PostgreSQL runs carry eight statistics columns more than before master's autovacuum runner
was merged in: `n_tup_ins`, `n_tup_del` and `autoanalyze_count` for both the measured table
and its TOAST table, and `usertable_relpages`/`usertable_size_in_bytes` with
`toast_relpages`/`toast_size_in_bytes`. They are appended in the same relative order, so
older CSVs still parse by name; nothing that existed before was renamed or removed.

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
│   └── javagc/javagc_run<N>_<phase>_epoch<K>.log
├── data/
│   ├── workload_data/<name>.csv         # the results CSV (analysis input)
│   ├── key_sizes_<name>.csv
│   └── value_size_data/value_sizes_*.csv
├── workloads/                           # generated, immutable, provenance-tagged
└── config/                              # what this run was configured with (see below)
    ├── resolved_config.txt              # every knob as the run used it, credentials masked
    ├── input_<file>                     # workload template and applied --config files
    ├── postgresql.conf                  # server configuration   (PostgreSQL family)
    ├── server_settings.txt              # settings actually in force (PostgreSQL family)
    └── server_log_<file>                # the server-log lines between this run's markers
```

`EXPERIMENT_NAME` = `<type>_<scale>_extend-<dist>_<workload>_run<N>` plus a `_baseline`
suffix in baseline mode.

## Pause, Resume And Background Maintenance

**Pause between iterations.** `touch PAUSE_SCRIPT` in the runner's directory (or
`--var PAUSE_FILE=/path/to/file`) stops the experiment once the current iteration ends —
never in the middle of a phase — and logs `PAUSE experiment paused`; remove the file to
continue. The wait is logged with its duration, so a paused run cannot be mistaken for a
slow one.

**Resume after an interruption.** `--resume-from N` continues the *same* experiment
directory instead of starting over:

```bash
# interrupted at iteration 37 of a 10x10 run; the databases still hold their state:
./experiment.sh postgresql_textarray --config conf/scale.heavy.env \
    --type postgresql_textarrays_autovacuum --scale heavy --run-id 3 \
    --epochs 10 --steps 10 --resume-from 37
```

What that changes, and why it is safe:

* the `load` and `reference-load` phases do not run — the databases already contain what
  they loaded, and each is verified instead of recreated (`ERROR resume: database … has no
  table public.usertable to continue from` if it does not);
* iterations below `N` are skipped, everything from `N` runs normally;
* the run log, results CSV, value-size CSVs and histogram are **appended to**, never
  rewritten; each attempt is still identifiable by its own `EXECUTION_ID` line.

Resuming therefore requires the interrupted run's databases. If they were dropped, or if
the point of interruption is unknown, start a new `--run-id` instead — that is what keeps
evidence unambiguous.

**Background maintenance.** Between measurements the runner asks the database to stop and
start its own maintenance of the measured table (`PAUSE_MAINTENANCE`): off before the
reference and clean-run phases, on again before the next extend, and always restored at
the end so a finished run never leaves autovacuum disabled. Every idle wait also reports
what ran during it — `MAINTENANCE idle window … autovacuum_count=3->4 dead_tuples=…` —
which is what explains an unexpectedly slow phase. Backends without a per-table switch
(`supports_maintenance_mode=0`) do nothing here and say nothing.

**Server-side markers.** With `SERVER_LOG_MARKS=1` every phase boundary is also written
into the server's own log (`EXPERIMENT RUN=<run> EXEC=<execution-id> EPOCH=<e>
ITER=<i> PHASE=<phase>`), and the archived slice of that log at
`config/server_log_*` is exactly the window between this run's first and last marker —
checkpoints, autovacuum activity and errors, in the same order as the phases they explain.
That window only holds them if the server was told to write them and the role may read
them, which is what `--init` prepares (see "Server-Side Evidence").

## Stop Or Restart Cleanly

`Ctrl-C` in tmux: the runner's trap stops the watcher process group and finalises the
log. To stop a run without killing it, `touch PAUSE_SCRIPT` and wait for the iteration
boundary. Before reusing anything, confirm no leftovers:

```bash
pgrep -a -f 'experiment.sh|watcher.sh|ycsb|java' || true
mv <EXPERIMENT_DIR>{,_cancelled_$(date -u +%Y%m%dT%H%M%SZ)}   # archive the partial run
```

If the interruption was accidental and the databases were not touched, `--resume-from
<iteration>` continues that run instead of discarding it — see "Pause, Resume And
Background Maintenance". Check the interrupted log for the last `END iteration` line to
know where to resume; resuming from an iteration that already completed duplicates its
rows.

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

**Merging master after step 8c.** `master` still carries
`experiment_postgresql_array-text-autovacuum.sh`, so a merge reports it as modified here and
deleted there. Its changes are ported into the framework rather than brought back as a
script — that script is what this harness exists to replace, and its features apply to every
backend, not only to the text-array schema:

| What master changed there | Where it lives now |
| --- | --- |
| extra statistics columns (inserts/deletes, `autoanalyze_count`, relation sizes) | `lib/backends/_postgresql_common.sh` → all four PostgreSQL backends |
| phase markers in the server log (`experiment_log()`) | `backend::mark_run`, called from `lib/lifecycle.sh` for every phase of every backend |
| autovacuum switched off/on between phases | `backend::maintenance_mode` + `PAUSE_MAINTENANCE` (now also restored at the end of a run) |
| longer idle waits, and reporting what maintenance ran during them | `IDLE_WAIT_INTERVAL`/`IDLE_WAIT_TIMEOUT`, `postgresql::report_maintenance` |
| resuming an interrupted run (`RESUME_FROM_EPOCH`) | `--resume-from` / `RESUME_FROM_ITERATION`, in both engines; the old name is accepted as a synonym |
| archiving configuration and server logs at the end | `experiment::archive_configuration` + `backend::archive_server_state` |
| pausing between iterations (`PAUSE_SCRIPT`) | `pause_if_requested` + `PAUSE_FILE` |
| `javagc_run<N>_<phase>_epoch<K>.log` naming | `run_with_metrics`, unchanged for every backend |

Two of its changes were deliberately **not** ported: the `log()` allow-list (this branch logs
everything — see the comment in `lib/common.sh`) and dropping the second field of its log prefix
for a global iteration number. This harness keeps `epoch`+`step`, which identifies an iteration
exactly (see "Reading a run log"); master's own runner could not say which epoch an iteration
belonged to.
