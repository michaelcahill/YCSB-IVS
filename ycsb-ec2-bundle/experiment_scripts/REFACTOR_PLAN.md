# Experiment Scripts Refactoring Plan

Target: replace ~16.8k lines of copy-pasted experiment scripts with **one runner**
(`experiment.sh <backend>`), a small core library, one module per database backend,
an optional instrumentation module, and config files for parameters.

Authoritative specification: `experiment_postgresql_array-text-autovacuum.sh`.
Status: planning only — no code changes made yet.

---

## 0. Governing rule

`experiment_postgresql_array-text-autovacuum.sh` is the **specification** for everything
that is not backend-specific:

- phase sequence and phase names
- logging, traps, `EXECUTION_ID`, log/CSV paths
- CSV base columns and header-evolution logic
- key-size dump / histogram / append pipeline
- idle-wait before comparison phases
- comparison-database dump/restore + row-count verification
- experiment directory layout
- preflight checks

When porting any other script, classify each difference:

| Category | Action | Examples |
| --- | --- | --- |
| **Backend detail** | Keep, in `lib/backends/<backend>.sh` | psql / JDBC / cypher-shell / mongosh / n1ql invocation; schema DDL; size expressions for that data model; dump/restore mechanics; index-readiness waits (couchbase); APOC + Bolt URI checks (neo4j); binding name and `-p` overrides; capability flags |
| **Non-backend deviation** | **Discard silently** | shorter metric sets in other scripts; their `../analysis/Data/…` paths; their own `write_result` / `log` variants; `DIST` / `WORK` naming; couchbase `log_stderr`; the legacy `*_baseline.sh` loop bodies |
| **Extra observability** | Optional instrumentation module (§8) | array_json WAL / `pg_stat_statements` / buffer residency / `pg_prewarm` / checkpoint-log capture |

No feature is merged into the core engine just because some other script had it. If a
capability looks valuable but is not backend-specific (e.g. runtime watcher JSONL
sampling), it becomes a separate opt-in module proposal **after** this refactor.

---

## 1. Current state (measured)

`experiment_scripts/`: 21 `experiment_*.sh` + `watcher.sh` +
`run_postgresql_array_json_full_visibility.sh` + `benchmark_observability.py`,
**~16,800 shell lines**.

### Duplication (identical-modulo-whitespace function bodies)

| Function | Files | Distinct variants | ~Lines/copy |
| --- | --- | --- | --- |
| `write_result` (YCSB → CSV pivot) | 20 | 14 | 82 |
| `log` | 20 | 4 | 3–25 |
| `initialize_database` | 12 | 10 | 31 |
| `collect_postgres_metrics` | 10 | 8 | 54 |
| `append_first_iteration` / `append_subsequent_iterations` / `get_key_sizes` | 11 | 2–3 each | 52 total |
| `close_db` | 16 | 3 | ~5 |

### Two loop families (by `phase=` markers)

- **6-phase mainline**, 12 scripts: `load → extend → run → reference → clean-run → avg-run`
- **2-phase baseline**, 8 `*_baseline.sh`: `load → spread-run`

### Fork drift already present

Authoritative script (1,262 lines) vs nearest sibling `experiment_postgresql_array.sh`:
**~77% identical** (284+/106−). The delta is pure drift: `UNCHANGE_DB_NAME` →
`UNCHANGED_DB_NAME`, `log()` printing `${run}` instead of `${step}`, dead
`watcher_command` / `start_runtime_watcher` code removed, relation-size metrics and
`wait_for_idle_postgres` added.

### Stale artefacts

- `watch_postgresql18.py` **does not exist**, yet is referenced by
  `experiment_postgresql_array.sh:~470` and by `tests/test_runtime_watcher.py`
  (that test cannot load its module — broken today).

### Other drivers

- Three competing config conventions: `TYPE/DIST/SCALE/WORK/RUN` (majority);
  `EXPERIMENT_EPOCHS` / `EXPERIMENT_RUNS_PER_EPOCH` / `VACUUM_ENABLED` (array_json, per
  README launchers); `${NUM_EPOCHS:-10}` / `STEPS_PER_EPOCH` / `vacuum=0` (authoritative).
- **22 `perl -i -p` in-place rewrites of the workload file per run** — every one of the 20
  scripts does this, and preflight even requires `../workloads/*` to be writable. A crashed
  run leaves a poisoned workload file.
- The 10-field `octet_length(coalesce(array_to_string(fieldN,''),''))…` SQL block appears
  **34× per PG-array script** (~700 duplicated lines).
- **15 scripts hardcode DB passwords.**
- Unquoted `> $PLAN_LOG`, `rm -rf $KEY_SIZE_LOG`; key-diff/delete block duplicated verbatim
  for the main and unchanged databases.
- Committed `.DS_Store` and `analysis_scripts/__pycache__/*.pyc`.

---

## 2. Target architecture

```
experiment_scripts/
├── experiment.sh              # THE ONLY runner: ./experiment.sh <backend> [preset] [options]
├── lib/
│   ├── common.sh              # set -euo pipefail, SCRIPT_DIR/YCSB_HOME, log(), start_/finish_logging, traps
│   ├── config.sh              # layered config load, validation, legacy alias shim, presets
│   ├── registry.sh            # backend + instrumentation discovery, contract assertion, capabilities
│   ├── workload.sh            # generate_workload <phase> <iter> -> $WORKDIR/workloads/<phase>-iter<NN>.workload
│   ├── metrics.sh             # metric-name arrays, collect_cpu_memory_metrics, stats_header
│   ├── results.sh             # write_result + header evolution (authoritative behaviour, single impl)
│   ├── keysizes.sh            # dump_key_sizes, histogram, append_first/subsequent
│   ├── watcher_runner.sh      # wrapper preserving watcher.sh's env contract
│   ├── lifecycle.sh           # 6-phase engine: run_experiment (verbatim port of the authoritative loop)
│   ├── lifecycle_baseline.sh  # 2-phase engine: run_experiment_baseline
│   ├── instrumentation/
│   │   ├── README.md          # how a module registers with the engine
│   │   ├── none.sh            # default: no hooks, zero overhead
│   │   └── postgresql_fullview.sh   # WAL, pg_stat_statements, buffer residency/free space,
│   │                                # pg_prewarm intervention, checkpoint-log capture, vacuum progress
│   └── backends/
│       ├── postgresql_textarray.sh   # ← extracted from the authoritative script
│       ├── postgresql_row.sh
│       ├── postgrenosql.sh
│       ├── postgresql_json.sh
│       ├── couchbase.sh
│       ├── mongodb.sh
│       ├── mariadb_innodb.sh
│       ├── mariadb_rocksdb.sh
│       ├── neo4j.sh
│       ├── sample.sh                 # template / reference implementation
│       └── <backend>.usage           # optional per-backend help text
├── conf/
│   ├── db.<backend>.env        # endpoints, users, credentials (0600, gitignored) — auto-picked by backend
│   ├── scale.heavy.env
│   ├── scale.light.env
│   └── experiments/<preset>.env
├── tools/
│   ├── bundle.sh               # emit ONE self-contained experiment.bundle.sh for scp
│   └── deploy.sh               # tar the directory to EC2
└── tests/                      # existing + contract test, config-resolution test, golden CSV/schema test
```

**End state: 1 runner script, ~9 backend modules, 0 duplicated engines.** All
`experiment_*.sh` and `run_postgresql_array_json_full_visibility.sh` are deleted.

---

## 3. Backend contract

Each `lib/backends/<name>.sh` implements (function names precedented in
`experiment_sample.sh:5-171`):

```
backend::info                             # key=value: binding, default_db, min_version, capabilities, stats_header
backend::preflight <needs_dump> <db...>   # tools, server version, db-name safety, build artifacts
backend::init_db <db>                     # drop/create/schema DDL
backend::cli / backend::exec              # credential-free operation logging
backend::collect_metrics <db> <scope>     # + backend::collect_cpu_memory
backend::key_sizes <db> <out_csv>         # replaces the 34x octet_length block
backend::total_size <db>
backend::list_keys <db> <out>  /  delete_keys <db> <file>
backend::dump_restore <src_db> <dst_db>   # comparison DB + row-count verification
backend::truncate <db>
backend::wait_idle <db> <interval> <timeout>    # default no-op; PG implements via pg_stat_activity
backend::ycsb_args                        # binding name + -p overrides
backend::close                            # optional
backend::parse_args <argv...>             # optional backend-specific flags
```

`registry.sh` supplies defaults for optional hooks (a simple backend is ~60 lines) and
`assert_backend_contract` fails fast, listing every missing function.

Mapping from the authoritative script: `pg_cli` / `pg_exec`, `postgres_preflight`,
`collect_postgres_metrics`, `restore_comparison_database`, `wait_for_idle_postgres`,
`initialize_database`, and the size SQL all move into
`lib/backends/postgresql_textarray.sh` roughly 1:1.

The stats column set is backend-declared (`backend::info stats_header`) because a Mongo or
Neo4j backend cannot emit `pg_stat_*` columns; the **base** CSV columns stay exactly as in
the authoritative script.

---

## 4. Instrumentation contract (separate from backends)

Backends describe *how to talk to the database*; instrumentation describes *what extra data
to collect around a phase*. Two contracts, so instrumentation composes with any compatible
backend and the engine never branches on a module name.

```
instrument::info                       # name, compatible_backends, required_capabilities, own flags
instrument::preflight                  # extension checks (pg_stat_statements, pg_prewarm, walinspect, freespace)
instrument::on_run_start <phase> <iter> <db>
instrument::on_run_stop  <phase> <iter> <db>   # start/stop samplers around each YCSB invocation
instrument::on_phase_event <event> <kv...>     # e.g. checkpoint / vacuum observations
instrument::write_outputs              # into $EXPERIMENT_DIR/data/instrumentation/<module>/
```

`lifecycle.sh` calls the hooks unconditionally; `none.sh` implements them as no-ops, so the
default path carries zero overhead and zero instrumentation code paths.
`benchmark_observability.py` stays in place and becomes private to
`postgresql_fullview.sh`.

---

## 5. Single-entrypoint dispatch

```
./experiment.sh <backend> [<preset>] [options]
    --mode mainline|baseline        # selects lifecycle engine; default mainline
    --instrument MODULE[,MODULE]    # default: none
    --config FILE        --var k=v  # extra layering / overrides
    --run-id ID   --epochs N   --steps N
    --workload TEMPLATE             # read-only workload template
    --experiment-dir DIR
    --dry-run                       # preflight + resolved-config dump, no YCSB
    --list-backends
    --list-instrumentation
    -h | --help [<backend>]
```

Examples:

```bash
./experiment.sh postgresql_textarray heavy_zipfian --epochs 10 --steps 10
./experiment.sh mongodb light --mode baseline
./experiment.sh postgresql_json full_view --instrument postgresql_fullview \
    --run-id full_view_run2 --sample-interval-seconds 5 \
    --relation-size-sample-interval-seconds 30
```

Rules:

- `<backend>` resolves to `lib/backends/<backend>.sh`; unknown name → error + available list
  (exit 2). Legacy aliases: `postgresql_array→postgresql_textarray`,
  `postgresql→postgresql_row`, `innodb→mariadb_innodb`, `rocksdb→mariadb_rocksdb`,
  `array_json|jsonb→postgresql_json`.
- **Capabilities, not names**: engines branch only on registry facts —
  `has_dump_restore` (skip clean-run/avg-run when absent), `requires_index_wait`,
  `supports_idle_wait`, `per_phase_extra_args`. No backend or module names inside
  `lifecycle.sh`.
- Backend- and instrumentation-specific flags are declared in their `info` and consumed by
  their own `parse_args`; core rejects unknown flags first, so typos still fail loudly.
- `TYPE` defaults to `<backend>` + preset; `EXPERIMENT_NAME` and all paths derive from it
  exactly as in the authoritative script.

---

## 6. Config design

Precedence (later wins):

```
lib/defaults.env  ->  conf/db.<backend>.env  ->  conf/scale.<mode>.env
                  ->  conf/experiments/<preset>.env  ->  process env  ->  CLI flags
```

- One mechanism: the `${VAR:-default}` idiom already used by the authoritative script.
- **Alias shim** in `config.sh` keeps existing EC2 launchers alive:
  `DIST→EXTEND_DIST`, `WORK→WORKLOAD`, `vacuum→VACUUM_ENABLED`,
  `UNCHANGE_DB_NAME→UNCHANGED_DB_NAME`, `EXPERIMENT_EPOCHS→NUM_EPOCHS`,
  `EXPERIMENT_RUNS_PER_EPOCH→STEPS_PER_EPOCH`,
  `EXTEND_OPERATIONCOUNT→EXTENDOPERATIONCOUNT`.
- Credentials move out of tracked scripts into `conf/db.<backend>.env` (0600, gitignored) or
  the environment; scripts fail fast when absent.
- Output layout standardises on the authoritative script's
  `../analysis/experiments/ycsb_<EXPERIMENT_NAME>/{logs,data/{workload_data,value_size_data}}`,
  overridable with `--experiment-dir`.

---

## 7. Workload files: generated into the output directory

**No experiment code may write to `workloads/` or any tracked workload file.** All 22
`perl -i -p` sites per run are deleted and replaced by generation.

- **Location**: `$EXPERIMENT_DIR/workloads/<phase>-iter<NN>.workload`, e.g.
  `…/workloads/load-iter00.workload`, `extend-iter07.workload`, `run-iter07.workload`,
  `comparison-load-iter07.workload`. One immutable file per YCSB invocation; nothing is ever
  rewritten.
- **Mechanism**: `generate_workload <phase> <iteration>` copies the read-only template
  (`--workload`, default `../workloads/workloadc-uniform-heavy`), applies the phase overlay
  (proportions, distributions, `operationcount`, `fieldlength*`) via a single `upsert_kv`
  helper that adds-or-replaces keys — the logic today scattered across 22 perl calls plus the
  README launcher's `sed` dance — then emits the file and echoes its path.
- **Consumption**: every YCSB invocation uses `-P "$generated"`, including the
  reference / clean-run / avg-run phases. The histogram written by `get_key_sizes` lands in
  `$EXPERIMENT_DIR/data/` and is passed as `-p fieldlengthhistogram=<that path>`.
- **Feedback values move to overlays, not files**: today's `fieldlengthaverage` computation
  rewrites/appends `fieldlength=` in the shared workload; it becomes a variable in the next
  phase's overlay. The add-then-strip of `fieldlengthdistribution=histogram` and the
  `awk '!/^fieldlengthdistribution=/' … > tmp && mv tmp` cleanup both disappear.
- **Provenance and reproducibility**: each generated file carries
  `# template=<path> sha256=<hash> phase=… iteration=… generated=<UTC>`; the run log prints
  the path used for every phase; `$EXPERIMENT_DIR/workloads/` is retained with the logs so a
  run can be replayed exactly.
- **Preflight relaxed**: drop the `-w "$WORKLOAD_FILE"` requirement in `postgres_preflight`;
  add `-r` on the template plus a writability check on `$EXPERIMENT_DIR/workloads`.
- **Runbook simplification**: the README launcher's ~40-line copy/`sed`/append block
  (`README.md:392-470`) collapses to `--workload <clean template>` plus `--var k=v` pairs.

---

## 8. Migration plan (each step independently shippable)

| # | Work | Verification |
| --- | --- | --- |
| **0** | Fix §10 bugs on the authoritative script first, so goldens encode intended behaviour. Capture smoke goldens (`--epochs 1 --steps 1`, small recordcount): CSV, log markers, key-size/histogram/plan files. Add CI: `bash -n` + `shellcheck -x` on all scripts, `python3 -m pytest tests/`. | Golden set committed; suite green |
| **1** | Port the authoritative script's core verbatim into `lib/{common,metrics,results,keysizes}.sh`; the script sources them and keeps its current name. | Re-run smoke → byte-identical CSV/log |
| **2** | Extract `lib/backends/postgresql_textarray.sh` + `registry.sh`; introduce **`experiment.sh`**; authoritative script becomes a 3-line shim (`exec "$(dirname $0)"/experiment.sh postgresql_textarray "$@"`). Repoint `experiment_postgresql_array.sh` and `tests/test_logging.sh` at the same backend (ends the 77% drift); delete dead watcher code; resolve `watch_postgresql18.py` (restore or drop its test). | Smoke through both entry paths → same goldens; contract test green |
| **3** | Add `config.sh` + `conf/` presets + alias shim; add `-h/--help`, `--list-backends`, `--dry-run`. | Config unit tests (precedence, aliases, backends); README launcher template still runs unchanged |
| **4** | Implement §7 workload generation; switch every YCSB invocation to generated files. | `git diff --exit-code ../workloads` after a full run; every logged `-P` path resolves inside `$EXPERIMENT_DIR`; goldens otherwise unchanged |
| **5** | Lift the loop into `lifecycle.sh` (authoritative behaviour only). Add backends one at a time — `postgresql_row → postgrenosql → mariadb_innodb → mariadb_rocksdb → mongodb → neo4j → couchbase` — each as a backend module + capability flags. Legacy scripts become temporary `exec`-only shims and are **deleted, not diff-ported**. | Per backend: same phase sequence, same base CSV columns (stats columns per `backend::info stats_header`), same log markers; run completes and output parses |
| **6** | Baseline mode on the same engine (`--mode baseline`) reproducing *authoritative* behaviour with the comparison/reference phases disabled — legacy `*_baseline.sh` bodies are discarded per §0. Delete those 8 files. | Smoke `--mode baseline`; schema identical |
| **7** | Ops: `tools/bundle.sh` (inline lib + selected backends into one scp-able file, preserving today's single-file deploy at `README.md:344-390`), `tools/deploy.sh` (tar the directory), README rewrite (§Deploy / Clean EC2 Run / Launcher / Verify / Output Layout), `.gitignore` for `.DS_Store` / `__pycache__`, remove committed `.pyc`. | Fresh-EC2 dry run executed strictly from the rewritten runbook; bundle smoke-tested in CI |
| **8a** | `postgresql_json` backend: jsonb schema DDL, size/total-size/key SQL for the JSON data model, binding + `-p` overrides, capability flags. | Standard smoke goldens with `--instrument none` |
| **8b** | Port array_json samplers into `lib/instrumentation/postgresql_fullview.sh`, reusing step-1 libs for logging/CSV/key-sizes; its `benchrun_*` process helpers fold into `common.sh` + `watcher_runner.sh` where they overlap, otherwise stay in the module. Convert `run_postgresql_array_json_full_visibility.sh` into `conf/experiments/full_view.env`. | full_view preset run reproduces the same instrumentation artefacts (same files, same columns) as a stored reference run; `--instrument none` runs stay byte-identical to step-5 goldens |
| **8c** | Delete all remaining shims and legacy scripts (including `experiment_postgresql_array_json.sh`); rewrite README §Frozen Full Visibility Profile to the new launcher line. | Full runbook re-executed from scratch |

---

## 9. Constraints and risks

### Frozen interfaces

- `watcher.sh` env contract:
  `DB_PWD db_name phase epoch metrics_file DB_STATS_FILE PG_1S_FILE OS_1S_FILE OS_DISK_DEVICES OS_DISK_DEVICE_FILE DB_STATS_TABLE INTERVAL`.
  Wrap it in `lib/watcher_runner.sh`; do not change the contract.
- **CSV schema**: ~20 scripts in `../analysis_scripts/` parse these columns. Base columns are
  fixed by the authoritative script; stats columns are backend-declared and must be declared
  explicitly in `backend::info`.

### Deployment

README currently deploys a single self-contained `.sh` + `benchmark_observability.py` by scp
(`README.md:344-390`). After the split:

- **Primary**: ship the directory — `tools/deploy.sh` (`tar | ssh tar -x`).
- **Single-file UX preserved**: `tools/bundle.sh [--backends all|postgresql_textarray,…]`
  inlines `lib/*` + selected backends/instrumentation into one `experiment.bundle.sh`, a
  drop-in for today's scp commands. Bundles are generated, never edited; CI smokes both the
  tree and the bundle.

### Risks

- **Larger blast radius** from one runner: a `lib/` regression hits every backend. Mitigate
  with per-backend contract tests in CI, `bash -n lib/*.sh`, a smoke matrix over the whole PG
  family plus at least one non-SQL backend, `git tag pre-refactor-scripts`, and a documented
  "run the old script" escape hatch until step 8c.
- **Backend/instrumentation re-coupling**: CI greps to ensure backend modules never call
  `instrument::*` and instrumentation never calls backend internals beyond the contract.
  `postgresql_fullview` declares `compatible_backends` and refuses others at preflight rather
  than half-working.
- **Flag drift between backends**: prevented by capability-based branching and core rejecting
  unknown flags before delegation.
- **Migration window with both shim and dispatcher**: shims are one-line `exec` only — no
  logic, nothing to drift.

### Neo4j note

Per `AGENTS.md`, Neo4j-side work should be validated with `./experiment_neo4j.sh`; that file
does not exist at the repository root today (the runner is
`experiment_scripts/experiment_neo4j.sh`). Resolve this — either add the expected entrypoint
or update `AGENTS.md` — when step 5 reaches the neo4j backend.

---

## 10. Bugs found while reading (fix at step 0)

1. **Script aborts after the first YCSB phase.** `run_with_metrics` line 600 logs
   `status=$rc duration=$((SECONDS-started))`, but neither `rc` nor `started` is declared in
   that function (locals are only `db_name phase epoch output_csv pg_1s_file os_1s_file
   run_buffer_sampler_pid operation_count wal_*`) and `set -u` is active → unbound-variable
   exit.
2. **EXIT trap destroyed.** `trap - EXIT INT TERM` (line 606) clears the `finish_logging`
   trap installed by `start_logging`, so log finalization and the `EXPERIMENT_COMPLETED`
   guard stop working after phase 1. Use function-scoped cleanup instead of clearing traps.
3. **YCSB failures swallowed.** `$status` is captured and only `echo`ed; the function returns
   the status of `echo`.
4. **`wait_for_idle_postgres` can never return early.**
   `printf '%s\n' "$empty" | wc -l` yields `1`, so `active_count == 0` is never true and every
   call burns the full 1,200 s timeout (~3 calls/iteration ≈ 1 h dead time). Test
   `-z "$active_backends"`.
5. **Minor**: unquoted `> $PLAN_LOG` and `rm -rf $KEY_SIZE_LOG`; key-diff/delete block
   duplicated verbatim for `DB_NAME` and `UNCHANGED_DB_NAME`; broken
   `watch_postgresql18.py` references in `experiment_postgresql_array.sh` and
   `tests/test_runtime_watcher.py`.

---

## 11. Acceptance criteria

- Exactly **one** runner script (`experiment.sh`, plus generated bundle) taking `<backend>` as
  its argument; ~9 backend modules; single implementations of `write_result`, `log`, key-size
  plumbing, and the lifecycle engines.
- Shell line count reduced from ~16.8k to **<5k**.
- No credentials in tracked files.
- **Zero writes to `workloads/`**, and every YCSB invocation driven from a generated file
  under `$EXPERIMENT_DIR/workloads/`.
- Behaviour of the authoritative script preserved exactly (byte-identical smoke goldens).
- Every backend passes smoke producing the standard CSV base schema; instrumentation output
  reproduced identically under `--instrument postgresql_fullview`, with no cost on the default
  path.
- README deploy works against the new layout, and the bundle reproduces today's single-file
  scp workflow.
