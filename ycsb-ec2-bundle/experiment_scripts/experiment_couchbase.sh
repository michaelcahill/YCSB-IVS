#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# Bucket names
COUCHBASE_BUCKET="ycsb"
COUCHBASE_BACKUP_BUCKET="ycsb_backup"
COUCHBASE_UNCHANGE_BUCKET="ycsb_unchange"

# Couchbase connection settings
COUCHBASE_HOST="${COUCHBASE_HOST:-127.0.0.1}"
# This binding uses bucket-password auth for YCSB operations (SDK 2.3.1).
# COUCHBASE_USERNAME/COUCHBASE_PASSWORD are also used for REST management calls.
COUCHBASE_USERNAME="${COUCHBASE_USERNAME:-ycsb}"
COUCHBASE_PASSWORD="${COUCHBASE_PASSWORD:-USyd2025}"
COUCHBASE_PASSWORD_PRIMARY="${COUCHBASE_PASSWORD_PRIMARY:-$COUCHBASE_PASSWORD}"
COUCHBASE_PASSWORD_BACKUP="${COUCHBASE_PASSWORD_BACKUP:-$COUCHBASE_PASSWORD_PRIMARY}"
COUCHBASE_PASSWORD_UNCHANGE="${COUCHBASE_PASSWORD_UNCHANGE:-$COUCHBASE_PASSWORD_PRIMARY}"
COUCHBASE_BOOST="${COUCHBASE_BOOST:-1}"
COUCHBASE_KV_MODE="${COUCHBASE_KV_MODE:-false}"
COUCHBASE_ADHOC="${COUCHBASE_ADHOC:-true}"
COUCHBASE_KV_ENABLED="false"
RESET_BUCKET_BEFORE_RUN="true"
FLUSH_FAILURE_STRATEGY="offset"
INSERTION_RETRY_LIMIT="20"
INSERTION_RETRY_INTERVAL="2"
INDEX_READY_TIMEOUT_SEC="${INDEX_READY_TIMEOUT_SEC:-180}"
INDEX_READY_POLL_INTERVAL_SEC="${INDEX_READY_POLL_INTERVAL_SEC:-2}"

# Change naming parameters here
TYPE="couchbase"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="heavy" # "heavy" OR "light"
WORK="mixed" # e.g. "mixed", "pure", or "spreadrun"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv"
HISTOGRAM_FILE="histogram.txt"

# Plan log file
PLAN_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_query_plan.log"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"
readrequestdistribution_extend="uniform"
updaterequestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"
readrequestdistribution_postextend="uniform"
updaterequestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"
WORKLOAD_BACKUP_FILE=""

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

log_stderr() {
    echo "$1" | tee -a "$LOG_FILE" >&2
}

password_var_hint_for_bucket() {
    local bucket_name="$1"
    case "$bucket_name" in
        "$COUCHBASE_BUCKET")
            echo "COUCHBASE_PASSWORD_PRIMARY"
            ;;
        "$COUCHBASE_BACKUP_BUCKET")
            echo "COUCHBASE_PASSWORD_BACKUP"
            ;;
        "$COUCHBASE_UNCHANGE_BUCKET")
            echo "COUCHBASE_PASSWORD_UNCHANGE"
            ;;
        *)
            echo "COUCHBASE_PASSWORD"
            ;;
    esac
}

ycsb_output_has_invalid_password() {
    grep -Eq 'InvalidPasswordException|Passwords for bucket ".*" do not match|Authentication Failure\.' "$OUTPUT_CSV"
}

restore_workload_file() {
    if [ -n "${WORKLOAD_BACKUP_FILE:-}" ] && [ -f "$WORKLOAD_BACKUP_FILE" ]; then
        cp "$WORKLOAD_BACKUP_FILE" "$WORKLOAD_FILE"
        rm -f "$WORKLOAD_BACKUP_FILE"
        log "Restored original workload file: $WORKLOAD_FILE"
    fi
}

backup_workload_file() {
    WORKLOAD_BACKUP_FILE=$(mktemp)
    cp "$WORKLOAD_FILE" "$WORKLOAD_BACKUP_FILE"
}

# Ensure required modules are staged for source-run
ensure_core_dependencies() {
    if [ ! -d "$YCSB_HOME/core/target/dependency" ] || [ ! -d "$YCSB_HOME/couchbase2/target/dependency" ]; then
        log "[WARN] core/couchbase2 dependencies missing; building with -Psource-run..."
        (cd "$YCSB_HOME" && mvn -Psource-run -pl core,couchbase2 -am package -DskipTests -Dcheckstyle.skip=true)
    fi
}

set_workload_property() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$WORKLOAD_FILE"; then
        perl -i -p -e "s/^${key}=.*/${key}=${value}/" "$WORKLOAD_FILE"
    else
        printf "%s=%s\n" "$key" "$value" >> "$WORKLOAD_FILE"
    fi
}

delete_workload_property() {
    local key="$1"
    perl -i -ne "print unless /^${key}=/" "$WORKLOAD_FILE"
}

get_couchbase_bucket_item_count() {
    local bucket_name="$1"
    local bucket_json
    bucket_json=$(curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" \
        "http://$COUCHBASE_HOST:8091/pools/default/buckets/$bucket_name" || true)
    perl -ne 'if (/"itemCount"\s*:\s*([0-9]+)/) { print $1; exit }' <<< "$bucket_json"
}

apply_unique_insertstart_offset() {
    local bucket_name="$1"
    local original_recordcount existing_item_count effective_insertstart adjusted_recordcount

    original_recordcount=$(awk -F= '/^recordcount=/{print $2}' "$WORKLOAD_FILE" | tail -1)
    if ! [[ "$original_recordcount" =~ ^[0-9]+$ ]]; then
        log "[WARN] Unable to parse workload recordcount ('$original_recordcount'); defaulting to 0 for offset calculation."
        original_recordcount=0
    fi

    existing_item_count=$(get_couchbase_bucket_item_count "$bucket_name")
    if ! [[ "$existing_item_count" =~ ^[0-9]+$ ]]; then
        log "[WARN] Unable to read current Couchbase itemCount from bucket '$bucket_name'; using insertstart=0 fallback."
        existing_item_count=0
    fi

    effective_insertstart="$existing_item_count"
    adjusted_recordcount=$((effective_insertstart + original_recordcount))

    set_workload_property "insertstart" "$effective_insertstart"
    set_workload_property "recordcount" "$adjusted_recordcount"
    delete_workload_property "insertcount"
    log "Applied insert offset fallback: bucket=$bucket_name insertstart=$effective_insertstart, recordcount=$adjusted_recordcount (base recordcount=$original_recordcount, existing items=$existing_item_count)."
}

tcp_port_open() {
    local host="$1"
    local port="$2"
    timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
}

bucket_http_status() {
    local bucket_name="$1"
    curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" -o /dev/null -w "%{http_code}" \
      "http://$COUCHBASE_HOST:8091/pools/default/buckets/$bucket_name" || true
}

preflight_bucket_or_die() {
    local bucket_name="$1"
    local bucket_http
    bucket_http=$(bucket_http_status "$bucket_name")
    log "Preflight /pools/default/buckets/$bucket_name status=$bucket_http"
    if [ "$bucket_http" != "200" ]; then
        log "[ERROR] Couchbase preflight failed: bucket '$bucket_name' is not reachable/authenticated (HTTP $bucket_http)."
        exit 1
    fi
}

resolve_couchbase_kv_mode_or_die() {
    local kv_port_open="false"
    local query_port_open="false"

    if tcp_port_open "$COUCHBASE_HOST" 11210; then
        kv_port_open="true"
    fi
    if tcp_port_open "$COUCHBASE_HOST" 8093; then
        query_port_open="true"
    fi

    case "$COUCHBASE_KV_MODE" in
        true)
            COUCHBASE_KV_ENABLED="true"
            ;;
        false)
            COUCHBASE_KV_ENABLED="false"
            ;;
        auto)
            if [ "$query_port_open" = "true" ] && [ "$kv_port_open" = "true" ]; then
                COUCHBASE_KV_ENABLED="true"
            elif [ "$query_port_open" = "true" ]; then
                COUCHBASE_KV_ENABLED="false"
            elif [ "$kv_port_open" = "true" ]; then
                COUCHBASE_KV_ENABLED="true"
            else
                log "[ERROR] Neither KV port 11210 nor Query port 8093 is reachable on $COUCHBASE_HOST."
                exit 1
            fi
            ;;
        *)
            log "[ERROR] Invalid COUCHBASE_KV_MODE='$COUCHBASE_KV_MODE'. Expected true, false, or auto."
            exit 1
            ;;
    esac

    # This script requires N1QL for bucket copy, key-size extraction and key cleanup.
    if [ "$query_port_open" != "true" ]; then
        log "[ERROR] Query port 8093 is required by experiment_couchbase.sh but is unreachable."
        exit 1
    fi

    log "Couchbase access mode: couchbase.kv=$COUCHBASE_KV_ENABLED (auto mode=$COUCHBASE_KV_MODE, kv11210=$kv_port_open, query8093=$query_port_open)"
}

preflight_couchbase_or_die() {
    log "=== Couchbase preflight check ==="

    if ! command -v curl >/dev/null 2>&1; then
        log "[ERROR] curl is required for Couchbase preflight checks but was not found in PATH."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "[ERROR] jq is required by experiment_couchbase.sh for query result parsing but was not found in PATH."
        exit 1
    fi

    local pools_http
    pools_http=$(curl -s -o /dev/null -w "%{http_code}" "http://$COUCHBASE_HOST:8091/pools" || true)
    log "Preflight /pools status=$pools_http"
    if [ "$pools_http" != "200" ] && [ "$pools_http" != "401" ]; then
        log "[ERROR] Couchbase preflight failed: management endpoint /pools returned HTTP $pools_http (expected 200 or 401)."
        exit 1
    fi

    preflight_bucket_or_die "$COUCHBASE_BUCKET"
    preflight_bucket_or_die "$COUCHBASE_BACKUP_BUCKET"
    preflight_bucket_or_die "$COUCHBASE_UNCHANGE_BUCKET"

    resolve_couchbase_kv_mode_or_die
}

flush_bucket_or_die() {
    local bucket_name="$1"
    local strategy="$2"
    local flush_http

    flush_http=$(curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" \
        -X POST -o /dev/null -w "%{http_code}" \
        "http://$COUCHBASE_HOST:8091/pools/default/buckets/$bucket_name/controller/doFlush" || true)

    if [ "$flush_http" != "200" ] && [ "$flush_http" != "202" ]; then
        if [ "$strategy" = "offset" ]; then
            log "[WARN] Failed to flush bucket '$bucket_name' (HTTP $flush_http)."
            log "[WARN] Falling back to unique insertstart offset strategy."
            apply_unique_insertstart_offset "$bucket_name"
            return
        fi
        log "[ERROR] Failed to flush bucket '$bucket_name' (HTTP $flush_http)."
        exit 1
    fi

    log "Bucket '$bucket_name' flush requested successfully (HTTP $flush_http)."
}

n1ql_query_json() {
    local statement="$1"
    curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "statement=$statement" \
      --data-urlencode "scan_consistency=request_plus" \
      "http://$COUCHBASE_HOST:8093/query/service" || true
}

primary_index_name_for_bucket() {
    local bucket_name="$1"
    local idx_suffix
    idx_suffix=$(echo "$bucket_name" | sed 's/[^a-zA-Z0-9_]/_/g')
    echo "idx_primary_${idx_suffix}"
}

index_status_json() {
    curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" \
      "http://$COUCHBASE_HOST:8091/indexStatus" || true
}

n1ql_is_indexer_rollback_response() {
    local response="$1"
    printf '%s' "$response" | jq -e '
        (.errors // [])
        | map(select(
            ((.code // 0) == 5000) or
            ((.reason.code // 0) == 4350) or
            ((.msg // "" | ascii_downcase | contains("indexer rollback"))) or
            ((.reason.message // "" | ascii_downcase | contains("gsi error")))
        ))
        | length > 0
    ' >/dev/null 2>&1
}

n1ql_first_error_message() {
    local response="$1"
    printf '%s' "$response" | jq -r '
        (.errors[0].msg // .errors[0].reason.message // .errors[0].reason.cause.error // "unknown n1ql error")
    ' 2>/dev/null || echo "unknown n1ql error"
}

wait_for_primary_index_ready_or_die() {
    local bucket_name="$1"
    local index_name attempts attempt response state progress stale

    index_name=$(primary_index_name_for_bucket "$bucket_name")
    attempts=$(( (INDEX_READY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    if [ "$attempts" -le 0 ]; then
        attempts=1
    fi

    for attempt in $(seq 1 "$attempts"); do
        response=$(index_status_json)
        state=$(printf '%s' "$response" | jq -r --arg bucket "$bucket_name" --arg idx "$index_name" '
            (.indexes // [])
            | map(select((.bucket // "") == $bucket and (((.index // .indexName // "") == $idx) or ((.index // .indexName // "") == "#primary"))))
            | if length == 0 then "MISSING" else (.[0].status // "UNKNOWN") end
        ' 2>/dev/null || echo "PARSE_ERROR")
        progress=$(printf '%s' "$response" | jq -r --arg bucket "$bucket_name" --arg idx "$index_name" '
            (.indexes // [])
            | map(select((.bucket // "") == $bucket and (((.index // .indexName // "") == $idx) or ((.index // .indexName // "") == "#primary"))))
            | if length == 0 then "n/a" else ((.[0].progress // "n/a")|tostring) end
        ' 2>/dev/null || echo "n/a")
        stale=$(printf '%s' "$response" | jq -r --arg bucket "$bucket_name" --arg idx "$index_name" '
            (.indexes // [])
            | map(select((.bucket // "") == $bucket and (((.index // .indexName // "") == $idx) or ((.index // .indexName // "") == "#primary"))))
            | if length == 0 then "n/a" else ((.[0].stale // "n/a")|tostring) end
        ' 2>/dev/null || echo "n/a")

        if [ "$state" = "Ready" ]; then
            return
        fi

        if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ]; then
            log_stderr "[WARN] Waiting for primary index '$index_name' on bucket '$bucket_name' (state=$state, progress=$progress, stale=$stale, attempt $attempt/$attempts)."
        fi
        sleep "$INDEX_READY_POLL_INTERVAL_SEC"
    done

    log_stderr "[ERROR] Primary index '$index_name' for bucket '$bucket_name' did not become Ready within ${INDEX_READY_TIMEOUT_SEC}s."
    log_stderr "[ERROR] Last /indexStatus payload: $(index_status_json)"
    exit 1
}

wait_for_bucket_query_ready_or_die() {
    local bucket_name="$1"
    local context="$2"
    local probe_stmt probe_response probe_status attempts attempt err_msg

    probe_stmt="SELECT RAW META().id FROM \`$bucket_name\` LIMIT 1;"
    attempts=$(( (INDEX_READY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    if [ "$attempts" -le 0 ]; then
        attempts=1
    fi

    for attempt in $(seq 1 "$attempts"); do
        wait_for_primary_index_ready_or_die "$bucket_name"

        probe_response=$(n1ql_query_json "$probe_stmt")
        probe_status=$(printf '%s' "$probe_response" | jq -r '.status // empty' 2>/dev/null || true)
        if [ "$probe_status" = "success" ]; then
            return
        fi

        if n1ql_is_indexer_rollback_response "$probe_response"; then
            if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ]; then
                err_msg=$(n1ql_first_error_message "$probe_response")
                log_stderr "[WARN] Waiting for active index/query path on bucket '$bucket_name' before $context (attempt $attempt/$attempts): $err_msg"
            fi
            sleep "$INDEX_READY_POLL_INTERVAL_SEC"
            continue
        fi

        log_stderr "[ERROR] Query readiness probe failed during: $context"
        log_stderr "[ERROR] Probe statement: $probe_stmt"
        log_stderr "[ERROR] Probe response: $probe_response"
        exit 1
    done

    log_stderr "[ERROR] Timed out waiting for active index/query path on bucket '$bucket_name' before $context."
    exit 1
}

n1ql_query_with_active_index_or_die() {
    local statement="$1"
    local context="$2"
    local bucket_name="$3"
    local response status attempts attempt err_msg

    attempts=$(( (INDEX_READY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    if [ "$attempts" -le 0 ]; then
        attempts=1
    fi

    for attempt in $(seq 1 "$attempts"); do
        wait_for_bucket_query_ready_or_die "$bucket_name" "$context"
        response=$(n1ql_query_json "$statement")
        status=$(printf '%s' "$response" | jq -r '.status // empty' 2>/dev/null || true)
        if [ "$status" = "success" ]; then
            printf '%s' "$response"
            return
        fi

        if n1ql_is_indexer_rollback_response "$response"; then
            if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ]; then
                err_msg=$(n1ql_first_error_message "$response")
                log_stderr "[WARN] Active-index-gated query still hit index rollback during: $context (attempt $attempt/$attempts): $err_msg"
            fi
            sleep "$INDEX_READY_POLL_INTERVAL_SEC"
            continue
        fi

        log_stderr "[ERROR] N1QL query failed during: $context"
        log_stderr "[ERROR] Statement: $statement"
        log_stderr "[ERROR] Response: $response"
        exit 1
    done

    log_stderr "[ERROR] N1QL query failed during: $context after waiting ${INDEX_READY_TIMEOUT_SEC}s for active index/query path."
    log_stderr "[ERROR] Statement: $statement"
    log_stderr "[ERROR] Last response: $response"
    exit 1
}

n1ql_query_or_die() {
    local statement="$1"
    local context="$2"
    local response status

    response=$(n1ql_query_json "$statement")
    status=$(printf '%s' "$response" | jq -r '.status // empty' 2>/dev/null || true)

    if [ -z "$status" ] || [ "$status" != "success" ]; then
        log "[ERROR] N1QL query failed during: $context"
        log "[ERROR] Statement: $statement"
        log "[ERROR] Response: $response"
        exit 1
    fi

    printf '%s' "$response"
}

ensure_primary_index() {
    local bucket_name="$1"
    local idx_name
    idx_name=$(primary_index_name_for_bucket "$bucket_name")
    n1ql_query_or_die "CREATE PRIMARY INDEX IF NOT EXISTS \`$idx_name\` ON \`$bucket_name\`;" "create primary index on $bucket_name" >/dev/null
    wait_for_primary_index_ready_or_die "$bucket_name"
}

ensure_query_indexes() {
    ensure_primary_index "$COUCHBASE_BUCKET"
    ensure_primary_index "$COUCHBASE_BACKUP_BUCKET"
    ensure_primary_index "$COUCHBASE_UNCHANGE_BUCKET"
}

collect_couchbase_metrics() {
    blks_read=0
    blks_hit=0
    tup_returned=0
    tup_fetched=0
    tup_inserted=0
    tup_updated=0
    tup_deleted=0
    deadlocks=0
    temp_files=0
    temp_bytes=0
    checkpoints_timed=0
    checkpoints_req=0
    buffers_checkpoint=0
    buffers_clean=0
    buffers_backend=0
    buffers_alloc=0
    checkpoint_write_time=0
    checkpoint_sync_time=0
    wal_bytes=0
    wal_records=0
    wal_fpi=0
    wal_buffers_full=0
}

write_result() {
    local first="$1"
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")
    if [ "$first" == "TRUE" ]; then
        dynamic_cols=$(awk '{print $2}' <<< "$filtered_output" \
            | sed 's/,$//' \
            | grep -v '^Return=ERROR$' \
            | uniq \
            | awk '{ORS=","; print}' \
            | sed 's/,$//')
        if [ -n "$dynamic_cols" ]; then
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$dynamic_cols"
        else
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    epoch=${epoch:-0}
    run=${run:-0}
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * (epoch - 1) + run))
    fi

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

    run_specific=()
    while IFS= read -r inner_line; do
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    operation=""
    while IFS= read -r line; do
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        if [ "$operation" = "READ" ] && [ -n "$readrequestdistribution" ]; then
            op_requestdistribution="$readrequestdistribution"
        elif [ "$operation" = "UPDATE" ] && [ -n "$updaterequestdistribution" ]; then
            op_requestdistribution="$updaterequestdistribution"
        else
            op_requestdistribution="$requestdistribution"
        fi

        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    log "Arrangement completed. Output saved to $OUTPUT_FILE"
}

append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    log "First iteration: Appended values from $key_size_log to $key_size_file"
}

append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}
        FNR==1 {print $0 ",Run" iter; next}
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}
        !($1 in key_sizes) {print $0 ",0"}
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"
    log "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    log "Generating histogram from key size log: $key_size_log"

    awk -F, '
        BEGIN {
            block = 100
            OFS = "\t"
        }
        NR == 1 { next }
        {
            size = $2 + 0
            bucket = int(size / (block * 10))
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

run_ycsb() {
    local mode="$1"
    local bucket_name="$2"
    local use_histogram="$3"
    local bucket_password="$4"
    local password_hint_var

    password_hint_var=$(password_var_hint_for_bucket "$bucket_name")

    local cmd
    cmd=("$YCSB" "$mode" couchbase2 -s -P "$WORKLOAD_FILE"
        -p "couchbase.host=$COUCHBASE_HOST"
        -p "couchbase.bucket=$bucket_name"
        -p "couchbase.password=$bucket_password"
        -p "couchbase.adhoc=$COUCHBASE_ADHOC"
        -p "couchbase.kv=$COUCHBASE_KV_ENABLED"
        -p "couchbase.boost=$COUCHBASE_BOOST"
        -p "core_workload_insertion_retry_limit=$INSERTION_RETRY_LIMIT"
        -p "core_workload_insertion_retry_interval=$INSERTION_RETRY_INTERVAL")

    if [ "$use_histogram" = "true" ]; then
        cmd+=( -p "fieldlengthhistogram=$HISTOGRAM_FILE" )
    fi

    set +e
    "${cmd[@]}" 2>&1 | tee "$OUTPUT_CSV"
    local rc=${PIPESTATUS[0]}
    set -e

    if ycsb_output_has_invalid_password; then
        log "[ERROR] Bucket '$bucket_name' authentication failed (bucket-password auth). Update $password_hint_var for this bucket."
        exit 1
    fi

    if [ "$rc" -ne 0 ]; then
        log "[ERROR] YCSB $mode failed for bucket '$bucket_name' with status $rc."
        exit 1
    fi

    if grep -Eq 'Exception:|RequestCancelledException|Error inserting,' "$OUTPUT_CSV"; then
        log "[ERROR] YCSB $mode emitted exceptions for bucket '$bucket_name'."
        exit 1
    fi
}

get_bucket_keys() {
    local bucket_name="$1"
    local output_file="$2"
    local response

    response=$(n1ql_query_or_die "SELECT RAW META().id FROM \`$bucket_name\`;" "fetch keys from $bucket_name")
    printf '%s' "$response" | jq -r '.results[]' > "$output_file"
}

delete_keys_from_bucket() {
    local bucket_name="$1"
    local keys_file="$2"

    if [ ! -s "$keys_file" ]; then
        return
    fi

    local keys_json
    keys_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$keys_file")
    if [ "$keys_json" = "[]" ]; then
        return
    fi

    n1ql_query_or_die "DELETE FROM \`$bucket_name\` USE KEYS $keys_json;" "delete extra keys from $bucket_name" >/dev/null
}

copy_bucket_data() {
    local source_bucket="$1"
    local target_bucket="$2"

    log "Backing up the bucket started"
    flush_bucket_or_die "$target_bucket" "strict"
    n1ql_query_or_die "INSERT INTO \`$target_bucket\` (KEY k, VALUE v) SELECT META(s).id AS k, s AS v FROM \`$source_bucket\` AS s;" "copy $source_bucket to $target_bucket" >/dev/null
    log "Backing up the bucket finished"
}

size_expression() {
    cat <<'EXPR'
LENGTH(TOSTRING(IFMISSINGORNULL(field0, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field1, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field2, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field3, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field4, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field5, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field6, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field7, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field8, ""))) +
LENGTH(TOSTRING(IFMISSINGORNULL(field9, "")))
EXPR
}

dump_key_sizes() {
    local bucket_name="$1"
    local out_file="$2"
    local expr response

    expr=$(size_expression | tr '\n' ' ')
    echo "ycsb_key,size" > "$out_file"
    response=$(n1ql_query_with_active_index_or_die \
        "SELECT RAW [META().id, ($expr)] FROM \`$bucket_name\`;" \
        "dump key sizes from $bucket_name" \
        "$bucket_name")
    if ! printf '%s' "$response" | jq -r '.results[] | "\(.[0]),\(.[1] // 0)"' >> "$out_file" 2>/dev/null; then
        log_stderr "[ERROR] Failed to parse N1QL JSON during: dump key sizes from $bucket_name"
        log_stderr "[ERROR] Raw response: $response"
        exit 1
    fi
}

get_total_size() {
    local bucket_name="$1"
    local expr response total

    expr=$(size_expression | tr '\n' ' ')
    response=$(n1ql_query_with_active_index_or_die \
        "SELECT RAW SUM(($expr)) FROM \`$bucket_name\`;" \
        "compute total size from $bucket_name" \
        "$bucket_name")
    if ! total=$(printf '%s' "$response" | jq -r '.results[0] // 0' 2>/dev/null); then
        log_stderr "[ERROR] Failed to parse N1QL JSON during: compute total size from $bucket_name"
        log_stderr "[ERROR] Raw response: $response"
        exit 1
    fi
    echo "$total"
}

log_query_plan() {
    local bucket_name="$1"
    local epoch_num="$2"
    local run_num="$3"
    local response test_key explain_response escaped_key

    response=$(n1ql_query_or_die "SELECT RAW META().id FROM \`$bucket_name\` LIMIT 1;" "fetch test key from $bucket_name")
    test_key=$(printf '%s' "$response" | jq -r '.results[0] // empty')

    if [ -z "$test_key" ]; then
        log "[WARN] Could not fetch test key for query plan logging from bucket '$bucket_name'."
        return
    fi

    escaped_key=${test_key//\\/\\\\}
    escaped_key=${escaped_key//\"/\\\"}
    explain_response=$(n1ql_query_or_die "EXPLAIN SELECT * FROM \`$bucket_name\` USE KEYS [\"$escaped_key\"];" "collect query plan for $bucket_name")

    {
        echo "========================================"
        echo "Epoch=$epoch_num Run=$run_num Phase=run Time=$(date)"
        echo "Bucket=$bucket_name"
        echo "Key=$test_key"
        echo "----------------------------------------"
        echo "$explain_response" | jq .
        echo
    } >> "$PLAN_LOG"
}

ensure_core_dependencies

> "$LOG_FILE"
rm -rf "$KEY_SIZE_LOG"
rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$OUTPUT_CSV")" "$(dirname "$KEY_SIZE_FILE_AFTER_EXTEND")" "$(dirname "$KEY_SIZE_FILE_AFTER_RUN")"

backup_workload_file
trap restore_workload_file EXIT

preflight_couchbase_or_die
ensure_query_indexes

if [ "$RESET_BUCKET_BEFORE_RUN" = "true" ]; then
    log "=== Resetting Couchbase buckets before run ==="
    flush_bucket_or_die "$COUCHBASE_BUCKET" "$FLUSH_FAILURE_STRATEGY"
    flush_bucket_or_die "$COUCHBASE_BACKUP_BUCKET" "strict"
    flush_bucket_or_die "$COUCHBASE_UNCHANGE_BUCKET" "strict"
fi

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
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

run_ycsb load "$COUCHBASE_BUCKET" "false" "$COUCHBASE_PASSWORD_PRIMARY"
collect_couchbase_metrics
write_result "TRUE"

# Load unchange value-size bucket (reference), mirroring PostgreSQL experiment logic.
log "=== Executing the load phase for unchange reference bucket ==="
run_ycsb load "$COUCHBASE_UNCHANGE_BUCKET" "false" "$COUCHBASE_PASSWORD_UNCHANGE"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 3); do
    for run in $(seq 1 3); do

        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" "$WORKLOAD_FILE"
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
        run_ycsb run "$COUCHBASE_BUCKET" "true" "$COUCHBASE_PASSWORD_PRIMARY"

        # Extract extend failure count from YCSB output
        extend_failed_count=$(grep -oP 'EXTEND-FAILED: Count=\K\d+' "$OUTPUT_CSV" | head -1 || echo "0")
        if [ -n "$extend_failed_count" ] && [ "$extend_failed_count" != "0" ]; then
            log "WARNING: $extend_failed_count EXTEND operations failed during extend phase"
            if [ "$extend_failed_count" -ge "$extendoperationcount" ]; then
                log "ERROR: All EXTEND operations failed. Check couchbase2 binding extend() implementation and bucket setup."
                exit 1
            fi
        fi

        collect_couchbase_metrics
        write_result "FALSE"

        # Key Sizes
        log "Size computation started"
        dump_key_sizes "$COUCHBASE_BUCKET" "$KEY_SIZE_LOG"

        # Verify extend operations
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

        get_key_sizes "$KEY_SIZE_LOG" "$HISTOGRAM_FILE"

        iteration=$((10*($epoch-1)+$run))
        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        if [[ "$iteration" -eq 1 ]]; then
            append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
        else
            append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" "$WORKLOAD_FILE"
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

        # Save the existing keys in the bucket
        get_bucket_keys "$COUCHBASE_BUCKET" "keys_before_run.txt"

        # Log query plan before run phase
        log "Checking query plan before run phase"
        log_query_plan "$COUCHBASE_BUCKET" "$epoch" "$run"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        run_ycsb run "$COUCHBASE_BUCKET" "true" "$COUCHBASE_PASSWORD_PRIMARY"
        collect_couchbase_metrics
        write_result "FALSE"

        # Save keys to remove duplicates later
        get_bucket_keys "$COUCHBASE_BUCKET" "keys_after_run.txt"

        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt
        delete_keys_from_bucket "$COUCHBASE_BUCKET" "keys_to_delete.txt"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        get_bucket_keys "$COUCHBASE_UNCHANGE_BUCKET" "keys_before_run.txt"

        # Reference workload with unchanging value sizes
        phase="reference"
        run_ycsb run "$COUCHBASE_UNCHANGE_BUCKET" "true" "$COUCHBASE_PASSWORD_UNCHANGE"
        collect_couchbase_metrics
        write_result "FALSE"

        # Save keys to remove duplicates later
        get_bucket_keys "$COUCHBASE_UNCHANGE_BUCKET" "keys_after_run.txt"

        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt
        delete_keys_from_bucket "$COUCHBASE_UNCHANGE_BUCKET" "keys_to_delete.txt"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"

            copy_bucket_data "$COUCHBASE_BUCKET" "$COUCHBASE_BACKUP_BUCKET"

            run_ycsb run "$COUCHBASE_BACKUP_BUCKET" "true" "$COUCHBASE_PASSWORD_BACKUP"
            collect_couchbase_metrics
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            log "Size computation started"
            dump_key_sizes "$COUCHBASE_BACKUP_BUCKET" "$KEY_SIZE_LOG"

            iteration=$((10*($epoch-1)+$run))
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            else
                append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # Get total size of all records from backup bucket
            total_size=$(get_total_size "$COUCHBASE_BACKUP_BUCKET")

            # Set average field length
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage=$(grep -E '^fieldlength=' "$WORKLOAD_FILE" | cut -d'=' -f2)
                fieldlengthaverage=${fieldlengthaverage:-$fieldlengthoriginal}
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            log "Total size: $total_size, Field length average: $fieldlengthaverage"

            # Changing the value size for comparison
            if grep -q '^fieldlength=' "$WORKLOAD_FILE"; then
                perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" "$WORKLOAD_FILE"
            else
                echo "fieldlength=$fieldlengthaverage" >> "$WORKLOAD_FILE"
            fi
            source "$WORKLOAD_FILE"
            actual_fieldlength=$(grep -E '^fieldlength=' "$WORKLOAD_FILE" | cut -d'=' -f2)
            log "Workload file fieldlength set to: $actual_fieldlength (expected: $fieldlengthaverage)"

            # Reset backup bucket with new data load
            flush_bucket_or_die "$COUCHBASE_BACKUP_BUCKET" "strict"

            log "=== Executing the load phase for the comparison study ==="
            run_ycsb load "$COUCHBASE_BACKUP_BUCKET" "false" "$COUCHBASE_PASSWORD_BACKUP"

            # Verify record sizes after avg-run load
            iteration=$((10*($epoch-1)+$run))
            total_size_avg_run=$(get_total_size "$COUCHBASE_BACKUP_BUCKET")
            log "Avg-run verification - Epoch:$epoch Run:$run Iteration:$iteration TotalSize:$total_size_avg_run ExpectedFieldLength:$fieldlengthaverage"

            # Keep fieldlength at the newly computed average for this run.
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"
            run_ycsb run "$COUCHBASE_BACKUP_BUCKET" "false" "$COUCHBASE_PASSWORD_BACKUP"
            collect_couchbase_metrics
            write_result "FALSE"
        fi
    done
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
