# Experiment Scripts Refactoring Plan

Target: replace ~16.8k lines of copy-pasted experiment scripts with **one runner**
(`experiment.sh <backend>`), a small core library, one module per database backend,
and config files for parameters.

Authoritative specification: `experiment_postgresql_array-text-autovacuum.sh`.

> **Decision (supersedes the earlier "instrumentation module" design):** the extra
> observability in `experiment_postgresql_array_json.sh` is **discarded, not ported**
> (§4). Only its *jsonb schema* becomes a backend — `postgresql_json` — running the same
> phase loop, watcher and CSV pipeline as the other PostgreSQL backends. That work moved
> from step 8 into **step 5 tail (b)**; steps 8a/8b are gone.

**Status: steps 0–6 complete** — nine backends verified end-to-end (`postgresql_textarray`,
`postgresql_row`, `postgresql_json`, `postgrenosql`, `mariadb_innodb`, `mariadb_rocksdb`,
`mongodb`, `neo4j`, `couchbase`) and two phase sequences (`mainline`, `--mode baseline`) on one
set of phase steps. Of step 5 only the array_json shim remains, **held for 8c**.
This file now carries only what the **remaining work** (§8) needs — the original
duplication analysis, migration rows for completed steps, and the §10 bug list (all fixed
in step 0) were trimmed; full detail lives in git history (`git log -- REFACTOR_PLAN.md`).
Operational state: [`REFACTOR_STATUS.md`](./REFACTOR_STATUS.md).

---

## 0. Governing rule (still binds all remaining ports)

`experiment_postgresql_array-text-autovacuum.sh` is the **specification** for everything
that is not backend-specific: phase sequence and names, logging/traps/`EXECUTION_ID`,
CSV base columns + header evolution, key-size dump/histogram/append pipeline, idle waits,
comparison-database dump/restore + row-count verification, directory layout, preflight.

When porting anything that is left (the step 7 tooling, and anything an EC2 run uncovers at
8c), classify each difference:

| Category | Action | Examples |
| --- | --- | --- |
| **Backend detail** | Keep, in `lib/backends/<backend>.sh` | CLI/JDBC invocation; schema DDL; size expressions; dump/restore mechanics; index-readiness waits (couchbase); binding name and `-p` overrides; capability flags |
| **Non-backend deviation** | **Discard silently** | shorter metric sets in other scripts; `../analysis/Data/…` paths; their own `write_result`/`log` variants; `DIST`/`WORK` naming; the legacy `*_baseline.sh` loop bodies |
| **Extra observability** | **Discard** (§4) | array_json WAL / `pg_stat_statements` / buffer residency / `pg_prewarm` / checkpoint-log capture / read sampling / detoast probes |

No feature is merged into the core engine just because some other script had it.

---

## 1. Original state (condensed)

21 `experiment_*.sh` + helpers, ~16,800 shell lines: 14 variants of `write_result`, two
loop families (6-phase mainline, 2-phase baseline), 22 in-place workload rewrites per run,
15 hardcoded passwords, ~77% fork drift between sibling scripts. Resolved by steps 0–5;
see git history for the measured tables.

---

## 2. Target architecture (markers: ✅ built · ⬜ still to build)

```
experiment_scripts/
├── experiment.sh              # ✅ THE ONLY runner: ./experiment.sh <backend> [preset] [options]
├── lib/
│   ├── common.sh config.sh registry.sh workload.sh metrics.sh results.sh
│   ├── keysizes.sh watcher_runner.sh lifecycle.sh          # ✅
│   ├── lifecycle_baseline.sh                                # ✅ step 6 (`--mode baseline`)
│   └── backends/            # ✅ postgresql_textarray/_row/json/postgrenosql,
│                            #    mariadb_innodb/mariadb_rocksdb, mongodb, neo4j, couchbase
│                            #    (+ _postgresql_common, _mariadb_common) — all nine ported
├── conf/                    # ✅ db.<backend>.env (0600, gitignored), scale.{heavy,light}.env
├── tools/
│   ├── check_scripts.sh     # ✅ shellcheck ratchet (legacy list only shrinks)
│   ├── bundle.sh            # ⬜ step 7: inline lib + selected backends into one scp-able file
│   └── deploy.sh            # ⬜ step 7: tar the directory to EC2
└── tests/                   # ✅ run_tests.sh, smoke_authoritative.sh + goldens,
                             #    smoke_backend.sh, contract/config tests
```

**End state: 1 runner, ~9 backend modules, 0 duplicated engines, no instrumentation layer.**
All legacy `experiment_*.sh` and `run_postgresql_array_json_full_visibility.sh` deleted at
step 8c.

---

## 3. Backend contract (as implemented — the porting reference)

Each `lib/backends/<name>.sh` implements; `registry.sh` supplies no-op defaults for
optional hooks and `assert_backend_contract` fails fast on missing mandatory ones.

- **Mandatory:** `backend::info` `default_config` `preflight` `init_db` `collect_metrics`
  `key_sizes` `total_size` `list_keys` `sample_key` `explain_sql` `delete_keys` `truncate`
- **Optional (no-op defaults):** `vacuum` `wait_idle` `dump_restore` `close` `parse_args`
  `extra_binding_params`
- **Capabilities declared in `backend::info`** decide what the engine attempts:
  `supports_vacuum`, `supports_query_plan`, `has_dump_restore`, `runtime_watcher_dialect`,
  `host_os_user`, `min_server_version[_num]`. Engines branch only on these facts — never
  on backend or module names.
- Statistics columns belong to the backend (`backend::metric_names`); the CSV **base**
  columns are fixed by the authoritative script.
- Connection properties: `BINDING_PARAM_PREFIX` (default `db`) and/or explicit
  `BINDING_PARAM_URL/USER/PASSWD` names; an empty value means "this binding has no such
  property"; `backend::extra_binding_params` adds further `-p k=v` pairs per invocation.
- A role argument may select a whole server (neo4j): every admin hook receives the role.
- Schema modules sharing a database family source `_postgresql_common.sh` /
  `_mariadb_common.sh` and override only `info`, `init_db` (DDL), `size_expression`,
  `default_config`. Registry skips `_`-prefixed files.

---

## 4. Extra observability — dropped (was: the full-visibility module)

`experiment_postgresql_array_json.sh` is 3,557 lines, of which ~2.7k are observability the
other backends never had. **None of it is ported.** Reasons, once, so it is not
re-litigated:

- It needs powers the backend contract deliberately does not grant: a **second database
  identity** (`PG_EXTENSION_USERNAME/PWD`) to run `ALTER SYSTEM`/`CREATE EXTENSION`, and
  **server-host access** — it reads `pg_current_logfile`, `data_directory`, `log_directory`
  to scrape checkpoint messages out of the server log.
- It requires server configuration a benchmark runner should not own
  (`shared_preload_libraries=pg_stat_statements`, `track_io_timing=on`, `log_checkpoints=on`,
  4 extensions in every database, `pg_walinspect` execute privilege) and hard-fails
  (`require_full_visibility_ready`) when any of it is missing.
- Part of it is **client-side**, not server-side: read/slow-read sampling passes
  `jdbc.readsample.*` / `jdbc.slowread.*` properties understood only by the forked
  `jdbc-array-json` client, so that capability belongs to a Java binding rather than a
  backend — a third axis the architecture has no place for.
- Its engine had drifted from the authoritative spec (own supervision/heartbeat/redaction,
  own `run_with_metrics`, samplers keyed to `operationcount` percentiles). Merging that into
  core would violate §0; keeping it out of core means a module forks the engine again.

**Discarded outright** (no replacement, no flag, no hook):
`benchrun_*` process supervision / heartbeat / stream redaction, spike-trigger tracing
(`SPIKE_TRIGGER_*`, 92 references), WAL boundary + `pg_get_wal_stats` capture,
`pg_stat_statements` reset/collect, buffer residency / page identity / freespace snapshots,
the `pg_prewarm` intervention and its mode matrix, checkpoint-log setting/message capture,
vacuum-progress and run-buffer-progress samplers, read/slow-read sampling arguments,
detoast probes (incl. the element-count probe), `require_full_visibility_ready`,
`ensure_pg_*_extension`, and the `VALUE_VARIANT` switch — jsonb_array / text_array /
text_scalar are three separate backends: `postgresql_json`, `postgresql_textarray`,
`postgresql_row`.

**Consequences, accepted:** full-visibility runs are no longer reproducible after 8c (they
stay reproducible from the `pre-refactor-scripts` tag); `benchmark_observability.py` loses
its last caller and is deleted at 8c; the read/slow-read sampling code in
`jdbc-array-json/.../JdbcDBClient.java` becomes dead — removing it is an optional, separate
Java-side follow-up, but nothing in the harness may pass those properties.

---

## 5. Entrypoint — what is still missing

Implemented: dispatch, `--config/--var/--epochs/--steps/--run-id/--type/--scale/
--workload/--experiment-dir/--dry-run/--list-backends/--check/-h`, and the backend-name aliases
in `registry::alias` — `postgresql_array→postgresql_textarray`,
`jsonb|array_json|arrayjson|postgresql_array_json→postgresql_json`,
`postgresql→postgresql_row`, `innodb→mariadb_innodb`, `rocksdb→mariadb_rocksdb` (notice on
stderr, because `registry::resolve` prints the path on stdout; deleted with the legacy scripts at
8c). `--instrument` is **gone**, not reserved: with §4 dropping the instrumentation layer it is an
unknown option again.

`--mode NAME` is implemented (step 6): `mainline` (default) or `baseline`, validated in
`config::init_defaults` so an environment/`--var` setting is rejected too, and reported by
`--dry-run` together with the phase sequence it will run. A baseline run creates only `$DB_NAME`,
skips pg_dump in preflight and gains a `_baseline` artefact suffix; see §8 row 6.

Backend-specific flags are declared in `backend::info` and consumed by `backend::parse_args`;
core rejects unknown flags first.

---

## 6–7. Config and workload files (done — constraints that persist)

- Precedence: defaults → parsed `conf/db.<backend>.env` → preset (`--config`) → process
  env → CLI. Config files are **parsed, not executed**. Alias shim keeps legacy launcher
  names alive. Credentials only in gitignored `conf/*.env` or the environment.
- Workload templates are **read-only**; every YCSB invocation uses an immutable,
  provenance-tagged file generated under `$EXPERIMENT_DIR/workloads/`. Zero writes to
  `workloads/` is asserted by the smoke suite. Feedback values (e.g.
  `fieldlengthaverage`) go through overlays, not file edits.

---

## 8. Remaining migration steps (each independently shippable)

| # | Work | Verification |
| --- | --- | --- |
| ~~**5 tail (a)**~~ **done** | `mariadb_rocksdb` backend on `_mariadb_common.sh`. No official MariaDB image has the RocksDB engine; verified against `docker.io/devonkupiec/mariadb-rocksdb` (MariaDB 10.3 + MyRocks), which is documented in `conf/db.mariadb_rocksdb.env(.example)` as a verification server and **not** an evidence host. Statistics come from `SHOW GLOBAL STATUS 'Rocksdb%'` + `information_schema.ROCKSDB_CFSTATS/DBSTATS/SST_PROPS`; the legacy `sudo du` of the engine's data directory is gone, `lsm_levels` reports 0 on engines without a per-level view. | Structural smoke PASS (8 phases, dump/restore verified, 6 rows × 57 columns, non-zero compaction/WAL/stall counters); in `BACKEND_SMOKES`, not required (special image) |
| ~~**5 tail (b)**~~ **done** | `postgresql_json` backend = **only the jsonb data model** of `experiment_postgresql_array_json.sh`, on `_postgresql_common.sh`: DDL `fieldN JSONB`; `backend::size_expression` = Σ over the 10 fields of `COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(fieldN, '[]'::jsonb))), 0)`; `default_binding=jdbc-array-json`, artifact `jdbc-array-json/target/*.jar`, capability flags copied from `postgresql_textarray`, `postgresql::base_config` defaults. **Everything else in that script is discarded per §4** — phase loop, watcher, statistics columns, key-size/histogram pipeline and CSV all come from core exactly as for `postgresql_textarray`. Also done: deleted the reserved `--instrument` branch in `experiment.sh` and rewrote the stale deferral text in `lib/config.sh` (`config::warn_discarded_legacy`). **Held:** the one-line shim mapping `VALUE_VARIANT` → backend (jsonb_array→`postgresql_json`, text_array→`postgresql_textarray`, text_scalar→`postgresql_row`), because `run_postgresql_array_json_full_visibility.sh` execs that script and shimming it deletes full visibility before this plan's own 8c EC2 gate — see REFACTOR_STATUS "Open questions". | Standard smoke goldens PASS; in `BACKEND_SMOKES` **and** `REQUIRED_BACKEND_SMOKES`; `./experiment.sh postgresql_json --check` PASS; structural smoke PASS (8 phases, 74-column CSV) |
| ~~**6**~~ **done** | Baseline mode. `lib/lifecycle_baseline.sh` is a *sequence of the shared phase steps* from `lib/lifecycle.sh`, not a second loop: `run_experiment` became a mode dispatcher and its body was split into `experiment_bootstrap`, `run_load_phase`, `run_reference_load_phase`, `run_extend_phase`, `merge_value_sizes`, `vacuum_if_enabled`, `snapshot_keys`/`remove_new_keys`, `run_measured_phase`, `run_reference_phase`, `run_comparison_phases`, `experiment_complete`; the baseline engine calls bootstrap(false, `$DB_NAME`) → load → (extend → vacuum → measure) × epochs×steps. A unit test fails if that file ever invokes YCSB, samples metrics or writes a row itself. Legacy `*_baseline.sh` bodies discarded per §0 — **nine** files deleted (`experiment_{couchbase,mariadb_innodb,mariadb_rocksdb,mongodb,neo4j,postgresql,postgresql_array,postgresql_array_json,sample}_baseline.sh`; their legacy CSV headers were first captured as data in `tests/golden/legacy_csv_columns.txt`, which is what the column-comparability test now reads). Config layer: `EXPERIMENT_MODE` (validated, `_baseline` artefact suffix, `COMPARISON_INTERVAL=0`); preflight of a baseline run does not require pg_dump. | Goldens byte-identical after the split; `tests/smoke_backend.sh <backend> baseline` PASS for postgresql_textarray (+ mongodb, mariadb_innodb): 3 phases, the 5 forbidden phases absent, neither comparison database created, CSV header asserted **exactly** equal to the base columns with `metrics::header` spliced in (74/22/132 columns — identical to each backend's mainline schema), one row per measured phase |
| **7** | Ops: `tools/bundle.sh` (inline lib + selected backends into one `experiment.bundle.sh`, preserving the single-file scp deploy at `README.md:344-390`), `tools/deploy.sh` (tar to EC2), README rewrite (§Deploy / Clean EC2 Run / Launcher / Verify / Output Layout), `.gitignore` for `.DS_Store`/`__pycache__`, remove committed `.pyc`. | Fresh-EC2 dry run executed strictly from the rewritten runbook; bundle smoke-tested in CI |
| **8a/8b** | ~~`postgresql_json` backend · full-visibility instrumentation module~~ — 8a folded into **5 tail (c)**; 8b **cancelled** (§4: observability is discarded) |
| **8c** | Delete all remaining shims and legacy scripts, incl. `experiment_postgresql_array_json.sh`, `run_postgresql_array_json_full_visibility.sh` and `benchmark_observability.py`; rewrite README to drop §Frozen Full Visibility Profile and document `postgresql_json`. **Gate: only after user confirms on EC2 hardware** — the legacy script is the provenance of existing full-visibility evidence, so keep it runnable (from the tag) until then. | Full runbook re-executed from scratch |

---

## 9. Constraints and risks

### Frozen interfaces
- `watcher.sh` env contract:
  `DB_PWD db_name phase epoch metrics_file DB_STATS_FILE PG_1S_FILE OS_1S_FILE OS_DISK_DEVICES OS_DISK_DEVICE_FILE DB_STATS_TABLE INTERVAL`.
  Wrapped by `lib/watcher_runner.sh`; do not change the contract. The sampler itself is
  still PostgreSQL-only and hardcodes `sudo -u postgres` (remote-server port = open work).
- **CSV schema**: ~20 scripts in `../analysis_scripts/` parse these columns. Base columns
  fixed by the authoritative script; stats columns backend-declared via
  `backend::metric_names`.

### Deployment
README deploys a single self-contained `.sh` + `benchmark_observability.py` by scp
(`README.md:344-390`). After step 7: primary path ships the directory (`tools/deploy.sh`);
single-file UX preserved via generated (never hand-edited) `experiment.bundle.sh`, with CI
smoking both tree and bundle.

### Risks that still apply
- **Larger blast radius**: a `lib/` regression hits every backend — per-backend contract
  tests, smoke matrix, `git tag pre-refactor-scripts`, and the "run the old script" escape
  hatch stay in force until 8c.
- **Lost observability is permanent**: after 8c nothing regenerates WAL / buffer residency /
  `pg_stat_statements` / prewarm evidence (§4). Accepted; the tag and archived logs are the
  only record, which is why 8c stays EC2-gated.
- **`postgresql_json` CSV columns differ from legacy array_json**: it emits the shared
  PostgreSQL statistics set (`backend::metric_names` in `_postgresql_common.sh`), not the
  legacy 30-column subset — the same deliberate deviation `postgresql_row`/`postgresql_textarray`
  already ship, so every PostgreSQL backend keeps one schema for `../analysis_scripts/`.
- **Migration window with shims**: shims are one-line `exec` only — no logic to drift.
- **Neo4j note (open)**: `AGENTS.md` says validate with `./experiment_neo4j.sh`, which does
  not exist at the repository root. Add the entrypoint or update `AGENTS.md`.

---

## 10. Acceptance criteria — remaining

- Shell line count reduced from ~16.8k to **<5k** (legacy scripts deleted at 8c).
- ✅ Every backend (incl. mariadb_rocksdb, `postgresql_json`) passes smoke with the standard CSV
  base schema; `postgresql_json` runs the identical engine path as its PostgreSQL siblings —
  its only differences from legacy array_json are the discarded observability (§4) and the
  shared statistics column set.
- ✅ Both phase sequences (`mainline`, `--mode baseline`) execute the same phase-step functions and
  write the same CSV schema; the baseline engine contains no YCSB invocation of its own.
- README deploy works against the new layout; the bundle reproduces today's single-file scp
  workflow.
- Behaviour of the authoritative script stays byte-identical to smoke goldens.
