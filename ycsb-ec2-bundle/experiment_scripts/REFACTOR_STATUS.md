# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **steps 1–5 complete — every backend is ported and verified end-to-end** (nine:
`postgresql_textarray`, `postgresql_row`, `postgresql_json`, `postgrenosql`, `mariadb_innodb`,
`mariadb_rocksdb`, `mongodb`, `neo4j`, `couchbase`) — one runner (`experiment.sh <backend>`), nine
verified backends behind shared modules, an engine that calls nothing but `backend::*`, a layered
config layer with a legacy-launcher alias shim (variable names *and* backend names), and
**workload files are read-only templates** (one generated file per phase in the experiment
directory). Goldens unchanged apart from the intended `-P` paths. The single leftover of step 5 —
the shim for `experiment_postgresql_array_json.sh` — is **held by your decision**: that script is
`run_postgresql_array_json_full_visibility.sh`'s callee, so shimming it would delete full
visibility before the EC2 gate that exists to protect it; it folds into step 8c. Next up:
**step 6 (`--mode baseline`)**, then step 7 (tooling + README). There is no instrumentation module
any more.

Read this file first after an interruption. Append to the **Log** at every meaningful
checkpoint, and keep the **Step status** table current.

> **Trimmed 2026-09-24:** the per-step findings sections and Log entries for completed work
> (steps 0–5 ports) were removed; durable facts they produced are folded into "Facts that
> save time" below. Full history: `git log --follow REFACTOR_STATUS.md`.

---

## Environment (verified on this machine, 2026-09-24)

| Item | Status | Notes |
| --- | --- | --- |
| PostgreSQL server | ✅ live | `127.0.0.1:5432`, PG 18 (`server_version_num=180006`), data dir `/var/lib/pgsql/data` |
| Benchmark role | ✅ superuser + login | user `ycsb`, password **`USyd2025`** — *not* the `usyd2026` hardcoded in legacy scripts; local runs must pass `DB_PWD=USyd2025` |
| psql/createdb/dropdb/pg_dump | ✅ PG 18.6 client | satisfies the PG18 preflight |
| YCSB module jars | ✅ present | `core`, `jdbc`, `jdbc-array` (built once: `mvn -o -pl site.ycsb:jdbc-array-binding -am package -DskipTests`), `jdbc-array-json`, `postgrenosql`, `neo4j` driver, `couchbase2` java-client-2.3.1 |
| shellcheck | ✅ installed | `tools/check_scripts.sh` ratchet: harness (`lib/`, `experiment.sh`, `tests/`, `tools/`) must be clean; the legacy list (12 scripts) is advisory and only shrinks — nothing new may join, ported/deleted files leave. SC2034/SC2154 excluded globally (globals shared across sourced files). `SHELLCHECK_STRICT=1` fails on everything |
| sudo | ❌ password required | cannot create PG roles or touch server config; use the existing `ycsb` role |
| podman | ✅ working, can pull | no docker, no local server binaries — containers are how backends are smoke-tested here. Containers were lost once and recreated from the `podman run` lines documented in each untracked `conf/db.<backend>.env` |
| MariaDB container | ✅ up, verified | `ycsb_mariadb` = `mariadb:11` on `-p 3307:3306`; role `ycsb` needs **`GRANT ALL PRIVILEGES ON *.*`** (load phase inserts). Endpoint + wrap in untracked `conf/db.mariadb_innodb.env`. MariaDB JDBC driver (`jdbc/target/dependency/mariadb-java-client-3.4.1.jar`) checked via `BACKEND_DRIVER_JAR` |
| MongoDB container | ✅ up, verified | `ycsb_mongo` = `mongo:5.0` on `-p 27017`, no auth. Admin tools run through **`MONGO_CLI_WRAP=podman exec -i ycsb_mongo`**; endpoint + wrap in untracked `conf/db.mongodb.env`. Binding got a minimal `mongodb/conf/mongodb.properties` (every YCSB invocation needs one) |
| Neo4j containers | ✅ up, verified | three instances (`ycsb_neo4j_{main,backup,unchange}` = `neo4j:5`, ports 7687/7787/7887, password `USyd2025`), because Community has **one user database per instance**. `NEO4J_CLI_WRAP_<ROLE>=podman exec -i …` + Bolt URI; APOC enabled; **shared podman volume for the import dir** with world-writable `tmp/` (needed by the clean-run graphml copy). Full wrap config in untracked `conf/db.neo4j.env` |
| MariaDB RocksDB container | ✅ up, verified | MyRocks exists in **no official image**. Pulled `docker.io/devonkupiec/mariadb-rocksdb` (MariaDB **10.3.27**, 5 years old, `SHOW ENGINES` lists ROCKSDB as DEFAULT) as `ycsb_mariadb_rocksdb` on `-p 3308:3306`, role `ycsb`/`USyd2025` with `GRANT ALL ON *.*`. Endpoint + wrap in untracked `conf/db.mariadb_rocksdb.env`; **both that file and the example carry the caveat** that this image verifies the port and is not an evidence host — EC2 RocksDB evidence needs a server built `-DPLUGIN_ROCKSDB=YES` |
| `pre-refactor-scripts` tag | ✅ created 2026-09-24 | points at `03f96d44`, the last commit before step 0 — every legacy runner exactly as written. Plan §9 promised this escape hatch and it did not exist. `experiment_postgresql_array_json.sh`, `run_postgresql_array_json_full_visibility.sh` and `benchmark_observability.py` are byte-identical in tag and working tree (`watcher.sh` differs: step 0 fixed bugs in it). `git worktree add ../pre-refactor pre-refactor-scripts` reproduces a full-visibility run |
| Couchbase container | ✅ up, verified | `ycsb_couchbase` = **`docker.io/library/couchbase:community-7.6.2`** started with `--net=host` (so the cluster advertises `127.0.0.1` and the SDK works), `cluster-init --services data,index,query`. Three buckets + one local RBAC user per bucket named exactly like it (SDK 2.x authenticates as the bucket). Runner can create missing buckets/users itself (`COUCHBASE_CREATE_MISSING_BUCKETS=1`). Config in untracked `conf/db.couchbase.env` |

## Verification commands

```bash
cd ycsb-ec2-bundle/experiment_scripts

# everything: static checks + python tests + PostgreSQL smoke run (needs DB_PWD)
DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh

# parts
bash tools/check_scripts.sh                        # bash -n + shellcheck ratchet, no DB
bash tests/test_config_workload.sh                 # config layer + workload generation, no DB
python3 -m unittest discover -s tests -t tests     # mock-based runner tests, no DB
DB_PWD=USyd2025 bash tests/smoke_authoritative.sh  # real PG18 end-to-end vs goldens
DB_PWD=USyd2025 bash tests/smoke_backend.sh mariadb_innodb  # structural, any reachable backend
bash tests/smoke_backend.sh mongodb|neo4j|couchbase  # needs the matching container
bash tests/smoke_backend.sh mariadb_rocksdb         # needs the MyRocks image (conf/db.mariadb_rocksdb.env)

# is a server reachable for one backend? (what run_tests.sh uses to skip)
./experiment.sh <backend> --check
```

The smoke run takes ~40 s and uses its own databases (`ycsb_smoke`, `ycsb_smoke_unch`,
`ycsb_smoke_bak`). Re-capture goldens only deliberately:
`DB_PWD=… bash tests/smoke_authoritative.sh --update`. With `SMOKE_KEEP=1` the work
directory is kept for inspection.

## Step status

| # | Step | Status | Notes |
| --- | --- | --- | --- |
| 0 | Fix §10 bugs; smoke goldens; CI checks | ✅ done | all bugs fixed against real PG 18 + YCSB; `check_scripts.sh`, `run_tests.sh`, `smoke_authoritative.sh` + goldens |
| 1 | Core libs `lib/{common,metrics,results,keysizes}.sh` | ✅ done | name inventories verified identical to `HEAD`; goldens unchanged |
| 2 | Backend module, `registry.sh`, `experiment.sh` dispatcher | ✅ done | authoritative script is a compatibility shim; both entry paths golden-identical |
| 3 | `config.sh` + `conf/` presets + alias shim + help/dry-run | ✅ done | parsed-not-executed config; legacy aliases with deprecation lines |
| 4 | Workload generation into `$EXPERIMENT_DIR/workloads/` | ✅ done | immutable provenance-tagged files; all in-place rewrites gone; smoke asserts `../workloads` stays clean |
| 5 | Engine + backend ports | ✅ **done** | **nine backends, all verified end-to-end:** engine drives only `backend::*`; PostgreSQL split into `_postgresql_common.sh` + `postgresql_textarray`/`postgresql_row`/`postgresql_json`/`postgrenosql`, MariaDB into `_mariadb_common.sh` + `mariadb_innodb`/`mariadb_rocksdb`, plus `mongodb`, `neo4j`, `couchbase` — each ported legacy script is a one-line shim and in `BACKEND_SMOKES`. Only the `experiment_postgresql_array_json.sh` shim is outstanding, **deliberately held** (its sibling launcher execs it) and therefore folded into 8c |
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ⬜ pending | `--mode baseline` currently rejected by `experiment.sh` |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ⬜ pending | |
| 8a/8b | ~~`postgresql_json` backend · fullview instrumentation module~~ | ➖ folded/cancelled | 8a → step 5(b) **done** (`postgresql_json`, verified); 8b **cancelled** — WAL / `pg_stat_statements` / residency / prewarm / checkpoint-log / sampling / detoast probes are discarded (plan §4), and the `--instrument` placeholder is deleted from `experiment.sh` |
| 8c | Delete remaining shims/legacy scripts (+ `benchmark_observability.py`) | ⬜ pending | **gate:** only after user confirms on EC2 hardware — legacy array_json is the provenance of existing full-visibility evidence |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked · ➖ cancelled/folded

## Where to resume

All backends are ported. Next is **step 6 (`--mode baseline`)**; the items below are the
carry-overs to remember while doing it.

- **Held for 8c: the `experiment_postgresql_array_json.sh` shim.** The plan's last item of step 5
  is a one-line shim mapping `VALUE_VARIANT` → backend, but
  `run_postgresql_array_json_full_visibility.sh` ends in `exec ./experiment_postgresql_array_json.sh
  --full-visibility …`, so replacing that script removes full visibility *before* the EC2
  confirmation step 8c waits for. Agreed course (2026-09-24): leave the legacy pair alone (a FROZEN
  header comment only, no code changed) and point at `postgresql_json` from the config warning.
- **Done: `postgresql_json` (step 5b).** `lib/backends/postgresql_json.sh` sources
  `_postgresql_common.sh` and overrides only `info` (`jdbc-array-json`,
  `default_type=postgresql_arrayjson_TOAST` — the legacy artefact prefix —, `workloada-extend`,
  capability flags copied from `postgresql_textarray`), `init_db` (`fieldN JSONB` × 10) and
  `size_expression`. Nothing else came across: no extensions, no second DB identity, no
  server-log access, no `jdbc.readsample.*`. Verified against PG 18 (74-column CSV; a fresh load
  measures exactly 10 × fieldlength per row); in `BACKEND_SMOKES` **and**
  `REQUIRED_BACKEND_SMOKES`; `--instrument` deleted from `experiment.sh` and
  `config::warn_deferred_legacy` renamed to `config::warn_discarded_legacy`.
- **Done: `mariadb_rocksdb` (step 5a).** `lib/backends/mariadb_rocksdb.sh` on
  `_mariadb_common.sh`: same ten LONGTEXT columns as InnoDB (so a size difference is an engine
  effect) with `ENGINE=RocksDB DEFAULT COLLATE=latin1_bin`, and its own 35-column statistics set
  read from `SHOW GLOBAL STATUS 'Rocksdb%'` plus `information_schema.ROCKSDB_CFSTATS /
  ROCKSDB_DBSTATS / ROCKSDB_SST_PROPS`. Verified end-to-end on a real MyRocks server (57-column
  CSV, dump/restore included, compaction/WAL/stall counters non-zero). Its legacy runner is a shim
  and left `LEGACY_WITH_WARNINGS`; the *_baseline sibling waits for step 6.

- `./experiment.sh <backend> --check` runs that backend's preflight (server reachable, role
  allowed to create/drop, build artifacts present) and exits without benchmarking — that is
  how `run_tests.sh` decides to run or skip a smoke, and the fastest way to separate "not
  installed here" from "broken". All nine ported backends are in `BACKEND_SMOKES`, so any
  can be re-verified with `bash tests/smoke_backend.sh <backend>` once its server answers;
  `REQUIRE_DB=1` still fails when a *required* backend (the PostgreSQL family) is
  unreachable.
- **The runtime watcher is still PostgreSQL inside.** `watcher.sh` reads `pg_stat_activity`
  / `pg_stat_*` through `sudo -u postgres psql`. It receives `DB_DIALECT` (from
  `runtime_watcher_dialect` in `backend::info`) plus `OS_PROCESS_USER`: for unknown dialects
  it samples the server's OS account only and writes **no** `.dbstats` file. Porting the
  sampler itself (`lib/watcher_runner.sh`) and removing the `sudo -u postgres` dependency
  (remote servers) is still open.
- Backend names go through `registry::alias` (`postgresql_array`→`postgresql_textarray`,
  `jsonb`/`array_json`/`arrayjson`/`postgresql_array_json`→`postgresql_json`,
  `postgresql`→`postgresql_row`, `innodb`→`mariadb_innodb`, `rocksdb`→`mariadb_rocksdb`), so an
  old launcher keeps working while `--list-backends` stays honest. The deprecation notice goes to
  **stderr**: `registry::resolve`'s stdout is the resolved path. Aliases die with the legacy
  scripts at 8c; they are covered by tests/test_config_workload.sh.
- `postgresql_json` measures the **logical** value size exactly like its textarray sibling — Σ of
  the ten JSON arrays' element octet lengths, JSON syntax excluded — so a fresh load reads 10 ×
  fieldlength per row (verified: min 1000 at fieldlength 100) and extend growth is comparable
  with `postgresql_textarray` row for row. `postgrenosql` is the deliberate exception: its size
  includes the document's JSON syntax.
- MyRocks is not in any official MariaDB image, and its MariaDB 10.3 build differs from the
  legacy script's assumptions in three ways that matter: a **767-byte index key limit** (a utf8mb4
  VARCHAR(255) primary key needs 1020, hence `DEFAULT COLLATE=latin1_bin` on the table — YCSB data
  is ASCII so stored bytes are unaffected), no per-level SST view (`lsm_levels` reports 0), and
  `SHOW ENGINE ROCKSDB STATUS` prints **none** of the five phrases the legacy runner grepped, so
  all five of its LSM columns were empty on this engine. Statistics now come from
  `information_schema.ROCKSDB_CFSTATS / ROCKSDB_DBSTATS / ROCKSDB_SST_PROPS`, and the legacy
  `sudo du /var/lib/mysql/#rocksdb/*.sst` is replaced by `total_sst_size` from SQL.
- Steps 6–7: baseline mode, tooling/README rewrite (see plan §8). No instrumentation layer —
  plan §4 records why the array_json samplers are dropped rather than ported.

## Facts that save time

- `$WORKLOAD_FILE` is a read-only template. Every phase gets its own file from
  `workload::generate <phase> <iteration>` (`lib/workload.sh`) written to `$WORKLOAD_DIR`
  (= `$EXPERIMENT_DIR/workloads`); the engine keeps the current one in `$WORKLOAD_PHASE`.
  Phase overlays live in `workload::generate`'s `case`; fed-back values (e.g.
  `fieldlengthaverage`) are passed as extra `KEY=VALUE` arguments.
- `write_result` still reads the lowercase globals (`recordcount`, `readproportion`, ...);
  `workload::apply_context <file>` publishes exactly those ten names — keep it in sync with
  the CSV columns.
- `run_experiment()` in `lib/lifecycle.sh` calls nothing outside the contract. Mandatory
  hooks (`registry::required_functions`): `info`, `default_config`, `preflight`, `init_db`,
  `collect_metrics`, `key_sizes`, `total_size`, `list_keys`, `sample_key`, `explain_sql`,
  `delete_keys`, `truncate`. Optional with no-op defaults: `vacuum`, `wait_idle`,
  `dump_restore`, `close`, `parse_args`, `extra_binding_params`. Capabilities declared in
  `backend::info` decide what the engine attempts (`supports_vacuum`,
  `supports_query_plan`, `has_dump_restore`, `runtime_watcher_dialect`, `host_os_user`,
  `min_server_version[_num]`).
- Binding properties beyond a connection: `backend::extra_binding_params` prints further
  `-p key=value` pairs (one per line) that `binding_db_params` appends to **every** YCSB
  invocation; an empty `BINDING_PARAM_*` value means "this binding has no such property"
  (`config.sh` therefore uses `${VAR-default}`, not `${VAR:-default}`). couchbase2 is the
  reference user (host/adhoc/kv/boost/core-retries, no username).
- `backend::total_size`, `key_sizes`, `list_keys` are what the size/verification code calls;
  a schema module only supplies `backend::size_expression`, which those helpers embed.
  Statistics columns belong to the backend (`backend::metric_names`); `lib/metrics.sh` only
  samples CPU/memory for `host_os_user`. A hygiene test fails if PostgreSQL names reappear
  in core (`lib/metrics.sh`, `lib/results.sh`).
- Two engine-side operations live in backends because their SQL is the whole point:
  single-key query plan logging (`sample_key` + `explain_sql`) and post-run key deletion
  (`delete_keys`), both capability-gated.
- Shared-family modules source `_postgresql_common.sh` / `_mariadb_common.sh` and override
  only `info`, `init_db` (DDL), `size_expression`, `default_config`; the registry skips
  `_`-prefixed files. Required build artifacts follow `$YCSB_BINDING/target/*.jar`; minimum
  server version comes from `backend::info min_server_version_num`.
- A role argument may select a whole server: every admin contract call receives the role
  (neo4j selects an instance, others a database). No engine change was needed when a
  three-endpoint backend joined.
- Config files are **parsed, not executed** (`config::load_file`): comments + `KEY=VALUE`,
  no substitutions; names already in the environment when the runner started are skipped
  (`config::snapshot_env`; CLI via `config::set_cli`). Paths derive exactly once, after all
  layers (`config::derive_paths`). `conf/scale.<mode>.env` is applied with `--config`, not
  auto-loaded (an auto preset would silently resize datasets). Unquoted values keep a
  trailing `# …` verbatim (documented in `conf/README.md`). Tests of legacy alias names must
  run under `env -i`.
- Smoke suites compare the untracked-file list of `../workloads` before/after a run ("this
  run created nothing"), not "no untracked files". `smoke_backend.sh` only pre-cleans for
  the `postgresql` dialect, only exports `DB_PWD` when one was actually given, and fails on
  any database-side error line in the run log or non-zero `Return=ERROR` rows — assertions
  that caught real silent failures during the ports.
- Deliberate deviations already baked in: preflight runs after the log is created (a failed
  preflight is recorded); PostgreSQL ≥ 18 required (`pg_stat_checkpointer`); couchbase does
  not shift `insertstart` when flush is refused (DELETE FROM, then error); N1QL copy/flush
  poll until counts agree; neo4j reset is batched `DETACH DELETE`, graphml import re-labels
  every node; mongodb restore uses a server-only URI (`MONGO_SERVER_URL`) + count check.

## Decisions and deviations still in force

1. **Goldens come from real YCSB + real PG 18, but assert structure, not measurements.**
   Timings, throughput, latencies, PG counters, OIDs, execution ids, timestamps and
   credentials are masked; phase markers, log shapes, CSV column names, row/operation shape
   compared exactly. Suite is deterministic on this machine.
2. **Legacy scripts become one-line `exec` shims and stay until step 8c** — deleting
   backends we cannot run here would ship unverified deletions.
3. **Local runs must pass `DB_PWD=USyd2025`**; the hardcoded `usyd2026` does not match this
   machine's server.
4. `experiment_postgresql_array_baseline.sh` is broken on PG 18 (`buffers_backend` removed
   from `pg_stat_bgwriter`) and excluded from the mock suite — replaced by `--mode baseline`
   in step 6.
5. **array_json = schema only.** Its full-visibility observability is discarded, not
   deferred (plan §4): no instrumentation layer, no `instrument::*` contract, no engine hook
   points, and nothing may pass `jdbc.readsample.*` / `jdbc.slowread.*` to a binding. Do not
   re-open this by "temporarily" copying sampler code into core or a backend.

## Open questions for the user


- **`log()` allow-list drops real progress lines.** `lib/common.sh` echoes only recognised
  message shapes, so e.g. `Initial-load verification - TotalSize:…`, `Extend verification - …`,
  `Workload file fieldlength set to:…` and the `=== …phase ===` banners never reach the run
  log (pre-existing, also on `master`). Widening the list adds lines to every future log and
  needs the goldens re-captured — do it, or keep the current log shape?
- **Couchbase's 22 statistics columns are literal zeros** (kept from the legacy runner for
  CSV comparability; real bucket counters go to the run log), same for neo4j's mostly-zero
  19 columns. Keep as-is, or replace with real counters — which changes that backend's CSV
  schema and needs the `../analysis_scripts/` checked. Decide once, for both.
- Should `conf/db.postgresql.env` be committed as a template (`conf/db.postgresql.env.example`)
  with real credentials kept out of git? (Plan says credentials stay out of tracked files.)
- **Credential leak:** YCSB echoes `-p db.passwd=…` into the results log via its
  `Command line:` banner. The smoke suite masks it; a real fix (env/`PGPASSWORD` or redact
  at capture) changes log contents — needs a decision.
- EC2 acceptance run: who runs it, and against which instance? Step 8c is gated on it.

## Log

### 2026-09-24 — step 5 tail (a): `mariadb_rocksdb` backend, verified end-to-end → step 5 done

- Pulled `docker.io/devonkupiec/mariadb-rocksdb` (MariaDB 10.3.27, MyRocks compiled in, ROCKSDB
  shown as DEFAULT) after confirming no official image carries the engine; started it as
  `ycsb_mariadb_rocksdb` on `-p 3308:3306`, role `ycsb` with `GRANT ALL ON *.*`, endpoint + wrap in
  untracked `conf/db.mariadb_rocksdb.env` (+ tracked `.example`). Both files say out loud that this
  five-year-old image verifies the port and is **not** an evidence host.
- New `lib/backends/mariadb_rocksdb.sh` on `_mariadb_common.sh`: identical column types to
  `mariadb_innodb` with `ENGINE=RocksDB DEFAULT COLLATE=latin1_bin`, plus a backend-declared
  35-column statistics set (LSM facts from information_schema + the `Rocksdb_*` counters: rows,
  memtables, block cache, L0/L1/L2+ read hits, WAL/flush/compaction bytes, write stalls).
  Replaces two things the legacy runner could not do portably — greps that match nothing on this
  engine, and `sudo du` over the server's data directory (see Facts above for all of it).
- `experiment_mariadb_rocksdb.sh` is now a one-line shim and left `LEGACY_WITH_WARNINGS`; added to
  `BACKEND_SMOKES` (deliberately **not** required — the special image will not always be up).
- Alias test rewritten: every alias must resolve to an existing backend file, which `rocksdb` now
  does (58 shell tests).
- Suite: static checks PASS · 58 shell + 7 python OK · authoritative smoke PASS vs unchanged
  goldens · **eight** structural backend smokes PASS, mariadb_rocksdb included (8 phases,
  dump/restore verified, 6 rows × 57 columns, non-zero compaction/WAL counters in the CSV).
- Step 5 is therefore complete: nine backends behind one engine. Only the held array_json shim
  remains of it, folded into 8c by your decision.

### 2026-09-24 — step 5 tail (b): `postgresql_json` backend, verified end-to-end

- New `lib/backends/postgresql_json.sh` (jsonb-array schema on `_postgresql_common.sh`,
  `jdbc-array-json` binding) — the **data model** of `experiment_postgresql_array_json.sh` and,
  per plan §4, nothing of its instrumentation. Verified against real PG 18 + YCSB:
  `tests/smoke_backend.sh postgresql_json` PASS (8 phases, no database-side errors, 6 rows ×
  74 columns), stored values are real JSON arrays, extend appends elements (`||
  jsonb_build_array`, the binding's PostgreSQL path) and the size expression reads 1000 bytes per
  fresh row at fieldlength 100 — i.e. the same logical measure as `postgresql_textarray`.
- `postgresql_json` added to `BACKEND_SMOKES` **and** `REQUIRED_BACKEND_SMOKES`; the reserved
  `--instrument` branch is deleted from `experiment.sh` (plain unknown option now) and
  `config::warn_deferred_legacy` → `config::warn_discarded_legacy`, its text no longer promising a
  module but naming `postgresql_json` and §4.
- **Backend-name aliases implemented** (`registry::alias`, called from `registry::resolve`) — plan
  §5 claimed them but nothing did the mapping, so `./experiment.sh postgresql_array` failed. Nine
  new assertions in `tests/test_config_workload.sh` (54 shell tests now).
- **Created the annotated tag `pre-refactor-scripts` → `03f96d44`.** Plan §9 relied on it as the
  escape hatch; it did not exist anywhere in the repository. Checked that the three
  full-visibility artefacts are byte-identical between that commit and the working tree.
- Suite after the change: static checks PASS · **54** shell + 7 python tests OK · authoritative
  smoke PASS vs unchanged goldens · **seven** structural backend smokes PASS (PostgreSQL ×3 on
  the system server, MariaDB/MongoDB/Neo4j×3/Couchbase in containers).
- Held: the `experiment_postgresql_array_json.sh` shim of this step (see "Where to resume" and
  "Open questions") — it would delete full visibility before the 8c EC2 gate.

### 2026-09-24 — status trimmed to remaining work

- Removed the per-step findings sections and Log entries for completed steps 0–5 (PG ports,
  mariadb_innodb, mongodb, neo4j, couchbase, config/workload layers) — all verified
  end-to-end, suite green: static checks PASS · 41 shell + 7 python tests OK · authoritative
  smoke PASS vs unchanged goldens · six structural backend smokes PASS. Durable facts folded
  into "Facts that save time"; full narrative in `git log --follow REFACTOR_STATUS.md`.
- Also trimmed the plan: §1 duplication analysis, completed migration rows, and the fixed
  §10 bug list are gone from `REFACTOR_PLAN.md`.

### 2026-09-24 — array_json re-planned: schema only, observability discarded

- Plan updated (REFACTOR_PLAN.md §0/§2/§4/§5/§8/§9/§10): the full-visibility instrumentation
  module is **cancelled**, not deferred. `postgresql_json` moves from step 8a into **step
  5(b)** and reuses the standard loop, watcher, statistics columns and CSV of its PostgreSQL
  siblings; `lib/instrumentation/`, `conf/experiments/full_view.env` and the reserved
  `--instrument` flag are off the roadmap. Step 8c additionally deletes
  `benchmark_observability.py` (loses its last caller) and stays EC2-gated because the legacy
  script is the provenance of existing full-visibility evidence.
- Rationale recorded in plan §4: the samplers need a second DB identity (`ALTER SYSTEM`,
  `CREATE EXTENSION`) plus server-host log access, require server config the runner should
  not own, are partly client-side (`jdbc.readsample.*` exists only in the forked
  `jdbc-array-json` client), and their engine had drifted from the authoritative spec.

### Next checkpoint

Step 6: `--mode baseline` (`lib/lifecycle_baseline.sh`, then delete the eight legacy
`*_baseline.sh`). Step 5 is complete; the array_json shim is settled (held for 8c).
