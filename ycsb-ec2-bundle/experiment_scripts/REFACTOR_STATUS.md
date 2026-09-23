# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **steps 1–4 complete; step 5 in progress (all PostgreSQL backends,
**mariadb_innodb, mongodb, neo4j and couchbase done, verified end-to-end)** — one runner
(`experiment.sh <backend>`), seven verified backends behind shared modules, an engine that calls
nothing but `backend::*`, a layered config layer with a legacy-launcher alias shim, and
**workload files are read-only templates** (one generated file per phase in the experiment
directory). Goldens unchanged apart from the intended `-P` paths. Only **mariadb_rocksdb** is left
in step 5, and it needs a MariaDB build with the RocksDB engine (absent from the stock image).

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
| shellcheck | ✅ installed (2026-09-24) | `tools/check_scripts.sh` now runs it: the harness (`lib/`, `experiment.sh`, `tests/`, `tools/`) must be clean, 12 legacy scripts warn without failing (list only shrinks; `SHELLCHECK_STRICT=1` fails on everything). SC2034/SC2154 are excluded globally because these scripts share globals across sourced files |
| sudo | ❌ password required | cannot create PG roles or touch the server config; use the existing `ycsb` role |
| podman | ✅ working, can pull images | found 2026-09-24: `podman run docker.io/library/mariadb:11` starts and answers on a published port (rootless). No docker, no local mariadb/mongo/neo4j/couchbase server binaries — containers are how the remaining backends can be smoke-tested here |
| MariaDB container | ✅ up, backend verified | `ycsb_mariadb` = `docker.io/library/mariadb:11` (server 11.8.9) published on `-p 3307:3306`, role `ycsb` with global CREATE/DROP; endpoint + container wrap live in the **untracked** `conf/db.mariadb_innodb.env`, example file added |
| MariaDB JDBC driver | ✅ present | `jdbc/target/dependency/mariadb-java-client-3.4.1.jar`; not part of the YCSB build, so preflight checks for it explicitly (`BACKEND_DRIVER_JAR`) |
| MongoDB container | ✅ up, backend verified | `ycsb_mongo` = `docker.io/library/mongo:5.0` on `-p 27017:27017`, no auth (like the legacy runners). No mongosh/mongodump/mongorestore on this host, so admin tools run through **`MONGO_CLI_WRAP=podman exec -i ycsb_mongo`** (tools 100.17 inside the image); endpoint + wrap in the untracked `conf/db.mongodb.env`, example file added. The `mongodb` binding is built and got a minimal `mongodb/conf/mongodb.properties` (it ships without a conf dir, but every YCSB invocation needs a properties file) |
| Neo4j containers | ✅ up, backend verified | three instances, because Neo4j Community has **one user database per instance** and the study's three roles are main/backup/unchange: `ycsb_neo4j_{main,backup,unchange}` = `docker.io/library/neo4j:5` (5.26.31) on `-p 7687/7787/7887`, role `neo4j`, APOC enabled with file import/export, heap capped (`512M`/`128M` pagecache, `--memory=1400m`) because the host has little free RAM. cypher-shell only exists inside them → `NEO4J_CLI_WRAP_<ROLE>=podman exec -i …` + `NEO4J_CLI_BOLT_URI=bolt://localhost:7687`. The clean-run copy needs a **shared import directory**: podman volume `ycsb_neo4j_import` mounted at `/var/lib/neo4j/import` in all three, with a world-writable `tmp/` inside (`podman exec ycsb_neo4j_main mkdir -p -m 777 /var/lib/neo4j/import/tmp`). Endpoint + wraps + the full `podman run` line in the untracked `conf/db.neo4j.env`, example file added. All three containers use password **USyd2025** so one `DB_PWD=… tests/run_tests.sh` covers every backend |
| Neo4j JDBC/Bolt driver | ✅ present | `neo4j/target/dependency/neo4j-java-driver-5.15.0.jar`, brought in by `mvn -o -pl site.ycsb:neo4j-binding -am package -DskipTests` (log `/tmp/mvn-neo4j.log`); the binding got a minimal `neo4j/conf/neo4j.properties` like mongodb |
| Couchbase container | ✅ up, backend verified | `ycsb_couchbase` = **`docker.io/library/couchbase:community-7.6.2`** (the official image is in the `library/` namespace; `couchbase/community-edition` does not exist and 401s). Started with `--net=host`, which is what makes the SDK work: the cluster advertises `127.0.0.1` instead of a container IP. Initialized with `couchbase-cli cluster-init --services data,index,query` (the image has no auto-setup script and `cluster-init` takes no quota arguments in 7.6). Three buckets (`ycsb`, `ycsb_backup`, `ycsb_unchange`, `bucketType=membase`, `flushEnabled=1`) plus one **local RBAC user per bucket named exactly like it** — SDK 2.x sends the bucket name as the username, so `openBucket(bucket, pw)` cannot authenticate otherwise. The runner creates missing buckets/users itself (`COUCHBASE_CREATE_MISSING_BUCKETS=1`), so a fresh cluster works; endpoint + credentials in the untracked `conf/db.couchbase.env`, example file added |
| Java SDK 2.3.1 vs Couchbase 7.6 | ✅ verified | `mvn -o -Psource-run -pl site.ycsb:couchbase2-binding -am package -DskipTests` builds it (`couchbase2/target/dependency/java-client-2.3.1.jar`); insert/read/**extend** through the couchbase2 binding against 7.6.2 all work, `couchbase.kv=false` (mutations via N1QL) included. The binding prefixes document ids with the table name, so keys are `usertable:user…` — that is also what `META().id` returns and what `USE KEYS` accepts (checked: a delete really removes the document) |
| Containers from earlier sessions | ⚠️ had to be recreated | this host kept no containers (`podman ps -a` was empty); mariadb/mongo/neo4j were restarted from the `podman run` lines documented in each untracked `conf/db.<backend>.env`, and **the MariaDB benchmark role needs more than CREATE/DROP** — the load phase inserts, so `GRANT ALL PRIVILEGES ON *.* TO 'ycsb'@'%'` (note added to that file) |

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
bash tests/smoke_backend.sh mongodb                 # needs the ycsb_mongo container, no DB_PWD
bash tests/smoke_backend.sh neo4j                   # needs the three ycsb_neo4j_* containers
bash tests/smoke_backend.sh couchbase               # needs the ycsb_couchbase container + conf/db.couchbase.env

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
| 5 | `lifecycle.sh` engine + backend ports (PG row -> postgrenosql -> mariadb x2 -> mongodb -> neo4j -> couchbase) | IN PROGRESS | **done:** engine drives only `backend::*`; PostgreSQL split into `_postgresql_common.sh` + `postgresql_textarray` / **`postgresql_row`** / **`postgrenosql`**, plus **`mariadb_innodb`** on `_mariadb_common.sh`, **`mongodb`**, **`neo4j`** and **`couchbase`** - all seven verified end-to-end; `experiment_postgresql.sh`, `experiment_postgresql_array.sh`, `experiment_postgrenosql.sh`, `experiment_mariadb_innodb.sh`, `experiment_mongodb.sh`, `experiment_neo4j.sh` and `experiment_couchbase.sh` are shims. **Remaining:** mariadb_rocksdb (the stock MariaDB image has no RocksDB engine - it needs a purpose-built image, or it stays unverified).
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ⬜ pending | |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ⬜ pending | |
| 8a | `postgresql_json` backend | ⬜ pending | |
| 8b | `lib/instrumentation/postgresql_fullview.sh` + `full_view` preset | ⬜ pending | decision: keep as optional instrumentation module |
| 8c | Delete remaining shims/legacy scripts | ⬜ pending | **gate:** only after user confirms on EC2 hardware |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked

## Where to resume

Seven backends are on the new architecture and pass an end-to-end run here: the engine calls
nothing but `backend::*`, the PostgreSQL specifics live in `lib/backends/_postgresql_common.sh`
plus one file per schema (`postgresql_textarray`, `postgresql_row`, `postgrenosql`) and the
MariaDB specifics in `lib/backends/_mariadb_common.sh` plus `mariadb_innodb`. Every ported
backend is listed in `BACKEND_SMOKES` in `tests/run_tests.sh`, which asks
`./experiment.sh <backend> --check` first - so an unrelated change does not need every server
in the world to be up, while `REQUIRE_DB=1` still fails when a *required* backend (the
PostgreSQL family) is unreachable.

Next: **mariadb_rocksdb** - the last script of step 5. It is a MariaDB variant, so
`_mariadb_common.sh` covers most of it, but the stock `docker.io/library/mariadb:11` image has no
RocksDB storage engine, so either a purpose-built image is found or the port ships unverified
(no shim, no deletion - same rule as before). Its legacy runner is still in
`LEGACY_WITH_WARNINGS`. Steps 6-8 after that.
All seven are in `BACKEND_SMOKES`, so any of them can be re-verified with
`bash tests/smoke_backend.sh <backend>` once its server answers.

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
3. Port one at a time: ~~postgrenosql~~ -> ~~mariadb_innodb~~ -> ~~mongodb~~ -> ~~neo4j~~ ->
   ~~couchbase~~ -> mariadb_rocksdb. A ported backend gets its module, its legacy script becomes a one-line
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
  `vacuum`, `wait_idle`, `dump_restore`, `close`, `parse_args`, `extra_binding_params`.
  Capabilities a backend declares in `backend::info` decide what the engine attempts at all
  (`supports_vacuum`, `supports_query_plan`, `has_dump_restore`, `runtime_watcher_dialect`,
  `host_os_user`, `min_server_version[_num]`).
- A binding that reads more than a connection is expressible without touching the engine:
  `backend::extra_binding_params` prints further `-p key=value` pairs (one per line) that
  `binding_db_params` appends to **every** YCSB invocation, and a `BINDING_PARAM_*` name set to
  the empty string means "this binding has no such property" (`config.sh` therefore uses
  `${VAR-default}`, not `${VAR:-default}`). couchbase2 is the first user of both: it needs
  host/adhoc/kv/boost/core-retries and reads no username, because SDK 2.x authenticates as the
  bucket itself. Empty for every other backend, which is why the goldens did not move.
- `backend::total_size`, `key_sizes`, `list_keys` are what the size/verification code calls
  now; a schema module only supplies `backend::size_expression`, which those helpers embed.
- Two engine-side operations were moved into the backend because their SQL is the whole point:
  logging a single-key query plan (`sample_key` + `explain_sql`) and deleting keys after a run
  (`delete_keys`). Both are gated on capabilities so a backend that cannot explain a plan just
  skips that step.
- Run everything with `DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh`.

## Findings during step 5 (couchbase, and what an HTTP-only backend needs)

1. **No CLI wrap.** couchbase.sh is the first backend whose admin interface is HTTP: management
   through `curl` on 8091 and N1QL on 8093. Unlike neo4j/mongodb there is nothing to run inside
   the server's container, so a remote or containerised cluster needs configuration only - and
   the two failure modes are an HTTP status (`COUCHBASE_HTTP_STATUS`, set by `couchbase::rest`)
   and a N1QL `errors[]` entry, both of which are logged without credentials.
2. **A bucket name is an authentication identity.** SDK 2.x has no username property, so every
   bucket needs a local RBAC user named exactly like it. `backend::init_db` creates the bucket
   *and* that user when they are missing (`COUCHBASE_CREATE_MISSING_BUCKETS=1`, default), and
   preflight probes the credential the **binding** will use (write+delete of one probe document,
   via `UPSERT` so an interrupted run cannot leave a duplicate-key failure behind). Setting it to
   0 restores "provision three buckets and three users beforehand", which is what the EC2 hosts
   did; then preflight fails instead of writing anything.
3. **N1QL is eventually consistent, so `status: success` proves nothing twice over.** An
   `INSERT ... SELECT` whose SELECT matches no row succeeds, and reading a count right after a
   write can return a stale number (measured: 19 documents copied, first read said 12). Both the
   copy to the comparison bucket and every flush therefore *poll* until the counts agree
   (`CONSISTENCY_TIMEOUT_SEC`), which is also what `backend::wait_empty` is for. The legacy
   runner checked neither.
4. **Two N1QL syntax traps hit while writing this:** `INSERT INTO b (KEY "k", VALUE {...})` is a
   syntax error - only the SELECT variant takes that form, `VALUES` needs
   `(KEY, VALUE) VALUES (...)`; and an object literal must not be parenthesised.
5. **Keys are prefixed with the table name** (`formatId(table, key)` → `usertable:user…`). That
   is what `META().id` returns and what `DELETE … USE KEYS [...]` accepts - verified by counting
   documents after a measured phase, so unlike the neo4j quoting bug the cleanup really deletes.
   `backend::delete_keys` batches (default 500 keys per statement) instead of sending one
   statement per run phase like the legacy script.
6. **The statistics columns are 22 literal zeros**, kept in the legacy order because that is what
   Couchbase has no equivalent of; a new test asserts them against
   `experiment_couchbase_baseline.sh`'s header for every backend whose legacy script is still in
   the tree (couchbase, mariadb_innodb, mongodb). Real bucket counters (itemCount/disk/data/RAM)
   go to the run log instead of the CSV.
7. **Deliberate deviation from the legacy runner:** no `insertstart`/`recordcount` rewriting when
   a bucket cannot be flushed - shifting the key range changes what is measured, so the fallback
   is `DELETE FROM <bucket>` and, failing that, an error.

## Findings during step 5 (harness fixes found by the couchbase port)

1. **"`../workloads` must stay clean" was a whole-tree assertion**: both smoke scripts failed on
   *any* untracked file there, so leftovers of earlier manual runs (`workloads/workloada-extend-small`
   is one, and `git status` also shows stray `*.osstats`/`key_sizes_*.csv` output in
   `experiment_scripts/`) turned a green run red. They now snapshot the untracked list before the
   run and compare after, which is what "this run created nothing" actually means.
2. `tests/smoke_backend.sh` still cannot tell a *skipped* cleanup from a working one for non-
   PostgreSQL dialects - unchanged here, but note that couchbase adds nothing: its buckets are
   emptied by the runner itself in `init_db`.

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
7. **Neo4j's statistics columns are as honest as the legacy ones, no more:** only four of the 19
   have a server-side source (`SHOW TRANSACTIONS`, `db.stats.retrieve('GRAPH COUNTS')`,
   `SHOW INDEXES` read counts, commit/rollback of currently visible transactions), and
   `GRAPH COUNTS` counts store entries, so `nodes_created` does not go down when nodes are deleted
   - that is the legacy query's behaviour, kept deliberately. What the phases really did is in the
   value-size files.
8. **A role name may be a whole server.** Every admin contract call receives the role
   (`backend::key_sizes "$BACKUP_DB_NAME"`, …), which for PostgreSQL/MariaDB/MongoDB selects a
   database and for neo4j selects an instance. That is why no engine code needed to change when a
   backend with three endpoints joined.

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

- **Couchbase's 22 statistics columns are literal zeros** (`blks_read` … `wal_buffers_full`), kept
  from the legacy runner so its CSV stays comparable. They carry no information and their names
  belong to another database. Options: keep as-is (comparable, honest about nothing), or replace
  them with real Couchbase counters (`itemCount`, `diskUsed`, `dataUsed`, `memUsed`, ops/sec from
  the bucket REST API) which changes that backend's CSV schema and would need the analysis scripts
  checked. Currently kept, with the real numbers logged per phase instead. Same question applies
  to neo4j's mostly-zero 19 columns - decide once, for both.

- Should `conf/db.postgresql.env` be committed as a template (`conf/db.postgresql.env.example`)
  with real credentials kept out of git? (Plan says credentials stay out of tracked files.)
- EC2 acceptance run: who runs it, and against which instance? Step 8c is gated on it.

## Log

### 2026-09-23 — step 5b: couchbase backend (verified end-to-end)

- `lib/backends/couchbase.sh` (management REST + N1QL helpers, bucket/user provisioning, preflight,
  copy, size helpers, contract) + `conf/db.couchbase.env.example` + a minimal
  `couchbase2/conf/couchbase.properties` (deliberately assigning nothing - every value the runner
  controls is passed with `-p`, so it shows up in the YCSB banner). `experiment_couchbase.sh` is a
  one-line shim and left `LEGACY_WITH_WARNINGS` (12 legacy scripts remain); `couchbase` joined
  `BACKEND_SMOKES`. Verified against **Couchbase Community 7.6.2** in podman: value size grows
  200000 → 230000 across extend, the reference bucket stays at 200000, the comparison copy reports
  the same 230000 and the average-field-length reload lands back on 230000; each of the three
  buckets holds exactly `recordcount` documents when the run ends, i.e. the inserted keys really
  were removed. Results CSV: 44 columns = base + CPU/Memory + the legacy 22 statistics columns.
- **Environment:** `docker.io/library/couchbase:community-7.6.2` (there is no
  `couchbase/community-edition` repository - it 401s), `--net=host` so the cluster advertises
  `127.0.0.1`, `cluster-init --services data,index,query`, three buckets with flush enabled and
  one local RBAC user per bucket. Java client 2.3.1 talks to server 7.6 without changes, insert,
  read and extend all through the couchbase2 binding with `couchbase.kv=false`.
- **New contract points** (engine + config, both no-ops for every other backend):
  `backend::extra_binding_params` appends further `-p` properties to each YCSB invocation, and an
  empty `BINDING_PARAM_USER` means the binding has no username property. See "Facts that save
  time".
- **Deviations from the legacy runner** (all in the module header): no insertstart/recordcount
  shifting when flush is refused (DELETE FROM instead, then error); one bucket password for all
  three roles, because `binding_db_params` sends exactly one per phase and the legacy defaults
  were all equal; the comparison copy is verified by document count; buckets/users may be created
  by the runner unless `COUCHBASE_CREATE_MISSING_BUCKETS=0`.
- **Bug class found by running it:** N1QL reports success for a copy that transferred nothing, and
  counts read back can lag behind writes - so both the flush and the copy poll until they agree.
  The legacy script trusted `status: success` alone.
- Also fixed while testing: both smoke suites treated *any* untracked file under `../workloads` as
  a failure, which made them red because of leftovers from earlier manual runs; they now compare
  before/after (see the findings section).
- Suite: static checks PASS (12 legacy warnings) - 41 shell + 7 python tests OK (the new guard
  compares three backends' statistics columns with their legacy headers) - authoritative smoke PASS
  against unchanged goldens - **all six** structural smokes PASS (`postgresql_row`,
  `postgrenosql`, `mariadb_innodb`, `mongodb`, `neo4j`, `couchbase`) with
  `DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh`.


### 2026-09-23 — step 5b: neo4j backend (verified end-to-end)

- `lib/backends/neo4j.sh` + `conf/db.neo4j.env.example` + a minimal `neo4j/conf/neo4j.properties`
  (like mongodb, the binding ships without a conf directory but every YCSB invocation is given
  one). `experiment_neo4j.sh` is a one-line shim and left `LEGACY_WITH_WARNINGS` (13 remain);
  `neo4j` joined `BACKEND_SMOKES`. Verified end to end against three Neo4j 5.26.31 containers:
  value size grows 200000 -> 230000 across extend, the reference instance stays at 200000, the
  graphml copy reports the same 230000, and the comparison reload at the average field length
  lands back on 230000; results CSV has the legacy 19 statistics columns (41 in total).
- **One instance per role.** Neo4j Community has a single user database, so the three roles are
  three Bolt endpoints (`NEO4J_PORT_MAIN/_BACKUP/_UNCHANGE`, or three `NEO4J_BOLT_URI_*`), which
  is what the EC2 hosts ran as `/opt/neo4j-instance-*`. Preflight connects to all three and fails
  if two roles share an instance - silently comparing a database with itself is worse than failing.
- **New contract point:** the connection property *names* are configured, not just their prefix.
  The neo4j binding reads `url`/`username`/`password` with no `db.` prefix at all, so
  `BINDING_PARAM_URL/USER/PASSWD` (defaulting to `${BINDING_PARAM_PREFIX}.…`) replace the single
  prefix in `binding_db_params`. PostgreNoSQL and the JDBC bindings are unchanged.
- **Bug found by running it: cypher-shell quotes every returned value.** The legacy runners piped
  key listings straight into files and then into a `jq`-built Cypher list, so each key arrived as
  `"user…"` and `MATCH (n:usertable {id: k})` matched nothing - the "delete the keys inserted
  during the run" step deleted **nothing**, on every legacy run. Keys and sizes are now returned as
  one joined column and unquoted; checked after a measured phase with inserts: both instances hold
  exactly `recordcount` nodes again.
- **Second bug found (in this port's own code):** `if ! out=$(…); then rc=$?` captures the status
  of `!`, i.e. always 0, so an authentication failure was logged as `status=0`. Now `out=$(…) || rc=$?`.
- **Reset is a delete, not a restart.** The legacy script stopped each instance, removed its data
  directory and re-ran `neo4j-admin dbms set-initial-password`; a benchmark role can do none of
  that, so an instance is cleared with batched `DETACH DELETE` (APOC `periodic.iterate`) and the
  uniqueness constraint is recreated idempotently wherever an instance is prepared.
- **Comparison copy stays APOC graphml**, but paths are relative to each *instance's* import
  directory, so those must be shared (one podman volume in all three here). Where they cannot be -
  the EC2 hosts had one per instance - `NEO4J_BACKUP_COPY_CMD` with `{src}`/`{dst}` moves it; that
  path replaces the legacy hardcoded `sudo cp` + `sudo chown neo4j:neo4j`. Import is verified by
  node count and by re-labelling every restored node (graphml does not restore `:usertable`).
- **Test-harness fixes found by this port:** `tests/smoke_backend.sh` exported an empty `DB_PWD`,
  which claims the environment layer and silently beat `conf/db.<backend>.env` - it now only
  exports a password that was actually given. Its database-side error grep only knew JDBC wording,
  so it also catches the neo4j binding's `Error updating Neo4j: …` style lines, and a new generic
  assertion fails if any results row carries a non-zero `Return=ERROR` (verified both ways).
  `conf/README.md` documents that unquoted values keep a trailing `# …` verbatim - the local
  neo4j env file hit exactly that.
- Suite: static checks PASS (13 legacy warnings) - 39 shell + 7 python tests OK (the backend
  contract test picks up new backends by itself) - authoritative
  smoke PASS against unchanged goldens - postgresql_row, postgrenosql, mariadb_innodb, mongodb and
  neo4j structural smokes PASS (`DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh`).

### 2026-09-24 — step 5b: mongodb backend (verified end-to-end)

- `lib/backends/mongodb.sh` (admin CLI wrapper, preflight, dump/restore, size helpers, contract)
  + `conf/db.mongodb.env.example` + a minimal `mongodb/conf/mongodb.properties` (the mongodb
  binding ships without a conf directory, but the harness passes one properties file to every
  YCSB invocation). `experiment_mongodb.sh` is a one-line shim and left `LEGACY_WITH_WARNINGS`
  (14 legacy scripts remain); `mongodb` joined `BACKEND_SMOKES`.
- **No statistics columns**, exactly like the legacy header: `backend::metric_names` is empty,
  so the results CSV has the 22 base columns. CPU/Memory sample `HOST_OS_USER=mongod`, or report
  0 when the server is a container and there is no local process to sample.
- **Comparison database on the same server.** The legacy runner needed a second mongod on 28018
  and restored into a database of the same name; here `mongodump --archive | mongorestore
  --nsFrom/--nsTo` keeps `ycsb_backup` apart from `ycsb`. Two silent failures found by running
  it: (a) giving mongorestore a **database in `--uri`** makes it filter namespaces to that name,
  so a target-named URI restores *0 documents and exits 0* - the restore URI must be server-only
  (`MONGO_SERVER_URL`); (b) "nothing matched the rename" is not an error either, so the
  source/target document-count comparison is what actually catches it (plus a non-empty-archive
  check).
- Two connection knobs the engine used to hardcode are now backend configuration:
  `BINDING_PARAM_CREDENTIALS=0` (the mongodb binding has no user/password properties - the URI
  carries everything) next to the existing `BINDING_PARAM_PREFIX=mongodb`.
- **Test-harness fix found by this port:** `tests/smoke_backend.sh` pre-cleaned its databases
  with `dropdb`/`PGPASSWORD` whenever a psql client was on `PATH` - for MongoDB that meant three
  connections to the postgres port hanging on a password prompt (and, if a PostgreSQL server *is*
  reachable, dropping unrelated databases). It now asks the backend's own
  `runtime_watcher_dialect` via `lib/registry.sh` and only cleans up for `postgresql`.
- Verified: value size grows 233576 -> 263576 across extend, the restored comparison database
  reports the same 263576, the average-field-length reload lands at 295576; no database-side
  error lines in the run log. Suite: static checks PASS (14 legacy warnings) - 38 shell + 7
  python tests OK - authoritative smoke PASS against unchanged goldens - postgresql_row,
  postgrenosql, mariadb_innodb and mongodb structural smokes PASS.

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
