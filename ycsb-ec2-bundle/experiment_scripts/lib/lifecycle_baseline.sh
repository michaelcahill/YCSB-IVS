#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# The baseline engine: `./experiment.sh <backend> --mode baseline`.
#
#   load -> [ extend -> measure ] x (epochs x steps)
#
# It is the mainline sequence without the two comparison databases: no reference-load and
# reference phase (an unmodified-value-size control), no clean-run/comparison-load/avg-run
# (a freshly restored copy and a reload at the measured average value size). What remains is
# the same load, extend and measured run that the mainline engine performs, executed by the
# same functions from lib/lifecycle.sh — so a baseline row and a mainline row of the same
# workload are the same measurement, written with the same columns, and only the comparison
# context is missing.
#
# Why it exists as a mode instead of a script: the nine legacy `experiment_*_baseline.sh`
# runners each carried a private copy of the phase loop, their own `write_result`, their own
# shorter metric set and in-place workload rewrites, and had drifted from the authoritative
# script in every one of those ways. Their bodies were discarded rather than ported
# (REFACTOR_PLAN.md §0); this file is what replaces all nine.
#
# Consequences of running without the comparison databases:
#   * $UNCHANGED_DB_NAME and $BACKUP_DB_NAME are never created, dropped or written to;
#   * pg_dump is not required, so preflight does not ask for it;
#   * only value_sizes_*_before_*.csv is produced (the "after" file comes from the
#     comparison copy), and COMPARISON_INTERVAL has no meaning — lib/config.sh forces it to 0
#     so that a preset asking for comparisons cannot silently pretend it got them.

run_experiment_baseline() {
    local -a DB_PARAMS=()

    experiment_bootstrap false "$DB_NAME"

    run_load_phase

    for epoch in $(seq 1 "$NUM_EPOCHS"); do
        for step in $(seq 1 "$STEPS_PER_EPOCH"); do

            iteration=$((STEPS_PER_EPOCH * ($epoch - 1) + $step))

            run_extend_phase
            vacuum_if_enabled
            run_measured_phase

            log "END iteration"
        done
    done

    experiment_complete
}
