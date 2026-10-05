# Configuration files

`experiment.sh` resolves configuration in this order (later wins):

1. built-in defaults — `lib/config.sh`
2. backend defaults — `lib/backends/<backend>.sh` → `backend::default_config`
3. `conf/db.<family>.env`, then `conf/db.<backend>.env` — loaded automatically when they
   exist (the family is named by the backend's `conf_family`; the four PostgreSQL backends
   share `db.postgresql.env`, and the per-backend file wins on a clash)
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
exported yourself (so machine-specific secrets stay in the environment), and the runner
says so:

```
[config] conf/scale.light.env: 1 assignment(s) ignored, the environment already sets them
```

An unquoted value keeps everything after `=` verbatim, `#` included — there is no inline-comment
syntax, because a password may contain that character. Put explanations on their own line, or
quote the value.

| File | Purpose |
| --- | --- |
| `db.<family>.env` | settings shared by several backends on one server — `db.postgresql.env` is the endpoint/role of the four PostgreSQL schemas **and** the `--init` administrator connection (`PG_INIT_ADMIN_CLI_WRAP=sudo -u postgres` by default) |
| `db.<backend>.env` | endpoint, role and credentials for one backend; committed with working defaults and commented options. Machine-specific values — especially real passwords — belong in exported environment variables, which beat the file |
| `scale.heavy.env`, `scale.light.env` | record/operation counts for the two documented scale modes; apply with `--config`, they are not loaded automatically because silently resizing a dataset changes what a run measures |
| `experiments/<preset>.env` | a named experiment: type, distributions, epochs, vacuum policy |

`--dry-run` prints the active configuration and the files that were applied.

## Only canonical names

The names in this directory's files are the canonical configuration names — exactly the
ones `--dry-run` prints. The pre-refactor launcher aliases (`DIST`, `WORK`,
`UNCHANGE_DB_NAME`, `EXPERIMENT_EPOCHS`, `DB_PASSWORD`, the `EXTEND_*`/`RUN_*`
proportion pairs, …) and the full-visibility instrumentation variables
(`REQUIRE_FULL_VISIBILITY`, `SAMPLE_INTERVAL_SECONDS`, `SPIKE_TRIGGER_*`, …) were removed
with refactor step 8c: nothing translates or warns about them any more, so a stale
variable simply has no effect. Old launchers live in the `pre-refactor-scripts` tag.
