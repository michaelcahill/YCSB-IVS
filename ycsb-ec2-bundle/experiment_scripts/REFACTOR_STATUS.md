# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **steps 1–4 complete; step 5 in progress (all PostgreSQL backends and**
**mariadb_innodb done, verified end-to-end)** — one runner (`experiment.sh <backend>`), four
verified backends behind shared modules, an engine that calls nothing but `backend::*`, a
layered config layer with a legacy-launcher alias shim, and **workload files are read-only
templates** (one generated file per phase in the experiment directory). Goldens unchanged apart
from the intended `-P` paths.

Read this file first after an interruption. Append to the **Log** at every meaningful
checkpoint, and keep the **Step status** table current.

---

## Environment (verified on this machine, 2026-09-23)

| Item | Status | Notes |
| --- | --- | --- |
| PostgreSQL server | ✅ live | `127.0.0.1:5432`, `server_version_num=180006` (PG 18), data dir `/var/lib/pgsql/data` |
| Benchmark role | ✅ superuser + login | user `ycsb`, password **`USyd2025`** (from `jdbc-binding/conf/postgres.properties`) — *not* the `usyd2026` hardcoded in the scripts; override with `DB_PWD=USyd2025` |
| Benchmark databases | ✅ exist | `ycsb`, `ycsb_backup`, `ycsb_unchange` (leftovers from earlier runs) |
| psql/createdb/dropdb/pg_dump | ✅ PG 18.6 client | satisfies the scripts' PG18 preflight |
| `jdbc-array` binding jar | ⚠️ not built | `jdbc-array/target/` absent; build: `mvn -o -Psource-run -pl site.ycsb:jdbc-array-binding -am package -DskipTests` (log `/tmp/mvn-jdbc-array.log`) |
| Other module jars | ✅ present | `core/target/core-0.18.0-SNAPSHOT.jar`, `jdbc/`, `jdbc-array-json/`, `postgrenosql/` |
| shellcheck | ✅ installed (2026-09-24) | `tools/check_scripts.sh` now runs it: the harness (`lib/`, `experiment.sh`, `tests/`, `tools/`) must be clean, 16 legacy scripts warn without failing (list only shrinks; `SHELLCHECK_STRICT=1` fails on everything). SC2034/SC2154 are excluded globally because these scripts share globals across sourced files |
| sudo | ❌ password required | cannot create PG roles or touch the server config; use the existing `ycsb` role |
| podman | ✅ working, can pull images | found 2026-09-24: `podman run docker.io/library/mariadb:11` starts and answers on a published port (rootless). No docker, no local mariadb/mongo/neo4j/couchbase server binaries — containers are how the remaining backends can be smoke-tested here |
| MariaDB container | ✅ up, backend verified | `ycsb_mariadb` = `docker.io/library/mariadb:11` (server 11.8.9) published on `-p 3307:3306`, role `ycsb` with global CREATE/DROP; endpoint + container wrap live in the **untracked** `conf/db.mariadb_innodb.env`, example file added |
| MariaDB JDBC driver | ✅ present | `jdbc/target/dependency/mariadb-java-client-3.4.1.jar`; not part of the YCSB build, so preflight checks for it explicitly (`BACKEND_DRIVER_JAR`) |

Note: the smoke suite needs the `jdbc-array` binding built once:
`mvn -o -pl site.ycsb:jdbc-array-binding -am package -DskipTests` (already done here).

## Verification commands

```bash
cd ycsb-ec2-bundle/experiment_scripts

# everything: static checks + python tests + PostgreSQL smoke run (needs DB_PWD)
DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh

# parts
bash tools/check_scripts.sh                       # bash -n on all shell files, no DB
bash tests/test_config_workload.sh                # config layer + workload generation, no DB
python3 -m unittest discover -s tests -t tests    # mock-based runner tests, no DB
DB_PWD=USyd2025 bash tests/smoke_authoritative.sh # real PG18 end-to-end vs goldens
DB_PWD=USyd2025 bash tests/smoke_backend.sh mariadb_innodb  # structural check, any reachable backend

# is a server reachable for one backend? (what run_tests.sh uses to skip)
./experiment.sh mariadb_innodb --check

The smoke run takes ~40 s and uses its own databases (`ycsb_smoke`,
`ycsb_smoke_unch`, `ycsb_smoke_bak`). Re-capture goldens only deliberately:
`DB_PWD=… bash tests/smoke_authoritative.sh --update`. With `SMOKE_KEEP=1` the
work directory is kept for inspection.

## Step status

| # | Step | Status | Notes |
| --- | --- | --- | --- |
| 0 | Fix §10 bugs; capture smoke goldens; add CI checks | ✅ done | all four §10 bugs fixed and verified against real PG 18 + real YCSB; `tools/check_scripts.sh`, `tests/run_tests.sh`, `tests/smoke_authoritative.sh` + goldens added; stale mock test repaired (7 tests OK) |
| 1 | Port core into `lib/{common,metrics,results,keysizes}.sh` | ✅ done | runner 1253 → 1022 lines; libs = common 119, results 75, keysizes 61, metrics 48. Function + top-level-name inventories verified identical to `HEAD` (nothing lost/duplicated); smoke goldens unchanged |
| 2 | `lib/backends/postgresql_textarray.sh`, `registry.sh`, `experiment.sh` dispatcher | ✅ done | PG backend module (387 ln) with `backend::*` contract + legacy aliases; `lib/registry.sh` discovers and validates backends; `experiment.sh` is the single entry point; authoritative script is now a compatibility shim |
| 3 | `config.sh` + `conf/` presets + alias shim + `--help/--dry-run/--list-backends` | DONE | layered config with `${VAR:-default}` everywhere and `config::derive_paths` last; flags `--var/--config/--epochs/--steps/--run-id/--type/--scale/--workload/--experiment-dir/--dry-run/--list-backends`; legacy alias shim (`DIST`, `WORK`, `UNCHANGE_DB_NAME`, `EXPERIMENT_EPOCHS`, `EXPERIMENT_RUNS_PER_EPOCH`, `DB_PASSWORD`, `FIELD_LENGTH_ORIGINAL`, `vacuum`, `EXTEND_*`/`RUN_*` proportions) with deprecation lines; `conf/scale.{heavy,light}.env`; 31 assertions in `tests/test_config_workload.sh`. `--mode baseline` / `--instrument` still rejected until steps 6 and 8b |
| 4 | Workload generation into `$EXPERIMENT_DIR/workloads/` | DONE | `lib/workload.sh`: one immutable, provenance-tagged file per YCSB invocation; the 22 in-place `perl -i -p` rewrites and the `awk` strip are gone from `lib/lifecycle.sh`; preflight no longer needs a writable workload; smoke asserts `../workloads` stays clean and that all 8 phase files exist |
| 5 | `lifecycle.sh` engine + backend ports (PG row -> postgrenosql -> mariadb x2 -> mongodb -> neo4j -> couchbase) | IN PROGRESS | **done:** engine drives only `backend::*`; PostgreSQL split into `_postgresql_common.sh` + `postgresql_textarray` / **`postgresql_row`** / **`postgrenosql`**, plus **`mariadb_innodb`** on `_mariadb_common.sh` - all four verified end-to-end; `experiment_postgresql.sh`, `experiment_postgresql_array.sh`, `experiment_postgrenosql.sh` and `experiment_mariadb_innodb.sh` are shims. **Remaining:** mongodb, neo4j, couchbase (podman containers available), mariadb_rocksdb (the stock MariaDB image has no RocksDB engine).
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ⬜ pending | |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ⬜ pending | |
| 8a | `postgresql_json` backend | ⬜ pending | |
| 8b | `lib/instrumentation/postgresql_fullview.sh` + `full_view` preset | ⬜ pending | decision: keep as optional instrumentation module |
| 8c | Delete remaining shims/legacy scripts | ⬜ pending | **gate:** only after user confirms on EC2 hardware |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked

## Where to resume

Five backends are on the new architecture and pass an end-to-end run here: the engine calls
nothing but `backend::*`, the PostgreSQL specifics live in `lib/backends/_postgresql_common.sh`
plus one file per schema (`postgresql_textarray`, `postgresql_row`, `postgrenosql`) and the
MariaDB specifics in `lib/backends/_mariadb_common.sh` plus `mariadb_innodb`. Every ported
backend is listed in `BACKEND_SMOKES` in `tests/run_tests.sh`, which asks
`./experiment.sh <backend> --check` first - so an unrelated change does not need every server
in the world to be up, while `REQUIRE_DB=1` still fails when a *required* backend (the
PostgreSQL family) is unreachable.

Next: **mongodb**, then neo4j, couchbase, and mariadb_rocksdb last (no RocksDB storage engine
in the stock MariaDB image - it needs a purpose-built image or stays unverified).

0. **Asking whether a backend is usable here:** `./experiment.sh <backend> --check` runs that
   backend's preflight (server reachable, role allowed to create/drop, build artifacts present)
   and exits without benchmarking. That is how `run_tests.sh` decides to run or skip a smoke,
   and it is the fastest way to separate "not installed here" from "broken".
1. **The runtime watcher is still PostgreSQL inside.** `watcher.sh` reads `pg_stat_activity`
   and `pg_stat_*` through `sudo -u postgres psql`. It now receives `DB_DIALECT` (from
   `runtime_watcher_dialect` in `backend::info`) plus `OS_PROCESS_USER`: for a dialect it does
   not know it samples the server's OS account only and writes **no** `.dbstats` file rather
   than an empty one in PostgreSQL's shape. Porting the sampler itself
   (`lib/watcher_runner.sh`, see the note at step 2 of the plan) is still open, as is the fact
   that it hardcodes `sudo -u postgres` and therefore cannot work against a remote server.
2. Prerequisite for non-PostgreSQL backends is done: the statistics columns are owned by the
   backend (`backend::metric_names`, in `_postgresql_common.sh` / `_mariadb_common.sh`) and
   `lib/metrics.sh` keeps only CPU/memory sampling of `host_os_user`. A hygiene test fails if
   PostgreSQL names reappear in core.
3. Port one at a time: ~~postgrenosql~~ -> ~~mariadb_innodb~~ -> mongodb -> neo4j -> couchbase
   -> mariadb_rocksdb. A ported backend gets its module, its legacy script becomes a one-line
   shim (which also leaves `LEGACY_WITH_WARNINGS` in `tools/check_scripts.sh`), and it joins
   `BACKEND_SMOKES` only once a server answers for it here; otherwise the module stays
   unverified and the legacy script is left alone (no shim, no deletion).
4. Steps 6-8: baseline mode, tooling/README rewrite, `postgresql_json` backend plus fullview
   instrumentation.

Facts that save time when resuming:

- `$WORKLOAD_FILE` is a read-only template. Every phase gets its own file from
  `workload::generate <phase> <iteration>` (`lib/workload.sh`) written to `$WORKLOAD_DIR`
  (= `$EXPERIMENT_DIR/workloads`); the engine keeps the current one in `$WORKLOAD_PHASE`.
  Phase overlays live in `workload::generate`'s `case`; values a run feeds back into later
  phases (today `fieldlengthaverage`) are passed as extra `KEY=VALUE` arguments.
- `write_result` still reads the lowercase globals (`recordcount`, `readproportion`, ...).
  They used to come from `source "$WORKLOAD_FILE"`; `workload::apply_context <file>` now
  publishes exactly those ten names, so keep it in sync with the CSV columns.
- `run_experiment()` in `lib/lifecycle.sh` calls nothing outside the contract. Mandatory hooks
  (`registry::required_functions`): `info`, `default_config`, `preflight`, `init_db`,
  `collect_metrics`, `key_sizes`, `total_size`, `list_keys`, and since this checkpoint also
  `sample_key`, `explain_sql`, `delete_keys`, `truncate`. Optional ones get no-op defaults:
  `vacuum`, `wait_idle`, `dump_restore`, `close`, `parse_args`. Capabilities a backend
  declares in `backend::info` decide what the engine attempts at all
  (`supports_vacuum`, `supports_query_plan`, `has_dump_restore`, `runtime_watcher_dialect`,
  `host_os_user`, `min_server_version[_num]`).
- `backend::total_size`, `key_sizes`, `list_keys` are what the size/verification code calls
  now; a schema module only supplies `backend::size_expression`, which those helpers embed.
- Two engine-side operations were moved into the backend because their SQL is the whole point:
  logging a single-key query plan (`sample_key` + `explain_sql`) and deleting keys after a run
  (`delete_keys`). Both are gated on capabilities so a backend that cannot explain a plan just
  skips that step.
- Run everything with `DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh`.

## Findings during step 5 (who owns the results CSV schema)

1. `lib/metrics.sh` no longer knows anything about databases: it samples CPU/memory for the
   account named by the backend's `host_os_user` and builds the header from
   `backend::metric_names`. The PostgreSQL column list moved to `_postgresql_common.sh`
   (`metric_field_names`, renamed from the legacy `binding_field_names`).
2. Goldens prove it is behaviour-preserving: the 74-column results CSV is byte-identical.
3. Guard added: `tests/test_config_workload.sh` fails if `lib/metrics.sh` or `lib/results.sh`
   mentions `pg_stat`, `blks_read`, `usertable_` or `postgres` (it also caught the leftover
   `postgres_stats*` local names in `write_result`, now `stats_values`/`stats_csv`).

## Findings during step 5 (backends)

1. **Two PostgreSQL backends, one implementation.** `lib/backends/_postgresql_common.sh`
   holds the CLI wrapper, PG18 metrics query, preflight, dump/restore, idle wait and the size
   helpers; a schema module sources it and overrides only `backend::info`, `init_db` (the DDL),
   `size_expression` and `default_config`. The registry skips `_`-prefixed files, so shared
   code is never advertised as a backend.
2. **Required build artifacts follow the configured binding** (`$YCSB_BINDING/target/*.jar`),
   so `jdbc` and `jdbc-array` need no list of their own and the build hint is derived too. The
   minimum server version comes from `backend::info min_server_version_num` instead of a
   hardcoded `^18` regex.
3. **The retargeted mock suite paid for itself:** it caught a regression introduced while
   extracting the common file (pg_dump's version was checked even when `needs_dump=false`) and
   made one silent change from steps 1-2 explicit (preflight runs after the log is created).
4. **Deliberate behaviour, now asserted:** logging starts before preflight so a failed preflight
   is recorded in the run log; the test checks the log exists and names the failure, instead of
   checking that no log was written.
5. `BACKUP_FILE` is `${BACKUP_FILE:-./ycsb_dump.sql}` now - the last connection knob that a
   preset or the environment could not override.
6. **New tests:** `tests/smoke_backend.sh <backend>` (structural end-to-end: eight phases, CSV
   base columns and one row per measured phase, value-size files, histogram, generated
   workloads, clean `../workloads`) runs for `postgresql_row` inside `run_tests.sh`;
   `tests/test_postgresql_array_pg18.py` is replaced by
   `tests/test_postgresql_backend_pg18.py`, which drives the real stack inside a fake YCSB_HOME
   instead of text-extracting support code from a legacy script.

## Findings during steps 3-4

1. **Config files are parsed, not executed.** Sourcing them made "environment beats a
   preset" impossible to honour (a sourced assignment always wins) and quietly turned
   `conf/` into code execution. `config::load_file` accepts comments plus `KEY=VALUE`
   assignments, rejects substitutions, and skips names that were already in the environment
   when the runner started (`config::snapshot_env`, with `config::set_cli` for CLI flags).
   Both existing `.example` files still parse unchanged.
2. **Deviation from section 6 of the plan:** `conf/scale.<mode>.env` is applied with
   `--config` instead of automatically. An auto-loaded preset would silently resize
   datasets (the smoke suite runs a 200-record template while `SCALE=heavy`), which changes
   what a run measures without saying so.
3. **Preflight no longer requires a writable workload** (`-r`, not `-rw`); writability of
   `$WORKLOAD_DIR` is checked by `workload::init`. The README's "create a clean launcher"
   workaround (copy the template, then ~40 lines of `sed`) is obsolete for `experiment.sh`
   runs; the README rewrite itself is step 7.
4. **Goldens changed only where step 4 says they should:** the six YCSB `Command line:`
   banners now name `-P <WORKDIR>/experiment/workloads/<phase>-iterNN.workload`. Re-captured,
   then verified deterministic (2 compare runs, both entry points, all PASS).
5. **Test-harness gotcha:** the alias test failed whenever the caller exported a canonical
   name (`DB_PWD`), because a legacy value may not override one - that is the documented
   precedence. Tests of legacy names now run under `env -i`.

## Findings during steps 2–3

1. **Config-layer bug found and fixed:** paths were derived inside
   `config::init_defaults`, so overriding `TYPE`/`SCALE` via `--config`/`--var` renamed the
   result CSV but not `$EXPERIMENT_DIR` (already captured by a `${VAR:-…}` guard). Derivation
   now happens exactly once, after every configuration layer.
2. **Both entry points verified identical:** `bash ./experiment.sh postgresql_textarray`
   (`TARGET_CMD='bash ./experiment.sh postgresql_textarray' tests/smoke_authoritative.sh`) and
   the compatibility shim both match the same goldens.
3. `lib/registry.sh` gives optional hooks (`backend::wait_idle`, `dump_restore`, `truncate`,
   `close`, `parse_args`) no-op defaults, so a minimal backend implements only:
   `info`, `default_config`, `preflight`, `init_db`, `collect_metrics`, `key_sizes`,
   `total_size`, `list_keys`.

## Findings during step 1

1. **Smoke goldens were not deterministic.** Two sources found and fixed:
   * leftover smoke databases changed the runner's output (`dropdb --if-exists` only
     emits its NOTICE when the database is absent) → the suite now drops the three smoke
     databases before every run;
   * `WAITING FOR IDLE POSTGRES` lines appear only when the server happens to be busy with
     autovacuum/checkpoint work from earlier runs → filtered out of the golden markers
     (the surrounding `START/END WAIT` pair is still compared).
   Verified with 4 consecutive compare runs, all PASS.
2. **`tests/test_postgresql_array_pg18.py` still targets `experiment_postgresql_array.sh`,**
   not the authoritative script, so it was unaffected by step 1. It must be retargeted in
   step 2 when that sibling becomes a shim over the shared backend.
3. Extraction is otherwise mechanical: `log`, `start_logging`, `finish_logging`,
   `stop_runtime_watcher` → `lib/common.sh`; metric arrays + `collect_cpu_memory_metrics` +
   `stats_header` → `lib/metrics.sh`; `write_result` → `lib/results.sh`;
   `append_first_iteration`, `append_subsequent_iterations`, `get_key_sizes` →
   `lib/keysizes.sh`. The runner sources them right after computing `SCRIPT_DIR`.

## Findings during step 0 (beyond the plan)

1. **Bug #1 confirmed empirically.** The pre-fix script dies with
   `exp.sh: line 600: rc: unbound variable` at the end of the *first* YCSB phase, i.e. it
   cannot complete even one phase. Fixed version completes all eight phases, exit 0.
2. **New bug found while fixing #1 (fixed):** `wait` on the SIGTERM'd watcher returns 143;
   with `set -e` active this unwound `run_with_metrics`, and the EXIT trap then referenced the
   out-of-scope local `watcher_pid`. Cleanup now uses a global `RUNTIME_WATCHER_PGID` +
   `stop_runtime_watcher` (always succeeds, safe from any trap) and is also called by
   `finish_logging` as a safety net.
3. **`experiment_postgresql_array_baseline.sh` cannot run on PostgreSQL 18.** It still expects
   the pre-PG16 column `buffers_backend` (removed from `pg_stat_bgwriter`) and fails its own
   metrics validation, so preflight never passes. Left as-is (it is replaced by `--mode
   baseline`, step 6); excluded from the mock test suite with a comment.
4. **`tests/test_postgresql_array_pg18.py` was stale** (4 failures + 1 error before this
   work): its mock did not know `SHOW track_counts`, hardcoded 23 metrics columns, asserted on
   `buffers_backend`, and asserted preflight errors on stderr although they are tee'd to
   stdout. Repaired: the mock now derives the column count from the SQL being asked, CSV
   assertions check header/value ordering generically, and the baseline runner is excluded.
5. **Deleted `tests/test_runtime_watcher.py`** — it imported `watch_postgresql18.py`, which
   does not exist in the repository (plan step 2 anticipated "restore or drop its test").
   Still outstanding: `experiment_postgresql_array.sh` keeps dead code referencing that module.
6. **Credential leak:** YCSB echoes `-p db.passwd=…` into the results log via its
   `Command line:` banner, so experiment logs contain the DB password in plaintext. The smoke
   suite masks it; a real fix (pass credentials via env/`PGPASSWORD` or redact at capture)
   belongs with step 2/3 — **needs a decision**, since it changes log contents.
7. Minimal env overrides were added to the authoritative script so it can be driven from a
   test (`DB_USERNAME`, `DB_PWD`, `TYPE`, `YCSB_BINDING`, `WORKLOAD_FILE`, `EXPERIMENT_DIR`,
   `FIELDLENGTHORIGINAL`, `EXTEND_OPERATIONCOUNT`); step 3 replaces them with the config layer.

## Decisions and deviations from the plan

1. **Goldens come from real YCSB + real PG 18, but assert structure, not measurements.**
   Timings, throughput, latencies, PostgreSQL counters, relation OIDs, execution ids,
   timestamps and credentials are masked; phase markers, log line shapes, CSV column names,
   row/operation shape and operation counts are compared exactly. Two consecutive compare
   runs passed, so the suite is deterministic on this machine.
2. **Legacy scripts become shims and stay until step 8c.** Plan says "delete, not diff-port";
   deleting backends we cannot run here (couchbase/mongo/neo4j/mariadb) would ship unverified
   deletions. Shims are one-line `exec` wrappers, so there is nothing to drift.
3. **shellcheck is unavailable** → CI uses `bash -n` plus the test suite; add shellcheck when
   it can be installed.
4. **Local runs must pass `DB_PWD=USyd2025`**; the hardcoded `usyd2026` in the scripts does not
   match this machine's server.

## Open questions for the user

- **`log()` allow-list drops real progress lines.** `lib/common.sh` echoes only recognised
  message shapes, so e.g. `Initial-load verification - TotalSize:…`, `Extend verification - …`,
  `Workload file fieldlength set to:…` and the `=== …phase ===` banners never reach the run log
  (pre-existing, also on `master`). Widening the list adds lines to every future log and needs
  the goldens re-captured - do it, or keep the current log shape?

- Should `conf/db.postgresql.env` be committed as a template (`conf/db.postgresql.env.example`)
  with real credentials kept out of git? (Plan says credentials stay out of tracked files.)
- EC2 acceptance run: who runs it, and against which instance? Step 8c is gated on it.

## Log

### 2026-09-24 — step 5b: mariadb_innodb backend (verified end-to-end)

- `lib/backends/_mariadb_common.sh` (admin CLI wrapper, `SHOW GLOBAL STATUS` snapshot,
  preflight, dump/restore, size helpers) + `lib/backends/mariadb_innodb.sh` (metadata, DDL,
  value-size expression, defaults). `experiment_mariadb_innodb.sh` is a one-line shim and left
  `LEGACY_WITH_WARNINGS`; `conf/db.mariadb_innodb.env.example` documents the endpoint, the
  container wrap and the JDBC-driver requirement (`conf/db.*.env` is gitignored - the local
  file points at the podman MariaDB on 3307).
- The **110 statistics columns are byte-for-byte the legacy list and order** (checked
  programmatically against `experiment_mariadb_innodb.sh`'s header), so results stay
  comparable with the old EC2 runs. Status variables a newer MariaDB removed keep their column
  and report 0. `btree_height` reports 0 unless `INNO_SPACE_TOOL` + `INNODB_IBD_FILE` are set:
  the legacy script ran `sudo ../inno_space/inno` inside the measured run.
- **Fix found by running it:** the dump used mysqldump's own `-r`, which with a container wrap
  writes the file *inside* the container and leaves the runner with nothing to restore (and
  `--databases` would have restored the source database's name). The runner now writes the
  dump itself (`--single-transaction`, no database clause) and loads it into the comparison
  database, which works wrapped or not.
- **Second fix, the silent one:** the schema was `fieldN VARCHAR(255)`, so the extend phase
  overflowed it. JdbcDBClient logs `Error in processing update...`/`Data too long for column`
  on stderr and **still exits 0**, so the run "passed" with a partly-failed extend. Columns are
  `LONGTEXT` now (the legacy runners created them by hand), and
  `tests/smoke_backend.sh` fails if the run log contains database-side errors at all - that
  assertion would have caught this on the first try. Verified: no error lines, value size grows
  200000 -> 230000 across extend.
- **Runtime watcher is dialect-gated.** `watcher.sh` only knows PostgreSQL (`pg_stat_activity`,
  `pg_stat_*`, via `sudo -u postgres psql`). It now takes `DB_DIALECT` (from
  `runtime_watcher_dialect` in `backend::info`) and `OS_PROCESS_USER`; with any other dialect
  it samples the server's OS account and writes no `.dbstats` file rather than an empty
  PostgreSQL-shaped one. Unset means PostgreSQL, so the legacy callers are unchanged and the
  goldens still match byte-for-byte.
- **New: `./experiment.sh <backend> --check`** runs that backend's preflight and exits - the
  difference between "no server here" and "broken". `tests/run_tests.sh` uses it to gate the
  structural smokes (`BACKEND_SMOKES`, `REQUIRED_BACKEND_SMOKES`), so mariadb_innodb joined the
  suite without making the suite depend on a running container.
- Suite: static checks PASS (legacy warning list down to 15) - 37 shell + 7 python tests OK -
  authoritative smoke PASS against unchanged goldens - postgresql_row, postgrenosql and
  mariadb_innodb structural smokes PASS.

### 2026-09-24 — shellcheck became available, gate turned into a ratchet

- `tools/check_scripts.sh` used to skip shellcheck; it now runs it per file. Strict for the
  harness, advisory (with a printed count) for the 16 legacy runners in
  `LEGACY_WITH_WARNINGS`, so the gate is green today and cannot get worse: a file leaves the
  list when it is ported or deleted, and nothing new may join it.
- SC2034/SC2154 excluded project-wide — every one of the 72 hits was a variable assigned in
  one sourced file and read in another (`readproportion_extend`, `metric_field_names`,
  `iteration`), which per-file analysis cannot see.
- Real fixes in the harness: `> $PLAN_LOG` / `> $HISTOGRAM_FILE` → `: > "$…"` (one was also
  unquoted), `export "$assignment"` documented as intentional, `YCSB_HOME=` split from its
  export in `experiment.sh` and `tests/test_logging.sh`, `mapfile` instead of `size_files=(
  $(find …))`, shebang added to `_postgresql_common.sh` (it had a stray duplicate header
  mid-file from the step-5 extraction), SC1090 disabled in the backend-contract test.
- `watcher.sh` turned out clean under the new exclusions and left the legacy list.

### 2026-09-24 — step 5b: postgrenosql backend (verified end-to-end)

- `lib/backends/postgrenosql.sh`: JSONB document schema (`YCSB_KEY VARCHAR(255)`,
  `YCSB_VALUE JSONB`), size expression `octet_length(ycsb_value::text)`, binding
  `postgrenosql`, properties `../postgrenosql/conf/postgrenosql.properties`. Everything else
  (metrics, preflight, dump/restore, idle wait, size helpers) is inherited from
  `_postgresql_common.sh`, so its results CSV has the same 74 columns as the other backends
  instead of the legacy script's smaller set.
- New contract point for non-JDBC bindings: the connection property **prefix** is configured
  (`BINDING_PARAM_PREFIX`, default `db`) and `binding_db_params <url>` in `lib/lifecycle.sh`
  builds `-p <prefix>.url/.user/.passwd` for each of the eight YCSB invocations. `db.*` was
  hardcoded 24 times before; the engine now names no binding property at all.
- `postgresql::base_config` takes the binding's properties file as an argument, so a backend
  does not have to re-derive it after the shared defaults have already filled the variable
  (the first attempt silently kept `../jdbc-binding/conf/postgres.properties`).
- `experiment_postgrenosql.sh` is a one-line shim; `conf/db.postgrenosql.env.example` added,
  and `conf/db.postgresql.env.example` now names the two files it can be copied to.
- Deliberate behaviour change: PostgreSQL >= 18 is required (the shared metrics query uses
  `pg_stat_checkpointer`), where the legacy script still had pre-17 fallbacks.
- Tests: `tests/run_tests.sh` runs `smoke_backend.sh postgrenosql` next to `postgresql_row`;
  full suite PASS — static checks · shell + python tests · authoritative smoke against
  unchanged goldens (the `-p db.*` -> `${DB_PARAMS[@]}` rewrite is output-identical) ·
  postgresql_row and postgrenosql structural smokes.
- Found while checking extend: `log` in `lib/common.sh` allow-lists message shapes, so the
  engine's `Initial-load verification - TotalSize:…`, `Extend verification - …` and
  `Field length average:…` lines never reach the run log (pre-existing, also on `master`;
  worth fixing when the size helpers are wired in).
- Environment discovery: **podman works here and can pull images**, so the remaining backends
  do not have to ship unverified — see the Environment table.

### 2026-09-24 — step 5b: results-CSV schema belongs to the backend

- `backend::metric_names` is the contract point for statistics columns; `_postgresql_common.sh`
  provides the PG18 list (`metric_field_names`, ex `binding_field_names`). `lib/metrics.sh`
  keeps CPU/memory only, sampling `host_os_user` from backend info.
- `write_result` uses `metrics::header`; local variables renamed away from PostgreSQL wording.
- New guard: core (`lib/metrics.sh`, `lib/results.sh`) must not mention PostgreSQL. Suite:
  35 shell + 7 python tests OK, both smoke suites PASS, goldens byte-identical.

### 2026-09-24 — step 5b: postgresql_row backend, PostgreSQL specifics shared

- `lib/backends/_postgresql_common.sh` (shared PG implementation) + a slim
  `postgresql_textarray.sh` and the new `postgresql_row.sh` (metadata, DDL, value-size
  expression, config only). Registry discovery ignores `_`-prefixed files.
- `experiment_postgresql.sh` and `experiment_postgresql_array.sh` are one-line shims over
  `experiment.sh postgresql_row|postgresql_textarray` (-1084 lines of drifted copies): the last
  two PostgreSQL runners that were still full copies.
- Tests: `tests/smoke_backend.sh` added (structural, any backend) and wired into
  `run_tests.sh`; mock suite retargeted to the real stack as
  `tests/test_postgresql_backend_pg18.py` (7 tests, fully mocked).
- Suite: static checks PASS - 34 shell + 7 python tests OK - authoritative smoke PASS against
  unchanged goldens - postgresql_row structural smoke PASS (8 phases, 74 CSV columns).

### 2026-09-24 — step 5 (engine half): contract only, aliases deleted

- `lib/lifecycle.sh` now calls exclusively `backend::preflight/init_db/exec/collect_metrics/
  wait_idle/dump_restore/total_size/key_sizes/list_keys`; the 34x duplicated value-size SQL
  and the per-phase key listings are gone (engine -78/+30 lines).
- `lib/backends/postgresql_textarray.sh`: implementations renamed into the contract names and
  the eight wrapper/alias functions deleted; only the private `pg_cli` helper remains.
- New regression guard in `tests/test_config_workload.sh`: every backend must implement the
  contract, and `lib/lifecycle.sh` must contain neither PostgreSQL function names nor any
  write to `$WORKLOAD_FILE`. Verified the guard fails when either is violated.
- Suite unchanged otherwise: static checks PASS - 33 shell + 7 python tests OK - smoke PASS
  against the same goldens (no golden update needed for this step).

### 2026-09-24 — steps 3 and 4 complete

- `lib/config.sh`: legacy launcher alias shim (`DIST`, `WORK`, `UNCHANGE_DB_NAME`,
  `EXPERIMENT_EPOCHS`, `EXPERIMENT_RUNS_PER_EPOCH`, `DB_PASSWORD`,
  `FIELD_LENGTH_ORIGINAL`, `vacuum`, `EXTEND_*`/`RUN_*` proportions), each with a
  deprecation line; canonical name wins when both are set. Instrumentation variables of
  step 8b are reported as unsupported instead of silently ignored.
- Configuration files are now **parsed, not executed** (`config::load_file`), which is what
  makes "environment beats presets" true; `conf/db.<backend>.env` is loaded automatically,
  `conf/scale.{heavy,light}.env` explicitly with `--config`. New flags: `--scale`,
  `--workload`, `--experiment-dir`; `--dry-run` lists the files applied.
- `lib/workload.sh`: `workload::generate <phase> <iteration>` builds one immutable,
  provenance-tagged properties file per YCSB invocation under `$EXPERIMENT_DIR/workloads`;
  `workload::apply_context` publishes the ten globals `write_result` records. `lib/lifecycle.sh`
  lost all 22 `perl -i -p` rewrites, the conditional `fieldlengthdistribution` append and the
  `awk` strip; preflight no longer asks for a writable workload.
- Tests: new `tests/test_config_workload.sh` (31 assertions: precedence, aliases, parsing
  errors, overlays, template immutability) wired into `run_tests.sh`; the smoke suite now
  fails if `../workloads` is touched, if a phase file is missing, if a generated file has no
  provenance header, or if temporary files are left behind.
- Goldens re-captured (only the six YCSB `Command line:` `-P` paths changed) and verified:
  static checks PASS · 31 shell + 7 python tests OK · smoke PASS twice plus through the
  `experiment.sh postgresql_textarray` entry point.

### 2026-09-23 — steps 2 and (part of) 3

- `lib/backends/postgresql_textarray.sh`: PG18 specifics (pg_cli/pg_exec, metrics query,
  preflight, comparison-DB restore, idle wait, init/close) + `backend::*` contract + new
  `total_size` / `key_sizes` / `list_keys` / `size_expression` helpers.
- `lib/registry.sh`: discovery, contract assertion, capability lookup.
- `lib/config.sh`: layered configuration with `${VAR:-default}` knobs and a final
  `config::derive_paths`; plus `conf/README.md`, `conf/db.postgresql.env.example`,
  `conf/experiments/smoke.env.example`.
- `experiment.sh`: single entry point; `--mode baseline` / `--instrument` rejected until
  steps 6 and 8b. `experiment_postgresql_array-text-autovacuum.sh` is now a shim.
- Suite: static checks PASS · 7 python tests OK · smoke PASS via both entry points.

### 2026-09-23 — step 1 complete

- Created `lib/{common,metrics,results,keysizes}.sh`; the authoritative runner sources them
  and shrank from 1253 to 1022 lines. Function and top-level-name inventories diffed against
  `HEAD`: identical.
- Made the smoke suite deterministic (pre-clean smoke databases; filter idle-wait chatter);
  goldens re-captured, then 4 consecutive compare runs PASS.
- Suite: static checks PASS · 7 python tests OK · smoke PASS.

### 2026-09-23 — step 0 complete

- Fixed the four §10 bugs in `experiment_postgresql_array-text-autovacuum.sh`
  (`run_with_metrics` unbound `$rc`/`$started` + swallowed status; EXIT trap clobbering
  `finish_logging`; `wait_for_idle_postgres` never detecting idle; watcher-cleanup abort), plus
  quoting of `$PLAN_LOG` / `$KEY_SIZE_LOG`.
- Added `tools/check_scripts.sh`, `tests/run_tests.sh`, `tests/smoke_authoritative.sh`,
  `tests/golden/smoke/*` (9 normalised artefacts).
- Repaired the stale mock suite; deleted the dead `test_runtime_watcher.py`.
- Suite status: static checks PASS · 7 python tests OK · smoke run PASS vs goldens.

### 2026-09-23 — setup

- Branch `refactor/experiment-scripts` created from `master` (`5709fd5`).
- Environment probed: PG 18 server + superuser role usable for real smoke runs; built the
  missing `jdbc-array` binding.
