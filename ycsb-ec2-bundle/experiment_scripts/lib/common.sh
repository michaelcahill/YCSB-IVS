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
log() {
    printf '[epoch=%s run=%s phase=%s] %s\n' \
        "${epoch:-0}" "${step:-0}" "${phase:-setup}" "$*" >&2
}

start_logging() {
    EXECUTION_ID="${EXECUTION_ID:-$(date -u +%Y%m%dT%H%M%SZ)_$$}"

    mkdir -p "$(dirname "$LOG_FILE")"
    LOG_FILE="$(cd "$(dirname "$LOG_FILE")" && pwd)/$(basename "$LOG_FILE")"
    : > "$LOG_FILE"

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

    log "START experiment execution=$EXECUTION_ID host=$DB_HOST port=$DB_PORT"
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
