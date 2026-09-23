# Configuration files

`experiment.sh` resolves configuration in this order (later wins):

1. built-in defaults — `lib/config.sh`
2. backend defaults — `lib/backends/<backend>.sh` → `backend::default_config`
3. `conf/db.<backend>.env` — loaded automatically when it exists
4. `--config FILE` — any of the files in this directory, applied in the order given
5. environment variables
6. CLI flags (`--epochs`, `--steps`, `--run-id`, `--type`, `--scale`, `--workload`,
   `--experiment-dir`, `--var KEY=VALUE`)

## Parsing rules

Configuration files are **parsed, not executed**. They may contain blank lines, `#`
comments and `KEY=VALUE` assignments (an optional leading `export` is accepted, one
layer of matching quotes is stripped). Anything else — command substitution, function
definitions, control flow — makes the run fail before it touches the database. That is
what allows layer 5 to beat layers 3 and 4: a file can never override something you
exported yourself, and the runner says so:

```
[config] conf/scale.light.env: 1 assignment(s) ignored, the environment already sets them
```

An unquoted value keeps everything after `=` verbatim, `#` included — there is no inline-comment
syntax, because a password may contain that character. Put explanations on their own line, or
quote the value.

| File | Purpose |
| --- | --- |
| `db.<backend>.env` | endpoint, role and credentials. **Not committed** — copy from `db.<backend>.env.example` and keep the real file at mode 0600 |
| `scale.heavy.env`, `scale.light.env` | record/operation counts for the two documented scale modes; apply with `--config`, they are not loaded automatically because silently resizing a dataset changes what a run measures |
| `experiments/<preset>.env` | a named experiment: type, distributions, epochs, vacuum policy |

`--dry-run` prints the active configuration and the files that were applied.

## Legacy launcher variables

Launchers written against the old scripts keep working through the alias shim in
`lib/config.sh`: `DIST→EXTEND_DIST`, `WORK→WORKLOAD`,
`UNCHANGE_DB_NAME→UNCHANGED_DB_NAME`, `EXPERIMENT_EPOCHS→NUM_EPOCHS`,
`EXPERIMENT_RUNS_PER_EPOCH→STEPS_PER_EPOCH`, `DB_PASSWORD→DB_PWD`,
`FIELD_LENGTH_ORIGINAL→FIELDLENGTHORIGINAL`, `vacuum→VACUUM_ENABLED` and the
`EXTEND_*`/`RUN_*` proportion and distribution names. Each translation prints a
deprecation line; when both names are set the canonical one wins. The shim is scheduled
for removal one release after the runbook is updated (REFACTOR_PLAN.md step 7).

Instrumentation variables (`REQUIRE_FULL_VISIBILITY`, `SAMPLE_INTERVAL_SECONDS`,
`SPIKE_TRIGGER_*`, …) belong to the full-visibility module of step 8b and are reported as
unsupported rather than silently ignored.
