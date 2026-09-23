#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC2155  # the cd cannot fail; assigning first would need a second line
YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export YCSB_HOME
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# DB names
DB_NAME="${DB_NAME:-ycsb}"
BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
TARGET_TABLE="${TARGET_TABLE:-usertable}"

# PostgreSQL endpoint shared by JDBC and CLI commands
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME"
JDBC_PROPERTIES="../jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="usyd2026"
BACKUP_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$BACKUP_DB_NAME"
BACKUP_FILE="./ycsb_dump.sql"
UNCHANGED_DB_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$UNCHANGED_DB_NAME"

# Change naming parameters here
TYPE="postgresql_test"
YCSB_BINDING="TEST"
SCALE="heavy" # "heavy" OR "light"
EXTEND_DIST="zipfian" # "uniform" OR "zipfian"
WORKLOAD="readonly-uniform" # e.g. "read-only-uniform" "mixed", "pure", or "spreadrun"
RUN="TEST"

# VACUUM settings
vacuum=1

# how many epochs in this experiment?
NUM_EPOCHS=${NUM_EPOCHS:-10}
STEPS_PER_EPOCH=${STEPS_PER_EPOCH:-10}
COMPARISON_INTERVAL=${COMPARISON_INTERVAL:-1}

# Define execution ID for this run, based on UTC timestamp and process ID
EXECUTION_ID="$(date -u +%Y%m%dT%H%M%SZ)_$$"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloadc-uniform-heavy"
EXPERIMENT_NAME="${TYPE}_${SCALE}_extend-${EXTEND_DIST}_${WORKLOAD}_run${RUN}"
EXPERIMENT_DIR="./ycsb_${EXPERIMENT_NAME}"
LOG_DIR="${EXPERIMENT_DIR}/logs"
LOG_FILE="${LOG_DIR}/ycsb_${EXPERIMENT_NAME}_results.log"
OUTPUT_CSV="${LOG_DIR}/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="${LOG_DIR}/${TYPE}_output.csv"
OUTPUT_FILE="${EXPERIMENT_DIR}/data/workload_data/${EXPERIMENT_NAME}.csv"

# Key size gathering
KEY_SIZE_LOG="${EXPERIMENT_DIR}/data/key_sizes_${EXPERIMENT_NAME}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="${EXPERIMENT_DIR}/data/value_size_data/value_sizes_${TYPE}_${SCALE}_run${RUN}_extend-${EXTEND_DIST}_before_${WORKLOAD}.csv"
KEY_SIZE_FILE_AFTER_RUN="${EXPERIMENT_DIR}/data/value_size_data/value_sizes_${TYPE}_${SCALE}_run${RUN}_extend-${EXTEND_DIST}_after_${WORKLOAD}.csv"
HISTOGRAM_FILE="${LOG_DIR}/histogram.txt"

# Plan log file
PLAN_LOG="${LOG_DIR}/${EXPERIMENT_NAME}_query_plan.log"

# watcher.sh paramters
DB_STATS_INTERVAL=${DB_STATS_INTERVAL:-60}
OS_DISK_DEVICES="${OS_DISK_DEVICES:-auto}"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="${EXTEND_DIST}"
# Optional specific request distributions for each operation
readrequestdistribution_extend="${EXTEND_DIST}"
updaterequestdistribution_extend="${EXTEND_DIST}"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"
# Optional specific request distributions for each operation
readrequestdistribution_postextend="uniform"
updaterequestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="100000"

# Begin local PG18 support functions.
PG_MAINTENANCE_DB="${PG_MAINTENANCE_DB:-postgres}"

# PG18 statistics collection
global_metric_names=(
    blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated
    tup_deleted deadlocks temp_files temp_bytes checkpoints_timed checkpoints_req
    checkpoints_done buffers_checkpoint buffers_clean buffers_alloc
    checkpoint_write_time checkpoint_sync_time wal_bytes wal_records wal_fpi wal_buffers_full
)

table_metric_names=(
    n_tup_upd n_live_tup n_dead_tup n_ins_since_vacuum vacuum_count autovacuum_count
    total_vacuum_time total_autovacuum_time total_analyze_time total_autoanalyze_time
)

relsize_metric_names=(
    relation_name relation_type raw_rel_size relation_size
)

binding_field_names=("${global_metric_names[@]}")

for prefix in usertable toast; do
    for metric in "${table_metric_names[@]}"; do
        binding_field_names+=("${prefix}_${metric}")
    done
done

binding_field_names+=(toast_n_tup_ins toast_n_tup_del)

binding_field_names+=(
    usertable_heap_blks_read usertable_heap_blks_hit usertable_idx_blks_read usertable_idx_blks_hit
    toast_blks_read toast_blks_hit tidx_blks_read tidx_blks_hit
)


pg_cli() {
    local tool="$1"
    shift
    local started=$SECONDS rc=0 arg next_is_db=false next_is_sql=false target_db=unspecified action="$tool"
    for arg in "$@"; do
        if [[ "$next_is_db" == true ]]; then target_db="$arg"; next_is_db=false; fi
        if [[ "$next_is_sql" == true ]]; then
            read -r action _ <<< "${arg#"${arg%%[![:space:]]*}"}"
            next_is_sql=false
        fi
        [[ "$arg" != -c ]] || next_is_sql=true
        [[ "$arg" != -d && "$arg" != --dbname ]] || next_is_db=true
    done
    log "START PostgreSQL operation tool=$tool action=$action database=$target_db"
    # Do not log arguments: JDBC/CLI arguments can contain credentials.
    PGPASSWORD="$DB_PWD" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
        "$tool" --host="$DB_HOST" --port="$DB_PORT" --username="$DB_USERNAME" \
        --no-password "$@" || rc=$?
    log "END PostgreSQL operation tool=$tool action=$action database=$target_db status=$rc duration=$((SECONDS-started))s"
    return "$rc"
}

pg_exec() {
    # Ignore user psqlrc formatting and stop on SQL errors, including stdin/-f.
    pg_cli psql -X -q -v ON_ERROR_STOP=1 "$@"
}


collect_cpu_memory_metrics() {
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum + 0}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum + 0}')
}

collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"
    local scope="${2:-all}" output value field index metric alias
    local extra_select="" extra_joins=""
    local -a values names=("${global_metric_names[@]}")
    local dbmetrics relssizestats relsizes
    
    if [[ "$scope" == all ]]; then
        names=("${binding_field_names[@]}")
        for alias in u t; do
            for metric in "${table_metric_names[@]}"; do
                extra_select+=", $alias.$metric"
            done
        done

        extra_select+=", t.n_tup_ins, t.n_tup_del"
        
        # toast_* and tidx_* belong to the PARENT row, not the TOAST row.
        extra_select+=", io.heap_blks_read, io.heap_blks_hit, io.idx_blks_read, io.idx_blks_hit,
                         io.toast_blks_read, io.toast_blks_hit, io.tidx_blks_read, io.tidx_blks_hit"
        # Resolve schema-qualified usertable, then follow reltoastrelid. TOAST
        # names/OIDs change when the comparison DB is recreated or restored.
        extra_joins="
        JOIN pg_catalog.pg_class AS r ON r.oid = to_regclass('public.usertable')
        JOIN pg_catalog.pg_stat_all_tables AS u ON u.relid = r.oid
        JOIN pg_catalog.pg_stat_all_tables AS t ON t.relid = r.reltoastrelid
        JOIN pg_catalog.pg_statio_all_tables AS io ON io.relid = r.oid"
    fi
    log "START statistics snapshot database=$db scope=$scope"
    # Capture the exit status BEFORE read: read <<< $(psql ...) hides SQL errors.
    if ! output=$(pg_exec -d "$db" -At -F '|' -c "
        SELECT d.blks_read, d.blks_hit, d.tup_returned, d.tup_fetched,
               d.tup_inserted, d.tup_updated, d.tup_deleted, d.deadlocks,
               d.temp_files, d.temp_bytes, c.num_timed, c.num_requested,
               c.num_done, c.buffers_written, b.buffers_clean, b.buffers_alloc,
               c.write_time, c.sync_time, w.wal_bytes, w.wal_records,
               w.wal_fpi, w.wal_buffers_full $extra_select
        FROM pg_catalog.pg_stat_database AS d
        CROSS JOIN pg_catalog.pg_stat_checkpointer AS c
        CROSS JOIN pg_catalog.pg_stat_bgwriter AS b
        CROSS JOIN pg_catalog.pg_stat_wal AS w
        $extra_joins
        WHERE d.datname = current_database();"); then
        echo "[ERROR] PostgreSQL metrics query failed for $db." >&2
        return 1
    fi
    if [[ -z "$output" || "$output" == *$'\n'* ]]; then
        echo "[ERROR] Expected one metrics row for $db." >&2
        return 1
    fi
    IFS='|' read -r -a values <<< "$output"
    if [[ ${#values[@]} -ne ${#names[@]} ]]; then
        echo "[ERROR] Unexpected metrics column count for $db." >&2
        return 1
    fi
    # Validate everything before publishing any values to the CSV writer.
    for index in "${!names[@]}"; do
        field="${names[$index]}"
        value="${values[$index]}"
        if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
            echo "[ERROR] Missing or invalid metric $field for $db." >&2
            return 1
        fi
    done
   	dbmetrics=""
    for index in "${!names[@]}"; do
        printf -v "${names[$index]}" '%s' "${values[$index]}"
    	dbmetrics+="${names[$index]}=${values[$index]} "
    done
    log "DB statistics $dbmetrics"

	# check for relation sizes too
    if ! size_output=$(pg_exec -d "$db" -At -F '|' -c "
        SELECT c.relname AS relation_name,
 				CASE c.relkind
  			      WHEN 'r' THEN 'table'
  			      WHEN 'i' THEN 'index'
   			      WHEN 't' THEN 'TOAST'
  			      WHEN 'm' THEN 'matview'
   			      WHEN 'S' THEN 'sequence'
  			      WHEN 'p' THEN 'partitioned_table'
  			      WHEN 'I' THEN 'partitioned_index'
   			     ELSE c.relkind::text
  			  END AS relation_type,
    		pg_relation_size(c.oid) raw_rel_size,
		    pg_size_pretty(pg_relation_size(c.oid)) AS relation_size
		FROM pg_catalog.pg_class AS c
		WHERE c.relfilenode > 100000;"); then
        	echo "[ERROR] PostgreSQL relation size query failed for $db." >&2
        	return 1
    fi
    if [[ -z "$size_output" ]]; then
        echo "[ERROR] Expected one relation size row for $db." >&2
        return 1
    fi
    relsizes=0
    while IFS='|' read -r -a size_values; do
    	relsizes=$((relsizes + 1))
    	relssizestats=""
	    for index in "${!relsize_metric_names[@]}"; do
    	    printf -v "${relsize_metric_names[$index]}" '%s' "${size_values[$index]}"
    	    if [[ "${relsize_metric_names[$index]}" == "raw_rel_size" ]]; then
	    	    relssizestats+="size: "
    	    fi
    	    relssizestats+="${size_values[$index]} "
		done
		log "DB statistics $relssizestats"
	done <<< "$size_output"

    log "END statistics snapshot database=$db statistics=${#names[@]} relsizes=$relsizes"
}

wait_for_idle_postgres() {
    local database="${1:-$DB_NAME}"
    local interval="${2:-20}"
    local timeout="${3:-1200}"
    local start active_backends active_count now

	# wait for backend services (autovacuum, checkpointing) to finish
	log "START WAIT FOR IDLE POSTGRES"
	idle_wait_started=$SECONDS
	start=$(date +%s)
	while true; do
		# Count connections that are NOT idle (excluding this script's connection)
		# Variant 1: Count
	    # active_count=$(pg_exec -d "$database" -At -c \
       	#	"SELECT COUNT(*) FROM pg_stat_activity WHERE state != 'idle' AND pid != pg_backend_pid();")
       	# active_count="${active_count//[[:space:]]/}"
	    # if [[ "$active_count" == "0" ]]; then
	    #     ...
	    #    	if (( now - start >= timeout )); then
        #    log "TIMEOUT WAIT FOR IDLE POSTGRES: $active_count backend(s) are still not idle."
        #    break
        #fi
	    # 
	    # Variant B: Details
	    active_backends=$(pg_exec -d "$database" -At -c \
       		"SELECT backend_type, query, query_start, wait_event, state FROM pg_stat_activity WHERE state != 'idle' AND pid != pg_backend_pid();")
    	active_count=$(printf '%s\n' "$active_backends" | wc -l)
	    #if [[ -z "$active_backends" ]]; then
	    if [[ "$active_count" == "0" ]]; then
			log "END WAIT FOR IDLE POSTGRES duration=$((SECONDS-idle_wait_started))s"
	       	break
    	fi
    	now=$(date +%s)
    	if (( now - start >= timeout )); then
            log "TIMEOUT WAIT FOR IDLE POSTGRES: $active_count backend(s) are still not idle: $(printf '%s' "$active_backends" | tr '\n' '\t')"
            break
        fi
	    log "WAITING FOR IDLE POSTGRES - $active_count active processes: $(printf '%s' "$active_backends" | tr '\n' '\t')"
    	sleep "$interval"
	done	
}

# stderr keeps diagnostics out of captured SQL results and raw YCSB CSV.
log() {
    case "$*" in
        "START experiment "*|"END experiment "*|\
        "START preflight"|"END preflight"|\
        "START statistics"*|"END statistics"*|"DB statistics"*|\
        "START YCSB "*|"END YCSB "*|\
        "START VACUUM"*|"END VACUUM"*|\
        "START WAIT"*|"END WAIT"*|"TIMEOUT WAIT"*|"WAITING"*|\
        "Initializing PostgreSQL database "*|"Done initializing "*|\
        "Backing up the database started"|"Backing up the database finished"|\
        "Log file: "*|"Result CSV: "*|"Download this log from EC2: "*|\
        *ERROR*|*WARNING*|Warning:*)
            printf '[epoch=%s run=%s phase=%s] %s\n' \
                "${epoch:-0}" "${step:-0}" "${phase:-setup}" "$*" >&2
            ;;
        *)
            return 0
            ;;
    esac
}

# test
log "=== Executing the load phase ==="
collect_cpu_memory_metrics
collect_postgres_metrics $DB_NAME

# wait for all backend processes (interval 20s timeout 20 mins)
wait_for_idle_postgres "$DB_NAME" 20 1200
