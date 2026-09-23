# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **steps 1–4 complete, plus the engine half of step 5** — one runner
(`experiment.sh <backend>`), a PostgreSQL backend module whose only interface is `backend::*`,
a layered config layer with a legacy-launcher alias shim, and **workload files are read-only
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
| shellcheck | ❌ not installed | CI check uses `bash -n` only until it can be installed |
| sudo | ❌ password required | cannot create PG roles or touch the server config; use the existing `ycsb` role |

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
```

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
| 5 | `lifecycle.sh` engine + backend ports (PG row -> postgrenosql -> mariadb x2 -> mongodb -> neo4j -> couchbase) | IN PROGRESS | **engine half done:** `lib/lifecycle.sh` drives only `backend::*`, the PostgreSQL legacy aliases are deleted, and a hygiene test fails if either regresses. Remaining backends cannot be verified on this machine (no servers). |
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ⬜ pending | |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ⬜ pending | |
| 8a | `postgresql_json` backend | ⬜ pending | |
| 8b | `lib/instrumentation/postgresql_fullview.sh` + `full_view` preset | ⬜ pending | decision: keep as optional instrumentation module |
| 8c | Delete remaining shims/legacy scripts | ⬜ pending | **gate:** only after user confirms on EC2 hardware |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked

## Where to resume

Steps 3, 4 and the engine half of step 5 are complete: `lib/lifecycle.sh` calls nothing but
`backend::*`, the PostgreSQL module's legacy aliases are gone, and the inline 34x value-size
SQL is replaced by `backend::key_sizes` / `total_size` / `list_keys`. Next up is **step 5b**:
port the remaining backends.

1. Step 5b: add backends one at a time (`postgresql_row` -> `postgrenosql` ->
   `mariadb_innodb` -> `mariadb_rocksdb` -> `mongodb` -> `neo4j` -> `couchbase`) and retire
   each legacy script as an `exec` shim; retarget `tests/test_postgresql_array_pg18.py`,
   which still points at `experiment_postgresql_array.sh`.
3. Steps 6-8: baseline mode, tooling/README rewrite, `postgresql_json` backend plus fullview
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
- `run_experiment()` in `lib/lifecycle.sh` still calls the legacy PG names (`pg_exec`,
  `collect_postgres_metrics`, `postgres_preflight`, `restore_comparison_database`,
  `wait_for_idle_postgres`, `initialize_database`, `close_db`) which the backend module defines.
- `backend::key_sizes`, `backend::total_size`, `backend::list_keys` and
  `backend::size_expression` exist but are **unused so far** - they replace the inline 34x
  size SQL once the engine is rewired.
- Run everything with `DB_PWD=USyd2025 REQUIRE_DB=1 bash tests/run_tests.sh`.

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

- Should `conf/db.postgresql.env` be committed as a template (`conf/db.postgresql.env.example`)
  with real credentials kept out of git? (Plan says credentials stay out of tracked files.)
- EC2 acceptance run: who runs it, and against which instance? Step 8c is gated on it.

## Log

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
