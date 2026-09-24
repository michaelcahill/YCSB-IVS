#!/usr/bin/env bash
# Couchbase backend — JSON document store, driven by the couchbase2 binding (Java SDK 2.x).
# The last control-group member of the study: one JSON document per key, so the extend phase
# grows a document, exactly like MongoDB but through N1QL instead of a shell.
#
# Sourced by lib/registry.sh, never run directly.
#
# What makes this backend different from the others here:
#   * its admin interface is HTTP, not a CLI. Management runs through the REST API (port 8091)
#     and N1QL through the query service (port 8093), so unlike neo4j/mongodb there is nothing
#     to wrap when the server is a container - `curl` reaches it either way;
#   * the three experiment roles are three **buckets** of one cluster, and SDK 2.x authenticates
#     with the bucket name as the username (`cluster.openBucket(bucket, password)`). Every bucket
#     therefore needs a local RBAC user named exactly like it - which is why backend::init_db
#     creates the bucket *and* its user when they do not exist yet;
#   * Couchbase's indexes are asynchronous. Every count read after a mutation can be stale, so
#     the copy to the comparison bucket is verified by polling until the two counts agree rather
#     than by trusting the INSERT's `status: success` - an insert that matched nothing also
#     reports success (measured here: 19 documents copied, first read back said 12);
#   * `couchbase.kv=false` (as in the legacy runners): mutations go through N1QL, reads through
#     the KV service. The binding prefixes every document id with the table name, so keys look
#     like `usertable:user123`, and that is also what META().id returns and what USE KEYS takes.
#
# Differences from the legacy experiment_couchbase.sh, all deliberate:
#   * no insertstart/recordcount rewriting when a bucket cannot be flushed. Shifting the key
#     range changes what the run measures; instead a bucket is emptied by flush and, where flush
#     is not permitted, by `DELETE FROM <bucket>`. Only if both fail does the run stop;
#   * one bucket password (DB_PWD) for all three roles. The legacy variables
#     COUCHBASE_PASSWORD_PRIMARY/_BACKUP/_UNCHANGE all defaulted to the same value and that is
#     the only configuration the engine can express, because binding_db_params sends one
#     password per phase;
#   * the copy to the comparison bucket is verified (document counts must agree), which the
#     legacy INSERT ... SELECT never checked;
#   * endpoints come from configuration instead of a hardcoded 127.0.0.1, and the buckets may be
#     created by the runner when COUCHBASE_CREATE_MISSING_BUCKETS=1 (the default). Where the
#     benchmark role may not create them, set it to 0 and create three buckets plus three
#     bucket-named users beforehand - see conf/db.couchbase.env.example.
#
# The 22 statistics columns are the legacy list in the legacy order (the header of
# experiment_couchbase_baseline.sh, kept as data in tests/golden/legacy_csv_columns.txt and
# asserted by tests/test_config_workload.sh), and they are all zero:
# Couchbase exposes no equivalent of those PostgreSQL counters, and the legacy runner emitted
# literal zeros for them too. Keeping the names keeps this backend's results CSV comparable with
# the EC2 runs made before the refactor; what a phase really did is in the value-size files and,
# since this port, in the run log (backend::collect_metrics records the bucket's own numbers).
# One deliberate addition: CPU and Memory. Every backend of this harness reports them - the
# legacy Couchbase runner's header had neither, so its CSV is these two columns narrower.

# The admin transport is HTTP, so unlike the neo4j/mongodb backends nothing has to be wrapped
# when the server runs in a container - curl reaches it either way.
COUCHBASE_CLI="${COUCHBASE_CLI:-curl}"

# ---------------------------------------------------------------------------
# Statistics columns (the results CSV schema for this backend)
# ---------------------------------------------------------------------------

metric_field_names=(
    blks_read
    blks_hit
    tup_returned
    tup_fetched
    tup_inserted
    tup_updated
    tup_deleted
    deadlocks
    temp_files
    temp_bytes
    checkpoints_timed
    checkpoints_req
    buffers_checkpoint
    buffers_clean
    buffers_backend
    buffers_alloc
    checkpoint_write_time
    checkpoint_sync_time
    wal_bytes
    wal_records
    wal_fpi
    wal_buffers_full
)

backend::metric_names() {
    printf '%s\n' "${metric_field_names[@]}"
}

# write_result reads one variable per column name; initialise them so a call-order change can
# never turn into an unbound-variable abort. backend::collect_metrics sets the same names.
for _metric_name in "${metric_field_names[@]}"; do
    printf -v "$_metric_name" '%s' 0
done
unset _metric_name

# Zeroes for the PostgreSQL-shaped columns (see the header), plus the numbers Couchbase really
# does report, logged so that a phase can be recognised after the fact: documents, their size on
# disk and in RAM. scope=global is the preflight probe, where no bucket has to exist yet.
backend::collect_metrics() {
    local db="${1:-$DB_NAME}" scope="${2:-all}" stats
    local name

    for name in "${metric_field_names[@]}"; do
        printf -v "$name" '%s' 0
    done

    log "START statistics snapshot database=$db scope=$scope"
    if [[ "$scope" != global ]]; then
        local total
        total=$(backend::total_size "$db") || return 1
        log "DB statistics value size: $total database=$db"
        stats=$(couchbase::bucket_stats "$db" itemCount,diskUsed,dataUsed,memUsed 2>/dev/null || true)
        log "DB statistics bucket counters database=$db ${stats:-unavailable}"
    fi
    log "END statistics snapshot database=$db statistics=${#metric_field_names[@]}"
}

# ---------------------------------------------------------------------------
# Management API (REST + N1QL over HTTP)
# ---------------------------------------------------------------------------

COUCHBASE_HTTP_STATUS=""
COUCHBASE_LAST_BODY=""

# couchbase::rest METHOD PATH [curl args...] - one management call as the management user.
# The body goes to stdout, the HTTP status code to COUCHBASE_HTTP_STATUS. Credentials never
# reach the log: every request here carries the management password.
couchbase::rest() {
    local method="${1:?HTTP method required}" path="${2:?management path required}"
    shift 2
    local started=$SECONDS rc=0 status="" file err
    log "START Couchbase management call method=$method path=$path"

    file=$(mktemp "${TMPDIR:-/tmp}/ycsb-couchbase-response.XXXXXX")
    err=$(mktemp "${TMPDIR:-/tmp}/ycsb-couchbase-error.XXXXXX")
    status=$("$COUCHBASE_CLI" -s -S -o "$file" -w '%{http_code}' -X "$method" \
        --connect-timeout 10 --max-time "${COUCHBASE_MGMT_TIMEOUT_SEC:-120}" \
        -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" \
        "http://$COUCHBASE_HOST:$COUCHBASE_PORT_MGMT$path" "$@" 2>"$err") || rc=$?
    COUCHBASE_HTTP_STATUS="$status"
    COUCHBASE_LAST_BODY="$(cat "$file")"
    [[ -s "$err" ]] && log "WARNING Couchbase management call reported: $(tail -c 300 "$err" | tr '\n' ' ')" >&2
    rm -f "$file" "$err"

    log "END Couchbase management call method=$method path=$path http=${status:-none} status=$rc duration=$((SECONDS-started))s"
    [[ -n "$status" ]] || return 1
    printf '%s' "$COUCHBASE_LAST_BODY"
}

# couchbase::query_as <user> <password> <statement> - one N1QL request; prints the raw JSON.
# Statements are not logged (they can hold credentials and grow large); a failing statement is
# logged by couchbase::query_or_die, which owns the error message.
couchbase::query_as() {
    local user="$1" password="$2" statement="$3"
    local started=$SECONDS rc=0 out
    log "START Couchbase query user=$user length=${#statement}"
    out=$("$COUCHBASE_CLI" -s -S -u "$user:$password" \
        --connect-timeout 10 --max-time "${COUCHBASE_QUERY_TIMEOUT_SEC:-600}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'scan_consistency=request_plus' \
        --data-urlencode "statement=$statement" \
        "http://$COUCHBASE_HOST:$COUCHBASE_PORT_QUERY/query/service" 2>&1) || rc=$?
    log "END Couchbase query user=$user length=${#statement} status=$rc duration=$((SECONDS-started))s"
    printf '%s' "$out"
    return "$rc"
}

# couchbase::query <statement> - one N1QL request as the management user, the only principal
# allowed to read all three buckets (the copy and the size queries span two of them).
couchbase::query() {
    couchbase::query_as "$COUCHBASE_USERNAME" "$COUCHBASE_PASSWORD" "${1:?statement required}"
}

couchbase::query_status() { printf '%s' "${1:-}" | jq -r '.status // empty' 2>/dev/null; }

couchbase::query_error() {
    printf '%s' "${1:-}" | jq -r '
        (.errors[0].msg // .errors[0].reason.message // .errors[0].reason.cause.error // "unknown n1ql error")
    ' 2>/dev/null || printf 'unknown n1ql error'
}

# The indexer can briefly report a rollback after a flush or rebalance; those failures are worth
# retrying, everything else is a real error. Same classification as the legacy runner.
couchbase::query_is_rollback() {
    printf '%s' "${1:-}" | jq -e '
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

# couchbase::query_or_die <statement> <context> - run a statement, retrying indexer rollbacks.
# Prints the JSON response on success; returns 1 (with the statement and response logged)
# otherwise. Never exits: the engine turns a failed backend call into a failed run.
couchbase::query_or_die() {
    local statement="${1:?statement required}" context="${2:-query}"
    local attempt attempts=1 response status error

    if ((INDEX_READY_TIMEOUT_SEC > 0)); then
        attempts=$(( (INDEX_READY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    fi
    ((attempts > 0)) || attempts=1

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        response=$(couchbase::query "$statement")
        status=$(couchbase::query_status "$response")
        if [[ "$status" == success ]]; then
            printf '%s' "$response"
            return 0
        fi
        if couchbase::query_is_rollback "$response"; then
            error=$(couchbase::query_error "$response")
            log "WARNING waiting for an active index/query path during: $context (attempt $attempt/$attempts): $error" >&2
            sleep "$INDEX_READY_POLL_INTERVAL_SEC"
            continue
        fi
        log "ERROR N1QL query failed during: $context" >&2
        log "ERROR statement: $statement" >&2
        log "ERROR response: $response" >&2
        return 1
    done

    log "ERROR N1QL query still failing after ${INDEX_READY_TIMEOUT_SEC}s during: $context" >&2
    log "ERROR statement: $statement" >&2
    return 1
}

# couchbase::query_values <statement> <context> - results array of a query, one line per row.
couchbase::query_values() {
    local response
    response=$(couchbase::query_or_die "${1:?statement required}" "${2:-query}") || return 1
    printf '%s' "$response" | jq -r '.results[]'
}

# --- indexes -------------------------------------------------------------------

couchbase::index_name() {
    printf 'idx_primary_%s\n' "${1//[^a-zA-Z0-9_]/_}"
}

# couchbase::index_state <bucket> -> Ready / Building / ... (MISSING when there is none).
couchbase::index_state() {
    local bucket="${1:?bucket required}" index body
    index=$(couchbase::index_name "$bucket")
    body=$(couchbase::rest GET /indexStatus) || { printf 'UNREACHABLE\n'; return 1; }
    printf '%s' "$body" | jq -r --arg bucket "$bucket" --arg idx "$index" '
        (.indexes // [])
        | map(select((.bucket // "") == $bucket and ((.index // .indexName // "") == $idx or (.index // .indexName // "") == "#primary")))
        | if length == 0 then "MISSING" else (.[0].status // "UNKNOWN") end
    ' 2>/dev/null || printf 'PARSE_ERROR'
}

# couchbase::wait_index_ready <bucket> - the query service answers nothing useful until the
# primary index of a bucket is Ready; this is the legacy wait_for_primary_index_ready_or_die.
couchbase::wait_index_ready() {
    local bucket="${1:?bucket required}"
    local attempt attempts=1
    if ((INDEX_READY_TIMEOUT_SEC > 0)); then
        attempts=$(( (INDEX_READY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    fi
    ((attempts > 0)) || attempts=1

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        state=$(couchbase::index_state "$bucket")
        [[ "$state" == Ready ]] && return 0
        if ((attempt == 1 || attempt % 5 == 0)); then
            log "WARNING waiting for the primary index of bucket '$bucket' (state=$state, attempt $attempt/$attempts)" >&2
        fi
        sleep "$INDEX_READY_POLL_INTERVAL_SEC"
    done

    log "ERROR primary index of bucket '$bucket' did not become Ready within ${INDEX_READY_TIMEOUT_SEC}s" >&2
    return 1
}

couchbase::ensure_index() {
    local bucket="${1:?bucket required}" index
    index=$(couchbase::index_name "$bucket")
    couchbase::query_or_die \
        "CREATE PRIMARY INDEX IF NOT EXISTS \`$index\` ON \`$bucket\`;" \
        "create primary index on $bucket" >/dev/null || return 1
    couchbase::wait_index_ready "$bucket"
}

# --- buckets -------------------------------------------------------------------

# couchbase::bucket_exists <bucket> -> 0 when the bucket answers with 200.
couchbase::bucket_exists() {
    local bucket="${1:?bucket required}"
    couchbase::rest GET "/pools/default/buckets/$bucket" >/dev/null || return 1
    [[ "$COUCHBASE_HTTP_STATUS" == 200 ]]
}

# couchbase::bucket_stats <bucket> [field,field,...] -> "field=value ..." from basicStats.
couchbase::bucket_stats() {
    local bucket="${1:?bucket required}" fields="${2:-itemCount,diskUsed,dataUsed,memUsed}"
    local body field value
    body=$(couchbase::rest GET "/pools/default/buckets/$bucket" 2>/dev/null) || return 1
    [[ "$COUCHBASE_HTTP_STATUS" == 200 ]] || return 1
    for field in ${fields//,/ }; do
        value=$(printf '%s' "$body" | jq -r --arg f "$field" '.basicStats[$f] // empty' 2>/dev/null)
        printf '%s=%s ' "$field" "${value:-0}"
    done
}

# Create a missing bucket, and the local user named after it that SDK 2.x authenticates as.
# Both need cluster-management rights; where the benchmark role does not have them, the buckets
# are provisioned beforehand and COUCHBASE_CREATE_MISSING_BUCKETS=0 says so.
couchbase::ensure_bucket() {
    local bucket="${1:?bucket required}"

    if couchbase::bucket_exists "$bucket"; then
        return 0
    fi
    if [[ "$COUCHBASE_CREATE_MISSING_BUCKETS" != 1 ]]; then
        log "ERROR bucket '$bucket' does not exist and COUCHBASE_CREATE_MISSING_BUCKETS=0." >&2
        log "ERROR create it (flush enabled) plus a local user named '$bucket' before running." >&2
        return 1
    fi
    if [[ -z "$DB_PWD" ]]; then
        log "ERROR bucket '$bucket' does not exist and no bucket password is configured, so neither the bucket nor its SDK 2.x user can be created." >&2
        return 1
    fi

    echo "[INFO] Creating Couchbase bucket $bucket (ramQuotaMB=$COUCHBASE_BUCKET_RAM_QUOTA_MB) and its SDK 2.x user."
    couchbase::rest POST /pools/default/buckets \
        -d "name=$bucket" -d bucketType=membase -d storageBackend=couchstore \
        -d "ramQuotaMB=$COUCHBASE_BUCKET_RAM_QUOTA_MB" -d flushEnabled=1 >/dev/null
    if [[ "$COUCHBASE_HTTP_STATUS" != 202 && "$COUCHBASE_HTTP_STATUS" != 200 ]]; then
        log "ERROR could not create bucket '$bucket' (HTTP ${COUCHBASE_HTTP_STATUS:-none}): $COUCHBASE_LAST_BODY" >&2
        return 1
    fi

    local attempt attempts=30
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        couchbase::bucket_exists "$bucket" && break
        sleep 2
    done
    if ! couchbase::bucket_exists "$bucket"; then
        log "ERROR bucket '$bucket' was accepted but never became reachable." >&2
        return 1
    fi

    # SDK 2.x has no username concept: openBucket(bucket, password) sends the bucket name as the
    # username, so a local user of that exact name is what makes the binding authenticate.
    couchbase::ensure_user "$bucket" || return 1

    # A freshly created bucket needs a moment before it accepts mutations.
    local attempt2
    for ((attempt2 = 1; attempt2 <= 30; attempt2++)); do
        couchbase::write_probe "$bucket" && return 0
        sleep 2
    done
    log "ERROR bucket '$bucket' was created but never accepted a write." >&2
    return 1
}

# Create or refresh the local RBAC user named after a bucket. PUT is idempotent, and where a
# bucket was provisioned without its user (or with another password) this is what makes the
# binding's credential work again - possible only while the runner holds cluster-management
# rights, i.e. exactly when creating buckets is allowed too.
couchbase::ensure_user() {
    local bucket="${1:?bucket required}"
    [[ "$bucket" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
        log "ERROR refusing to create a user with the unsafe name '$bucket'." >&2
        return 1
    }
    couchbase::rest PUT "/settings/rbac/users/local/$bucket" \
        -d "name=$bucket" -d "password=$DB_PWD" \
        --data-urlencode "roles=bucket_full_access[$bucket]" >/dev/null
    if [[ "$COUCHBASE_HTTP_STATUS" != 200 && "$COUCHBASE_HTTP_STATUS" != 201 ]]; then
        log "ERROR could not create the SDK 2.x user '$bucket' (HTTP ${COUCHBASE_HTTP_STATUS:-none}): $COUCHBASE_LAST_BODY" >&2
        return 1
    fi
}

# Write and delete one document as the bucket's own user: proof that the credential the binding
# will use works, without leaving anything behind.
couchbase::write_probe() {
    local bucket="${1:?bucket required}" response
    # The VALUES form is what N1QL accepts here; `INSERT INTO ks (KEY "k", VALUE v)` is only
    # valid as the SELECT variant (used by backend::dump_restore). UPSERT, so that a probe left
    # behind by an interrupted run can never turn into a duplicate-key failure.
    response=$(couchbase::query_as "$bucket" "$DB_PWD" \
        "UPSERT INTO \`$bucket\` (KEY, VALUE) VALUES (\"_ycsb_probe\", {\"probe\": 1});") || return 1
    [[ "$(couchbase::query_status "$response")" == success ]] || return 1
    response=$(couchbase::query_as "$bucket" "$DB_PWD" \
        "DELETE FROM \`$bucket\` USE KEYS [\"_ycsb_probe\"];") || return 1
    [[ "$(couchbase::query_status "$response")" == success ]]
}

# Empty a bucket: flush where permitted (that is what the legacy runners did), otherwise delete
# through N1QL. Both are asynchronous, so "empty" is only true once couchbase::wait_empty says so.
couchbase::clear_bucket() {
    local bucket="${1:?bucket required}"
    couchbase::rest POST "/pools/default/buckets/$bucket/controller/doFlush" >/dev/null
    if [[ "$COUCHBASE_HTTP_STATUS" == 200 || "$COUCHBASE_HTTP_STATUS" == 202 ]]; then
        echo "[INFO] Bucket '$bucket' flush requested (HTTP $COUCHBASE_HTTP_STATUS)."
    else
        log "WARNING flush of bucket '$bucket' refused (HTTP ${COUCHBASE_HTTP_STATUS:-none}); deleting through N1QL instead." >&2
        couchbase::query_or_die "DELETE FROM \`$bucket\`;" "clear bucket $bucket" >/dev/null || return 1
    fi
    couchbase::wait_empty "$bucket"
}

# Couchbase applies a flush asynchronously and index reads lag behind it, so a bucket is only
# really empty when the query service says so.
couchbase::wait_empty() {
    local bucket="${1:?bucket required}"
    local attempt attempts=1 count
    if ((CONSISTENCY_TIMEOUT_SEC > 0)); then
        attempts=$(( (CONSISTENCY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    fi
    ((attempts > 0)) || attempts=1

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        count=$(couchbase::count "$bucket") || return 1
        [[ "$count" == 0 ]] && return 0
        if ((attempt == 1 || attempt % 5 == 0)); then
            log "WARNING waiting for bucket '$bucket' to empty (documents=$count, attempt $attempt/$attempts)" >&2
        fi
        sleep "$INDEX_READY_POLL_INTERVAL_SEC"
    done

    log "ERROR bucket '$bucket' still held documents after ${CONSISTENCY_TIMEOUT_SEC}s." >&2
    return 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

backend::preflight() {
    local needs_dump="$1"
    shift
    local tool version db account seen='|'

    for tool in java curl jq awk sed grep perl sort bc ps tee date mktemp; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "[ERROR] Required executable missing: $tool" >&2
            return 1
        }
    done
    if [[ ! -x "$YCSB" || ! -r "$WORKLOAD_FILE" || ! -r "$JDBC_PROPERTIES" ]]; then
        echo "[ERROR] YCSB launcher/config is missing, or the workload template is not readable: $WORKLOAD_FILE" >&2
        return 1
    fi
    local -a jar_patterns=()
    mapfile -t jar_patterns < <(backend::required_artifacts)
    for pattern in "${jar_patterns[@]}"; do
        if ! compgen -G "$pattern" >/dev/null; then
            echo "[ERROR] Missing build artifact: $pattern" >&2
            echo "Build from YCSB_HOME: mvn -Psource-run -pl site.ycsb:${YCSB_BINDING}-binding -am package -DskipTests" >&2
            return 1
        fi
    done

    account="${HOST_OS_USER:-}"
    if [[ -n "$account" ]] && ! ps -u "$account" -o pid= >/dev/null; then
        echo "[ERROR] Cannot sample the $account OS account required by these runners (set HOST_OS_USER= when the server is not a local process)." >&2
        return 1
    fi

    # /pools answers without credentials and names the server version; it is the cheapest proof
    # that the management port is Couchbase at all.
    if ! version=$(couchbase::rest GET /pools 2>/dev/null | jq -r '.implementationVersion // empty' 2>/dev/null) ||
        [[ -z "$version" ]]; then
        echo "[ERROR] No Couchbase management answer on $COUCHBASE_HOST:$COUCHBASE_PORT_MGMT." >&2
        return 1
    fi
    local min="${MIN_SERVER_VERSION:-$(registry::info min_server_version)}"
    if [[ "$(printf '%s\n%s\n' "$min" "${version%%-*}" | sort -V | head -1)" != "$min" ]]; then
        echo "[ERROR] These runners require Couchbase >= $min; got $version." >&2
        return 1
    fi

    # The management role: bucket listing, flush and the index status endpoint all need it.
    couchbase::rest GET /pools/default >/dev/null || {
        echo "[ERROR] Couchbase management API unreachable on $COUCHBASE_HOST:$COUCHBASE_PORT_MGMT." >&2
        return 1
    }
    if [[ "$COUCHBASE_HTTP_STATUS" != 200 ]]; then
        echo "[ERROR] Management user '$COUCHBASE_USERNAME' cannot read the cluster (HTTP $COUCHBASE_HTTP_STATUS); it needs cluster read plus flush and query rights on the benchmark buckets." >&2
        return 1
    fi

    for db in "$@"; do
        if [[ ! "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || ${#db} -gt 100 || "$seen" == *"|$db|"* ]]; then
            echo "[ERROR] Unsafe or duplicate bucket name: $db" >&2
            return 1
        fi
        seen="$seen$db|"

        if ! couchbase::bucket_exists "$db"; then
            if [[ "$COUCHBASE_CREATE_MISSING_BUCKETS" == 1 ]]; then
                log "Bucket '$db' does not exist yet; init_db will create it together with its SDK 2.x user."
                continue
            fi
            echo "[ERROR] Bucket '$db' is not reachable/authenticated (HTTP ${COUCHBASE_HTTP_STATUS:-none})." >&2
            return 1
        fi
        local writable=0
        if couchbase::write_probe "$db"; then
            writable=1
        elif [[ "$COUCHBASE_CREATE_MISSING_BUCKETS" == 1 ]]; then
            # The bucket exists but its SDK 2.x user does not, or has another password. Where the
            # runner may provision buckets it repairs that here instead of failing.
            couchbase::ensure_user "$db" >/dev/null 2>&1 || true
            couchbase::write_probe "$db" && writable=1
        fi
        if (( writable != 1 )); then
            echo "[ERROR] The benchmark role cannot write to bucket '$db' with the configured bucket password; every phase writes into its own bucket." >&2
            return 1
        fi
    done

    # KV vs N1QL mode, exactly as the legacy runner resolved it - but this backend needs the
    # query service either way (bucket copy, key listings, size extraction, cleanup).
    local kv_open=0 query_open=0
    if timeout 2 bash -c "</dev/tcp/$COUCHBASE_HOST/$COUCHBASE_PORT_KV" >/dev/null 2>&1; then kv_open=1; fi
    if timeout 2 bash -c "</dev/tcp/$COUCHBASE_HOST/$COUCHBASE_PORT_QUERY" >/dev/null 2>&1; then query_open=1; fi
    if [[ "$query_open" != 1 ]]; then
        echo "[ERROR] Query service on $COUCHBASE_HOST:$COUCHBASE_PORT_QUERY is unreachable, but this backend needs N1QL." >&2
        return 1
    fi
    case "$COUCHBASE_KV_MODE" in
        true)  COUCHBASE_KV_ENABLED=true ;;
        false) COUCHBASE_KV_ENABLED=false ;;
        auto)  [[ "$kv_open" == 1 ]] && COUCHBASE_KV_ENABLED=true || COUCHBASE_KV_ENABLED=false ;;
        *)
            echo "[ERROR] Invalid COUCHBASE_KV_MODE='$COUCHBASE_KV_MODE'. Expected true, false, or auto." >&2
            return 1
            ;;
    esac
    log "Couchbase access mode: couchbase.kv=$COUCHBASE_KV_ENABLED (mode=$COUCHBASE_KV_MODE, kv$COUCHBASE_PORT_KV=$kv_open, query$COUCHBASE_PORT_QUERY=$query_open)"

    if [[ "$needs_dump" == true && "$COUCHBASE_CREATE_MISSING_BUCKETS" != 1 ]]; then
        # The comparison bucket is prepared by backend::dump_restore, not by init_db, so where the
        # runner may not create buckets somebody else has to have created all three.
        couchbase::bucket_exists "$BACKUP_DB_NAME" || {
            echo "[ERROR] Comparison bucket '$BACKUP_DB_NAME' does not exist." >&2
            return 1
        }
    fi

    backend::collect_metrics "$DB_NAME" global >/dev/null || return 1
    echo "[INFO] Couchbase preflight passed on $COUCHBASE_HOST:$COUCHBASE_PORT_MGMT (server=$version)."
}

backend::required_artifacts() {
    printf '%s\n' \
        "$YCSB_HOME/core/target/*.jar" \
        "$YCSB_HOME/core/target/dependency/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/*.jar"
}

# ---------------------------------------------------------------------------
# Databases (buckets)
# ---------------------------------------------------------------------------

backend::init_db() {
    local bucket_name="${1:?bucket required}"
    [[ "$bucket_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
        echo "[ERROR] Unsafe bucket name: $bucket_name" >&2
        return 1
    }
    log "Initializing Couchbase bucket $bucket_name..."
    couchbase::ensure_bucket "$bucket_name" || return 1
    couchbase::clear_bucket "$bucket_name" || return 1
    couchbase::ensure_index "$bucket_name" || return 1
    log "Done initializing $bucket_name."
}

# The comparison bucket is a copy of the measured one, not a snapshot: legacy used
# INSERT INTO target (KEY k, VALUE v) SELECT META(s).id, s FROM source s. What it never checked
# is whether anything arrived - an INSERT ... SELECT whose SELECT matches nothing is a success in
# N1QL, and index reads lag behind writes, so the counts are polled until they agree.
backend::dump_restore() {
    local source_rows restored_rows attempt attempts=1

    : > "$RESTORE_LOG"
    # shellcheck disable=SC2034  # documented below, the count loop uses the timeout
    couchbase::ensure_bucket "$BACKUP_DB_NAME" || {
        echo "[ERROR] Comparison bucket '$BACKUP_DB_NAME' is not available; see $RESTORE_LOG." >&2
        return 1
    }
    couchbase::ensure_index "$BACKUP_DB_NAME" || return 1

    source_rows=$(couchbase::count "$DB_NAME") || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || {
        echo "[ERROR] Could not count documents in $DB_NAME (got '$source_rows')." >&2
        return 1
    }

    couchbase::clear_bucket "$BACKUP_DB_NAME" || return 1
    if ! couchbase::query_or_die \
        "INSERT INTO \`$BACKUP_DB_NAME\` (KEY k, VALUE v) SELECT META(s).id AS k, s AS v FROM \`$DB_NAME\` AS s;" \
        "copy $DB_NAME to $BACKUP_DB_NAME" >/dev/null; then
        echo "[ERROR] Copy failed; see $RESTORE_LOG." >&2
        return 1
    fi

    if ((CONSISTENCY_TIMEOUT_SEC > 0)); then
        attempts=$(( (CONSISTENCY_TIMEOUT_SEC + INDEX_READY_POLL_INTERVAL_SEC - 1) / INDEX_READY_POLL_INTERVAL_SEC ))
    fi
    ((attempts > 0)) || attempts=1
    restored_rows=-1
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        restored_rows=$(couchbase::count "$BACKUP_DB_NAME") || return 1
        [[ "$restored_rows" == "$source_rows" ]] && break
        if ((attempt == 1 || attempt % 5 == 0)); then
            log "WARNING waiting for bucket '$BACKUP_DB_NAME' to hold $source_rows documents (currently $restored_rows, attempt $attempt/$attempts)" >&2
        fi
        sleep "$INDEX_READY_POLL_INTERVAL_SEC"
    done

    if [[ "$restored_rows" != "$source_rows" ]]; then
        echo "[ERROR] Copy document count mismatch: source=$source_rows target=$restored_rows." >&2
        echo "[ERROR] The query service never agreed on the two counts within ${CONSISTENCY_TIMEOUT_SEC}s." >> "$RESTORE_LOG"
        return 1
    fi
    printf 'Copied %s documents from %s to %s\n' "$restored_rows" "$DB_NAME" "$BACKUP_DB_NAME" >> "$RESTORE_LOG"
    echo "[INFO] Copy verified: $restored_rows documents." >> "$RESTORE_LOG"
}

backend::close() {
    log "Couchbase backend: no manual bucket close required."
}

# ---------------------------------------------------------------------------
# Size helpers (the legacy definitions, kept so results stay comparable)
# ---------------------------------------------------------------------------

# The value of a YCSB record is field0..field9 of the document; sizes are their total string
# length in bytes. Documents always carry all ten fields after the load phase, but
# IFMISSINGORNULL keeps a partially written document from turning the sum into null.
backend::size_expression() {
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

# The same expression on one line, ready to embed in a SELECT.
couchbase::size_expression_inline() {
    backend::size_expression | tr '\n' ' '
}

# Document count as the query service currently sees it. Couchbase's secondary indexes are
# asynchronous, so this is only stable once nothing writes any more - which is why both the flush
# and the copy wait for a value instead of reading once.
couchbase::count() {
    local bucket="${1:?bucket required}"
    couchbase::query_values "SELECT RAW COUNT(1) FROM \`$bucket\`;" "count documents in $bucket" | tail -n1
}

backend::total_size() {
    local bucket="${1:?bucket required}" expr total
    expr=$(couchbase::size_expression_inline)
    total=$(couchbase::query_values "SELECT RAW SUM(($expr)) FROM \`$bucket\`;" "compute total size from $bucket" | tail -n1) || return 1
    printf '%s\n' "${total:-0}"
}

backend::key_sizes() {
    local bucket="${1:?bucket required}" out="${2:?output file required}" expr response
    expr=$(couchbase::size_expression_inline)
    echo "ycsb_key,size" > "$out"
    response=$(couchbase::query_or_die \
        "SELECT RAW [META().id, ($expr)] FROM \`$bucket\`;" "dump key sizes from $bucket") || return 1
    if ! printf '%s' "$response" | jq -r '.results[] | "\(.[0]),\(.[1] // 0)"' >> "$out" 2>/dev/null; then
        log "ERROR could not parse the N1QL response while dumping key sizes from $bucket" >&2
        return 1
    fi
}

backend::list_keys() {
    local bucket="${1:?bucket required}" out="${2:?output file required}"
    couchbase::query_values "SELECT RAW META().id FROM \`$bucket\`;" "fetch keys from $bucket" > "$out"
}

backend::sample_key() {
    local bucket="${1:?bucket required}"
    couchbase::query_values "SELECT RAW META().id FROM \`$bucket\` LIMIT 1;" "fetch test key from $bucket" | tail -n1
}

# The plan of one document lookup by key, as JSON - the legacy log_query_plan output.
backend::explain_sql() {
    local bucket="${1:?bucket required}" key="${2:?key required}" escaped response
    escaped=${key//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    response=$(couchbase::query_or_die \
        "EXPLAIN SELECT * FROM \`$bucket\` USE KEYS [\"$escaped\"];" "collect query plan for $bucket") || return 1
    printf '%s\n' "$response" | jq .
}

# Delete the documents a phase inserted. Batched (the legacy runner sent one statement per run
# phase, which grows with the number of new keys and eventually exceeds what N1QL accepts).
# couchbase::delete_keys_file <bucket> <file> - delete every key in a file, one statement.
couchbase::delete_keys_file() {
    local bucket="${1:?bucket required}" file="${2:?key file required}" json
    json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$file")
    [[ "$json" == "[]" ]] && return 0
    couchbase::query_or_die "DELETE FROM \`$bucket\` USE KEYS $json;" \
        "delete extra keys from $bucket" >/dev/null
}

backend::delete_keys() {
    local bucket="${1:?bucket required}" file="${2:?key file required}" part number=0 chunk
    [[ -s "$file" ]] || return 0

    chunk=$(mktemp "${TMPDIR:-/tmp}/ycsb-couchbase-keys.XXXXXX")
    split -l "$COUCHBASE_DELETE_BATCH_SIZE" "$file" "$chunk."
    for part in "$chunk".*; do
        [[ -s "$part" ]] || continue
        number=$((number + 1))
        couchbase::delete_keys_file "$bucket" "$part" || { rm -f "$chunk" "$chunk".*; return 1; }
    done
    rm -f "$chunk" "$chunk".*
    return 0
}

backend::truncate() {
    local bucket="${1:?bucket required}"
    couchbase::ensure_index "$bucket" || return 1
    couchbase::query_or_die "DELETE FROM \`$bucket\`;" "delete all documents from $bucket" >/dev/null || return 1
    couchbase::wait_empty "$bucket"
}

# The query service is the only thing that has to be quiet between phases; Couchbase has no
# transaction table to poll, and index readiness is exactly what a measurement depends on.
backend::wait_idle() {
    # The engine's poll interval and maximum wait are not used: index readiness has its own
    # configured timeouts (INDEX_READY_TIMEOUT_SEC / INDEX_READY_POLL_INTERVAL_SEC), and a bucket
    # whose index is Ready is the only thing a measurement here depends on.
    local bucket="${1:-$DB_NAME}"
    couchbase::wait_index_ready "$bucket"
}

# ---------------------------------------------------------------------------
# Backend contract: metadata and defaults
# ---------------------------------------------------------------------------

backend::info() {
    cat <<INFO
display_name=Couchbase (document store, SDK 2.x)
default_type=couchbase
default_workload=workloada-extend
default_binding=couchbase2
default_db=ycsb
min_server_version=6.5
has_dump_restore=1
supports_idle_wait=1
requires_index_wait=1
supports_vacuum=0
supports_query_plan=1
host_os_user=couchbase
runtime_watcher_dialect=
INFO
}

# Properties the couchbase2 binding needs beyond the connection itself; appended to every YCSB
# invocation by binding_db_params. The bucket and its password come from binding_db_params too,
# so nothing here may name them.
backend::extra_binding_params() {
    printf '%s\n' \
        "couchbase.host=$COUCHBASE_HOST" \
        "couchbase.adhoc=$COUCHBASE_ADHOC" \
        "couchbase.kv=$COUCHBASE_KV_ENABLED" \
        "couchbase.boost=$COUCHBASE_BOOST" \
        "core_workload_insertion_retry_limit=$INSERTION_RETRY_LIMIT" \
        "core_workload_insertion_retry_interval=$INSERTION_RETRY_INTERVAL"
}

backend::default_config() {
    DB_NAME="${DB_NAME:-ycsb}"
    BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
    UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
    TARGET_TABLE="${TARGET_TABLE:-usertable}"

    COUCHBASE_HOST="${COUCHBASE_HOST:-127.0.0.1}"
    COUCHBASE_PORT_MGMT="${COUCHBASE_PORT_MGMT:-8091}"
    COUCHBASE_PORT_QUERY="${COUCHBASE_PORT_QUERY:-8093}"
    COUCHBASE_PORT_KV="${COUCHBASE_PORT_KV:-11210}"
    DB_HOST="$COUCHBASE_HOST"
    DB_PORT="${DB_PORT:-$COUCHBASE_PORT_MGMT}"

    # Two credentials, because SDK 2.x authenticates as the bucket:
    #   COUCHBASE_USERNAME/PASSWORD - management user for REST and N1QL (bucket listing, flush,
    #     indexes, copy between buckets);
    #   DB_PWD                     - password of the local users named after the buckets, which
    #     is what the binding authenticates with.
    COUCHBASE_USERNAME="${COUCHBASE_USERNAME:-Administrator}"
    COUCHBASE_PASSWORD="${COUCHBASE_PASSWORD:-${DB_PWD:-}}"
    DB_USERNAME="${DB_USERNAME:-$COUCHBASE_USERNAME}"

    # Binding behaviour knobs, with the values the legacy runners used.
    COUCHBASE_ADHOC="${COUCHBASE_ADHOC:-true}"
    COUCHBASE_KV_MODE="${COUCHBASE_KV_MODE:-false}"
    COUCHBASE_BOOST="${COUCHBASE_BOOST:-1}"
    INSERTION_RETRY_LIMIT="${INSERTION_RETRY_LIMIT:-20}"
    INSERTION_RETRY_INTERVAL="${INSERTION_RETRY_INTERVAL:-2}"
    # Set by backend::preflight from COUCHBASE_KV_MODE and the reachable ports.
    COUCHBASE_KV_ENABLED="${COUCHBASE_KV_ENABLED:-false}"

    # Index readiness and index-lag waits.
    INDEX_READY_TIMEOUT_SEC="${INDEX_READY_TIMEOUT_SEC:-180}"
    INDEX_READY_POLL_INTERVAL_SEC="${INDEX_READY_POLL_INTERVAL_SEC:-2}"
    CONSISTENCY_TIMEOUT_SEC="${CONSISTENCY_TIMEOUT_SEC:-120}"
    COUCHBASE_DELETE_BATCH_SIZE="${COUCHBASE_DELETE_BATCH_SIZE:-500}"

    # Bucket provisioning: 0 means the three buckets (and their users) exist already.
    COUCHBASE_CREATE_MISSING_BUCKETS="${COUCHBASE_CREATE_MISSING_BUCKETS:-1}"
    COUCHBASE_BUCKET_RAM_QUOTA_MB="${COUCHBASE_BUCKET_RAM_QUOTA_MB:-256}"

    # The couchbase2 binding reads no url/user/password properties at all: the resource a phase
    # targets is named by `couchbase.bucket`, so a role's "url" is exactly its bucket name - and
    # there is no username property, because SDK 2.x sends the bucket name itself.
    DB_URL="$DB_NAME"
    BACKUP_URL="$BACKUP_DB_NAME"
    UNCHANGED_DB_URL="$UNCHANGED_DB_NAME"
    BINDING_PARAM_URL="${BINDING_PARAM_URL:-couchbase.bucket}"
    BINDING_PARAM_USER=""
    BINDING_PARAM_PASSWD="${BINDING_PARAM_PASSWD:-couchbase.password}"

    # The binding ships without a conf directory; the harness passes one properties file to every
    # YCSB invocation, so a documented empty default ships next to it.
    JDBC_PROPERTIES="${JDBC_PROPERTIES:-$YCSB_HOME/couchbase2/conf/couchbase.properties}"

    # CPU/memory are sampled from the server's OS account when it runs on this host. Set
    # HOST_OS_USER= (empty) for a container or remote server: there is no local process to
    # sample, and reporting 0 is honest where sampling another account would not be.
    HOST_OS_USER="${HOST_OS_USER-$(registry::info host_os_user)}"

    # The copy lives inside the cluster; BACKUP_FILE only has to be a name the engine can remove
    # after the clean-run phase.
    BACKUP_FILE="${BACKUP_FILE:-./ycsb_couchbase_copy.json}"
}
