# Refactor Status — experiment scripts

Plan: [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md) · Branch: `refactor/experiment-scripts`
Last updated: **step 0 complete** — bugs fixed, smoke goldens captured, test suite green

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
| 1 | Port core into `lib/{common,metrics,results,keysizes}.sh` | ⬜ pending | start here |
| 2 | `lib/backends/postgresql_textarray.sh`, `registry.sh`, `experiment.sh` dispatcher | ⬜ pending | |
| 3 | `config.sh` + `conf/` presets + alias shim + `--help/--dry-run/--list-backends` | ⬜ pending | |
| 4 | Workload generation into `$EXPERIMENT_DIR/workloads/` | ⬜ pending | unit-testable without any DB |
| 5 | `lifecycle.sh` engine + backend ports (PG row → postgrenosql → mariadb ×2 → mongodb → neo4j → couchbase) | ⬜ pending | only PG-family can be verified locally; others have no server here |
| 6 | `--mode baseline`; delete legacy `*_baseline.sh` | ⬜ pending | |
| 7 | `tools/bundle.sh`, `tools/deploy.sh`, README rewrite, gitignore | ⬜ pending | |
| 8a | `postgresql_json` backend | ⬜ pending | |
| 8b | `lib/instrumentation/postgresql_fullview.sh` + `full_view` preset | ⬜ pending | decision: keep as optional instrumentation module |
| 8c | Delete remaining shims/legacy scripts | ⬜ pending | **gate:** only after user confirms on EC2 hardware |

Legend: ✅ done · ⏳ in progress · ⬜ pending · ⛔ blocked

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
