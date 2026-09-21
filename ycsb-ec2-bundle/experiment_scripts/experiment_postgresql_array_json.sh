#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"
OBSERVABILITY_HELPER="$SCRIPT_DIR/benchmark_observability.py"

BENCHRUN_RUN_ID="${BENCHRUN_RUN_ID:-}"
BENCHRUN_OUTPUT_DIR="${BENCHRUN_OUTPUT_DIR:-$SCRIPT_DIR/benchruns}"
TARGET_TABLE="${TARGET_TABLE:-usertable}"
BENCHRUN_SAMPLE_INTERVAL_SECONDS="${BENCHRUN_SAMPLE_INTERVAL_SECONDS:-5}"
BENCHRUN_RELATION_SIZE_SAMPLE_INTERVAL_SECONDS="${BENCHRUN_RELATION_SIZE_SAMPLE_INTERVAL_SECONDS:-30}"
BENCHRUN_ENABLE_OS_WATCHERS="${BENCHRUN_ENABLE_OS_WATCHERS:-1}"
BENCHRUN_RESET_PG_STATS_BEFORE_RUN="${BENCHRUN_RESET_PG_STATS_BEFORE_RUN:-0}"
BENCHRUN_INSPECT_WAL_RANGES="${BENCHRUN_INSPECT_WAL_RANGES:-0}"
BENCHRUN_FULL_VISIBILITY="${BENCHRUN_FULL_VISIBILITY:-0}"
BENCHRUN_REQUIRE_FULL_VISIBILITY="${BENCHRUN_REQUIRE_FULL_VISIBILITY:-0}"
BENCHRUN_DRY_RUN_PREFLIGHT="${BENCHRUN_DRY_RUN_PREFLIGHT:-0}"
BENCHRUN_SKIP_CONTINUOUS_SAMPLING="${BENCHRUN_SKIP_CONTINUOUS_SAMPLING:-0}"
BENCHRUN_SKIP_DERIVED_ANALYSIS="${BENCHRUN_SKIP_DERIVED_ANALYSIS:-0}"
BENCHRUN_PHASE_VALUE_SIZES="${BENCHRUN_PHASE_VALUE_SIZES:-}"
VALUE_VARIANT="${VALUE_VARIANT:-jsonb_array}"
CLI_DB_URL=""
ORIGINAL_COMMAND_LINE="$0 $*"

usage() {
    cat <<'USAGE'
Usage: ./experiment_postgresql_array_json.sh [observability options]

Existing environment variables still work. Optional additions:
  --run-id ID
  --output-dir DIR
  --target-table TABLE
  --database-url JDBC_URL
  --sample-interval-seconds N
  --relation-size-sample-interval-seconds N
  --enable-os-watchers | --disable-os-watchers
  --reset-pg-stats-before-run
  --inspect-wal-ranges
  --full-visibility
  --require-full-visibility
  --pg-prewarm
  --pg-prewarm-mode MODE
  --variant jsonb_array|text_array|text_scalar
  --value-variant jsonb_array|text_array|text_scalar
  --phase-value-sizes LIST
  --dry-run-preflight
  --skip-continuous-sampling
  --skip-derived-analysis
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)
            BENCHRUN_RUN_ID="$2"; shift 2 ;;
        --output-dir)
            BENCHRUN_OUTPUT_DIR="$2"; shift 2 ;;
        --target-table)
            TARGET_TABLE="$2"; shift 2 ;;
        --database-url)
            CLI_DB_URL="$2"; shift 2 ;;
        --sample-interval-seconds)
            BENCHRUN_SAMPLE_INTERVAL_SECONDS="$2"; shift 2 ;;
        --relation-size-sample-interval-seconds)
            BENCHRUN_RELATION_SIZE_SAMPLE_INTERVAL_SECONDS="$2"; shift 2 ;;
        --enable-os-watchers)
            BENCHRUN_ENABLE_OS_WATCHERS=1; shift ;;
        --disable-os-watchers)
            BENCHRUN_ENABLE_OS_WATCHERS=0; shift ;;
        --reset-pg-stats-before-run)
            BENCHRUN_RESET_PG_STATS_BEFORE_RUN=1; shift ;;
        --inspect-wal-ranges)
            BENCHRUN_INSPECT_WAL_RANGES=1
            SPIKE_TRIGGER_WALINSPECT_ENABLED=1
            shift ;;
        --full-visibility)
            BENCHRUN_FULL_VISIBILITY=1
            BENCHRUN_INSPECT_WAL_RANGES=1
            SPIKE_TRIGGER_TRACE_ENABLED=1
            SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED=1
            SPIKE_TRIGGER_PAGE_IDENTITY_ENABLED=1
            SPIKE_TRIGGER_FREESPACE_ENABLED=1
            SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED=1
            SPIKE_TRIGGER_PG_STAT_STATEMENTS_RESET_PER_PHASE=1
            SPIKE_TRIGGER_WALINSPECT_ENABLED=1
            BENCHRUN_ENABLE_OS_WATCHERS=1
            BENCHRUN_SKIP_CONTINUOUS_SAMPLING=0
            shift ;;
        --require-full-visibility)
            BENCHRUN_REQUIRE_FULL_VISIBILITY=1; shift ;;
        --pg-prewarm)
            SPIKE_TRIGGER_PREWARM_ENABLED=1; shift ;;
        --pg-prewarm-mode)
            SPIKE_TRIGGER_PREWARM_MODE="$2"; shift 2 ;;
        --variant|--value-variant)
            VALUE_VARIANT="$2"; shift 2 ;;
        --variant=*|--value-variant=*)
            VALUE_VARIANT="${1#*=}"; shift ;;
        --phase-value-sizes)
            BENCHRUN_PHASE_VALUE_SIZES="$2"; shift 2 ;;
        --dry-run-preflight)
            BENCHRUN_DRY_RUN_PREFLIGHT=1; shift ;;
        --skip-continuous-sampling)
            BENCHRUN_SKIP_CONTINUOUS_SAMPLING=1; shift ;;
        --skip-derived-analysis)
            BENCHRUN_SKIP_DERIVED_ANALYSIS=1; shift ;;
        --help|-h)
            usage
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

# DB names
DB_NAME="${DB_NAME:-ycsb}"
BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
UNCHANGE_DB_NAME="${UNCHANGE_DB_NAME:-ycsb_unchange}"

# Path to the PostgreSQL data directory
DB_URL="${CLI_DB_URL:-${DB_URL:-jdbc:postgresql://localhost:5432/$DB_NAME}}"
JDBC_PROPERTIES="${JDBC_PROPERTIES:-../jdbc-binding/conf/postgres.properties}"
DB_USERNAME="${DB_USERNAME:-ycsb}"
DB_PWD="${DB_PWD:-USyd2025}"
PG_EXTENSION_USERNAME="${PG_EXTENSION_USERNAME:-$DB_USERNAME}"
PG_EXTENSION_PWD="${PG_EXTENSION_PWD:-$DB_PWD}"
BACKUP_URL="${BACKUP_URL:-jdbc:postgresql://localhost:5432/$BACKUP_DB_NAME}"
BACKUP_FILE="${BACKUP_FILE:-./ycsb_dump.sql}"
UNCHANGE_DB_URL="${UNCHANGE_DB_URL:-jdbc:postgresql://localhost:5432/$UNCHANGE_DB_NAME}"

# Change naming parameters here
TYPE="${TYPE:-postgresql_arrayjson_TOAST}"
DIST="${DIST:-zipfian}" # "uniform" OR "zipfian"
SCALE="${SCALE:-heavy}" # "heavy" OR "light"
WORK="${WORK:-pure}" # "mixed" OR "pure"
RUN="${RUN:-1}"

case "$VALUE_VARIANT" in
    jsonb_array)
        YCSB_BINDING="${YCSB_BINDING:-jdbc-array-json}"
        FIELD_SQL_TYPE="${FIELD_SQL_TYPE:-JSONB}"
        VALUE_VARIANT_LABEL="JSONB array"
        ;;
    text_array)
        YCSB_BINDING="${YCSB_BINDING:-jdbc-array}"
        FIELD_SQL_TYPE="${FIELD_SQL_TYPE:-TEXT[]}"
        VALUE_VARIANT_LABEL="TEXT array"
        ;;
    text_scalar)
        YCSB_BINDING="${YCSB_BINDING:-jdbc}"
        FIELD_SQL_TYPE="${FIELD_SQL_TYPE:-TEXT}"
        VALUE_VARIANT_LABEL="TEXT scalar"
        ;;
    *)
        echo "Invalid VALUE_VARIANT '$VALUE_VARIANT'; expected jsonb_array, text_array, or text_scalar." >&2
        exit 2
        ;;
esac

# Define the workload file and the log file
WORKLOAD_FILE="${WORKLOAD_FILE:-../workloads/workloada-extend}"
LOG_FILE="${LOG_FILE:-./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log}"
OUTPUT_CSV="${OUTPUT_CSV:-../analysis/postgresql_array_output.csv}"

# Define input and output filenames
INPUT_FILE="${INPUT_FILE:-$OUTPUT_CSV}"
OUTPUT_FILE="${OUTPUT_FILE:-../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv}"
EXPERIMENT_EPOCHS=${EXPERIMENT_EPOCHS:-10}
EXPERIMENT_RUNS_PER_EPOCH=${EXPERIMENT_RUNS_PER_EPOCH:-10}
COMPARISON_INTERVAL=${COMPARISON_INTERVAL:-1}

# Key size gathering
KEY_SIZE_LOG="${KEY_SIZE_LOG:-key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv}"
KEY_SIZE_FILE_AFTER_EXTEND="${KEY_SIZE_FILE_AFTER_EXTEND:-../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv}"
KEY_SIZE_FILE_AFTER_RUN="${KEY_SIZE_FILE_AFTER_RUN:-../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv}"
HISTOGRAM_FILE="${HISTOGRAM_FILE:-histogram.txt}"

# VACUUM settings
vacuum=${VACUUM_ENABLED:-1}

# Plan log file
PLAN_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_query_plan.log"
INTERNAL_DATA_DIR="../analysis/Data/Internal_data"
DETOAST_PROBE_LOG="${INTERNAL_DATA_DIR}/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}_detoast_probe.log"
DETOAST_PROBE_ENABLED=${DETOAST_PROBE_ENABLED:-1}
DETOAST_PROBE_EVERY=${DETOAST_PROBE_EVERY:-1}
DB_STATS_INTERVAL=${DB_STATS_INTERVAL:-60}
OS_DISK_DEVICES="${OS_DISK_DEVICES:-auto}"
SPIKE_TRIGGER_TRACE_ENABLED=${SPIKE_TRIGGER_TRACE_ENABLED:-1}
SPIKE_TRIGGER_READ_SAMPLE_RATE=${SPIKE_TRIGGER_READ_SAMPLE_RATE:-100}
SPIKE_TRIGGER_SLOW_READ_US=${SPIKE_TRIGGER_SLOW_READ_US:-1000}
SPIKE_TRIGGER_BUFFER_PROGRESS_PCTS="${SPIKE_TRIGGER_BUFFER_PROGRESS_PCTS:-1 2 5 10 25 50}"
SPIKE_TRIGGER_PAGE_IDENTITY_ENABLED=${SPIKE_TRIGGER_PAGE_IDENTITY_ENABLED:-1}
SPIKE_TRIGGER_PAGE_IDENTITY_SAMPLE_MOD=${SPIKE_TRIGGER_PAGE_IDENTITY_SAMPLE_MOD:-32}
SPIKE_TRIGGER_PAGE_IDENTITY_MIN_USAGECOUNT=${SPIKE_TRIGGER_PAGE_IDENTITY_MIN_USAGECOUNT:-4}
SPIKE_TRIGGER_PAGE_IDENTITY_BASE_EVENTS="${SPIKE_TRIGGER_PAGE_IDENTITY_BASE_EVENTS:-before_run run_progress_5pct run_progress_10pct after_run}"
SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EPOCHS="${SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EPOCHS:-45-50 56-61 68-73 81-86 94-100}"
SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EVENTS="${SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EVENTS:-after_extend after_vacuum prewarm_start prewarm_end before_run run_progress_1pct run_progress_2pct run_progress_5pct run_progress_10pct run_progress_25pct run_progress_50pct after_run}"
SPIKE_TRIGGER_FREESPACE_ENABLED=${SPIKE_TRIGGER_FREESPACE_ENABLED:-1}
SPIKE_TRIGGER_FREESPACE_SAMPLE_MAX_PAGES=${SPIKE_TRIGGER_FREESPACE_SAMPLE_MAX_PAGES:-4096}
SPIKE_TRIGGER_FREESPACE_BASE_EVENTS="${SPIKE_TRIGGER_FREESPACE_BASE_EVENTS:-after_extend after_vacuum before_run after_run}"
SPIKE_TRIGGER_FREESPACE_FOCUS_EPOCHS="${SPIKE_TRIGGER_FREESPACE_FOCUS_EPOCHS:-$SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EPOCHS}"
SPIKE_TRIGGER_FREESPACE_FOCUS_EVENTS="${SPIKE_TRIGGER_FREESPACE_FOCUS_EVENTS:-prewarm_start prewarm_end run_progress_5pct run_progress_10pct}"
SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED=${SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED:-1}
SPIKE_TRIGGER_CHECKPOINT_LOG_TAIL_LINES=${SPIKE_TRIGGER_CHECKPOINT_LOG_TAIL_LINES:-5000}
SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED=${SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED:-1}
SPIKE_TRIGGER_PG_STAT_STATEMENTS_RESET_PER_PHASE=${SPIKE_TRIGGER_PG_STAT_STATEMENTS_RESET_PER_PHASE:-1}
SPIKE_TRIGGER_PG_STAT_STATEMENTS_TOP_N=${SPIKE_TRIGGER_PG_STAT_STATEMENTS_TOP_N:-25}
SPIKE_TRIGGER_PG_STAT_STATEMENTS_QUERY_FILTER="${SPIKE_TRIGGER_PG_STAT_STATEMENTS_QUERY_FILTER:-usertable}"
SPIKE_TRIGGER_WALINSPECT_ENABLED=${SPIKE_TRIGGER_WALINSPECT_ENABLED:-$BENCHRUN_INSPECT_WAL_RANGES}
SPIKE_TRIGGER_WALINSPECT_PER_RECORD=${SPIKE_TRIGGER_WALINSPECT_PER_RECORD:-1}
SPIKE_TRIGGER_WALINSPECT_MAX_BYTES=${SPIKE_TRIGGER_WALINSPECT_MAX_BYTES:-0}
SPIKE_TRIGGER_PREWARM_ENABLED=${SPIKE_TRIGGER_PREWARM_ENABLED:-0}
SPIKE_TRIGGER_PREWARM_MODE="${SPIKE_TRIGGER_PREWARM_MODE:-toast_index}"
RUN_NAME="${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}"
TRIGGER_DATA_DIR="${INTERNAL_DATA_DIR}/toast_spike_trigger"
PHASE_TIMELINE_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_phase_timeline.csv"
PG_1S_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_pg_1s.csv"
OS_1S_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_os_1s.csv"
OS_DISK_DEVICE_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_os_disk_devices.csv"
CHECKPOINT_OBSERVATIONS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_checkpoint_observations.csv"
CHECKPOINT_LOG_SETTINGS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_checkpoint_log_settings.csv"
CHECKPOINT_LOG_MESSAGES_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_checkpoint_log_messages.csv"
CHECKPOINT_LOG_SEEN_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_checkpoint_log_messages.seen"
VACUUM_PROGRESS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_vacuum_progress_1s.csv"
BUFFER_RESIDENCY_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_buffer_residency.csv"
BUFFER_PAGE_IDENTITY_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_buffer_page_identity.csv"
FREESPACE_SUMMARY_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_freespace_summary.csv"
PG_STAT_STATEMENTS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_pg_stat_statements.csv"
WAL_BOUNDS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_wal_bounds.csv"
WAL_STATS_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_wal_stats.csv"
PREWARM_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_pg_prewarm.csv"
READ_SAMPLE_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_read_sample.csv"
SLOW_READ_SAMPLE_FILE="${TRIGGER_DATA_DIR}/${RUN_NAME}_slow_read_sample.csv"
SAMPLED_DETOAST_PROBE_LOG="${TRIGGER_DATA_DIR}/${RUN_NAME}_detoast_probe_sampled_keys.log"
YCSB_READ_SAMPLE_ARGS=()
TRACE_START_EPOCH_SECONDS=""

# Extend phase experiment parameters
extendproportion_extend="${EXTEND_EXTENDPROPORTION:-1}"
readproportion_extend="${EXTEND_READPROPORTION:-0}"
updateproportion_extend="${EXTEND_UPDATEPROPORTION:-0}"
scanproportion_extend="${EXTEND_SCANPROPORTION:-0}"
insertproportion_extend="${EXTEND_INSERTPROPORTION:-0}"
readmodifywriteproportion_extend="${EXTEND_READMODIFYWRITEPROPORTION:-0}"
requestdistribution_extend="${EXTEND_REQUESTDISTRIBUTION:-zipfian}"
# Optional specific request distributions for each operation
readrequestdistribution_extend="${EXTEND_READREQUESTDISTRIBUTION:-uniform}"
updaterequestdistribution_extend="${EXTEND_UPDATEREQUESTDISTRIBUTION:-uniform}"

# After extend phase experiment parameters
extendproportion_postextend="${RUN_EXTENDPROPORTION:-0}"
readproportion_postextend="${RUN_READPROPORTION:-1}"
updateproportion_postextend="${RUN_UPDATEPROPORTION:-0}"
scanproportion_postextend="${RUN_SCANPROPORTION:-0}"
insertproportion_postextend="${RUN_INSERTPROPORTION:-0}"
readmodifywriteproportion_postextend="${RUN_READMODIFYWRITEPROPORTION:-0}"
requestdistribution_postextend="${RUN_REQUESTDISTRIBUTION:-uniform}"
# Optional specific request distributions for each operation
readrequestdistribution_postextend="${RUN_READREQUESTDISTRIBUTION:-uniform}"
updaterequestdistribution_postextend="${RUN_UPDATEREQUESTDISTRIBUTION:-uniform}"

fieldlengthoriginal="${FIELD_LENGTH_ORIGINAL:-100}"
extendoperationcount="${EXTEND_OPERATIONCOUNT:-100000}"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

value_field_definitions_sql() {
    local definitions=""
    local i
    for i in $(seq 0 9); do
        if [ -z "$definitions" ]; then
            definitions="field${i} ${FIELD_SQL_TYPE}"
        else
            definitions="$definitions, field${i} ${FIELD_SQL_TYPE}"
        fi
    done
    printf '%s' "$definitions"
}

field_logical_size_expr() {
    local field_name="$1"

    case "$VALUE_VARIANT" in
        jsonb_array)
            printf "COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(%s, '[]'::jsonb)) AS elem(value)), 0)" "$field_name"
            ;;
        text_array)
            printf "COALESCE((SELECT SUM(octet_length(value)) FROM unnest(COALESCE(%s, ARRAY[]::text[])) AS elem(value)), 0)" "$field_name"
            ;;
        text_scalar)
            printf "COALESCE(octet_length(%s), 0)" "$field_name"
            ;;
    esac
}

logical_record_size_expr() {
    local expr=""
    local part
    local i

    for i in $(seq 0 9); do
        part=$(field_logical_size_expr "field${i}")
        if [ -z "$expr" ]; then
            expr="$part"
        else
            expr="$expr + $part"
        fi
    done
    printf '%s' "$expr"
}

logical_key_size_query() {
    printf 'SELECT ycsb_key, %s AS size FROM usertable;' "$(logical_record_size_expr)"
}

logical_total_size_query() {
    printf 'SELECT COALESCE(SUM(%s), 0) FROM usertable;' "$(logical_record_size_expr)"
}

logical_total_size() {
    local db_name="$1"
    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," \
        -c "$(logical_total_size_query)"
}

write_logical_key_sizes() {
    local db_name="$1"
    local output_file="$2"

    echo "ycsb_key,size" > "$output_file"
    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," \
        -c "$(logical_key_size_query)" >> "$output_file"
}

value_element_count_expr() {
    local expr=""
    local part
    local i

    case "$VALUE_VARIANT" in
        jsonb_array)
            for i in $(seq 0 9); do
                part="jsonb_array_length(COALESCE(field${i}, '[]'::jsonb))"
                if [ -z "$expr" ]; then
                    expr="$part"
                else
                    expr="$expr + $part"
                fi
            done
            ;;
        text_array)
            for i in $(seq 0 9); do
                part="COALESCE(cardinality(field${i}), 0)"
                if [ -z "$expr" ]; then
                    expr="$part"
                else
                    expr="$expr + $part"
                fi
            done
            ;;
    esac
    printf '%s' "$expr"
}

postgres_setting_row() {
    local query="$1"
    local row

    row=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -F $'\t' \
        -U "$PG_EXTENSION_USERNAME" -d postgres \
        -c "$query" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)

    if [ -z "$row" ]; then
        row=$(PGPASSWORD="$DB_PWD" psql -X -q -t -A -F $'\t' \
            -U "$DB_USERNAME" -d postgres \
            -c "$query" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
    fi

    printf '%s\n' "$row"
}

postgres_log_file_candidates() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED" != "1" ]; then
        return
    fi

    local row data_dir log_dir logging_collector log_destination candidate_dir current_logfile

    row=$(postgres_setting_row "SELECT current_setting('data_directory', true), current_setting('log_directory', true), current_setting('logging_collector', true), current_setting('log_destination', true);")
    IFS=$'\t' read -r data_dir log_dir logging_collector log_destination <<< "$row"

    {
        current_logfile=$(postgres_setting_row "SELECT pg_current_logfile();" | head -1)
        if [ -n "$current_logfile" ]; then
            if [[ "$current_logfile" == /* ]]; then
                printf '%s\n' "$current_logfile"
            elif [ -n "$data_dir" ]; then
                printf '%s\n' "${data_dir%/}/$current_logfile"
            fi
        fi

        if [ -n "$log_dir" ]; then
            if [[ "$log_dir" == /* ]]; then
                candidate_dir="$log_dir"
            elif [ -n "$data_dir" ]; then
                candidate_dir="${data_dir%/}/$log_dir"
            else
                candidate_dir=""
            fi

            if [ -n "$candidate_dir" ] && [ -d "$candidate_dir" ]; then
                find "$candidate_dir" -maxdepth 1 -type f \
                    \( -name "*.log" -o -name "*.csv" \) \
                    -printf "%T@ %p\n" 2>/dev/null \
                    | sort -rn \
                    | head -20 \
                    | sed 's/^[^ ]* //'
            fi
        fi

        if [ -d /var/log/postgresql ]; then
            find /var/log/postgresql -maxdepth 1 -type f -name "*.log" \
                -printf "%T@ %p\n" 2>/dev/null \
                | sort -rn \
                | head -20 \
                | sed 's/^[^ ]* //'
        fi
    } | sort -u
}

record_checkpoint_log_settings() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED" != "1" ]; then
        return
    fi

    local event_label="$1"
    local ts_ms rows setting_name setting_value log_source

    ts_ms=$(timestamp_ms)
    rows=$(postgres_setting_row "
        SELECT name, setting
        FROM pg_settings
        WHERE name IN (
            'data_directory',
            'log_checkpoints',
            'log_destination',
            'log_directory',
            'log_filename',
            'log_line_prefix',
            'logging_collector'
        )
        ORDER BY name;
    ")

    if [ -z "$rows" ]; then
        {
            csv_escape "$RUN_NAME"; printf ','
            csv_escape "$event_label"; printf ','
            printf '%s,' "$ts_ms"
            csv_escape "pg_settings_unavailable"; printf ','
            csv_escape "NULL"; printf '\n'
        } >> "$CHECKPOINT_LOG_SETTINGS_FILE"
    else
        while IFS=$'\t' read -r setting_name setting_value; do
            [ -z "$setting_name" ] && continue
            {
                csv_escape "$RUN_NAME"; printf ','
                csv_escape "$event_label"; printf ','
                printf '%s,' "$ts_ms"
                csv_escape "$setting_name"; printf ','
                csv_escape "$setting_value"; printf '\n'
            } >> "$CHECKPOINT_LOG_SETTINGS_FILE"
        done <<< "$rows"
    fi

    while IFS= read -r log_source; do
        [ -z "$log_source" ] && continue
        {
            csv_escape "$RUN_NAME"; printf ','
            csv_escape "$event_label"; printf ','
            printf '%s,' "$ts_ms"
            csv_escape "postgres_log_file"; printf ','
            csv_escape "$log_source"; printf '\n'
        } >> "$CHECKPOINT_LOG_SETTINGS_FILE"
    done < <(postgres_log_file_candidates)
}

record_checkpoint_log_message_row() {
    local phase_label="$1"
    local epoch_label="$2"
    local event_label="$3"
    local source_label="$4"
    local message="$5"
    local key ts_ms

    key="${source_label}"$'\t'"${message}"
    if [ -f "$CHECKPOINT_LOG_SEEN_FILE" ] && grep -Fqx -- "$key" "$CHECKPOINT_LOG_SEEN_FILE" 2>/dev/null; then
        return 1
    fi

    printf '%s\n' "$key" >> "$CHECKPOINT_LOG_SEEN_FILE"
    ts_ms=$(timestamp_ms)
    {
        csv_escape "$RUN_NAME"; printf ','
        csv_escape "$epoch_label"; printf ','
        csv_escape "$phase_label"; printf ','
        csv_escape "$event_label"; printf ','
        printf '%s,' "$ts_ms"
        csv_escape "$source_label"; printf ','
        csv_escape "$message"; printf '\n'
    } >> "$CHECKPOINT_LOG_MESSAGES_FILE"
    return 0
}

collect_checkpoint_log_messages() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED" != "1" ]; then
        return 0
    fi

    local phase_label="$1"
    local epoch_label="$2"
    local event_label="$3"
    local source_path raw_line saw_source saw_message saw_unreadable unreadable_sources
    local checkpoint_pattern='checkpoint (starting|complete|skipped)|restartpoint (starting|complete|skipped)|checkpoints are occurring too frequently'

    saw_source=0
    saw_message=0
    saw_unreadable=0
    unreadable_sources=""
    touch "$CHECKPOINT_LOG_SEEN_FILE" 2>/dev/null || true

    while IFS= read -r source_path; do
        [ -z "$source_path" ] && continue
        if [ ! -r "$source_path" ]; then
            saw_unreadable=1
            unreadable_sources="${unreadable_sources:+$unreadable_sources; }$source_path"
            continue
        fi
        saw_source=1
        while IFS= read -r raw_line; do
            [ -z "$raw_line" ] && continue
            if record_checkpoint_log_message_row "$phase_label" "$epoch_label" "$event_label" "$source_path" "$raw_line"; then
                saw_message=1
            fi
        done < <(tail -n "$SPIKE_TRIGGER_CHECKPOINT_LOG_TAIL_LINES" "$source_path" 2>/dev/null | grep -Ei "$checkpoint_pattern" || true)
    done < <(postgres_log_file_candidates)

    if command -v journalctl >/dev/null 2>&1 && [ -n "${TRACE_START_EPOCH_SECONDS:-}" ]; then
        while IFS= read -r raw_line; do
            [ -z "$raw_line" ] && continue
            if record_checkpoint_log_message_row "$phase_label" "$epoch_label" "$event_label" "journalctl:_COMM=postgres" "$raw_line"; then
                saw_message=1
            fi
        done < <(journalctl --since "@$TRACE_START_EPOCH_SECONDS" --no-pager -o short-iso _COMM=postgres 2>/dev/null | grep -Ei "$checkpoint_pattern" || true)
    fi

    if [ "$saw_source" -eq 0 ] && [ "$saw_unreadable" -eq 1 ] && [ "$saw_message" -eq 0 ]; then
        record_checkpoint_log_message_row "$phase_label" "$epoch_label" "$event_label" "checkpoint_log_unreadable" "PostgreSQL log file(s) were found but not readable by user $(id -un): $unreadable_sources" >/dev/null || true
        saw_message=1
    fi

    if [ "$saw_source" -eq 0 ] && [ "$saw_message" -eq 0 ]; then
        record_checkpoint_log_message_row "$phase_label" "$epoch_label" "$event_label" "checkpoint_log_unavailable" "No readable PostgreSQL log file or journal checkpoint message found; see checkpoint_log_settings for server log configuration." >/dev/null || true
    fi

    return 0
}

ensure_checkpoint_logging() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED" != "1" ]; then
        return
    fi

    local current_setting

    current_setting=$(postgres_setting_row "SHOW log_checkpoints;" | head -1)
    if [ "$current_setting" != "on" ]; then
        if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
            -U "$PG_EXTENSION_USERNAME" -d postgres \
            -c "ALTER SYSTEM SET log_checkpoints = 'on';" >/dev/null 2>&1
        then
            log "Warning: could not enable PostgreSQL log_checkpoints with PG_EXTENSION_USERNAME=$PG_EXTENSION_USERNAME. Set PG_EXTENSION_USERNAME/PG_EXTENSION_PWD to a role that can ALTER SYSTEM, or enable log_checkpoints manually."
            record_checkpoint_log_settings "enable_log_checkpoints_failed"
            collect_checkpoint_log_messages "experiment" "0" "enable_log_checkpoints_failed"
            return
        fi

        if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
            -U "$PG_EXTENSION_USERNAME" -d postgres \
            -c "SELECT pg_reload_conf();" >/dev/null 2>&1
        then
            log "Warning: ALTER SYSTEM SET log_checkpoints succeeded, but pg_reload_conf() failed."
        fi
    fi

    current_setting=$(postgres_setting_row "SHOW log_checkpoints;" | head -1)
    if [ "$current_setting" != "on" ]; then
        log "Warning: PostgreSQL log_checkpoints is still '$current_setting' after reload; checkpoint log messages may be missing."
    else
        log "PostgreSQL log_checkpoints is enabled for checkpoint message capture."
    fi

    record_checkpoint_log_settings "after_enable_log_checkpoints"
    collect_checkpoint_log_messages "experiment" "0" "after_enable_log_checkpoints"
}

ensure_pg_buffercache_extension() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local buffercache_schema grant_role
    grant_role=${DB_USERNAME//\"/\"\"}

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache;" >/dev/null 2>&1
    then
        log "Warning: could not ensure pg_buffercache in $db_name. Buffer residency rows may show pg_buffercache_unavailable. Set PG_EXTENSION_USERNAME/PG_EXTENSION_PWD to a role that can create extensions, or install pg_buffercache in template1."
        return
    fi

    buffercache_schema=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -U "$PG_EXTENSION_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_buffercache';
    " 2>/dev/null || true)

    if [ -z "$buffercache_schema" ]; then
        log "Warning: pg_buffercache extension was not found in $db_name after CREATE EXTENSION."
        return
    fi

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "GRANT SELECT ON ${buffercache_schema}.pg_buffercache TO \"$grant_role\";" >/dev/null 2>&1
    then
        log "Warning: could not grant SELECT on ${buffercache_schema}.pg_buffercache to $DB_USERNAME in $db_name."
    fi
}

ensure_pg_freespacemap_extension() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_FREESPACE_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local freespacemap_schema grant_role signature
    grant_role=${DB_USERNAME//\"/\"\"}

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_freespacemap;" >/dev/null 2>&1
    then
        log "Warning: could not ensure pg_freespacemap in $db_name. Free-space rows may show pg_freespacemap_unavailable. Set PG_EXTENSION_USERNAME/PG_EXTENSION_PWD to a role that can create extensions, or install pg_freespacemap in template1."
        return
    fi

    freespacemap_schema=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -U "$PG_EXTENSION_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_freespacemap';
    " 2>/dev/null || true)

    if [ -z "$freespacemap_schema" ]; then
        log "Warning: pg_freespacemap extension was not found in $db_name after CREATE EXTENSION."
        return
    fi

    for signature in "regclass" "regclass,bigint"; do
        PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
            -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
            -c "GRANT EXECUTE ON FUNCTION ${freespacemap_schema}.pg_freespace($signature) TO \"$grant_role\";" >/dev/null 2>&1 || true
    done
}

ensure_pg_stat_statements_extension() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local statements_schema grant_role signature
    grant_role=${DB_USERNAME//\"/\"\"}

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >/dev/null 2>&1
    then
        log "Warning: could not ensure pg_stat_statements in $db_name. Statement rows may show pg_stat_statements_unavailable. Set PG_EXTENSION_USERNAME/PG_EXTENSION_PWD to a role that can create extensions, or install pg_stat_statements in template1."
        return
    fi

    statements_schema=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -U "$PG_EXTENSION_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_stat_statements';
    " 2>/dev/null || true)

    if [ -z "$statements_schema" ]; then
        log "Warning: pg_stat_statements extension was not found in $db_name after CREATE EXTENSION."
        return
    fi

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "GRANT SELECT ON ${statements_schema}.pg_stat_statements TO \"$grant_role\";" >/dev/null 2>&1
    then
        log "Warning: could not grant SELECT on ${statements_schema}.pg_stat_statements to $DB_USERNAME in $db_name."
    fi

    for signature in "" "oid,oid,bigint" "oid,oid,bigint,boolean"; do
        PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
            -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
            -c "GRANT EXECUTE ON FUNCTION ${statements_schema}.pg_stat_statements_reset($signature) TO \"$grant_role\";" >/dev/null 2>&1 || true
    done

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "SELECT 1 FROM ${statements_schema}.pg_stat_statements LIMIT 1;" >/dev/null 2>&1
    then
        log "Warning: pg_stat_statements exists in $db_name but is not queryable. Add pg_stat_statements to shared_preload_libraries and restart PostgreSQL before relying on statement-level traces."
    fi
}

ensure_pg_walinspect_extension() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_WALINSPECT_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local walinspect_schema grant_role signature function_name
    grant_role=${DB_USERNAME//\"/\"\"}

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_walinspect;" >/dev/null 2>&1
    then
        log "Warning: could not ensure pg_walinspect in $db_name. WAL inspection rows may show pg_walinspect_unavailable. Set PG_EXTENSION_USERNAME/PG_EXTENSION_PWD to a role that can create extensions, or install pg_walinspect in template1."
        return
    fi

    walinspect_schema=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -U "$PG_EXTENSION_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_walinspect';
    " 2>/dev/null || true)

    if [ -z "$walinspect_schema" ]; then
        log "Warning: pg_walinspect extension was not found in $db_name after CREATE EXTENSION."
        return
    fi

    for function_name in pg_get_wal_record_info pg_get_wal_records_info pg_get_wal_stats; do
        for signature in "pg_lsn" "pg_lsn,pg_lsn" "pg_lsn,pg_lsn,boolean"; do
            PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
                -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
                -c "GRANT EXECUTE ON FUNCTION ${walinspect_schema}.${function_name}($signature) TO \"$grant_role\";" >/dev/null 2>&1 || true
        done
    done

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE quote_ident(n.nspname) = '$walinspect_schema' AND p.proname = 'pg_get_wal_stats' LIMIT 1;" >/dev/null 2>&1
    then
        log "Warning: pg_walinspect exists in $db_name but pg_get_wal_stats was not found."
    fi
}

ensure_pg_prewarm_extension() {
    if [ "$SPIKE_TRIGGER_PREWARM_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local prewarm_schema grant_role_sql
    grant_role_sql=$(printf "%s" "$DB_USERNAME" | sed "s/'/''/g")

    if ! PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm;" >/dev/null 2>&1
    then
        log "Warning: could not ensure pg_prewarm in $db_name. Prewarm intervention will be skipped unless pg_prewarm is already installed."
        return
    fi

    prewarm_schema=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -U "$PG_EXTENSION_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_prewarm';
    " 2>/dev/null || true)

    if [ -z "$prewarm_schema" ]; then
        log "Warning: pg_prewarm extension was not found in $db_name after CREATE EXTENSION."
        return
    fi

    PGPASSWORD="$PG_EXTENSION_PWD" psql -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "
        DO \$\$
        DECLARE
            r record;
        BEGIN
            FOR r IN
                SELECT n.nspname AS schema_name,
                       p.proname AS function_name,
                       pg_get_function_identity_arguments(p.oid) AS function_args
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                JOIN pg_extension e ON e.extnamespace = n.oid
                WHERE e.extname = 'pg_prewarm'
                  AND p.proname IN ('pg_prewarm', 'autoprewarm_start_worker', 'autoprewarm_dump_now')
            LOOP
                EXECUTE format(
                    'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO %I',
                    r.schema_name,
                    r.function_name,
                    r.function_args,
                    '$grant_role_sql'
                );
            END LOOP;
        END
        \$\$;
        " >/dev/null 2>&1 || true
}

collect_cpu_memory_metrics() {
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum + 0}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum + 0}')
}

timestamp_ms() {
    date +%s%3N
}

csv_escape() {
    local value="${1:-}"
    value=${value//\"/\"\"}
    if [[ "$value" == *","* || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *"\""* ]]; then
        printf '"%s"' "$value"
    else
        printf '%s' "$value"
    fi
}

sql_escape_literal() {
    printf "%s" "${1:-}" | sed "s/'/''/g"
}

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

BENCHRUN_DIR=""
BENCHRUN_STARTED=0
BENCHRUN_CLEANED_UP=0
BENCHRUN_HEARTBEAT_PID=""
BENCHRUN_VMSTAT_PID=""
BENCHRUN_IOSTAT_PID=""
BENCHRUN_PHASE_SAMPLER_PID=""
BENCHRUN_CURRENT_PHASE_ID=""
BENCHRUN_CHILD_PIDS=()
BENCHRUN_CHILD_PGIDS=()

benchrun_phase_id() {
    printf '%s_%s_%s' "$1" "$2" "$3" | tr -c 'A-Za-z0-9_.-' '_'
}

benchrun_redact_stream() {
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL -eL sed -u -E \
            -e 's/(db\.passwd=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's/(db\.password=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's/((PGPASSWORD|DB_PWD|DB_PASS|PASSWORD|password|passwd)=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+(@)#\1[REDACTED]\3#g'
    else
        sed -u -E \
            -e 's/(db\.passwd=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's/(db\.password=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's/((PGPASSWORD|DB_PWD|DB_PASS|PASSWORD|password|passwd)=)[^[:space:]]+/\1[REDACTED]/g' \
            -e 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+(@)#\1[REDACTED]\3#g'
    fi
}

benchrun_copy_sanitized_file() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || return
    mkdir -p "$(dirname "$dst")"
    benchrun_redact_stream < "$src" > "$dst"
}

benchrun_common_args() {
    printf '%s\0' \
        --run-dir "$BENCHRUN_DIR" \
        --run-id "$BENCHRUN_RUN_ID" \
        --db-name "$1" \
        --db-user "$DB_USERNAME" \
        --target-table "$TARGET_TABLE"
}

benchrun_python() {
    local db_name="$1"
    shift

    if [ "$BENCHRUN_STARTED" != "1" ]; then
        return 0
    fi

    python3 "$OBSERVABILITY_HELPER" "$@" \
        --run-dir "$BENCHRUN_DIR" \
        --run-id "$BENCHRUN_RUN_ID" \
        --db-name "$db_name" \
        --db-user "$DB_USERNAME" \
        --target-table "$TARGET_TABLE"
}

benchrun_register_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] && BENCHRUN_CHILD_PIDS+=("$pid")
}

benchrun_register_pgid() {
    local pid="${1:-}"
    [ -n "$pid" ] && BENCHRUN_CHILD_PGIDS+=("$pid")
}

benchrun_unregister_pid() {
    local remove="${1:-}"
    local pid
    local keep=()
    for pid in "${BENCHRUN_CHILD_PIDS[@]:-}"; do
        [ "$pid" != "$remove" ] && keep+=("$pid")
    done
    BENCHRUN_CHILD_PIDS=("${keep[@]:-}")
}

benchrun_unregister_pgid() {
    local remove="${1:-}"
    local pid
    local keep=()
    for pid in "${BENCHRUN_CHILD_PGIDS[@]:-}"; do
        [ "$pid" != "$remove" ] && keep+=("$pid")
    done
    BENCHRUN_CHILD_PGIDS=("${keep[@]:-}")
}

benchrun_stop_pid() {
    local pid="${1:-}"
    [ -z "$pid" ] && return
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    benchrun_unregister_pid "$pid"
}

benchrun_stop_pgid() {
    local pid="${1:-}"
    [ -z "$pid" ] && return
    kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    benchrun_unregister_pgid "$pid"
}

benchrun_start_heartbeat() {
    (
        while true; do
            printf '%s heartbeat run_id=%s\n' "$(utc_now)" "$BENCHRUN_RUN_ID" >> "$BENCHRUN_DIR/heartbeat.log"
            sleep 60
        done
    ) &
    BENCHRUN_HEARTBEAT_PID=$!
    benchrun_register_pid "$BENCHRUN_HEARTBEAT_PID"
}

benchrun_start_os_watchers() {
    if [ "$BENCHRUN_ENABLE_OS_WATCHERS" != "1" ]; then
        return
    fi

    if command -v vmstat >/dev/null 2>&1; then
        vmstat "$BENCHRUN_SAMPLE_INTERVAL_SECONDS" >> "$BENCHRUN_DIR/samples/vmstat.log" 2>> "$BENCHRUN_DIR/logs/os_watchers.log" &
        BENCHRUN_VMSTAT_PID=$!
        benchrun_register_pid "$BENCHRUN_VMSTAT_PID"
    else
        printf '%s vmstat unavailable\n' "$(utc_now)" >> "$BENCHRUN_DIR/logs/os_watchers.log"
    fi

    if command -v iostat >/dev/null 2>&1; then
        iostat -x "$BENCHRUN_SAMPLE_INTERVAL_SECONDS" >> "$BENCHRUN_DIR/samples/iostat.log" 2>> "$BENCHRUN_DIR/logs/os_watchers.log" &
        BENCHRUN_IOSTAT_PID=$!
        benchrun_register_pid "$BENCHRUN_IOSTAT_PID"
    else
        printf '%s iostat unavailable\n' "$(utc_now)" >> "$BENCHRUN_DIR/logs/os_watchers.log"
    fi
}

benchrun_copy_existing_outputs() {
    [ "$BENCHRUN_STARTED" = "1" ] || return
    [ "$BENCHRUN_DRY_RUN_PREFLIGHT" = "1" ] && return

    mkdir -p "$BENCHRUN_DIR/ycsb" "$BENCHRUN_DIR/logs"
    [ -f "$LOG_FILE" ] && benchrun_copy_sanitized_file "$LOG_FILE" "$BENCHRUN_DIR/logs/$(basename "$LOG_FILE")" || true
    [ -f "$PLAN_LOG" ] && benchrun_copy_sanitized_file "$PLAN_LOG" "$BENCHRUN_DIR/logs/$(basename "$PLAN_LOG")" || true
    [ -f "$OUTPUT_FILE" ] && benchrun_copy_sanitized_file "$OUTPUT_FILE" "$BENCHRUN_DIR/ycsb/$(basename "$OUTPUT_FILE")" || true
    [ -f "$OUTPUT_CSV" ] && benchrun_copy_sanitized_file "$OUTPUT_CSV" "$BENCHRUN_DIR/ycsb/latest_ycsb_output.txt" || true
    [ -f "$KEY_SIZE_LOG" ] && benchrun_copy_sanitized_file "$KEY_SIZE_LOG" "$BENCHRUN_DIR/ycsb/$(basename "$KEY_SIZE_LOG")" || true
    [ -f "$KEY_SIZE_FILE_AFTER_EXTEND" ] && benchrun_copy_sanitized_file "$KEY_SIZE_FILE_AFTER_EXTEND" "$BENCHRUN_DIR/ycsb/$(basename "$KEY_SIZE_FILE_AFTER_EXTEND")" || true
    [ -f "$KEY_SIZE_FILE_AFTER_RUN" ] && benchrun_copy_sanitized_file "$KEY_SIZE_FILE_AFTER_RUN" "$BENCHRUN_DIR/ycsb/$(basename "$KEY_SIZE_FILE_AFTER_RUN")" || true
    if [ -d "$TRIGGER_DATA_DIR" ]; then
        mkdir -p "$BENCHRUN_DIR/logs/toast_spike_trigger"
        local trigger_file
        for trigger_file in "$TRIGGER_DATA_DIR"/*; do
            [ -f "$trigger_file" ] || continue
            benchrun_copy_sanitized_file "$trigger_file" "$BENCHRUN_DIR/logs/toast_spike_trigger/$(basename "$trigger_file")" || true
        done
    fi
}

benchrun_cleanup() {
    local status="${1:-$?}"
    local pid

    if [ "$BENCHRUN_STARTED" != "1" ] || [ "$BENCHRUN_CLEANED_UP" = "1" ]; then
        return "$status"
    fi
    BENCHRUN_CLEANED_UP=1
    trap - EXIT INT TERM

    for pid in "${BENCHRUN_CHILD_PGIDS[@]:-}"; do
        benchrun_stop_pgid "$pid"
    done
    for pid in "${BENCHRUN_CHILD_PIDS[@]:-}"; do
        benchrun_stop_pid "$pid"
    done

    benchrun_copy_existing_outputs
    if [ "$BENCHRUN_SKIP_DERIVED_ANALYSIS" != "1" ]; then
        benchrun_python "$DB_NAME" derive >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
    fi
    benchrun_python "$DB_NAME" manifest-finish --exit-status "$status" >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
    return "$status"
}

benchrun_init() {
    if [ "$BENCHRUN_STARTED" = "1" ]; then
        return
    fi

    if [ -z "$BENCHRUN_RUN_ID" ]; then
        BENCHRUN_RUN_ID="${RUN_NAME}_$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    BENCHRUN_DIR="${BENCHRUN_OUTPUT_DIR%/}/$BENCHRUN_RUN_ID"
    mkdir -p "$BENCHRUN_DIR/sql" "$BENCHRUN_DIR/snapshots" "$BENCHRUN_DIR/samples" "$BENCHRUN_DIR/ycsb" "$BENCHRUN_DIR/derived" "$BENCHRUN_DIR/logs"
    BENCHRUN_STARTED=1

    exec > >(benchrun_redact_stream | tee -a "$BENCHRUN_DIR/stdout.log") 2> >(benchrun_redact_stream | tee -a "$BENCHRUN_DIR/stderr.log" >&2)

    benchrun_python "$DB_NAME" manifest-init \
        --script-path "$0" \
        --repo-root "$YCSB_HOME/.." \
        --workload-file "$WORKLOAD_FILE" \
        --command-line "$ORIGINAL_COMMAND_LINE" \
        --db-url "$DB_URL" \
        --type-name "$TYPE" \
        --dist "$DIST" \
        --scale "$SCALE" \
        --work "$WORK" \
        --run-number "$RUN" \
        --value-variant "$VALUE_VARIANT" \
        --ycsb-binding "$YCSB_BINDING" \
        --field-sql-type "$FIELD_SQL_TYPE" \
        --sample-interval-seconds "$BENCHRUN_SAMPLE_INTERVAL_SECONDS" \
        --relation-size-sample-interval-seconds "$BENCHRUN_RELATION_SIZE_SAMPLE_INTERVAL_SECONDS" \
        --inspect-wal-ranges "$BENCHRUN_INSPECT_WAL_RANGES" \
        --full-visibility-profile "$BENCHRUN_FULL_VISIBILITY" \
        --require-full-visibility "$BENCHRUN_REQUIRE_FULL_VISIBILITY" \
        --pg-prewarm-enabled "$SPIKE_TRIGGER_PREWARM_ENABLED" \
        --pg-prewarm-mode "$SPIKE_TRIGGER_PREWARM_MODE" \
        --reset-pg-stats-before-run "$BENCHRUN_RESET_PG_STATS_BEFORE_RUN" \
        --skip-continuous-sampling "$BENCHRUN_SKIP_CONTINUOUS_SAMPLING" \
        --phase-value-sizes "$BENCHRUN_PHASE_VALUE_SIZES" \
        --output-csv "$OUTPUT_CSV" \
        --log-file "$LOG_FILE" \
        --plan-log "$PLAN_LOG" \
        --key-size-log "$KEY_SIZE_LOG" >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true

    benchrun_start_heartbeat
    benchrun_start_os_watchers
    trap 'benchrun_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

benchrun_preflight() {
    local db_name="${1:-$DB_NAME}"
    benchrun_python "$db_name" preflight >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
}

benchrun_maybe_reset_stats() {
    if [ "$BENCHRUN_RESET_PG_STATS_BEFORE_RUN" != "1" ]; then
        return
    fi
    benchrun_python "$DB_NAME" reset-stats >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
}

benchrun_log_phase_event() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local phase_id="$5"
    local ycsb_output="${6:-}"
    local exit_status="${7:-}"
    local operation_count value_size logical_bytes_per_op ycsb_copy

    if [ "$phase_label" = "prewarm" ]; then
        operation_count=0
        value_size=""
        logical_bytes_per_op=""
    else
        operation_count=$(awk -F= '/^operationcount=/{ value=$2 } END { print value }' "$WORKLOAD_FILE" 2>/dev/null || true)
        value_size=$(awk -F= '
            /^fieldlength=/{ field_length=$2 }
            /^extendfieldlength=/{ extend_field_length=$2 }
            END {
                if (field_length != "") {
                    print field_length
                } else {
                    print extend_field_length
                }
            }
        ' "$WORKLOAD_FILE" 2>/dev/null || true)
        if [[ "$value_size" =~ ^[0-9]+$ ]]; then
            logical_bytes_per_op=$((value_size * 10))
        else
            logical_bytes_per_op=""
        fi
        if [ -n "${LOGICAL_BYTES_PER_OP:-}" ]; then
            logical_bytes_per_op="$LOGICAL_BYTES_PER_OP"
        fi
    fi

    ycsb_copy=""
    if [ -n "$ycsb_output" ] && [ -f "$ycsb_output" ]; then
        ycsb_copy="$BENCHRUN_DIR/ycsb/${phase_id}.out"
        benchrun_copy_sanitized_file "$ycsb_output" "$ycsb_copy" 2>/dev/null || ycsb_copy="$ycsb_output"
    fi

    benchrun_python "$db_name" phase \
        --phase-id "$phase_id" \
        --phase-name "$phase_label" \
        --epoch "$epoch_label" \
        --event "$event_label" \
        --operation-count "$operation_count" \
        --value-size-bytes "$value_size" \
        --logical-bytes-per-op "$logical_bytes_per_op" \
        --ycsb-output "$ycsb_copy" \
        --exit-status "$exit_status" >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
}

benchrun_start_phase() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local phase_id

    [ "$BENCHRUN_STARTED" = "1" ] || return
    phase_id=$(benchrun_phase_id "$db_name" "$phase_label" "$epoch_label")
    BENCHRUN_CURRENT_PHASE_ID="$phase_id"
    benchrun_log_phase_event "$db_name" "$phase_label" "$epoch_label" "before" "$phase_id"
    benchrun_python "$db_name" snapshot --phase-id "$phase_id" --label before >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true

    if [ "$BENCHRUN_SKIP_CONTINUOUS_SAMPLING" != "1" ]; then
        python3 "$OBSERVABILITY_HELPER" sample \
            --run-dir "$BENCHRUN_DIR" \
            --run-id "$BENCHRUN_RUN_ID" \
            --db-name "$db_name" \
            --db-user "$DB_USERNAME" \
            --target-table "$TARGET_TABLE" \
            --phase-id "$phase_id" \
            --sample-interval-seconds "$BENCHRUN_SAMPLE_INTERVAL_SECONDS" \
            --relation-size-sample-interval-seconds "$BENCHRUN_RELATION_SIZE_SAMPLE_INTERVAL_SECONDS" \
            >/dev/null 2>> "$BENCHRUN_DIR/logs/sampler_errors.log" &
        BENCHRUN_PHASE_SAMPLER_PID=$!
        benchrun_register_pid "$BENCHRUN_PHASE_SAMPLER_PID"
    fi
}

benchrun_stop_phase_sampler() {
    if [ -n "${BENCHRUN_PHASE_SAMPLER_PID:-}" ]; then
        benchrun_stop_pid "$BENCHRUN_PHASE_SAMPLER_PID"
        BENCHRUN_PHASE_SAMPLER_PID=""
    fi
}

benchrun_finish_phase() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local ycsb_output="${4:-}"
    local exit_status="${5:-}"
    local phase_id

    [ "$BENCHRUN_STARTED" = "1" ] || return
    phase_id="${BENCHRUN_CURRENT_PHASE_ID:-$(benchrun_phase_id "$db_name" "$phase_label" "$epoch_label")}"
    benchrun_stop_phase_sampler
    benchrun_log_phase_event "$db_name" "$phase_label" "$epoch_label" "after" "$phase_id" "$ycsb_output" "$exit_status"
    benchrun_python "$db_name" snapshot --phase-id "$phase_id" --label after >/dev/null 2>> "$BENCHRUN_DIR/logs/observability_errors.log" || true
    BENCHRUN_CURRENT_PHASE_ID=""
}

init_spike_trigger_trace() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    rm -rf "$TRIGGER_DATA_DIR"
    mkdir -p "$TRIGGER_DATA_DIR"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,timestamp_iso,record_count,operation_count,request_distribution,field_length,notes"
    } > "$PHASE_TIMELINE_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,checkpoints_timed,checkpoints_req,checkpoint_write_time,checkpoint_sync_time,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,wal_bytes,wal_records"
    } > "$CHECKPOINT_OBSERVATIONS_FILE"
    {
        echo "run_name,event,timestamp_unix_ms,name,setting"
    } > "$CHECKPOINT_LOG_SETTINGS_FILE"
    {
        echo "run_name,epoch,phase,event,observed_timestamp_unix_ms,source,message"
    } > "$CHECKPOINT_LOG_MESSAGES_FILE"
    > "$CHECKPOINT_LOG_SEEN_FILE"
    {
        echo "run_name,epoch,timestamp_unix_ms,relation,phase,heap_blks_total,heap_blks_scanned,heap_blks_vacuumed,index_vacuum_count,max_dead_tuples,num_dead_tuples"
    } > "$VACUUM_PROGRESS_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,relation_name,buffers,bytes"
    } > "$BUFFER_RESIDENCY_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,relation_role,relation_name,relation_oid,relfilenode,relforknumber,relblocknumber,usagecount,isdirty,pinning_backends,bufferid"
    } > "$BUFFER_PAGE_IDENTITY_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,relation_role,relation_name,relation_oid,relfilenode,relation_pages,sampled_pages,sample_step,estimated_free_bytes,avg_free_bytes,p50_free_bytes,p90_free_bytes,p99_free_bytes,estimated_pages_gt_half_free,max_free_bytes"
    } > "$FREESPACE_SUMMARY_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,source,userid,dbid,queryid,calls,total_exec_time,mean_exec_time,max_exec_time,stddev_exec_time,rows,shared_blks_hit,shared_blks_read,shared_blks_dirtied,shared_blks_written,blk_read_time,blk_write_time,temp_blks_read,temp_blks_written,wal_records,wal_bytes,query"
    } > "$PG_STAT_STATEMENTS_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,db_name,lsn,wal_bytes_since_start,source,message"
    } > "$WAL_BOUNDS_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,db_name,start_lsn,end_lsn,wal_bytes,source,resource_manager_record_type,count,count_percentage,record_size,record_size_percentage,fpi_size,fpi_size_percentage,combined_size,combined_size_percentage,message"
    } > "$WAL_STATS_FILE"
    {
        echo "run_name,epoch,phase,event,timestamp_unix_ms,db_name,mode,relation_role,relation_name,relation_oid,relation_size_bytes,blocks_done,status,message"
    } > "$PREWARM_FILE"
    {
        echo "run_name,epoch,phase,timestamp_unix_ms,probe_label,ycsb_key,size_bytes"
    } > "$SAMPLED_DETOAST_PROBE_LOG"

    TRACE_START_EPOCH_SECONDS=$(date +%s)
}

record_phase_event() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return 0
    fi

    local phase_label="$1"
    local epoch_label="$2"
    local event_label="$3"
    local notes="${4:-}"
    local ts_ms iso operation_count field_length

    ts_ms=$(timestamp_ms)
    iso=$(date -Iseconds)
    operation_count=$(awk -F= '/^operationcount=/{ value=$2 } END { print value }' "$WORKLOAD_FILE" 2>/dev/null || true)
    field_length=$(awk -F= '
        /^fieldlength=/{ field_length=$2 }
        /^extendfieldlength=/{ extend_field_length=$2 }
        END {
            if (field_length != "") {
                print field_length
            } else {
                print extend_field_length
            }
        }
    ' "$WORKLOAD_FILE" 2>/dev/null || true)
    if [ "$phase_label" = "prewarm" ]; then
        operation_count=0
        field_length=""
    fi

    {
        csv_escape "$RUN_NAME"; printf ','
        printf '%s,%s,%s,%s,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
        csv_escape "$iso"; printf ','
        csv_escape "${recordcount:-}"; printf ','
        csv_escape "$operation_count"; printf ','
        csv_escape "${requestdistribution:-}"; printf ','
        csv_escape "$field_length"; printf ','
        csv_escape "$notes"; printf '\n'
    } >> "$PHASE_TIMELINE_FILE"

    return 0
}

record_checkpoint_observation() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local ts_ms row

    ts_ms=$(timestamp_ms)
    row=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," -c "
        SELECT bg.checkpoints_timed, bg.checkpoints_req,
               bg.checkpoint_write_time, bg.checkpoint_sync_time,
               bg.buffers_checkpoint, bg.buffers_clean, bg.buffers_backend,
               bg.buffers_alloc,
               COALESCE(wal.wal_bytes, 0), COALESCE(wal.wal_records, 0)
        FROM pg_stat_bgwriter bg
        CROSS JOIN LATERAL (
            SELECT wal_bytes, wal_records
            FROM pg_stat_wal
        ) wal;
    " 2>/dev/null || true)

    [ -z "$row" ] && row="NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL"
    echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,$row" >> "$CHECKPOINT_OBSERVATIONS_FILE"
    collect_checkpoint_log_messages "$phase_label" "$epoch_label" "$event_label"
}

pg_stat_statements_schema() {
    local db_name="$1"

    PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_stat_statements';
    " 2>/dev/null || true
}

record_pg_stat_statements_status_row() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED" != "1" ]; then
        return
    fi

    local phase_label="$1"
    local epoch_label="$2"
    local event_label="$3"
    local source_label="$4"
    local message="${5:-}"
    local ts_ms i

    ts_ms=$(timestamp_ms)
    {
        csv_escape "$RUN_NAME"; printf ','
        printf '%s,%s,%s,%s,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
        csv_escape "$source_label"
        i=0
        while [ "$i" -lt 19 ]; do
            printf ',NULL'
            i=$((i + 1))
        done
        printf ','
        csv_escape "$message"
        printf '\n'
    } >> "$PG_STAT_STATEMENTS_FILE"
}

reset_pg_stat_statements() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] \
        || [ "$SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED" != "1" ] \
        || [ "$SPIKE_TRIGGER_PG_STAT_STATEMENTS_RESET_PER_PHASE" != "1" ]
    then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local statements_schema psql_output psql_status had_errexit

    statements_schema=$(pg_stat_statements_schema "$db_name")
    if [ -z "$statements_schema" ]; then
        record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_unavailable" "extension not installed in $db_name"
        return
    fi

    had_errexit=0
    case $- in
        *e*) had_errexit=1; set +e ;;
    esac
    psql_output=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "SELECT ${statements_schema}.pg_stat_statements_reset();" 2>&1)
    psql_status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    if [ "$psql_status" -ne 0 ]; then
        record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_reset_failed" "$psql_output"
        return
    fi

    record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_reset" "reset ok"
}

record_pg_stat_statements() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local ts_ms statements_schema top_n query_filter query_filter_sql rows_output psql_status had_errexit
    local userid dbid queryid calls total_exec_time mean_exec_time max_exec_time stddev_exec_time
    local rows_count shared_blks_hit shared_blks_read shared_blks_dirtied shared_blks_written
    local blk_read_time blk_write_time temp_blks_read temp_blks_written wal_records wal_bytes query_text

    statements_schema=$(pg_stat_statements_schema "$db_name")
    if [ -z "$statements_schema" ]; then
        record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_unavailable" "extension not installed in $db_name"
        return
    fi

    top_n="$SPIKE_TRIGGER_PG_STAT_STATEMENTS_TOP_N"
    if ! [[ "$top_n" =~ ^[0-9]+$ ]] || [ "$top_n" -lt 1 ]; then
        top_n=25
    fi
    query_filter="$SPIKE_TRIGGER_PG_STAT_STATEMENTS_QUERY_FILTER"
    query_filter_sql=$(sql_escape_literal "$query_filter")
    ts_ms=$(timestamp_ms)

    had_errexit=0
    case $- in
        *e*) had_errexit=1; set +e ;;
    esac
    rows_output=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -F $'\t' -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" -c "
        WITH stats AS (
            SELECT s.userid::text AS userid,
                   s.dbid::text AS dbid,
                   s.query,
                   to_jsonb(s) AS js
            FROM ${statements_schema}.pg_stat_statements s
            WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND ('$query_filter_sql' = '' OR s.query ILIKE '%' || '$query_filter_sql' || '%')
              AND s.query NOT ILIKE '%pg_stat_statements%'
        )
        SELECT userid,
               dbid,
               COALESCE(js->>'queryid', 'NULL'),
               COALESCE(js->>'calls', 'NULL'),
               COALESCE(js->>'total_exec_time', js->>'total_time', 'NULL'),
               COALESCE(js->>'mean_exec_time', js->>'mean_time', 'NULL'),
               COALESCE(js->>'max_exec_time', js->>'max_time', 'NULL'),
               COALESCE(js->>'stddev_exec_time', js->>'stddev_time', 'NULL'),
               COALESCE(js->>'rows', 'NULL'),
               COALESCE(js->>'shared_blks_hit', 'NULL'),
               COALESCE(js->>'shared_blks_read', 'NULL'),
               COALESCE(js->>'shared_blks_dirtied', 'NULL'),
               COALESCE(js->>'shared_blks_written', 'NULL'),
               COALESCE(js->>'blk_read_time', 'NULL'),
               COALESCE(js->>'blk_write_time', 'NULL'),
               COALESCE(js->>'temp_blks_read', 'NULL'),
               COALESCE(js->>'temp_blks_written', 'NULL'),
               COALESCE(js->>'wal_records', 'NULL'),
               COALESCE(js->>'wal_bytes', 'NULL'),
               regexp_replace(query, E'[\\t\\n\\r]+', ' ', 'g')
        FROM stats
        ORDER BY COALESCE(
            NULLIF(js->>'total_exec_time', '')::numeric,
            NULLIF(js->>'total_time', '')::numeric,
            0
        ) DESC
        LIMIT $top_n;
    " 2>&1)
    psql_status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    if [ "$psql_status" -ne 0 ]; then
        record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_snapshot_failed" "$rows_output"
        return
    fi
    if [ -z "$rows_output" ]; then
        record_pg_stat_statements_status_row "$phase_label" "$epoch_label" "$event_label" "pg_stat_statements_empty" "no matching statements for filter '$query_filter'"
        return
    fi

    while IFS=$'\t' read -r userid dbid queryid calls total_exec_time mean_exec_time max_exec_time stddev_exec_time \
        rows_count shared_blks_hit shared_blks_read shared_blks_dirtied shared_blks_written \
        blk_read_time blk_write_time temp_blks_read temp_blks_written wal_records wal_bytes query_text
    do
        [ -z "$userid$dbid$queryid$calls$query_text" ] && continue
        {
            csv_escape "$RUN_NAME"; printf ','
            printf '%s,%s,%s,%s,snapshot,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
                "$userid" "$dbid" "$queryid" "$calls" "$total_exec_time" "$mean_exec_time" \
                "$max_exec_time" "$stddev_exec_time" "$rows_count" "$shared_blks_hit" \
                "$shared_blks_read" "$shared_blks_dirtied" "$shared_blks_written" \
                "$blk_read_time" "$blk_write_time" "$temp_blks_read" "$temp_blks_written" \
                "$wal_records" "$wal_bytes"
            csv_escape "$query_text"
            printf '\n'
        } >> "$PG_STAT_STATEMENTS_FILE"
    done <<< "$rows_output"
}

pg_walinspect_schema() {
    local db_name="$1"

    PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_walinspect';
    " 2>/dev/null || true
}

wal_lsn_is_valid() {
    [[ "${1:-}" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]]
}

record_wal_boundary_row() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_WALINSPECT_ENABLED" != "1" ]; then
        return
    fi

    local phase_label="$1"
    local epoch_label="$2"
    local event_label="$3"
    local db_name="$4"
    local lsn="${5:-NULL}"
    local wal_bytes="${6:-NULL}"
    local source_label="$7"
    local message="${8:-}"
    local ts_ms

    [ -z "$lsn" ] && lsn="NULL"
    [ -z "$wal_bytes" ] && wal_bytes="NULL"
    ts_ms=$(timestamp_ms)

    {
        csv_escape "$RUN_NAME"; printf ','
        printf '%s,%s,%s,%s,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
        csv_escape "$db_name"; printf ','
        printf '%s,%s,' "$lsn" "$wal_bytes"
        csv_escape "$source_label"; printf ','
        csv_escape "$message"; printf '\n'
    } >> "$WAL_BOUNDS_FILE"
}

record_wal_stats_status_row() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_WALINSPECT_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local start_lsn="${5:-NULL}"
    local end_lsn="${6:-NULL}"
    local wal_bytes="${7:-NULL}"
    local source_label="$8"
    local message="${9:-}"
    local ts_ms i

    [ -z "$start_lsn" ] && start_lsn="NULL"
    [ -z "$end_lsn" ] && end_lsn="NULL"
    [ -z "$wal_bytes" ] && wal_bytes="NULL"
    ts_ms=$(timestamp_ms)

    {
        csv_escape "$RUN_NAME"; printf ','
        printf '%s,%s,%s,%s,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
        csv_escape "$db_name"; printf ','
        printf '%s,%s,%s,' "$start_lsn" "$end_lsn" "$wal_bytes"
        csv_escape "$source_label"
        i=0
        while [ "$i" -lt 9 ]; do
            printf ',NULL'
            i=$((i + 1))
        done
        printf ','
        csv_escape "$message"
        printf '\n'
    } >> "$WAL_STATS_FILE"
}

wal_lsn_diff_bytes() {
    local db_name="$1"
    local start_lsn="$2"
    local end_lsn="$3"
    local diff_output psql_status had_errexit

    if ! wal_lsn_is_valid "$start_lsn" || ! wal_lsn_is_valid "$end_lsn"; then
        echo ""
        return 0
    fi

    had_errexit=0
    case $- in
        *e*) had_errexit=1; set +e ;;
    esac
    diff_output=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "SELECT pg_wal_lsn_diff('$end_lsn'::pg_lsn, '$start_lsn'::pg_lsn)::numeric::bigint;" 2>&1)
    psql_status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    if [ "$psql_status" -ne 0 ] || ! [[ "$diff_output" =~ ^-?[0-9]+$ ]]; then
        echo ""
        return 0
    fi

    echo "$diff_output"
}

record_wal_boundary() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_WALINSPECT_ENABLED" != "1" ]; then
        echo ""
        return 0
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local start_lsn="${5:-}"
    local current_lsn psql_status had_errexit wal_bytes

    had_errexit=0
    case $- in
        *e*) had_errexit=1; set +e ;;
    esac
    current_lsn=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" \
        -c "SELECT pg_current_wal_lsn();" 2>&1)
    psql_status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    if [ "$psql_status" -ne 0 ] || ! wal_lsn_is_valid "$current_lsn"; then
        record_wal_boundary_row "$phase_label" "$epoch_label" "$event_label" "$db_name" "NULL" "NULL" "wal_lsn_failed" "$current_lsn"
        echo ""
        return 0
    fi

    wal_bytes="NULL"
    if wal_lsn_is_valid "$start_lsn"; then
        wal_bytes=$(wal_lsn_diff_bytes "$db_name" "$start_lsn" "$current_lsn")
        [ -z "$wal_bytes" ] && wal_bytes="NULL"
    fi

    record_wal_boundary_row "$phase_label" "$epoch_label" "$event_label" "$db_name" "$current_lsn" "$wal_bytes" "boundary" ""
    echo "$current_lsn"
}

record_wal_stats() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_WALINSPECT_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local start_lsn="${5:-}"
    local end_lsn="${6:-}"
    local walinspect_schema wal_bytes max_bytes per_record rows_output psql_status had_errexit ts_ms
    local resource_manager_record_type count count_percentage record_size record_size_percentage
    local fpi_size fpi_size_percentage combined_size combined_size_percentage

    if ! wal_lsn_is_valid "$start_lsn" || ! wal_lsn_is_valid "$end_lsn"; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "NULL" "walinspect_missing_bounds" "start or end LSN was not captured"
        return
    fi

    walinspect_schema=$(pg_walinspect_schema "$db_name")
    if [ -z "$walinspect_schema" ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "NULL" "pg_walinspect_unavailable" "extension not installed in $db_name"
        return
    fi

    wal_bytes=$(wal_lsn_diff_bytes "$db_name" "$start_lsn" "$end_lsn")
    if [ -z "$wal_bytes" ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "NULL" "walinspect_lsn_diff_failed" "could not calculate WAL bytes for phase"
        return
    fi
    if [ "$wal_bytes" -le 0 ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "$wal_bytes" "walinspect_empty_range" "no WAL generated between phase boundaries"
        return
    fi

    max_bytes="$SPIKE_TRIGGER_WALINSPECT_MAX_BYTES"
    if ! [[ "$max_bytes" =~ ^[0-9]+$ ]]; then
        max_bytes=0
    fi
    if [ "$max_bytes" -gt 0 ] && [ "$wal_bytes" -gt "$max_bytes" ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "$wal_bytes" "walinspect_skipped_range_too_large" "WAL range exceeds SPIKE_TRIGGER_WALINSPECT_MAX_BYTES=$max_bytes"
        return
    fi

    per_record=false
    if [ "$SPIKE_TRIGGER_WALINSPECT_PER_RECORD" = "1" ]; then
        per_record=true
    fi
    ts_ms=$(timestamp_ms)

    had_errexit=0
    case $- in
        *e*) had_errexit=1; set +e ;;
    esac
    rows_output=$(PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -F $'\t' -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" -c "
        WITH stats AS (
            SELECT to_jsonb(w) AS js
            FROM ${walinspect_schema}.pg_get_wal_stats('$start_lsn'::pg_lsn, '$end_lsn'::pg_lsn, $per_record) AS w
        )
        SELECT COALESCE(NULLIF(js->>'resource_manager/record_type', ''), NULLIF(concat_ws('/', js->>'resource_manager', js->>'record_type'), ''), 'NULL'),
               COALESCE(js->>'count', 'NULL'),
               COALESCE(js->>'count_percentage', 'NULL'),
               COALESCE(js->>'record_size', 'NULL'),
               COALESCE(js->>'record_size_percentage', 'NULL'),
               COALESCE(js->>'fpi_size', 'NULL'),
               COALESCE(js->>'fpi_size_percentage', 'NULL'),
               COALESCE(js->>'combined_size', 'NULL'),
               COALESCE(js->>'combined_size_percentage', 'NULL')
        FROM stats
        ORDER BY COALESCE(NULLIF(js->>'combined_size', '')::numeric, 0) DESC;
    " 2>&1)
    psql_status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    if [ "$psql_status" -ne 0 ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "$wal_bytes" "walinspect_snapshot_failed" "$rows_output"
        return
    fi
    if [ -z "$rows_output" ]; then
        record_wal_stats_status_row "$db_name" "$phase_label" "$epoch_label" "$event_label" "$start_lsn" "$end_lsn" "$wal_bytes" "walinspect_empty_stats" "pg_get_wal_stats returned no rows"
        return
    fi

    while IFS=$'\t' read -r resource_manager_record_type count count_percentage record_size record_size_percentage \
        fpi_size fpi_size_percentage combined_size combined_size_percentage
    do
        [ -z "$resource_manager_record_type$count$record_size$combined_size" ] && continue
        {
            csv_escape "$RUN_NAME"; printf ','
            printf '%s,%s,%s,%s,' "$epoch_label" "$phase_label" "$event_label" "$ts_ms"
            csv_escape "$db_name"; printf ','
            printf '%s,%s,%s,snapshot,' "$start_lsn" "$end_lsn" "$wal_bytes"
            csv_escape "$resource_manager_record_type"; printf ','
            printf '%s,%s,%s,%s,%s,%s,%s,%s,' \
                "$count" "$count_percentage" "$record_size" "$record_size_percentage" \
                "$fpi_size" "$fpi_size_percentage" "$combined_size" "$combined_size_percentage"
            printf '\n'
        } >> "$WAL_STATS_FILE"
    done <<< "$rows_output"
}

full_visibility_psql() {
    local db_name="$1"
    local sql="$2"

    PGPASSWORD="$PG_EXTENSION_PWD" psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -U "$PG_EXTENSION_USERNAME" -d "$db_name" -c "$sql" 2>&1
}

require_full_visibility_ready() {
    if [ "$BENCHRUN_REQUIRE_FULL_VISIBILITY" != "1" ]; then
        return
    fi

    local db_name="$1"
    local fail=0
    local value statements_schema walinspect_schema server_version_num view ext

    full_visibility_fail() {
        log "Full visibility preflight failed: $1"
        fail=1
    }

    log "Checking full visibility prerequisites in $db_name..."

    if ! value=$(full_visibility_psql "$db_name" "SHOW shared_preload_libraries;"); then
        full_visibility_fail "could not read shared_preload_libraries: $value"
    elif ! grep -Eq '(^|,)[[:space:]]*pg_stat_statements[[:space:]]*(,|$)' <<< "$value"; then
        full_visibility_fail "pg_stat_statements is not in shared_preload_libraries; add it and restart PostgreSQL"
    fi

    if ! value=$(full_visibility_psql "$db_name" "SHOW track_io_timing;"); then
        full_visibility_fail "could not read track_io_timing: $value"
    elif [ "$value" != "on" ]; then
        full_visibility_fail "track_io_timing is '$value'; set it to on for timing visibility"
    fi

    if ! value=$(full_visibility_psql "$db_name" "SHOW log_checkpoints;"); then
        full_visibility_fail "could not read log_checkpoints: $value"
    elif [ "$value" != "on" ]; then
        full_visibility_fail "log_checkpoints is '$value'; set it to on for checkpoint log-message visibility"
    fi

    for view in pg_stat_wal pg_stat_bgwriter pg_stat_activity; do
        if ! value=$(full_visibility_psql "$db_name" "SELECT to_regclass('pg_catalog.$view') IS NOT NULL;"); then
            full_visibility_fail "could not check $view: $value"
        elif [ "$value" != "t" ]; then
            full_visibility_fail "$view is unavailable"
        fi
    done

    server_version_num=$(full_visibility_psql "$db_name" "SHOW server_version_num;" || true)
    if [[ "$server_version_num" =~ ^[0-9]+$ ]] && [ "$server_version_num" -ge 160000 ]; then
        if ! value=$(full_visibility_psql "$db_name" "SELECT to_regclass('pg_catalog.pg_stat_io') IS NOT NULL;"); then
            full_visibility_fail "could not check pg_stat_io: $value"
        elif [ "$value" != "t" ]; then
            full_visibility_fail "pg_stat_io is unavailable on PostgreSQL $server_version_num"
        fi
    fi

    for ext in pg_buffercache pg_freespacemap pg_stat_statements pg_walinspect; do
        if ! value=$(full_visibility_psql "$db_name" "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = '$ext');"); then
            full_visibility_fail "could not check extension $ext: $value"
        elif [ "$value" != "t" ]; then
            full_visibility_fail "extension $ext is not installed in $db_name"
        fi
    done

    statements_schema=$(pg_stat_statements_schema "$db_name")
    if [ -z "$statements_schema" ]; then
        full_visibility_fail "pg_stat_statements schema is not visible in $db_name"
    elif ! value=$(full_visibility_psql "$db_name" "SELECT count(*) FROM ${statements_schema}.pg_stat_statements;"); then
        full_visibility_fail "pg_stat_statements is installed but not queryable: $value"
    fi

    walinspect_schema=$(pg_walinspect_schema "$db_name")
    if [ -z "$walinspect_schema" ]; then
        full_visibility_fail "pg_walinspect schema is not visible in $db_name"
    elif ! value=$(full_visibility_psql "$db_name" "
        SELECT EXISTS (
            SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE quote_ident(n.nspname) = '$walinspect_schema'
              AND p.proname = 'pg_get_wal_stats'
              AND has_function_privilege(current_user, p.oid, 'execute')
        );
    "); then
        full_visibility_fail "could not check pg_walinspect execute privilege: $value"
    elif [ "$value" != "t" ]; then
        full_visibility_fail "pg_walinspect is installed but pg_get_wal_stats is not executable by $PG_EXTENSION_USERNAME"
    fi

    if [ "$fail" -ne 0 ]; then
        log "Full visibility run cannot start. Fix PostgreSQL prerequisites or rerun without --require-full-visibility."
        benchrun_cleanup 2 || true
        exit 2
    fi

    log "Full visibility prerequisites passed in $db_name."
}

list_contains_word() {
    local list="$1"
    local needle="$2"
    local word

    for word in $list; do
        if [ "$word" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

epoch_in_ranges() {
    local epoch_label="$1"
    local ranges="$2"
    local item start end

    if ! [[ "$epoch_label" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    for item in $ranges; do
        if [[ "$item" =~ ^[0-9]+-[0-9]+$ ]]; then
            start=${item%-*}
            end=${item#*-}
            if [ "$epoch_label" -ge "$start" ] && [ "$epoch_label" -le "$end" ]; then
                return 0
            fi
        elif [[ "$item" =~ ^[0-9]+$ ]] && [ "$epoch_label" -eq "$item" ]; then
            return 0
        fi
    done

    return 1
}

should_capture_page_identity() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"

    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_PAGE_IDENTITY_ENABLED" != "1" ]; then
        return 1
    fi

    # Keep page-identity capture scoped to the primary benchmark database by default.
    # Control/read-only phases use the relation-level snapshot without the heavier page listing.
    if [ "$db_name" != "$DB_NAME" ]; then
        return 1
    fi

    if list_contains_word "$SPIKE_TRIGGER_PAGE_IDENTITY_BASE_EVENTS" "$event_label"; then
        return 0
    fi

    if epoch_in_ranges "$epoch_label" "$SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EPOCHS" \
        && list_contains_word "$SPIKE_TRIGGER_PAGE_IDENTITY_FOCUS_EVENTS" "$event_label"
    then
        return 0
    fi

    return 1
}

should_capture_freespace() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"

    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$SPIKE_TRIGGER_FREESPACE_ENABLED" != "1" ]; then
        return 1
    fi

    # Fragmentation evidence is only needed for the growing primary database.
    if [ "$db_name" != "$DB_NAME" ]; then
        return 1
    fi

    if list_contains_word "$SPIKE_TRIGGER_FREESPACE_BASE_EVENTS" "$event_label"; then
        return 0
    fi

    if epoch_in_ranges "$epoch_label" "$SPIKE_TRIGGER_FREESPACE_FOCUS_EPOCHS" \
        && list_contains_word "$SPIKE_TRIGGER_FREESPACE_FOCUS_EVENTS" "$event_label"
    then
        return 0
    fi

    return 1
}

record_buffer_residency() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local ts_ms buffercache_schema rows

    ts_ms=$(timestamp_ms)
    buffercache_schema=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_buffercache';
    " 2>/dev/null || true)
    if [ -z "$buffercache_schema" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_buffercache_unavailable,NULL,NULL" >> "$BUFFER_RESIDENCY_FILE"
        return
    fi

    rows=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," -c "
        WITH heap AS (
            SELECT c.oid AS heap_oid,
                   c.relname AS heap_name,
                   c.reltoastrelid AS toast_oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = 'usertable'
            ORDER BY n.nspname = 'public' DESC, n.nspname
            LIMIT 1
        ),
        rels AS (
            SELECT heap_oid AS oid, heap_name AS relname FROM heap
            UNION ALL
            SELECT toast_oid, t.relname
            FROM heap h
            JOIN pg_class t ON t.oid = h.toast_oid
            WHERE h.toast_oid <> 0
            UNION ALL
            SELECT i.indexrelid, ci.relname
            FROM heap h
            JOIN pg_index i ON i.indrelid = h.toast_oid
            JOIN pg_class ci ON ci.oid = i.indexrelid
        )
        SELECT rels.relname,
               count(b.*) AS buffers,
               count(b.*) * current_setting('block_size')::int AS bytes
        FROM rels
        LEFT JOIN ${buffercache_schema}.pg_buffercache b ON b.relfilenode = pg_relation_filenode(rels.oid)
        GROUP BY rels.relname
        ORDER BY rels.relname;
    " 2>/dev/null || true)

    if [ -z "$rows" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_buffercache_empty,NULL,NULL" >> "$BUFFER_RESIDENCY_FILE"
        return
    fi

    while IFS= read -r row; do
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,$row" >> "$BUFFER_RESIDENCY_FILE"
    done <<< "$rows"
}

record_buffer_page_identity() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local ts_ms buffercache_schema rows sample_mod min_usagecount

    if ! should_capture_page_identity "$db_name" "$phase_label" "$epoch_label" "$event_label"; then
        return
    fi

    ts_ms=$(timestamp_ms)
    sample_mod="$SPIKE_TRIGGER_PAGE_IDENTITY_SAMPLE_MOD"
    min_usagecount="$SPIKE_TRIGGER_PAGE_IDENTITY_MIN_USAGECOUNT"

    if ! [[ "$sample_mod" =~ ^[0-9]+$ ]] || [ "$sample_mod" -lt 1 ]; then
        sample_mod=32
    fi
    if ! [[ "$min_usagecount" =~ ^[0-9]+$ ]]; then
        min_usagecount=4
    fi

    buffercache_schema=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_buffercache';
    " 2>/dev/null || true)
    if [ -z "$buffercache_schema" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_buffercache_unavailable,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL" >> "$BUFFER_PAGE_IDENTITY_FILE"
        return
    fi

    rows=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," -c "
        WITH current_db AS (
            SELECT oid
            FROM pg_database
            WHERE datname = current_database()
        ),
        heap AS (
            SELECT c.oid AS heap_oid,
                   c.relname AS heap_name,
                   c.reltoastrelid AS toast_oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = 'usertable'
            ORDER BY n.nspname = 'public' DESC, n.nspname
            LIMIT 1
        ),
        rels AS (
            SELECT 'heap' AS relation_role, heap_oid AS rel_oid, heap_name AS relation_name
            FROM heap
            UNION ALL
            SELECT 'toast_heap', t.oid, t.relname
            FROM heap h
            JOIN pg_class t ON t.oid = h.toast_oid
            WHERE h.toast_oid <> 0
            UNION ALL
            SELECT 'toast_index', i.indexrelid, ci.relname
            FROM heap h
            JOIN pg_index i ON i.indrelid = h.toast_oid
            JOIN pg_class ci ON ci.oid = i.indexrelid
            WHERE h.toast_oid <> 0
        ),
        rel_map AS (
            SELECT relation_role,
                   relation_name,
                   rel_oid,
                   pg_relation_filenode(rel_oid) AS relfilenode
            FROM rels
        )
        SELECT rel_map.relation_role,
               rel_map.relation_name,
               rel_map.rel_oid,
               rel_map.relfilenode,
               b.relforknumber,
               b.relblocknumber,
               COALESCE(b.usagecount, -1),
               COALESCE(b.isdirty, false),
               COALESCE(b.pinning_backends, 0),
               b.bufferid
        FROM rel_map
        JOIN ${buffercache_schema}.pg_buffercache b
          ON b.relfilenode = rel_map.relfilenode
         AND b.reldatabase = (SELECT oid FROM current_db)
        WHERE rel_map.relfilenode IS NOT NULL
          AND b.relblocknumber IS NOT NULL
          AND b.relforknumber = 0
          AND (
              $sample_mod <= 1
              OR (b.relblocknumber % $sample_mod) = 0
              OR COALESCE(b.usagecount, 0) >= $min_usagecount
          )
        ORDER BY rel_map.relation_role, b.relblocknumber, b.bufferid;
    " 2>/dev/null || true)

    if [ -z "$rows" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_buffercache_empty,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL" >> "$BUFFER_PAGE_IDENTITY_FILE"
        return
    fi

    while IFS= read -r row; do
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,$row" >> "$BUFFER_PAGE_IDENTITY_FILE"
    done <<< "$rows"
}

record_freespace_summary() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local event_label="$4"
    local ts_ms freespacemap_schema rows max_sample_pages

    if ! should_capture_freespace "$db_name" "$phase_label" "$epoch_label" "$event_label"; then
        return
    fi

    ts_ms=$(timestamp_ms)
    max_sample_pages="$SPIKE_TRIGGER_FREESPACE_SAMPLE_MAX_PAGES"

    if ! [[ "$max_sample_pages" =~ ^[0-9]+$ ]]; then
        max_sample_pages=4096
    fi

    freespacemap_schema=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_freespacemap';
    " 2>/dev/null || true)
    if [ -z "$freespacemap_schema" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_freespacemap_unavailable,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL" >> "$FREESPACE_SUMMARY_FILE"
        return
    fi

    rows=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," -c "
        WITH heap AS (
            SELECT c.oid AS heap_oid,
                   c.relname AS heap_name,
                   c.reltoastrelid AS toast_oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = 'usertable'
            ORDER BY n.nspname = 'public' DESC, n.nspname
            LIMIT 1
        ),
        rels AS (
            SELECT 'heap' AS relation_role, heap_oid AS rel_oid, heap_name AS relation_name
            FROM heap
            UNION ALL
            SELECT 'toast_heap', t.oid, t.relname
            FROM heap h
            JOIN pg_class t ON t.oid = h.toast_oid
            WHERE h.toast_oid <> 0
        ),
        rel_map AS (
            SELECT relation_role,
                   relation_name,
                   rel_oid,
                   pg_relation_filenode(rel_oid) AS relfilenode,
                   current_setting('block_size')::int AS block_size,
                   CEIL(pg_relation_size(rel_oid)::numeric / current_setting('block_size')::int)::bigint AS relation_pages
            FROM rels
        ),
        sampled AS (
            SELECT rel_map.relation_role,
                   rel_map.relation_name,
                   rel_map.rel_oid,
                   rel_map.relfilenode,
                   rel_map.block_size,
                   rel_map.relation_pages,
                   CASE
                       WHEN $max_sample_pages = 0 THEN 1::bigint
                       ELSE GREATEST(1::bigint, CEIL(rel_map.relation_pages::numeric / GREATEST($max_sample_pages, 1))::bigint)
                   END AS sample_step,
                   fs.blkno,
                   fs.avail
            FROM rel_map
            LEFT JOIN LATERAL (
                SELECT gs.blkno,
                       ${freespacemap_schema}.pg_freespace(rel_map.rel_oid::regclass, gs.blkno::bigint) AS avail
                FROM generate_series(
                    0::bigint,
                    GREATEST(rel_map.relation_pages - 1, 0::bigint),
                    CASE
                        WHEN $max_sample_pages = 0 THEN 1::bigint
                        ELSE GREATEST(1::bigint, CEIL(rel_map.relation_pages::numeric / GREATEST($max_sample_pages, 1))::bigint)
                    END
                ) AS gs(blkno)
                WHERE rel_map.relation_pages > 0
            ) fs ON true
        )
        SELECT relation_role,
               relation_name,
               rel_oid,
               relfilenode,
               relation_pages,
               COUNT(avail) AS sampled_pages,
               sample_step,
               CASE
                   WHEN COUNT(avail) > 0 THEN ROUND(SUM(avail)::numeric * relation_pages::numeric / COUNT(avail))
                   ELSE 0
               END AS estimated_free_bytes,
               CASE WHEN COUNT(avail) > 0 THEN ROUND(AVG(avail)::numeric, 2) ELSE NULL END AS avg_free_bytes,
               CASE WHEN COUNT(avail) > 0 THEN ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY avail)::numeric, 2) ELSE NULL END AS p50_free_bytes,
               CASE WHEN COUNT(avail) > 0 THEN ROUND(percentile_cont(0.90) WITHIN GROUP (ORDER BY avail)::numeric, 2) ELSE NULL END AS p90_free_bytes,
               CASE WHEN COUNT(avail) > 0 THEN ROUND(percentile_cont(0.99) WITHIN GROUP (ORDER BY avail)::numeric, 2) ELSE NULL END AS p99_free_bytes,
               CASE
                   WHEN COUNT(avail) > 0 THEN ROUND(COUNT(*) FILTER (WHERE avail > block_size / 2)::numeric * relation_pages::numeric / COUNT(avail))
                   ELSE 0
               END AS estimated_pages_gt_half_free,
               COALESCE(MAX(avail), 0) AS max_free_bytes
        FROM sampled
        GROUP BY relation_role, relation_name, rel_oid, relfilenode, relation_pages, sample_step, block_size
        ORDER BY relation_role;
    " 2>/dev/null || true)

    if [ -z "$rows" ]; then
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,pg_freespacemap_empty,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL" >> "$FREESPACE_SUMMARY_FILE"
        return
    fi

    while IFS= read -r row; do
        echo "$RUN_NAME,$epoch_label,$phase_label,$event_label,$ts_ms,$row" >> "$FREESPACE_SUMMARY_FILE"
    done <<< "$rows"
}

record_buffer_snapshot() {
    record_buffer_residency "$@"
    record_buffer_page_identity "$@"
    record_freespace_summary "$@"
}

pg_prewarm_schema() {
    local db_name="$1"

    PGPASSWORD="$DB_PWD" psql -X -q -t -A \
        -U "$DB_USERNAME" -d "$db_name" -c "
        SELECT quote_ident(n.nspname)
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'pg_prewarm';
    " 2>/dev/null || true
}

record_prewarm_status_row() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local epoch_label="$2"
    local event_label="$3"
    local mode="$4"
    local relation_role="${5:-NULL}"
    local relation_name="${6:-NULL}"
    local relation_oid="${7:-NULL}"
    local relation_size_bytes="${8:-NULL}"
    local blocks_done="${9:-NULL}"
    local status="${10:-unknown}"
    local message="${11:-}"
    local ts_ms

    ts_ms=$(timestamp_ms)
    {
        csv_escape "$RUN_NAME"; printf ','
        csv_escape "$epoch_label"; printf ','
        csv_escape "prewarm"; printf ','
        csv_escape "$event_label"; printf ','
        printf '%s,' "$ts_ms"
        csv_escape "$db_name"; printf ','
        csv_escape "$mode"; printf ','
        csv_escape "$relation_role"; printf ','
        csv_escape "$relation_name"; printf ','
        csv_escape "$relation_oid"; printf ','
        csv_escape "$relation_size_bytes"; printf ','
        csv_escape "$blocks_done"; printf ','
        csv_escape "$status"; printf ','
        csv_escape "$message"; printf '\n'
    } >> "$PREWARM_FILE"
}

prewarm_target_filter() {
    local mode="$1"

    case "$mode" in
        heap)
            echo "relation_role = 'heap'" ;;
        toast_index)
            echo "relation_role = 'toast_index'" ;;
        toast_heap|full_toast_heap)
            echo "relation_role = 'toast_heap'" ;;
        toast|toast_all|toast_heap_toast_index)
            echo "relation_role IN ('toast_heap', 'toast_index')" ;;
        heap_toast_index)
            echo "relation_role IN ('heap', 'toast_index')" ;;
        heap_toast|heap_toast_heap)
            echo "relation_role IN ('heap', 'toast_heap')" ;;
        all|heap_toast_heap_toast_index|heap_toast_toast_index)
            echo "relation_role IN ('heap', 'toast_heap', 'toast_index')" ;;
        *)
            echo "" ;;
    esac
}

run_pg_prewarm_intervention() {
    if [ "$SPIKE_TRIGGER_PREWARM_ENABLED" != "1" ]; then
        return
    fi

    local db_name="$1"
    local epoch_label="$2"
    local mode="$SPIKE_TRIGGER_PREWARM_MODE"
    local target_filter target_table_sql prewarm_schema rows psql_status had_errexit
    local prewarm_status relation_role relation_name relation_oid relation_size_bytes blocks_done

    if [ "$db_name" != "$DB_NAME" ]; then
        return
    fi

    target_filter=$(prewarm_target_filter "$mode")
    if [ -z "$target_filter" ]; then
        log "Warning: invalid SPIKE_TRIGGER_PREWARM_MODE='$mode'. Supported modes: heap, toast_index, toast_heap, toast, heap_toast_index, heap_toast, all."
        record_prewarm_status_row "$db_name" "$epoch_label" "prewarm_skipped" "$mode" "NULL" "NULL" "NULL" "NULL" "NULL" "invalid_mode" "Unsupported prewarm mode"
        return
    fi

    log "pg_prewarm intervention start: db=$db_name epoch=$epoch_label mode=$mode"
    record_phase_event "prewarm" "$epoch_label" "prewarm_start" "db=$db_name mode=$mode"
    record_checkpoint_observation "$db_name" "prewarm" "$epoch_label" "prewarm_start"
    record_buffer_snapshot "$db_name" "prewarm" "$epoch_label" "prewarm_start"
    benchrun_start_phase "$db_name" "prewarm" "$epoch_label"

    ensure_pg_prewarm_extension "$db_name"
    prewarm_schema=$(pg_prewarm_schema "$db_name")
    if [ -z "$prewarm_schema" ]; then
        record_prewarm_status_row "$db_name" "$epoch_label" "prewarm_skipped" "$mode" "NULL" "NULL" "NULL" "NULL" "NULL" "pg_prewarm_unavailable" "pg_prewarm extension is not installed or visible"
        prewarm_status=1
    else
        target_table_sql=$(sql_escape_literal "$TARGET_TABLE")
        had_errexit=0
        case $- in
            *e*) had_errexit=1; set +e ;;
        esac
        rows=$(PGPASSWORD="$DB_PWD" psql -X -q -t -A -v ON_ERROR_STOP=1 -F $'\t' \
            -U "$DB_USERNAME" -d "$db_name" \
            -c "
            WITH heap AS (
                SELECT c.oid AS heap_oid,
                       c.relname AS heap_name,
                       c.reltoastrelid AS toast_oid
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = '$target_table_sql'
                ORDER BY n.nspname = 'public' DESC, n.nspname
                LIMIT 1
            ),
            rels AS (
                SELECT 'heap' AS relation_role, heap_oid AS rel_oid, heap_name AS relation_name
                FROM heap
                UNION ALL
                SELECT 'toast_heap', t.oid, t.relname
                FROM heap h
                JOIN pg_class t ON t.oid = h.toast_oid
                WHERE h.toast_oid <> 0
                UNION ALL
                SELECT 'toast_index', i.indexrelid, ci.relname
                FROM heap h
                JOIN pg_index i ON i.indrelid = h.toast_oid
                JOIN pg_class ci ON ci.oid = i.indexrelid
                WHERE h.toast_oid <> 0
            )
            SELECT relation_role,
                   relation_name,
                   rel_oid::oid,
                   pg_relation_size(rel_oid),
                   ${prewarm_schema}.pg_prewarm(rel_oid::regclass, 'buffer', 'main')
            FROM rels
            WHERE $target_filter
            ORDER BY CASE relation_role
                         WHEN 'heap' THEN 1
                         WHEN 'toast_heap' THEN 2
                         WHEN 'toast_index' THEN 3
                         ELSE 4
                     END, relation_name;
            " 2>&1)
        psql_status=$?
        if [ "$had_errexit" -eq 1 ]; then
            set -e
        fi

        if [ "$psql_status" -ne 0 ]; then
            record_prewarm_status_row "$db_name" "$epoch_label" "prewarm_failed" "$mode" "NULL" "NULL" "NULL" "NULL" "NULL" "error" "$rows"
            prewarm_status=1
        elif [ -z "$rows" ]; then
            record_prewarm_status_row "$db_name" "$epoch_label" "prewarm_skipped" "$mode" "NULL" "NULL" "NULL" "NULL" "NULL" "no_targets" "No matching relations for target table $TARGET_TABLE"
            prewarm_status=1
        else
            prewarm_status=0
            while IFS=$'\t' read -r relation_role relation_name relation_oid relation_size_bytes blocks_done; do
                [ -z "$relation_role" ] && continue
                record_prewarm_status_row "$db_name" "$epoch_label" "prewarm_relation" "$mode" "$relation_role" "$relation_name" "$relation_oid" "$relation_size_bytes" "$blocks_done" "ok" ""
            done <<< "$rows"
        fi
    fi

    benchrun_finish_phase "$db_name" "prewarm" "$epoch_label" "" "$prewarm_status"
    record_checkpoint_observation "$db_name" "prewarm" "$epoch_label" "prewarm_end"
    record_buffer_snapshot "$db_name" "prewarm" "$epoch_label" "prewarm_end"
    record_phase_event "prewarm" "$epoch_label" "prewarm_end" "db=$db_name mode=$mode status=$prewarm_status"
    record_db_stats_once "$db_name" "post-prewarm" "$epoch_label"
    log "pg_prewarm intervention end: db=$db_name epoch=$epoch_label mode=$mode status=$prewarm_status"
    return 0
}

start_vacuum_progress_sampler() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        echo ""
        return
    fi

    local db_name="$1"
    local epoch_label="$2"
    (
        while true; do
            local ts_ms rows
            ts_ms=$(timestamp_ms)
            rows=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -At -F"," -c "
                SELECT COALESCE(relid::regclass::text, 'unknown'),
                       COALESCE(phase, 'unknown'),
                       COALESCE(heap_blks_total, 0),
                       COALESCE(heap_blks_scanned, 0),
                       COALESCE(heap_blks_vacuumed, 0),
                       COALESCE(index_vacuum_count, 0),
                       COALESCE(max_dead_tuples, 0),
                       COALESCE(num_dead_tuples, 0)
                FROM pg_stat_progress_vacuum;
            " 2>/dev/null || true)
            if [ -n "$rows" ]; then
                while IFS= read -r row; do
                    echo "$RUN_NAME,$epoch_label,$ts_ms,$row" >> "$VACUUM_PROGRESS_FILE"
                done <<< "$rows"
            fi
            sleep 1
        done
    ) >/dev/null 2>&1 &
    echo "$!"
}

stop_background_pid() {
    local pid="${1:-}"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

record_vacuum_progress_unobserved_if_empty() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        return
    fi

    local epoch_label="$1"
    local ts_ms observed_count

    [ -f "$VACUUM_PROGRESS_FILE" ] || return
    observed_count=$(awk -F, -v ep="$epoch_label" 'NR > 1 && $2 == ep { count++ } END { print count + 0 }' "$VACUUM_PROGRESS_FILE" 2>/dev/null || echo 0)
    if [ "$observed_count" -eq 0 ]; then
        ts_ms=$(timestamp_ms)
        echo "$RUN_NAME,$epoch_label,$ts_ms,unobserved,vacuum_not_observed,0,0,0,0,0,0" >> "$VACUUM_PROGRESS_FILE"
    fi
}

wait_background_pid_with_timeout() {
    local pid="${1:-}"
    local timeout_seconds="${2:-5}"
    local waited=0

    if [ -z "$pid" ]; then
        return
    fi

    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$timeout_seconds" ]; do
        sleep 1
        waited=$((waited + 1))
    done
}

start_run_buffer_progress_sampler() {
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ]; then
        echo ""
        return
    fi
    if [ "${SPIKE_TRIGGER_READ_SAMPLE_RATE:-0}" -le 0 ]; then
        echo ""
        return
    fi

    local db_name="$1"
    local epoch_label="$2"
    local operation_count="$3"

    if ! [[ "$operation_count" =~ ^[0-9]+$ ]] || [ "$operation_count" -le 0 ]; then
        echo ""
        return
    fi

    (
        declare -A recorded=()
        local pct target max_op all_recorded

        while true; do
            if [ -f "$READ_SAMPLE_FILE" ]; then
                max_op=$(awk -F, -v ep="$epoch_label" '
                    NR > 1 && $2 == ep && $3 == "run" {
                        op = $5 + 0
                        if (op > max) {
                            max = op
                        }
                    }
                    END {
                        print max + 0
                    }
                ' "$READ_SAMPLE_FILE" 2>/dev/null)
            else
                max_op=0
            fi

            all_recorded=1
            for pct in $SPIKE_TRIGGER_BUFFER_PROGRESS_PCTS; do
                if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -le 0 ] || [ "$pct" -ge 100 ]; then
                    continue
                fi

                target=$((operation_count * pct / 100))
                [ "$target" -lt 1 ] && target=1

                if [ -z "${recorded[$pct]:-}" ]; then
                    all_recorded=0
                    if [ "$max_op" -ge "$target" ]; then
                        record_buffer_snapshot "$db_name" "run" "$epoch_label" "run_progress_${pct}pct"
                        recorded[$pct]=1
                    fi
                fi
            done

            if [ "$all_recorded" -eq 1 ]; then
                break
            fi

            sleep 1
        done
    ) >/dev/null 2>&1 &
    echo "$!"
}

set_read_sample_args() {
    local phase_label="$1"
    local epoch_label="$2"

    YCSB_READ_SAMPLE_ARGS=()
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" != "1" ] || [ "$phase_label" != "run" ]; then
        return
    fi

    YCSB_READ_SAMPLE_ARGS=(
        -p "jdbc.readsample.file=$READ_SAMPLE_FILE"
        -p "jdbc.slowread.file=$SLOW_READ_SAMPLE_FILE"
        -p "jdbc.readsample.rate=$SPIKE_TRIGGER_READ_SAMPLE_RATE"
        -p "jdbc.slowread.threshold.us=$SPIKE_TRIGGER_SLOW_READ_US"
        -p "jdbc.readsample.runname=$RUN_NAME"
        -p "jdbc.readsample.epoch=$epoch_label"
        -p "jdbc.readsample.phase=$phase_label"
    )
}

# CPU and Memory watcher
run_with_metrics() {
    set +e
    local db_name=$1
    local phase=$2
    local epoch=$3
    local output_csv=$4
    local pg_1s_file=""
    local os_1s_file=""
    local run_buffer_sampler_pid=""
    local operation_count=""
    local wal_start_lsn=""
    local wal_end_lsn=""

    shift 4

    metrics_file="../analysis/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase}.metrics"
    db_stats_file="${INTERNAL_DATA_DIR}/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase}.dbstats"
    if [ "$SPIKE_TRIGGER_TRACE_ENABLED" = "1" ]; then
        pg_1s_file="$PG_1S_FILE"
        os_1s_file="$OS_1S_FILE"
    fi

    echo "Starting metrics collection for $db_name"
    mkdir -p "$INTERNAL_DATA_DIR"
    record_phase_event "$phase" "$epoch" "${phase}_start" "db=$db_name"
    record_checkpoint_observation "$db_name" "$phase" "$epoch" "${phase}_start"
    record_buffer_snapshot "$db_name" "$phase" "$epoch" "before_${phase}"
    reset_pg_stat_statements "$db_name" "$phase" "$epoch" "${phase}_start"
    wal_start_lsn=$(record_wal_boundary "$db_name" "$phase" "$epoch" "${phase}_start")
    benchrun_start_phase "$db_name" "$phase" "$epoch"

    # Start watcher
    setsid env \
        DB_PWD="$DB_PWD" \
        DB_USERNAME="$DB_USERNAME" \
        db_name="$db_name" \
        phase="$phase" \
        epoch="$epoch" \
        metrics_file="$metrics_file" \
        DB_STATS_FILE="$db_stats_file" \
        PG_1S_FILE="$pg_1s_file" \
        OS_1S_FILE="$os_1s_file" \
        OS_DISK_DEVICE_FILE="$OS_DISK_DEVICE_FILE" \
        OS_DISK_DEVICES="$OS_DISK_DEVICES" \
        DB_STATS_TABLE="$TARGET_TABLE" \
        DB_STATS_INTERVAL="$DB_STATS_INTERVAL" \
        INTERVAL=1 \
        ./watcher.sh &
    watcher_pid=$!
    benchrun_register_pgid "$watcher_pid"

    if [ "$phase" = "run" ] && [ "$SPIKE_TRIGGER_TRACE_ENABLED" = "1" ]; then
        operation_count=$(grep -E '^operationcount=' "$WORKLOAD_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2)
        run_buffer_sampler_pid=$(start_run_buffer_progress_sampler "$db_name" "$epoch" "$operation_count")
        benchrun_register_pid "$run_buffer_sampler_pid"
    fi

    "$@" | benchrun_redact_stream > "$output_csv"
    status=$?

    wait_background_pid_with_timeout "$run_buffer_sampler_pid" 5
    stop_background_pid "$run_buffer_sampler_pid"
    run_buffer_sampler_pid=""

    # Stop watcher
    kill -TERM -$watcher_pid 2>/dev/null
    wait $watcher_pid 2>/dev/null

    trap - EXIT INT TERM
    trap 'benchrun_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    benchrun_finish_phase "$db_name" "$phase" "$epoch" "$output_csv" "$status"
    wal_end_lsn=$(record_wal_boundary "$db_name" "$phase" "$epoch" "${phase}_end" "$wal_start_lsn")
    record_wal_stats "$db_name" "$phase" "$epoch" "${phase}_end" "$wal_start_lsn" "$wal_end_lsn"
    record_pg_stat_statements "$db_name" "$phase" "$epoch" "${phase}_end"
    record_checkpoint_observation "$db_name" "$phase" "$epoch" "${phase}_end"
    record_buffer_snapshot "$db_name" "$phase" "$epoch" "after_${phase}"
    record_phase_event "$phase" "$epoch" "${phase}_end" "db=$db_name exit=$status"
    echo "Finished $db_name phase=$phase epoch=$epoch (exit=$status)"
    set -e
    return "$status"
}

record_db_stats_once() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local metrics_file="../analysis/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase_label}.metrics"
    local db_stats_file="${INTERNAL_DATA_DIR}/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase_label}.dbstats"

    mkdir -p "$INTERNAL_DATA_DIR"
    env \
        DB_PWD="$DB_PWD" \
        DB_USERNAME="$DB_USERNAME" \
        db_name="$db_name" \
        phase="$phase_label" \
        epoch="$epoch_label" \
        metrics_file="$metrics_file" \
        DB_STATS_FILE="$db_stats_file" \
        DB_STATS_TABLE="$TARGET_TABLE" \
        ONESHOT_DBSTATS=1 \
        ./watcher.sh
}

# Initialize PostgreSQL database
initialize_database() {
    local db_name="$1"
    local field_definitions
    log "Initializing PostgreSQL database $db_name..."

    PGPASSWORD="$DB_PWD" dropdb --if-exists "$db_name" -U "$DB_USERNAME"
    PGPASSWORD="$DB_PWD" createdb "$db_name" -U "$DB_USERNAME"
    ensure_pg_buffercache_extension "$db_name"
    ensure_pg_freespacemap_extension "$db_name"
    ensure_pg_stat_statements_extension "$db_name"
    ensure_pg_walinspect_extension "$db_name"
    ensure_pg_prewarm_extension "$db_name"

    field_definitions=$(value_field_definitions_sql)
    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            $field_definitions
        );"

    log "Done initializing $db_name."
}

benchrun_init
if [ "$BENCHRUN_DRY_RUN_PREFLIGHT" = "1" ]; then
    benchrun_preflight "$DB_NAME"
    log "Dry-run preflight completed. Outputs are in $BENCHRUN_DIR"
    exit 0
fi

# Clear the log file and previous backups
> $LOG_FILE
> $PLAN_LOG
> $HISTOGRAM_FILE

mkdir -p "$INTERNAL_DATA_DIR"
> "$DETOAST_PROBE_LOG"
init_spike_trigger_trace
ensure_checkpoint_logging
log "Value variant: $VALUE_VARIANT_LABEL (VALUE_VARIANT=$VALUE_VARIANT, YCSB_BINDING=$YCSB_BINDING, FIELD_SQL_TYPE=$FIELD_SQL_TYPE)"

rm -rf $KEY_SIZE_LOG
rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"
find "$INTERNAL_DATA_DIR" -maxdepth 1 -type f \
    -name "*${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}*.dbstats" -delete

initialize_database "$DB_NAME"
require_full_visibility_ready "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"
require_full_visibility_ready "$UNCHANGE_DB_NAME"
benchrun_preflight "$DB_NAME"
benchrun_maybe_reset_stats

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Filter for inserts, reads, updates, scans, and extends
    # Also catch the overall output
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")
    if [ "$first" == "TRUE" ]; then
        # Create header
        dynamic_cols=$(awk '{print $2}' <<< "$filtered_output" \
            | sed 's/,$//' \
            | grep -v '^Return=ERROR$' \
            | uniq \
            | awk '{ORS=","; print}' \
            | sed 's/,$//')
        if [ -n "$dynamic_cols" ]; then
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$dynamic_cols"
        else
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Set default values for epoch and run if not set
    epoch=${epoch:-0}
    run=${run:-0}
    # Load phase counts as 0
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((EXPERIMENT_RUNS_PER_EPOCH * ($epoch - 1) + $run))
    fi

    # Set default values for workload parameters
    recordcount=${recordcount:-""}
    readallfields=${readallfields:-""}
    requestdistribution=${requestdistribution:-""}
    readrequestdistribution=${readrequestdistribution:-""}
    updaterequestdistribution=${updaterequestdistribution:-""}
    readproportion=${readproportion:-""}
    updateproportion=${updateproportion:-""}
    scanproportion=${scanproportion:-""}
    insertproportion=${insertproportion:-""}
    extendproportion=${extendproportion:-""}
    cpu=${cpu:-""}
    memory=${memory:-""}

    # Extract throughput from overall output
    run_specific=()
    while IFS= read -r inner_line; do
        # Extract third value
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    # Initialize operation to empty
    operation=""
    while IFS= read -r line; do
        # Extract operation, metric label, and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        metric_label=$(echo "$line" | awk '{print $2}' | sed 's/,$//')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        # Write the associated distribution for the operation
        if [ "$operation" = "READ" ] && [ -n "$readrequestdistribution" ]; then
            op_requestdistribution="$readrequestdistribution"
        elif [ "$operation" = "UPDATE" ] && [ -n "$updaterequestdistribution" ]; then
            op_requestdistribution="$updaterequestdistribution"
        else
            op_requestdistribution="$requestdistribution"
        fi

        # Build CSV row
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    log "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to close the PostgreSQL database
close_db() {
    log "PostgreSQL backend: no manual DB close required."
}

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    log "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    log "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

# Generate histogram from key size log
get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    log "Generating histogram from key size log: $key_size_log"

    awk -F, '
        BEGIN {
            block = 100
            OFS = "\t"
        }
        NR == 1 { next }  # Skip header
        {
            size = $2 + 0
            bucket = int(size / (block * 10 ))   #Converting value length to field length as there are 10 fields
            histogram[bucket]++
            if (bucket > max_bucket) max_bucket = bucket
        }
        END {
            print "BlockSize", block > "'"$histogram_file"'"
            for (i = 0; i <= max_bucket; i++) {
                count = (i in histogram) ? histogram[i] : 0
                print i, count >> "'"$histogram_file"'"
            }
        }
    ' "$key_size_log"

    log "Histogram written to $histogram_file (BlockSize = 100)"
}

# Function to extract PostgreSQL database and background writer statistics
collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"

    # database-level stats
    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # bgwriter
    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # wal metrics
    if PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -c "\d pg_stat_wal" &>/dev/null; then
        read wal_bytes wal_records wal_fpi wal_buffers_full <<< \
            $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
                SELECT wal_bytes, wal_records, wal_fpi, wal_buffers_full
                FROM pg_stat_wal;
            " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    else
        wal_bytes="0"; wal_records="0"; wal_fpi="0"; wal_buffers_full="0"
    fi
}

select_detoast_probe_keys() {
    local key_size_log="$1"
    local sorted_sizes
    local count
    local rank

    sorted_sizes=$(mktemp)
    awk -F, 'NR > 1 && $2 ~ /^[0-9]+$/ {print $2 "," $1}' "$key_size_log" \
        | sort -t, -k1,1n > "$sorted_sizes"

    count=$(wc -l < "$sorted_sizes" | tr -d ' ')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        rm -f "$sorted_sizes"
        return
    fi

    emit_probe_key() {
        local label="$1"
        local rank="$2"
        local line
        local size
        local key

        line=$(sed -n "${rank}p" "$sorted_sizes")
        size=${line%%,*}
        key=${line#*,}
        printf '%s,%s,%s\n' "$label" "$key" "$size"
    }

    emit_probe_key "min" 1

    for label_quantile in "p50:0.50" "p90:0.90" "p95:0.95" "p99:0.99"; do
        label=${label_quantile%%:*}
        quantile=${label_quantile#*:}
        rank=$(awk -v n="$count" -v q="$quantile" 'BEGIN {
            r = int(n * q + 0.999999);
            if (r < 1) r = 1;
            if (r > n) r = n;
            print r;
        }')
        emit_probe_key "$label" "$rank"
    done

    emit_probe_key "max" "$count"
    rm -f "$sorted_sizes"
}

run_jsonb_detoast_probes() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local key_size_log="$4"
    local logical_size_expr
    local element_count_expr

    if [ "$DETOAST_PROBE_ENABLED" != "1" ]; then
        return
    fi

    if [ "$DETOAST_PROBE_EVERY" -gt 1 ] && [ $((epoch_label % DETOAST_PROBE_EVERY)) -ne 0 ]; then
        return
    fi

    if [ ! -s "$key_size_log" ]; then
        log "Skipping detoast probes: missing key size log $key_size_log"
        return
    fi

    mkdir -p "$INTERNAL_DATA_DIR"
    logical_size_expr=$(logical_record_size_expr)
    element_count_expr=$(value_element_count_expr)
    log "Running detoast probes for $VALUE_VARIANT_LABEL on $db_name phase=$phase_label epoch=$epoch_label"

    while IFS=, read -r probe_label probe_key probe_size; do
        if [ "$SPIKE_TRIGGER_TRACE_ENABLED" = "1" ]; then
            {
                csv_escape "$RUN_NAME"; printf ','
                printf '%s,%s,%s,' "$epoch_label" "$phase_label" "$(timestamp_ms)"
                csv_escape "$probe_label"; printf ','
                csv_escape "$probe_key"; printf ','
                csv_escape "$probe_size"; printf '\n'
            } >> "$SAMPLED_DETOAST_PROBE_LOG"
        fi
        {
            echo "========================================"
            echo "Epoch=$epoch Run=$run Iteration=$epoch_label Phase=$phase_label Probe=$probe_label Time=$(date)"
            echo "DB=$db_name"
            echo "Key=$probe_key"
            echo "SizeBytes=$probe_size"
            echo "----------------------------------------"
            echo "Lookup-only probe"
            printf '%s\n' \
                "EXPLAIN (ANALYZE, BUFFERS)" \
                "SELECT ycsb_key" \
                "FROM usertable" \
                "WHERE ycsb_key = :'probe_key';" \
                | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                    -v ON_ERROR_STOP=1 \
                    -v probe_key="$probe_key"
            echo
            if [ -n "$element_count_expr" ]; then
                echo "$VALUE_VARIANT_LABEL element-count detoast probe"
                printf '%s\n' \
                    "EXPLAIN (ANALYZE, BUFFERS)" \
                    "SELECT" \
                    "    $element_count_expr AS value_element_count" \
                    "FROM usertable" \
                    "WHERE ycsb_key = :'probe_key';" \
                    | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                        -v ON_ERROR_STOP=1 \
                        -v probe_key="$probe_key"
                echo
            fi
            echo "Detoast and logical byte probe"
            printf '%s\n' \
                "EXPLAIN (ANALYZE, BUFFERS)" \
                "SELECT" \
                "    $logical_size_expr AS logical_value_bytes" \
                "FROM usertable" \
                "WHERE ycsb_key = :'probe_key';" \
                | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                    -v ON_ERROR_STOP=1 \
                    -v probe_key="$probe_key"
            echo
        } >> "$DETOAST_PROBE_LOG"
    done < <(select_detoast_probe_keys "$key_size_log")
}

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
# Extract workload parameters for load phase
source "$WORKLOAD_FILE"
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readrequestdistribution=${readrequestdistribution:-""}
updaterequestdistribution=${updaterequestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_with_metrics "$DB_NAME" "$phase" "$run" "$OUTPUT_CSV" \
    "$YCSB" load "$YCSB_BINDING" -s \
    -P "$WORKLOAD_FILE" \
    -P "$JDBC_PROPERTIES" \
    -p db.url="$DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD"
cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
total_size_initial_load=$(logical_total_size "$DB_NAME")
log "Initial-load verification - TotalSize:$total_size_initial_load ExpectedFieldLength:$fieldlengthoriginal"
collect_postgres_metrics $DB_NAME
write_result "TRUE"

# Load unchange value size (reference) DB
run_with_metrics "$UNCHANGE_DB_NAME" "$phase" "$run" "$OUTPUT_CSV" \
    "$YCSB" load "$YCSB_BINDING" -s \
    -P "$WORKLOAD_FILE" \
    -P "$JDBC_PROPERTIES" \
    -p db.url="$UNCHANGE_DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD"

total_size_reference_load=$(logical_total_size "$UNCHANGE_DB_NAME")
log "Reference-load verification - TotalSize:$total_size_reference_load ExpectedFieldLength:$fieldlengthoriginal"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 "$EXPERIMENT_EPOCHS"); do
    for run in $(seq 1 "$EXPERIMENT_RUNS_PER_EPOCH"); do

        iteration=$((EXPERIMENT_RUNS_PER_EPOCH*($epoch-1)+$run))
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Execute the extend phase
        log "=== Executing the extend phase with extendproportion=1 and other proportions=0 ==="
        phase="extend"
        # Capture both stdout and stderr to capture status messages
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
            "$YCSB" run "$YCSB_BINDING" -s \
            -P "$WORKLOAD_FILE" \
            -P "$JDBC_PROPERTIES" \
            -p db.url="$DB_URL" \
            -p db.user="$DB_USERNAME" \
            -p db.passwd="$DB_PWD" \
            -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        # Extract extend failure count from YCSB output (status messages are in the output)
        extend_failed_count=$(grep -oP 'EXTEND-FAILED: Count=\K\d+' "$OUTPUT_CSV" | head -1 || echo "0")
        if [ -n "$extend_failed_count" ] && [ "$extend_failed_count" != "0" ]; then
            log "WARNING: $extend_failed_count EXTEND operations failed during extend phase"
        fi
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

        # Key Sizes
        log "Size computation started"
        write_logical_key_sizes "$DB_NAME" "$KEY_SIZE_LOG"
        
        # Verify extend operations: check min, max, avg sizes to detect extension failures
        extend_stats=$(awk -F, '
            NR == 1 { next }
            {
                sizes[NR-1] = $2
                sum += $2
                count++
            }
            END {
                if (count > 0) {
                    avg = sum / count
                    min = sizes[1]
                    max = sizes[1]
                    for (i = 2; i <= count; i++) {
                        if (sizes[i] < min) min = sizes[i]
                        if (sizes[i] > max) max = sizes[i]
                    }
                    printf "Min:%d Max:%d Avg:%.0f", min, max, avg
                }
            }
        ' "$KEY_SIZE_LOG")
        log "Extend verification - $extend_stats (Expected avg per record: ~$((10 * fieldlengthoriginal)) bytes initially)"

        get_key_sizes $KEY_SIZE_LOG $HISTOGRAM_FILE

        # Check if the output file exists, if not, create it with headers
        iteration=$((EXPERIMENT_RUNS_PER_EPOCH*($epoch-1)+$run))

        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            # Add header row
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # If it's the first iteration, append keys and sizes for the first run
        if [[ "$iteration" -eq 1 ]]; then
            append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        else
            append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        fi

        if [[ $vacuum -eq 1 ]]; then
            record_phase_event "vacuum" "$iteration" "vacuum_start" "db=$DB_NAME"
            record_checkpoint_observation "$DB_NAME" "vacuum" "$iteration" "vacuum_start"
            benchrun_start_phase "$DB_NAME" "vacuum" "$iteration"
            vacuum_wal_start_lsn=$(record_wal_boundary "$DB_NAME" "vacuum" "$iteration" "vacuum_start")
            vacuum_progress_pid=$(start_vacuum_progress_sampler "$DB_NAME" "$iteration")
            benchrun_register_pid "$vacuum_progress_pid"
            log "VACUUM start: $(date +%s)"
            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c "VACUUM (ANALYZE, VERBOSE) usertable;"
            log "VACUUM end: $(date +%s)"
            stop_background_pid "$vacuum_progress_pid"
            record_vacuum_progress_unobserved_if_empty "$iteration"
            benchrun_finish_phase "$DB_NAME" "vacuum" "$iteration" "" "0"
            vacuum_wal_end_lsn=$(record_wal_boundary "$DB_NAME" "vacuum" "$iteration" "vacuum_end" "$vacuum_wal_start_lsn")
            record_wal_stats "$DB_NAME" "vacuum" "$iteration" "vacuum_end" "$vacuum_wal_start_lsn" "$vacuum_wal_end_lsn"
            record_checkpoint_observation "$DB_NAME" "vacuum" "$iteration" "vacuum_end"
            record_buffer_snapshot "$DB_NAME" "vacuum" "$iteration" "after_vacuum"
            record_phase_event "vacuum" "$iteration" "vacuum_end" "db=$DB_NAME"
            record_db_stats_once "$DB_NAME" "post-vacuum" "$iteration"
        else
            record_db_stats_once "$DB_NAME" "post-extend-no-vacuum" "$iteration"
        fi

        run_pg_prewarm_intervention "$DB_NAME" "$iteration"

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Save the existing keys in the database
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Log query plan before run phase
        log "Checking query plan before run phase"

        TEST_KEY=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -c \
        "SELECT ycsb_key FROM usertable LIMIT 1;")

        {
            echo "========================================"
            echo "Epoch=$epoch Run=$run Phase=run Time=$(date)"
            echo "DB=$DB_NAME"
            echo "Key=$TEST_KEY"
            echo "----------------------------------------"

            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c "
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT * FROM usertable WHERE ycsb_key = '$TEST_KEY';
            "

            echo
        } >> "$PLAN_LOG"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        set_read_sample_args "$phase" "$iteration"
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        "$YCSB" run "$YCSB_BINDING" -s \
        -P "$WORKLOAD_FILE" \
        -P "$JDBC_PROPERTIES" \
        -p db.url="$DB_URL" \
        -p db.user="$DB_USERNAME" \
        -p db.passwd="$DB_PWD" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE" \
        "${YCSB_READ_SAMPLE_ARGS[@]}"
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"
        record_db_stats_once "$DB_NAME" "post-run" "$iteration"
        run_jsonb_detoast_probes "$DB_NAME" "post-run" "$iteration" "$KEY_SIZE_LOG"

        # Save keys to remove duplicates later
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Reference workload with unchanging value sizes
        phase="reference"
        run_with_metrics "$UNCHANGE_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        "$YCSB" run "$YCSB_BINDING" -s \
        -P "$WORKLOAD_FILE" \
        -P "$JDBC_PROPERTIES" \
        -p db.url="$UNCHANGE_DB_URL" \
        -p db.user="$DB_USERNAME" \
        -p db.passwd="$DB_PWD" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $UNCHANGE_DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt
    
        if (( COMPARISON_INTERVAL > 0 && iteration % COMPARISON_INTERVAL == 0 )); then
            phase="clean-run"
            
            log "Backing up the database started"
            PGPASSWORD="$DB_PWD" dropdb --if-exists "$BACKUP_DB_NAME" -U "$DB_USERNAME"
            PGPASSWORD="$DB_PWD" createdb "$BACKUP_DB_NAME" -U "$DB_USERNAME"

            # Dump primary DB into file with --clean to include DROP statements
            PGPASSWORD="$DB_PWD" pg_dump -U "$DB_USERNAME" -d "$DB_NAME" --clean > "$BACKUP_FILE"

            # Restore backup - --clean ensures tables are dropped before creation
            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -f "$BACKUP_FILE" > /dev/null 2>&1 || true
            ensure_pg_buffercache_extension "$BACKUP_DB_NAME"
            ensure_pg_freespacemap_extension "$BACKUP_DB_NAME"
            ensure_pg_stat_statements_extension "$BACKUP_DB_NAME"
            ensure_pg_walinspect_extension "$BACKUP_DB_NAME"
            ensure_pg_prewarm_extension "$BACKUP_DB_NAME"
            log "Backing up the database finished"

            run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                "$YCSB" run "$YCSB_BINDING" -s \
                -P "$WORKLOAD_FILE" \
                -P "$JDBC_PROPERTIES" \
                -p db.url="$BACKUP_URL" \
                -p db.user="$DB_USERNAME" \
                -p db.passwd="$DB_PWD" \
                -p fieldlengthhistogram="$HISTOGRAM_FILE"

            collect_cpu_memory_metrics
            collect_postgres_metrics $BACKUP_DB_NAME
            rm -rf "$BACKUP_FILE"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            log "Size computation started"
            write_logical_key_sizes "$BACKUP_DB_NAME" "$KEY_SIZE_LOG"
            
            # Check if the output file exists, if not, create it with headers
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                # Add header row
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # If it's the first iteration, append keys and sizes for the first run
            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            else
                append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # PostgreSQL query to get the total size of all records
            total_size=$(logical_total_size "$BACKUP_DB_NAME")

            # Set average field length
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            log "Total size: $total_size, Field length average: $fieldlengthaverage"

            # Changing the value size for comparison
            if grep -q '^fieldlength=' "$WORKLOAD_FILE"; then
                perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            else
                echo "fieldlength=$fieldlengthaverage" >> "$WORKLOAD_FILE"
            fi
            source "$WORKLOAD_FILE"
            # Verify fieldlength was set correctly
            actual_fieldlength=$(grep -E '^fieldlength=' "$WORKLOAD_FILE" | cut -d'=' -f2)
            log "Workload file fieldlength set to: $actual_fieldlength (expected: $fieldlengthaverage)"

            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" \
            -c "TRUNCATE TABLE usertable;"

            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            "$YCSB" load "$YCSB_BINDING" -s -P "$WORKLOAD_FILE" -P "$JDBC_PROPERTIES" -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" | benchrun_redact_stream > "$OUTPUT_CSV"
            total_size_comparison_load=$(logical_total_size "$BACKUP_DB_NAME")
            log "Comparison-load verification - Epoch:$epoch Run:$run TotalSize:$total_size_comparison_load ExpectedFieldLength:$fieldlengthaverage"
            
            # Verify record sizes after avg-run load
            total_size_avg_run=$(logical_total_size "$BACKUP_DB_NAME")
            log "Avg-run verification - Epoch:$epoch Run:$run Iteration:$iteration TotalSize:$total_size_avg_run ExpectedFieldLength:$fieldlengthaverage"
            
            # Chainging the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"

            run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                "$YCSB" run "$YCSB_BINDING" -s \
                -P "$WORKLOAD_FILE" \
                -P "$JDBC_PROPERTIES" \
                -p db.url="$BACKUP_URL" \
                -p db.user="$DB_USERNAME" \
                -p db.passwd="$DB_PWD"
            
            collect_cpu_memory_metrics
            collect_postgres_metrics $BACKUP_DB_NAME
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

record_checkpoint_log_settings "experiment_end"
collect_checkpoint_log_messages "experiment" "all" "experiment_end"
log "=== All steps completed. Results are logged in $LOG_FILE ==="
