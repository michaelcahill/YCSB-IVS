#!/usr/bin/env bash
# Part of the experiment runner; sourced, never executed directly.

# Logging, run lifecycle and signal-safe cleanup shared by every experiment run.
# stderr keeps diagnostics out of captured SQL results and raw YCSB CSV.
#
# Every log() call is echoed. The pre-refactor runner filtered messages through an
# allow-list of shapes, which silently dropped legitimate progress lines (e.g.
# "Initial-load verification - TotalSize:…", "Workload file fieldlength set to:…",
# the "=== …phase ===" banners); a decision on 2026-09-24 widened it to log
# everything. Verbosity is therefore controlled at the call site, never by a message
# filter that future callers must know about.
# The three context fields are the position of the message inside the experiment, and they mean
# exactly what the phase loop sets them to:
#
#   epoch  which epoch the current iteration belongs to (the outer loop; 0 before it starts)
#   run    which step *within that epoch* (the inner loop) — NOT the --run-id run counter, which
#          is $RUN and appears in the "START experiment" line and in every artefact name.
#          The name is historical and shared with analysis_scripts/plot_postgresql_phase_runtime.py,
#          which likewise refuses to confuse it with the run counter; do not reuse this field.
#   phase  the phase being executed (setup before the first one, complete after the last)
#
# A phase function must therefore set `phase` before its first log() call, and nothing may shadow
# epoch/step with a different quantity: log() reads the globals, so a local named `epoch` holding
# something else silently mislabels every line emitted while it is in scope.
log() {
    printf '[epoch=%s run=%s phase=%s] %s\n' \
        "${epoch:-0}" "${step:-0}" "${phase:-setup}" "$*" >&2
}

start_logging() {
    EXECUTION_ID="${EXECUTION_ID:-$(date -u +%Y%m%dT%H%M%SZ)_$$}"

    mkdir -p "$(dirname "$LOG_FILE")"
    LOG_FILE="$(cd "$(dirname "$LOG_FILE")" && pwd)/$(basename "$LOG_FILE")"
    # A resumed run continues the log of the attempt it resumes; a fresh run starts one. The
    # START line below carries EXECUTION_ID, so an appended log still says which attempt wrote
    # each of its lines.
    if declare -F experiment::resume_active >/dev/null && experiment::resume_active; then
        touch "$LOG_FILE"
    else
        : > "$LOG_FILE"
    fi

    LOGGER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ycsb-logger.XXXXXX")
    if ! mkfifo "$LOGGER_DIR/stream"; then
        rmdir "$LOGGER_DIR"
        return 1
    fi

    # Save the original terminal output descriptors.
    exec 3>&1 4>&2

    # Start the reader BEFORE redirecting the script's output.
    (
        trap - EXIT ERR INT TERM
        set -o pipefail

        perl -MPOSIX=strftime -ne '
            BEGIN { $| = 1; }
            print strftime("[%Y-%m-%d %H:%M:%S UTC] ", gmtime), $_;
        ' < "$LOGGER_DIR/stream" | tee -a "$LOG_FILE"
    ) &
    LOGGER_PID=$!

    EXPERIMENT_STARTED=$SECONDS
    EXPERIMENT_COMPLETED=0

    exec > "$LOGGER_DIR/stream" 2>&1

    trap 'log "ERROR status=$? line=$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'finish_logging "$?"' EXIT

    # The run counter cannot appear in the per-line prefix (see log()), so it is recorded here
    # once, next to the id that distinguishes this attempt from an earlier one of the same run.
    log "START experiment execution=$EXECUTION_ID run=${RUN:-?} host=$DB_HOST port=$DB_PORT"
    log "Log file: $LOG_FILE"
    log "Result CSV: $OUTPUT_FILE"
}

finish_logging() {
    local rc="$1"
    local logger_rc=0

    trap - EXIT ERR INT TERM

    # Safety net: never leave a watcher behind, whatever killed the run.
    stop_runtime_watcher

    # Prevent premature exits from being reported as successful.
    if (( rc == 0 )) && [[ "${EXPERIMENT_COMPLETED:-0}" != 1 ]]; then
        rc=1
        log "ERROR experiment exited before its completion marker"
    fi

    log "END experiment status=$rc duration=$((SECONDS-EXPERIMENT_STARTED))s"
    log "Download this log from EC2: $LOG_FILE"

    # Close the pipe's writer, then wait for the logger to finish.
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$LOGGER_PID" || logger_rc=$?

    rm -f "$LOGGER_DIR/stream"
    rmdir "$LOGGER_DIR"

    if (( logger_rc != 0 )); then
        printf 'Log writer failed (status=%s): %s\n' \
            "$logger_rc" "$LOG_FILE" >&2
        if (( rc == 0 )); then
            rc=$logger_rc
        fi
    fi

    exit "$rc"
}

# Stops the watcher process group started by run_with_metrics. Uses global state
# and always succeeds: it runs from EXIT/INT/TERM traps, where a non-zero status
# would abort cleanup and a function-local pid would already be out of scope.
RUNTIME_WATCHER_PGID=""

stop_runtime_watcher() {
    local pid="${RUNTIME_WATCHER_PGID:-}"
    RUNTIME_WATCHER_PGID=""
    [[ -n "$pid" ]] || return 0
    kill -TERM -"$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 0
}
