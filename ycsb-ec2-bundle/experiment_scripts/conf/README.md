# Configuration files

`experiment.sh` resolves configuration in this order (later wins):

1. built-in defaults — `lib/config.sh`
2. backend defaults — `lib/backends/<backend>.sh` → `backend::default_config`
3. `--config FILE` — any of the files in this directory
4. environment variables
5. CLI flags (`--epochs`, `--steps`, `--run-id`, `--type`, `--var KEY=VALUE`)

Files are plain `KEY=VALUE` shell assignments sourced by the runner, so keep them to
assignments only (no command substitution that depends on the run).

| File | Purpose |
| --- | --- |
| `db.<backend>.env` | endpoint, role and credentials. **Not committed** — copy from `db.<backend>.env.example`; keep real files at mode 0600 |
| `scale.heavy.env`, `scale.light.env` | record/operation counts for the two documented scale modes |
| `experiments/<preset>.env` | a named experiment: type, distributions, epochs, vacuum policy |

Legacy launcher variables still work (`DIST`, `WORK`, `EXPERIMENT_EPOCHS`, …) via the
alias shim in `lib/config.sh`; that shim is scheduled for removal one release after the
runbook is updated (REFACTOR_PLAN.md step 7).
