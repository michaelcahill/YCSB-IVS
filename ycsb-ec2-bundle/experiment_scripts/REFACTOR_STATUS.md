# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **refactor complete — steps 0–8c done. The EC2 acceptance run was confirmed by
the user, and step 8c deleted every legacy script, shim and alias.** Nine backends verified
end-to-end (
`postgresql_textarray`, `postgresql_row`, `postgresql_json`, `postgrenosql`, `mariadb_innodb`,
`mariadb_rocksdb`, `mongodb`, `neo4j`, `couchbase`) — one runner (`experiment.sh <backend>`), nine
verified backends behind shared modules, an engine that calls nothing but `backend::*`, a layered
config layer (canonical names only since 8c deleted the launcher/name alias shims), and
**workload files are read-only templates** (one generated file per phase in the experiment
directory). Goldens unchanged apart from the intended `-P` paths. Step 6 delivered
`--mode baseline`: one set of phase steps, two engines (`mainline`, `baseline`), and the nine
legacy `experiment_*_baseline.sh` scripts are gone. Step 7 delivered `tools/bundle.sh`
(generated single-file harness, tree/bundle equivalence + full benchmark through the bundle in CI),
`tools/deploy.sh` (overlay tar + remote backup + verify), the rewritten runbook, `.gitignore`
cleanup and the deletion of `tests/test_logging.sh`. Step 8c (EC2 gate cleared by the user's
confirmed acceptance run) deleted the 13 remaining legacy scripts/shims plus
`benchmark_observability.py` and `docs/benchmark_observability.md`, removed both alias layers
(`registry::alias` and the config launcher-variable shim), and turned `check_scripts.sh` into an
all-files-clean gate. Nothing from the plan is outstanding.

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
| shellcheck | ✅ installed | `tools/check_scripts.sh`: since 8c deleted the last pre-refactor script there is no tolerated-warnings list — **every** shell file must pass `bash -n` and shellcheck. SC2034/SC2154 excluded globally (globals shared across sourced files). `SHELLCHECK_STRICT=1` additionally re-enables the exclusions |
| sudo | ❌ password required | cannot create PG roles or touch server config; use the existing `ycsb` role |
| podman | ✅ working, can pull | no docker, no local server binaries — containers are how backends are smoke-tested here. Containers were lost once and recreated from the `podman run` lines documented in each untracked `conf/db.<backend>.env` |
| MariaDB container | ✅ up, verified | `ycsb_mariadb` = `mariadb:11` on `-p 3307:3306`; role `ycsb` needs **`GRANT ALL PRIVILEGES ON *.*`** (load phase inserts). Endpoint + wrap in untracked `conf/db.mariadb_innodb.env`. MariaDB JDBC driver (`jdbc/target/dependency/mariadb-java-client-3.4.1.jar`) checked via `BACKEND_DRIVER_JAR` |
| MongoDB container | ✅ up, verified | `ycsb_mongo` = `mongo:5.0` on `-p 27017`, no auth. Admin tools run through **`MONGO_CLI_WRAP=podman exec -i ycsb_mongo`**; endpoint + wrap in untracked `conf/db.mongodb.env`. Binding got a minimal `mongodb/conf/mongodb.properties` (every YCSB invocation needs one) |
| Neo4j containers | ✅ up, verified | three instances (`ycsb_neo4j_{main,backup,unchange}` = `neo4j:5`, ports 7687/7787/7887, password `USyd2025`), because Community has **one user database per instance**. `NEO4J_CLI_WRAP_<ROLE>=podman exec -i …` + Bolt URI; APOC enabled; **shared podman volume for the import dir** with world-writable `tmp/` (needed by the clean-run graphml copy). Full wrap config in untracked `conf/db.neo4j.env` |
| MariaDB RocksDB container | ✅ up, verified | MyRocks exists in **no official image**. Pulled `docker.io/devonkupiec/mariadb-rocksdb` (MariaDB **10.3.27**, 5 years old, `SHOW ENGINES` lists ROCKSDB as DEFAULT) as `ycsb_mariadb_rocksdb` on `-p 3308:3306`, role `ycsb`/`USyd2025` with `GRANT ALL ON *.*`. Endpoint + wrap in untracked `conf/db.mariadb_rocksdb.env`; **both that file and the example carry the caveat** that this image verifies the port and is not an evidence host — EC2 RocksDB evidence needs a server built `-DPLUGIN_ROCKSDB=YES` |
| `pre-refactor-scripts` tag | ✅ created 2026-09-24 | points at `03f96d44`, the last commit before step 0 — every legacy runner exactly as written. Since 8c this is the **only** copy of the deleted scripts (verified: all 14 deleted paths exist in the tag, incl. `experiment_sample.sh`, `benchmark_observability.py`, `docs/benchmark_observability.md`). `git worktree add ../pre-refactor pre-refactor-scripts` reproduces a full-visibility run |
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
DB_PWD=USyd2025 bash tests/smoke_backend.sh postgresql_textarray baseline   # the --mode baseline engine
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
| 5 | Engine + backend ports | ✅ **done** | **nine backends, all verified end-to-end:** engine drives only `backend::*`; PostgreSQL split into `_postgresql_common.sh` + `postgresql_textarray`/`postgresql_row`/`postgresql_json`/`postgrenosql`, MariaDB into `_mariadb_common.sh` + `mariadb_innodb`/`mariadb_rocksdb`, plus `mongodb`, `neo4j`, `couchbase` — each ported legacy script was a one-line shim during the migration (all of them, including the once-held `experiment_postgresql_array_json.sh`, deleted at 8c) and each backend is in `BACKEND_SMOKES` |
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ✅ done | `lib/lifecycle_baseline.sh` is a sequence of the shared steps (a unit test forbids it from re-implementing one); `run_experiment` dispatches on `EXPERIMENT_MODE`; nine legacy baseline runners deleted, their CSV headers kept as `tests/golden/legacy_csv_columns.txt`; goldens unchanged; baseline smoke PASS ×3 backends |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ✅ done | bundle = runner verbatim + inlined libs + per-backend loader functions (registry hooks `available`/`resolve`/`source_backend` overridden); `tests/test_bundle.sh` (19 assertions) + full benchmark through the bundle in `run_tests.sh`; deploy.sh overlay verified locally with remote-backup semantics; README rewritten around `experiment.sh` incl. `--mode baseline`; `.gitignore`: `__pycache__`/`*.pyc`/generated bundles/run-output dirs (no `.pyc` was tracked); `tests/test_logging.sh` deleted |
| 8a/8b | ~~`postgresql_json` backend · fullview instrumentation module~~ | ➖ folded/cancelled | 8a → step 5(b) **done** (`postgresql_json`, verified); 8b **cancelled** — WAL / `pg_stat_statements` / residency / prewarm / checkpoint-log / sampling / detoast probes are discarded (plan §4), and the `--instrument` placeholder is deleted from `experiment.sh` |
| 8c | Delete remaining shims/legacy scripts (+ `benchmark_observability.py`) | ✅ done | gate cleared (user confirmed the EC2 acceptance run). 13 legacy scripts + `docs/benchmark_observability.md` deleted; `registry::alias` and the config launcher-alias shim removed; READMEs rewritten; check_scripts tolerates nothing. Goldens byte-identical, full suite green |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked · ➖ cancelled/folded

## Where to resume

**The refactor is finished — steps 0–8c are all complete.** `experiment.sh <backend>` is the
only entry point; no legacy script, shim or alias survives (they exist only in the
`pre-refactor-scripts` tag). Work that remains is *outside* the plan and listed per item below;
the **Open questions** section is empty — every one was answered on 2026-09-24 and folded
into "Decisions and deviations still in force".

- **Step 8c (done, 2026-09-24).** Deleted: the nine `experiment_<backend>.sh` compatibility
  shims, `experiment_postgresql_array_json.sh`, `run_postgresql_array_json_full_visibility.sh`,
  `experiment_sample.sh`, `benchmark_observability.py`, and `docs/benchmark_observability.md`
  (its subject was deleted; the tag keeps it). Removed: `registry::alias` (+ its deprecation
  notice in `registry::resolve`, mirrored in the bundle override in `tools/bundle.sh`),
  `config::legacy_alias`/`apply_legacy_aliases`/`warn_discarded_legacy` (its own comment said
  "removed one release after the runbook is rewritten" — the EC2 acceptance ran on the rewritten
  runbook, so this was that release). `tools/check_scripts.sh` now requires every shell file to
  be clean. `tests/smoke_authoritative.sh` defaults to `experiment.sh postgresql_textarray`
  directly instead of via the deleted shim; alias tests became "removed aliases stay dead"
  assertions (tree and bundle). README §Legacy → historical pointer; conf/README.md documents
  canonical names only.
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
  and left `LEGACY_WITH_WARNINGS`; its `*_baseline` sibling was deleted with step 6.
- **Done: `--mode baseline` (step 6).** `run_experiment()` in `lib/lifecycle.sh` is now a dispatcher
  over `EXPERIMENT_MODE`, and the old single loop body is a set of named phase steps
  (`experiment_bootstrap`, `run_load_phase`, `run_reference_load_phase`, `run_extend_phase`,
  `merge_value_sizes`, `vacuum_if_enabled`, `snapshot_keys`/`remove_new_keys`,
  `run_measured_phase`, `run_reference_phase`, `run_comparison_phases`, `experiment_complete`).
  `lib/lifecycle_baseline.sh` sequences a subset of them; the unit test
  `baseline_engine_reuses_the_steps` fails if that file ever mentions `run_with_metrics`,
  `run_ycsb`, `write_result`, `$YCSB`, `collect_metrics`, `workload::generate` or `backend::`, which
  is the structural guarantee that the two modes cannot drift. `tests/smoke_backend.sh <backend>
  [mainline|baseline]` is mode-aware (phase list, CSV row/phase set, number of value-size files,
  forbidden phases, and — PostgreSQL only — that neither comparison database was created) and now
  asserts the **whole** CSV header prefix against `metrics::header`, so "same schema in both modes"
  is checked rather than assumed. Nine legacy `experiment_*_baseline.sh` deleted; their CSV headers
  live on as `tests/golden/legacy_csv_columns.txt`, read by the column-comparability test (the only
  reason those scripts were still load-bearing). `run_tests.sh` has a new step that runs the baseline
  smoke on the PostgreSQL server it already requires.

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
- ~~Backend names go through `registry::alias` …~~ **Gone at 8c:** backend names are exactly the
  files in `lib/backends/`; a test asserts that every pre-refactor spelling (`postgresql_array`,
  `jsonb`, `innodb`, …) neither resolves nor is advertised, in tree and bundle alike.
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
- Step 7 facts worth keeping: the bundle is generated into `experiment_scripts/experiment.bundle.sh`
  (gitignored; tests rebuild and remove it) and must **run inside `experiment_scripts/`** — it
  finds `../bin`, `conf/`, `workloads/` and `watcher.sh` relative to itself, so it updates harness
  code on an existing tree, never replaces the tree. `check_scripts.sh` excludes
  `experiment.bundle*.sh`. `registry.sh` gained exactly one indirection (`registry::source_backend`)
  and `experiment.sh --list-backends` now loads backends instead of grepping their files — both so
  the bundle overrides three registry functions and nothing else. `smoke_backend.sh` honours
  `RUNNER=<path>` (used to smoke the bundle). No instrumentation layer exists —
  plan §4 records why the array_json samplers are dropped rather than ported.

## Facts that save time

- **Two engines, one set of steps.** `run_experiment()` dispatches on `EXPERIMENT_MODE`
  (`mainline` | `baseline`); both engines call the same phase-step functions in
  `lib/lifecycle.sh`. A new phase is a new step function called by the engine(s) that run it —
  never a copied loop body (the forbidden duplication is asserted). A mode may only change: the
  phase sequence, `MODE_SUFFIX` (its artefact-name suffix, so modes cannot overwrite each other),
  which databases it creates, and whether preflight requires pg_dump.
- **Test-authoring gotcha in this repo's shell tests:** bash suppresses `errexit` inside an
  `if`/`&&`/`||` condition, and a subshell there inherits the suppression even if it re-enables
  `set -euo pipefail`, so `( set -e; f; printf … )` used as a condition keeps running after `f`
  fails and reports success. Helpers whose status is tested must write `f || exit 1`.
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
2. ~~Legacy scripts become one-line `exec` shims and stay until step 8c.~~ **Closed at 8c:**
   every shim and legacy script is deleted; the escape hatch is the `pre-refactor-scripts` tag.
3. **Local runs must pass `DB_PWD=USyd2025`**; the hardcoded `usyd2026` does not match this
   machine's server.
4. The legacy PG array baseline was already broken on PG 18 (`buffers_backend` removed from
   `pg_stat_bgwriter`). It is deleted with the rest of the `*_baseline.sh` family; `--mode
   baseline` collects the PG18 statistics set like every other PostgreSQL backend, so baseline
   and mainline rows stay comparable.
5. **array_json = schema only.** Its full-visibility observability is discarded, not
   deferred (plan §4): no instrumentation layer, no `instrument::*` contract, no engine hook
   points, and nothing may pass `jdbc.readsample.*` / `jdbc.slowread.*` to a binding. Do not
   re-open this by "temporarily" copying sampler code into core or a backend.
6. **`log()` logs everything** (user decision 2026-09-24, "widen"). The pre-refactor
   message-shape allow-list is gone — every `log()` call reaches the run log; verbosity is
   controlled at the call site, never by a filter future callers must know about. Goldens were
   re-captured for exactly this (+139 lines of verification rows, phase banners and
   backend-operation traces).
7. **couchbase's 22 / neo4j's 19 zero-valued statistics columns stay** (user decision
   2026-09-24). They exist for CSV comparability with the legacy headers; real counters go to
   the run log. Do not "fix" them into real counters — that changes the CSV schema and would
   require re-validating `../analysis_scripts/`.
8. **The YCSB `db.passwd=` echo in run logs is accepted** (user decision 2026-09-24). YCSB
   prints its `Command line:` banner, which includes the connection password; smoke goldens
   mask it at capture, real logs are not redacted. Treat run logs under `analysis/` as
   credential-bearing: do not commit them or paste them into tickets.

## Open questions for the user

**None.** All were answered on 2026-09-24; the outcomes are folded into "Decisions and
deviations still in force" items 6–8:

- ~~`log()` allow-list drops real progress lines.~~ **Resolved: widened** — `log()` now logs
  every call, goldens re-captured (see Log below).
- ~~Couchbase/neo4j zero statistics columns.~~ **Resolved: keep as-is** — CSV comparability
  wins; real counters stay in the run log; `../analysis_scripts/` needs no check.
- ~~Commit `conf/db.postgresql.env.example`?~~ **Resolved: already done** — every backend has
  a tracked `.example`, credentials live only in gitignored `conf/db.<backend>.env`.
- ~~Credential leak via YCSB's `Command line:` banner.~~ **Resolved: accepted** — goldens mask
  it; real run logs are treated as credential-bearing (decision 8).
- ~~EC2 acceptance run: who runs it, and against which instance? Step 8c is gated on it.~~
  **Resolved 2026-09-24: the user ran it and confirmed everything works as expected — step 8c
  shipped on that confirmation.** If the EC2 baseline evidence (first `--mode baseline` run) has
  not been captured there, that is an analysis task now, not a harness gate.
- ~~**`tests/test_logging.sh` is not a test.**~~ **Resolved at step 7: deleted.** It was a
  350-line pre-refactor experiment runner (hardcoded `DB_PWD="usyd2026"`) executed by nothing;
  recoverable from git if anyone disputes the call.

## Log

### 2026-09-24 — open questions all answered; `log()` widened, goldens re-captured

- User decisions: **widen** the log filter · **keep** couchbase/neo4j zero columns ·
  conf-example question closed as already-done · **accept** the YCSB `db.passwd` echo ·
  **leave** the branch unmerged. Recorded as decisions 6–8; the Open questions section is now
  empty.
- `lib/common.sh::log()` lost its message-shape allow-list: every call prints with the
  `[epoch run phase]` prefix. The filter was a pre-refactor habit that silently dropped real
  progress (`Initial-load verification - TotalSize:…`, workload-fieldlength lines, the
  `=== …phase ===` banners); with it gone, a new `log()` call can never be swallowed.
- Goldens re-captured (`smoke_authoritative.sh --update`): +139 lines each in run.out and
  results.markers — verification rows, phase banners, backend-operation START/END traces,
  CSV-write markers. Secret scan of the new goldens: only `db.passwd=<REDACTED>` (capture-time
  masking works). Re-run PASS (deterministic), then full `REQUIRE_DB=1` suite green:
  static checks · 58 + 19 shell tests · 7 python · authoritative goldens · baseline smoke ·
  bundle run · **all nine** backend smokes.

### 2026-09-24 — step 8c: legacy scripts, shims and aliases deleted → refactor complete

- **Gate cleared:** the user confirmed the EC2 acceptance run ("everything works as expected"),
  which is what REFACTOR_PLAN §8c waited for. The full-visibility provenance question is closed:
  existing evidence keeps its provenance via the `pre-refactor-scripts` tag, verified to contain
  all 14 deleted paths.
- **Deleted (git rm):** the nine `experiment_<backend>.sh` compatibility shims,
  `experiment_postgresql_array_json.sh`, `run_postgresql_array_json_full_visibility.sh`,
  `experiment_sample.sh`, `benchmark_observability.py` (last caller gone), and
  `docs/benchmark_observability.md` (documented only the deleted stack).
- **Alias layers removed:** `registry::alias` and the deprecation notice in
  `registry::resolve` (mirrored in the bundle's resolve override inside `tools/bundle.sh`), and
  the whole legacy launcher section of `lib/config.sh` (`config::legacy_alias`,
  `apply_legacy_aliases`, `warn_discarded_legacy`) plus their calls in `experiment.sh` — the
  section's own comment scheduled exactly this release ("one release after the runbook is
  rewritten", and the EC2 run used the rewritten runbook). The lowercase `vacuum=` name stays:
  it is an engine-internal global, not a launcher alias.
- **Tests:** alias tests inverted into "removed aliases stay dead" assertions; the bundle test
  asserts tree and bundle reject a removed name alike (stderr texts may differ — one lists
  available, the other bundled backends). `smoke_authoritative.sh` now defaults to
  `experiment.sh postgresql_textarray` instead of the deleted shim.
- **Docs:** README §Legacy → "Historical Scripts (deleted at refactor step 8c)"; the alias
  paragraphs in README/`--help`/conf/README/BUNDLE_README removed or rewritten to "canonical
  names only".
- `tools/check_scripts.sh`: the LEGACY_WITH_WARNINGS ratchet is retired — with the last
  pre-refactor script gone, every shell file must be shellcheck-clean (exclusions unchanged;
  `SHELLCHECK_STRICT=1` now additionally re-enables them).
- **Suite after the change:** static checks PASS · 58 config/workload + 19 bundle shell tests +
  7 python tests OK · `REQUIRE_DB=1 bash tests/run_tests.sh` → **all checks passed**:
  authoritative goldens byte-identical against the new direct target, baseline smoke PASS, full
  benchmark through the regenerated bundle PASS, structural smokes PASS for every backend whose
  server answered (PostgreSQL family on the system server; MariaDB ×2, MongoDB, Neo4j,
  Couchbase in containers).
- **Acceptance line count, honestly:** pre-refactor `experiment_*.sh` ≈ 16.8k → 0. Whole tree
  now 7.2k (runner+watcher 1.0k, core lib 1.4k, backends 3.2k, tests 1.1k, tools 0.4k) — over
  the original <5k estimate because that never counted the verification layer; ~5.7k without
  tests/tools. Recorded in REFACTOR_PLAN §10.

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

### 2026-09-24 — step 6: `--mode baseline`, one set of phase steps, nine legacy runners deleted

- **The engine was split before the second mode was added.** `run_experiment()` is a dispatcher on
  `EXPERIMENT_MODE`; its former 300-line body became named phase steps, and both engines are now
  sequences over them. That order matters: the split could be proven behaviour-preserving against
  the goldens (it is — `smoke_authoritative.sh` PASS with unchanged goldens), a copy of the loop for
  baseline never could.
- `lib/lifecycle_baseline.sh`: bootstrap(false, `$DB_NAME`) → load → (extend → vacuum → measure)
  × epochs×steps. It never mentions YCSB, metrics or the CSV — enforced by the unit test
  `baseline_engine_reuses_the_steps`, so a future edit cannot quietly fork the loop body again
  (that fork is exactly what the nine deleted scripts each were).
- Mode semantics worth remembering: artefact names gain `_baseline` (`MODE_SUFFIX` in
  `config::derive_paths`) so a baseline run cannot overwrite the mainline run it is compared with;
  `COMPARISON_INTERVAL` is forced to 0 rather than ignored; preflight runs without pg_dump because
  nothing is dumped; `$UNCHANGED_DB_NAME`/`$BACKUP_DB_NAME` are validated but never created —
  asserted by the smoke for PostgreSQL.
- **Deleted** `experiment_{couchbase,mariadb_innodb,mariadb_rocksdb,mongodb,neo4j,postgresql,
  postgresql_array,postgresql_array_json,sample}_baseline.sh` (nine; the plan said eight — it had
  not counted the sample pair). Their bodies are discarded per §0. Before deleting, their CSV
  headers were captured into `tests/golden/legacy_csv_columns.txt`: three backends (couchbase,
  mariadb_innodb, mongodb) had a column-comparability test that grepped those scripts, and without
  the capture step 6 would have silently weakened the very guarantee the refactor exists to keep.
- `tools/check_scripts.sh`'s legacy list drops from 11 files to 2 (`experiment_postgresql_array_json.sh`,
  `experiment_sample.sh`); `README.md`, `ycsb-ec2-bundle/README.md` and `BUNDLE_README.md` had
  commands naming deleted scripts and got one-line fixes now (full rewrite stays step 7).
- Suite after the change: static checks PASS · **63** shell + 7 python tests OK · authoritative
  smoke PASS vs unchanged goldens · baseline smoke PASS (postgresql_textarray 74 columns, mongodb
  22, mariadb_innodb 132 — each identical to that backend's mainline header) · all eight mainline
  backend smokes PASS.
- **Bash gotcha found while writing the mode test** (cost an hour, worth knowing in this codebase):
  `set -e` is suppressed inside the condition of `if`/`&&`/`||`, and a subshell started there
  inherits the suppression *even when it runs its own `set -euo pipefail`*. So in
  `( set -e; f; printf … )`, a failing `f` does not abort — the subshell prints and exits 0. In a
  test helper whose result is used as a condition, write `f || exit 1`.

### 2026-09-24 — step 7: bundle + deploy tooling, README rewrite, test-tree cleanup

- **`tools/bundle.sh`** generates `experiment.bundle.sh`: the runner body kept **verbatim**,
  with each `source "$LIB_DIR/x.sh"` line replaced by that file's content (order preserved),
  every selected backend wrapped in a `_bundle_load_<name>()` function, shared `_*.sh` modules
  embedded as `_bundle_module_<name>()` (their `source "$(…)/_x.sh"` lines rewritten to
  `_bundle::module` calls — any *other* source form fails generation rather than being dropped),
  and exactly three registry overrides (`available`, `resolve`, `source_backend`). Generation
  records UTC time + git commit (dirty flag), runs `bash -n`, and self-checks by loading every
  bundled backend through `--list-backends`.
- **Two core changes made that possible**, both behaviour-preserving: `registry::load` gained a
  one-line indirection (`registry::source_backend`), and `--list-backends` loads backends for
  their display name instead of sed-ing `lib/backends/*.sh` (no files inside a bundle).
- **`tools/deploy.sh`**: tarball of *tracked* `experiment_scripts/` files, extracted as an
  overlay on the target after a remote timestamped backup; untracked server files
  (`conf/db.*.env`, jars, `analysis/`) survive — verified locally by extracting over a fake
  tree. `--include-config` opts into shipping credentials; `--dry-run` prints the payload.
  Post-deploy verification on the target: `bash -n` + `--list-backends`.
- **CI for the bundle**: new `tests/test_bundle.sh` (19 assertions: generated header, no
  unrewritten source lines, all loaders present, byte-identical `--list-backends` and per-backend
  `--dry-run` vs the tree ×9, alias resolution, unknown-backend rejection, subset bundles).
  `run_tests.sh` additionally runs a **full structural smoke through the bundle**
  (`RUNNER=… tests/smoke_backend.sh`, new env override) whenever PostgreSQL is reachable.
- **README rewritten** around `experiment.sh`: Quick Start / Backends (aliases, PG≥18) / Host
  Requirements / Modes and Phases / Configuration / Options / Deploying to EC2 (deploy.sh primary,
  bundle single-file path) / Clean EC2 Run (launcher is pure env + one exec — no workload sedding) /
  Verify A Run / Output Layout / Stop-Restart / Tests. Full-visibility content reduced to a
  **frozen pointer** (§Legacy, deleted at 8c; history via the `pre-refactor-scripts` tag). The old
  §Deploy's scp-pair dance and launcher template are gone. `BUNDLE_README.md`'s experiment-script
  sections now describe the runner instead of per-database scripts.
- **Cleanup**: no `.pyc` was ever tracked (plan item pre-verified); root `.gitignore` gains
  `__pycache__/` + `*.pyc`; `experiment_scripts/.gitignore` gains generated bundles and the
  run-output directories (`javagc/ restore_logs/ stepdetail_logs/ vacuum_logs/`).
  **Deleted `tests/test_logging.sh`** (open question resolved: a 350-line pre-refactor runner
  with a hardcoded password that nothing executed).
- Suite after the change: static checks PASS · **19 bundle + 63 config/workload shell tests**
  + 7 python tests OK · authoritative smoke PASS vs unchanged goldens · baseline smoke PASS ·
  **bundle harness smoke PASS** (full mainline run through `experiment.bundle.sh`) · all eight
  mainline backend smokes PASS (PostgreSQL ×3 + postgrenosql on the system server, MariaDB ×2,
  MongoDB, Neo4j, Couchbase in containers).

### Next checkpoint

**No plan item is open.** Everything left is outside REFACTOR_PLAN and awaits user decisions or
follow-up work:

- Known open work (outside the plan, not scheduled): porting `watcher.sh`'s sampler away from
  `sudo -u postgres` (remote servers), and the optional Java-side removal of the now-dead
  `jdbc.readsample.*`/`jdbc.slowread.*` sampling in `jdbc-array-json`.
- Branch handling: user decided (2026-09-24) to **leave `refactor/experiment-scripts` as-is**
  — no merge to `master` for now.
