#!/usr/bin/env bash
# Neo4j backend — property graph, driven by the neo4j binding (com.yahoo.yscb.db.neo4j.Neo4jClient).
#
# Sourced by lib/registry.sh, never run directly.
#
# What makes this backend different from the others in this harness: Neo4j Community has one
# user database per instance, so the study's three roles (main, reference, comparison) are three
# **Neo4j instances** on three Bolt ports — not three databases on one server. The legacy runner
# managed them as /opt/neo4j-instance-{main,backup,unchange}; here a role is an endpoint, and
# `NEO4J_PORT_*` (or `NEO4J_BOLT_URI_*`) is what points the three roles at three servers. A
# single-instance deployment (Neo4j Enterprise with three databases) is not what these runners
# measured, so nothing here pretends to support it.
#
# Differences from the legacy experiment_neo4j.sh, all deliberate:
#   * an instance is reset by deleting its nodes (`MATCH (n) DETACH DELETE n`, batched through
#     apoc.periodic.iterate), not by stopping the server and wiping its data directory. The
#     benchmark role cannot restart a service, and a run must not need sudo;
#   * the APOC graphml export/import still moves main -> comparison, but into a path relative to
#     each instance's import directory, which therefore has to be shared (or copied — see
#     NEO4J_BACKUP_COPY_CMD in conf/db.neo4j.env.example);
#   * cypher-shell's plain output quotes strings, so keys and sizes are produced as one joined
#     column and unquoted here. The legacy runners kept the quotes, which is why their
#     "delete the keys inserted during the run" step deleted nothing at all;
#   * `host_os_user=neo4j` samples the server's OS account when it runs on this host, like the
#     legacy lsof/ps lookup did per instance.
#
# The 19 statistics columns are the legacy list in the legacy order, and most of them are still
# always 0: they were never populated because Neo4j exposes no equivalent of `SHOW TRANSACTIONS`
# history for those counters. Keeping the columns keeps the results CSV comparable with the
# earlier EC2 runs; see backend::collect_metrics for what is really measured.

NEO4J_CLI="${NEO4J_CLI:-cypher-shell}"

# ---------------------------------------------------------------------------
# Statistics columns (the results CSV schema for this backend)
# ---------------------------------------------------------------------------

metric_field_names=(
    transaction_commits
    transaction_rollbacks
    nodes_created
    nodes_deleted
    relationships_created
    relationships_deleted
    properties_set
    index_hits
    index_misses
    lock_acquisition_time
    lock_wait_time
    checkpoint_total_time
    checkpoint_total_events
    log_rotation_events
    log_rotation_total_time
    transaction_started
    transaction_peak_concurrent
    transaction_active
    transaction_terminated
)

backend::metric_names() {
    printf '%s\n' "${metric_field_names[@]}"
}

# ---------------------------------------------------------------------------
# Instances: one per experiment role
# ---------------------------------------------------------------------------

# neo4j::role <database-role-name> -> main | backup | unchange. The engine only ever names the
# three roles it knows, and each of them is a different instance here.
neo4j::role() {
    case "${1:-}" in
        "$DB_NAME")          printf 'main\n' ;;
        "$BACKUP_DB_NAME")   printf 'backup\n' ;;
        "$UNCHANGED_DB_NAME") printf 'unchange\n' ;;
        *) return 1 ;;
    esac
}

# neo4j::bolt_uri <role-name> -> bolt://host:port used by the admin CLI.
neo4j::bolt_uri() {
    local role var
    role="$(neo4j::role "${1:?which Neo4j instance}")" || return 1
    case "$role" in
        backup)   var="${NEO4J_BOLT_URI_BACKUP:-bolt://$DB_HOST:$NEO4J_PORT_BACKUP}" ;;
        unchange) var="${NEO4J_BOLT_URI_UNCHANGE:-bolt://$DB_HOST:$NEO4J_PORT_UNCHANGE}" ;;
        *)        var="${NEO4J_BOLT_URI_MAIN:-bolt://$DB_HOST:$NEO4J_PORT_MAIN}" ;;
    esac
    printf '%s\n' "$var"
}

# A wrapped CLI (the usual case on this machine: cypher-shell only exists inside the container)
# reaches its own instance on the container's internal address, so the wrap selects the instance
# and NEO4J_CLI_BOLT_URI selects the address inside it. Per-role overrides exist because the
# three containers are usually three different names.
neo4j::cli_prefix() {
    local role wrap
    role="$(neo4j::role "${1:?which Neo4j instance}")" || return 1
    case "$role" in
        backup)   wrap="${NEO4J_CLI_WRAP_BACKUP:-${NEO4J_CLI_WRAP:-}}" ;;
        unchange) wrap="${NEO4J_CLI_WRAP_UNCHANGE:-${NEO4J_CLI_WRAP:-}}" ;;
        *)        wrap="${NEO4J_CLI_WRAP_MAIN:-${NEO4J_CLI_WRAP:-}}" ;;
    esac
    if [[ -n "$wrap" ]]; then
        read -r -a NEO4J_CLI_PREFIX <<< "$wrap"
    else
        NEO4J_CLI_PREFIX=()
    fi
}

# neo4j_cypher <role-name> <action> <cypher> [format] -> rows on stdout, plain by default.
# Neither the arguments nor the query are logged: the URI can carry credentials and the query
# can carry values. Failures are logged with the server's own message, because that is the only
# place a phase log shows why a size query came back empty.
neo4j_cypher() {
    local role="${1:?which Neo4j instance}" action="${2:?what is being done}" \
        query="${3:?Cypher required}" format="${4:-plain}"
    local started=$SECONDS rc=0 out="" uri
    neo4j::cli_prefix "$role" || return 1
    uri="$(neo4j::bolt_uri "$role")"
    [[ -z "${NEO4J_CLI_PREFIX[*]}" ]] || uri="${NEO4J_CLI_BOLT_URI:-bolt://localhost:7687}"

    log "START Neo4j operation instance=$role action=$action"
    out=$("${NEO4J_CLI_PREFIX[@]}" "$NEO4J_CLI" \
        --address "$uri" --username "$DB_USERNAME" --password "$DB_PWD" \
        --format "$format" --non-interactive "$query" 2>&1) || rc=$?
    if (( rc != 0 )); then
        log "ERROR Neo4j operation instance=$role action=$action status=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    fi
    log "END Neo4j operation instance=$role action=$action status=$rc duration=$((SECONDS-started))s"
    [[ -z "$out" ]] || printf '%s\n' "$out"
    return "$rc"
}

backend::cli() {
    local role="${1:?which Neo4j instance}"
    shift
    neo4j_cypher "$role" snapshot "$@"
}

# Output helpers. cypher-shell's plain format is a header line plus `"value"` rows, so the
# scalar helper drops both decorations and the row helper keeps the (already comma-joined)
# columns of a single returned string.
neo4j::scalar() { tail -n +2 | head -1 | tr -d ' "'; }
neo4j::rows() { tail -n +2 | sed -e 's/^"//' -e 's/"$//'; }

# ---------------------------------------------------------------------------
# Statistics snapshot
# ---------------------------------------------------------------------------

# One snapshot of the instance a phase ran against. Every column gets a value; 0 means "this
# Neo4j does not report it", exactly like the legacy script, which defaulted all nineteen and
# then overwrote the four queries that exist: active transactions, graph counts (nodes,
# relationships, properties), index read counts, and commit/rollback counts of the currently
# visible transactions.
backend::collect_metrics() {
    local db="${1:-$DB_NAME}" scope="${2:-all}"
    local name raw first second third reads tx
    local -a errs=()

    log "START statistics snapshot database=$db scope=$scope"
    for name in "${metric_field_names[@]}"; do
        printf -v "$name" '%s' 0
    done

    tx=$(neo4j::scalar < <(neo4j_cypher "$db" metrics \
        'SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;'))
    if [[ "$tx" =~ ^[0-9]+$ ]]; then
        transaction_active="$tx"
    else
        errs+=("SHOW TRANSACTIONS failed")
    fi

    raw=$(neo4j::scalar < <(neo4j_cypher "$db" metrics \
        "CALL db.stats.retrieve('GRAPH COUNTS')
         YIELD section, data
         UNWIND data AS row
         RETURN
           reduce(total = 0, x IN row.nodes | total + x.count) AS nodes,
           reduce(total = 0, x IN row.relationships | total + x.count) AS relationships,
           reduce(total = 0, x IN row.properties | total + x.count) AS properties;"))
    IFS=',' read -r first second third <<< "$raw"
    if [[ "$first" =~ ^[0-9]+$ ]]; then
        nodes_created="$first"
        relationships_created="${second:-0}"
        properties_set="${third:-0}"
        [[ "$properties_set" == NULL ]] && properties_set=0
    else
        errs+=("graph counts unavailable")
    fi

    reads=$(neo4j::scalar < <(neo4j_cypher "$db" metrics \
        'SHOW INDEXES YIELD readCount, trackedSince RETURN sum(readCount) AS reads;'))
    if [[ "$reads" =~ ^[0-9]+$ ]]; then
        index_hits="$reads"
    else
        errs+=("index stats unavailable")
    fi

    raw=$(neo4j::scalar < <(neo4j_cypher "$db" metrics \
        "SHOW TRANSACTIONS YIELD status
         RETURN
           sum(CASE WHEN status = 'Committed' THEN 1 ELSE 0 END) AS commits,
           sum(CASE WHEN status = 'RolledBack' THEN 1 ELSE 0 END) AS rollbacks;"))
    IFS=',' read -r first second <<< "$raw"
    if [[ "$first" =~ ^[0-9]+$ ]]; then
        transaction_commits="$first"
        transaction_rollbacks="${second:-0}"
    else
        errs+=("transaction commit/rollback stats unavailable")
    fi

    local dbmetrics=""
    for name in "${metric_field_names[@]}"; do
        dbmetrics+="$name=${!name} "
    done
    log "DB statistics $dbmetrics"
    for name in "${errs[@]}"; do
        log "[METRIC-ERR] $name on $(neo4j::bolt_uri "$db")"
    done

    # The stored-value size needs the benchmark graph, so it is only available once a load ran;
    # preflight probes the instance with scope=global.
    if [[ "$scope" != global ]]; then
        local total
        total=$(backend::total_size "$db") || return 1
        log "DB statistics value size: $total database=$db"
    fi
    log "END statistics snapshot database=$db statistics=${#metric_field_names[@]}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

backend::preflight() {
    local needs_dump="$1"
    shift
    local tool name version pattern role uri seen='|'
    local -a required_tools=(java awk sed grep perl sort comm bc ps tee date mktemp "$NEO4J_CLI")
    for tool in "${required_tools[@]}"; do
        # A wrapped CLI (container) is checked by connecting below, not on this PATH.
        [[ -n "${NEO4J_CLI_WRAP:-}${NEO4J_CLI_WRAP_MAIN:-}" ]] ||
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
    local account="${HOST_OS_USER:-}"
    if [[ -n "$account" ]] && ! ps -u "$account" -o pid= >/dev/null; then
        echo "[ERROR] Cannot sample the $account OS account required by these runners." >&2
        return 1
    fi

    for name in "$@"; do
        if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || ${#name} -gt 63 || "$seen" == *"|$name|"* ]]; then
            echo "[ERROR] Unsafe or duplicate benchmark role name: $name" >&2
            return 1
        fi
        seen="$seen$name|"
    done

    # Each role is a server of its own, so all three have to answer, and two roles on one
    # instance would silently make the comparison study measure the data it compares against.
    local -a uris=()
    for name in "$@"; do
        if ! uri=$(neo4j::bolt_uri "$name"); then
            echo "[ERROR] Unknown benchmark role: $name (each role is one Neo4j instance)" >&2
            return 1
        fi
        if [[ "$seen" == *"|$uri|"* ]]; then
            echo "[ERROR] Two benchmark roles share the Neo4j instance $uri; the comparison study needs three." >&2
            return 1
        fi
        seen="$seen$uri|"
        uris+=("$name")
        if [[ -z "$(neo4j::scalar < <(neo4j_cypher "$name" preflight 'RETURN 1 AS ok;'))" ]]; then
            echo "[ERROR] No Neo4j answer on $(neo4j::bolt_uri "$name") (role $name)." >&2
            return 1
        fi
    done

    version=$(neo4j::scalar < <(neo4j_cypher "$DB_NAME" preflight \
        'CALL dbms.components() YIELD versions RETURN versions[0];'))
    local numeric="$version"
    local min="${MIN_SERVER_VERSION:-$(registry::info min_server_version)}"
    if [[ -z "$numeric" ]]; then
        echo "[ERROR] Could not determine the Neo4j version on $(neo4j::bolt_uri "$DB_NAME")." >&2
        return 1
    fi
    if [[ "$(printf '%s\n%s\n' "$min" "$numeric" | sort -V | head -1)" != "$min" ]]; then
        echo "[ERROR] These runners require Neo4j >= $min (db.stats.retrieve, constraint syntax); got $version." >&2
        return 1
    fi

    # The benchmark role must be able to create the uniqueness constraint the binding's inserts
    # rely on and to write nodes. Both are tested by doing them; the probe never outlives this.
    if ! neo4j_cypher "$DB_NAME" preflight \
        "CREATE (n:_ycsb_probe {id: '_ycsb_probe'}) WITH n DETACH DELETE n RETURN 1 AS ok;" >/dev/null; then
        echo "[ERROR] Benchmark role cannot write and delete nodes on $(neo4j::bolt_uri "$DB_NAME")." >&2
        return 1
    fi
    if ! neo4j_cypher "$DB_NAME" preflight \
        "CREATE CONSTRAINT _ycsb_probe_id IF NOT EXISTS FOR (n:_ycsb_probe) REQUIRE n.id IS UNIQUE;" >/dev/null ||
       ! neo4j_cypher "$DB_NAME" preflight "DROP CONSTRAINT _ycsb_probe_id IF EXISTS;" >/dev/null; then
        echo "[ERROR] Benchmark role cannot create constraints on $(neo4j::bolt_uri "$DB_NAME"); inserts would be able to duplicate keys." >&2
        return 1
    fi

    # The comparison study copies the graph through APOC, so it has to exist on both ends.
    if [[ "$needs_dump" == true ]]; then
        for role in "$DB_NAME" "$BACKUP_DB_NAME"; do
            if ! neo4j::assert_apoc "$role"; then
                echo "[ERROR] APOC is not available on $(neo4j::bolt_uri "$role"); the clean-run phase exports and imports graphml through it." >&2
                return 1
            fi
        done
    fi

    backend::collect_metrics "$DB_NAME" global >/dev/null || return 1
    echo "[INFO] Neo4j preflight passed on ${#uris[@]} instances (server=$version)."
}

# neo4j::assert_apoc <role-name> - APOC installed and its file procedures enabled?
neo4j::assert_apoc() {
    local version
    version=$(neo4j::scalar < <(neo4j_cypher "$1" preflight 'RETURN apoc.version();'))
    [[ -n "$version" && "$version" != *"no procedure"* ]] || return 1
}

backend::required_artifacts() {
    printf '%s\n' \
        "$YCSB_HOME/core/target/*.jar" \
        "$YCSB_HOME/core/target/dependency/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/dependency/*.jar"
}

# ---------------------------------------------------------------------------
# Instances, reset and comparison copy
# ---------------------------------------------------------------------------

# The label plus the uniqueness constraint the binding's CREATE relies on. Idempotent, so it is
# called wherever an instance is prepared: init_db, before an import, and after a truncate.
neo4j::ensure_schema() {
    local role="${1:?which Neo4j instance}"
    neo4j_cypher "$role" schema \
        "CREATE CONSTRAINT ${TARGET_TABLE}_id IF NOT EXISTS FOR (n:\`${TARGET_TABLE}\`) REQUIRE n.id IS UNIQUE;" >/dev/null
}

# Delete every node of one instance. The legacy script stopped the server and removed its data
# directory; a benchmark role can do neither, so this deletes in batches (a single huge
# transaction on a large graph is a heap problem, not a correctness one).
neo4j::clear_instance() {
    local role="${1:?which Neo4j instance}"
    if neo4j::assert_apoc "$role"; then
        neo4j_cypher "$role" clear \
            "CALL apoc.periodic.iterate('MATCH (n) RETURN n', 'DETACH DELETE n', {batchSize: 10000, parallel: false});" >/dev/null
    else
        neo4j_cypher "$role" clear 'MATCH (n) DETACH DELETE n;' >/dev/null
    fi
}

backend::init_db() {
    local db_name="${1:?which Neo4j instance}" uri
    uri="$(neo4j::bolt_uri "$db_name")" || {
        echo "[ERROR] Unknown benchmark role: $db_name" >&2
        return 1
    }
    log "Initializing Neo4j instance $uri for $db_name..."
    neo4j::clear_instance "$db_name" || return 1
    neo4j::ensure_schema "$db_name" || return 1
    log "Done initializing $db_name."
}

# The comparison copy is a graphml export of the main instance imported into the comparison
# instance. Both paths are relative to the *instance's* import directory, so the instances have
# to share it (one volume mounted in each). Where they cannot - the EC2 hosts had one directory
# per instance under /opt/neo4j-instance-* - NEO4J_BACKUP_COPY_CMD moves the file; it is run with
# the source and target path substituted for {src} and {dst}, e.g.
#   NEO4J_BACKUP_COPY_CMD='sudo cp {src} {dst} && sudo chown neo4j:neo4j {dst}'
backend::dump_restore() {
    local source_rows restored_rows
    : > "$RESTORE_LOG"

    neo4j::assert_apoc "$DB_NAME" || {
        echo "[ERROR] APOC is not available on $(neo4j::bolt_uri "$DB_NAME")." >&2
        return 1
    }
    source_rows=$(backend::count_nodes "$DB_NAME") || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || {
        echo "[ERROR] Could not count the nodes to export." >&2
        return 1
    }

    log "Exporting $source_rows nodes from $(neo4j::bolt_uri "$DB_NAME") via APOC"
    if ! neo4j_cypher "$DB_NAME" dump \
        "CALL apoc.export.graphml.all('$NEO4J_APOC_BACKUP_FILE', {useTypes: true});" \
        >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] APOC export failed; see $RESTORE_LOG." >&2
        return 1
    fi

    if [[ -n "${NEO4J_BACKUP_COPY_CMD:-}" ]]; then
        local src="${NEO4J_APOC_EXPORT_PATH:-}" dst="${NEO4J_APOC_IMPORT_PATH:-}"
        [[ -n "$src" && -n "$dst" ]] || {
            echo "[ERROR] NEO4J_BACKUP_COPY_CMD needs NEO4J_APOC_EXPORT_PATH and NEO4J_APOC_IMPORT_PATH (absolute, as the runner sees them)." >&2
            return 1
        }
        local copy_cmd="${NEO4J_BACKUP_COPY_CMD//\{src\}/$src}"
        copy_cmd="${copy_cmd//\{dst\}/$dst}"
        log "Copying the export with NEO4J_BACKUP_COPY_CMD"
        if ! bash -c "$copy_cmd" >> "$RESTORE_LOG" 2>&1; then
            echo "[ERROR] Could not move the export to the comparison instance; see $RESTORE_LOG." >&2
            return 1
        fi
    fi

    log "Clearing $(neo4j::bolt_uri "$BACKUP_DB_NAME") before the import"
    neo4j::clear_instance "$BACKUP_DB_NAME" || {
        echo "[ERROR] Could not clear the comparison instance; see $RESTORE_LOG." >&2
        return 1
    }
    if ! neo4j_cypher "$BACKUP_DB_NAME" restore \
        "CALL apoc.import.graphml('$NEO4J_APOC_BACKUP_FILE', {useTypes: true});" \
        >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] APOC import failed (is $NEO4J_APOC_BACKUP_FILE in the comparison instance's import directory?); see $RESTORE_LOG." >&2
        return 1
    fi

    # GraphML does not carry the label back onto the nodes, so every restored node has to be put
    # on the benchmark label again - otherwise the measured phase finds an empty graph.
    if ! neo4j_cypher "$BACKUP_DB_NAME" restore \
        "CALL apoc.periodic.iterate('MATCH (n) WHERE NOT n:\`${TARGET_TABLE}\` RETURN n', 'SET n:\`${TARGET_TABLE}\`', {batchSize: 10000, parallel: false});" \
        >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] Could not restore the ${TARGET_TABLE} label after import; see $RESTORE_LOG." >&2
        return 1
    fi
    neo4j::ensure_schema "$BACKUP_DB_NAME" || return 1

    restored_rows=$(backend::count_nodes "$BACKUP_DB_NAME") || return 1
    if [[ "$restored_rows" != "$source_rows" ]]; then
        echo "[ERROR] Restore node count mismatch: source=$source_rows target=$restored_rows (see $RESTORE_LOG)." >&2
        return 1
    fi
    echo "[INFO] Restore verified: $restored_rows nodes." >> "$RESTORE_LOG"
}

backend::close() {
    log "Neo4j backend: no manual DB close required."
}

# ---------------------------------------------------------------------------
# Size helpers
#
# The two legacy definitions are kept exactly (see neo4j::size_expression): per key the length
# of the ten field properties, in total the same sum over the whole graph.
# ---------------------------------------------------------------------------

# The value-size definition of these runners: the total length of the ten field properties of a
# node. Used for both the per-key sizes (the histogram is bucketed from them) and the total that
# is divided by 10*recordcount to get fieldlengthaverage.
neo4j::size_expression() {
    printf '%s' "reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] | total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END)"
}

backend::count_nodes() {
    local db="${1:?which Neo4j instance}"
    neo4j::scalar < <(neo4j_cypher "$db" count \
        "MATCH (n:\`${TARGET_TABLE}\`) RETURN count(n);")
}

backend::total_size() {
    local db="${1:?which Neo4j instance}" total
    total=$(neo4j::scalar < <(neo4j_cypher "$db" size \
        "MATCH (n:\`${TARGET_TABLE}\`) RETURN coalesce(sum($(neo4j::size_expression)), 0);"))
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$total"
}

backend::key_sizes() {
    local db="${1:?which Neo4j instance}" out="${2:?output file required}"
    echo "ycsb_key,size" > "$out"
    # One joined column: cypher-shell quotes every returned value, and two columns would put
    # those quotes in front of the key.
    neo4j::rows < <(neo4j_cypher "$db" size \
        "MATCH (n:\`${TARGET_TABLE}\`) RETURN n.id + ',' + toString($(neo4j::size_expression)) AS row ORDER BY n.id;") \
        >> "$out"
}

backend::list_keys() {
    local db="${1:?which Neo4j instance}" out="${2:?output file required}"
    neo4j::rows < <(neo4j_cypher "$db" keys \
        "MATCH (n:\`${TARGET_TABLE}\`) RETURN n.id AS row;") > "$out"
}

backend::sample_key() {
    local db="${1:?which Neo4j instance}"
    neo4j::rows < <(neo4j_cypher "$db" keys \
        "MATCH (n:\`${TARGET_TABLE}\`) RETURN n.id AS row LIMIT 1;") | head -1
}

# PROFILE, not EXPLAIN: the legacy query-plan log recorded an executed plan, and verbose is
# cypher-shell's only spelling for "plan plus statistics". Only the key is returned - the legacy
# statement returned the whole node, so every entry in that log also contained the value it had
# grown to (kilobytes per entry at heavy scale), which is noise next to the access path.
backend::explain_sql() {
    local db="${1:?which Neo4j instance}" key="${2:?key required}"
    neo4j_cypher "$db" explain \
        "PROFILE MATCH (n:\`${TARGET_TABLE}\` {id: '${key//\'/\\\'}'}) RETURN n.id AS id LIMIT 1;" verbose
}

backend::delete_keys() {
    local db="${1:?which Neo4j instance}" file="${2:?key file required}" batch="" key count=0
    [[ -s "$file" ]] || return 0
    # Batched UNWIND over a literal list, as the legacy runner did (with jq). Keys are YCSB
    # identifiers; anything else is refused rather than pasted into Cypher.
    while IFS= read -r key || [[ -n "$key" ]]; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
            echo "[ERROR] Unexpected character in benchmark key: $key" >&2
            return 1
        }
        batch+="\"$key\","
        count=$((count + 1))
        if (( count % 1000 == 0 )); then
            neo4j_delete_batch "$db" "${batch%,}" || return 1
            batch=""
        fi
    done < "$file"
    [[ -z "$batch" ]] || neo4j_delete_batch "$db" "${batch%,}" || return 1
}

neo4j_delete_batch() {
    local db="${1:?which Neo4j instance}" keys="${2:?key list required}"
    neo4j_cypher "$db" delete \
        "UNWIND [$keys] AS k MATCH (n:\`${TARGET_TABLE}\` {id: k}) DETACH DELETE n;" >/dev/null
}

backend::truncate() {
    local db="${1:?which Neo4j instance}"
    neo4j::clear_instance "$db" || return 1
    neo4j::ensure_schema "$db"
}

# ---------------------------------------------------------------------------
# Backend contract: metadata and defaults
# ---------------------------------------------------------------------------

backend::info() {
    cat <<INFO
display_name=Neo4j (property graph)
default_type=neo4j
default_workload=workloada-extend
default_binding=neo4j
default_db=ycsb
min_server_version=5.0
has_dump_restore=1
supports_idle_wait=0
requires_index_wait=0
supports_vacuum=0
supports_query_plan=1
host_os_user=neo4j
INFO
}

backend::default_config() {
    DB_NAME="${DB_NAME:-ycsb}"
    BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
    UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
    TARGET_TABLE="${TARGET_TABLE:-usertable}"

    # The three roles are three instances; DB_HOST/DB_PORT describe the main one (DB_PORT is
    # what --dry-run prints, and the Bolt port of the instance the driver talks to first).
    DB_HOST="${DB_HOST:-127.0.0.1}"
    NEO4J_PORT_MAIN="${NEO4J_PORT_MAIN:-7687}"
    NEO4J_PORT_BACKUP="${NEO4J_PORT_BACKUP:-7787}"
    NEO4J_PORT_UNCHANGE="${NEO4J_PORT_UNCHANGE:-7887}"
    DB_PORT="${DB_PORT:-$NEO4J_PORT_MAIN}"

    DB_USERNAME="${DB_USERNAME:-neo4j}"
    DB_PWD="${DB_PWD:-}"

    # The neo4j binding reads url/username/password, not db.url/db.user/db.passwd.
    BINDING_PARAM_URL="${BINDING_PARAM_URL:-url}"
    BINDING_PARAM_USER="${BINDING_PARAM_USER:-username}"
    BINDING_PARAM_PASSWD="${BINDING_PARAM_PASSWD:-password}"

    # Driver URIs (neo4j:// routes through the driver), one per instance.
    local scheme="${NEO4J_URI_SCHEME:-neo4j}"
    DB_URL="$scheme://$DB_HOST:$NEO4J_PORT_MAIN"
    BACKUP_URL="$scheme://$DB_HOST:$NEO4J_PORT_BACKUP"
    UNCHANGED_DB_URL="$scheme://$DB_HOST:$NEO4J_PORT_UNCHANGE"

    JDBC_PROPERTIES="${JDBC_PROPERTIES:-$YCSB_HOME/neo4j/conf/neo4j.properties}"

    # graphml export/import path, relative to each instance's import directory (shared, or
    # moved with NEO4J_BACKUP_COPY_CMD - see backend::dump_restore).
    NEO4J_APOC_BACKUP_FILE="${NEO4J_APOC_BACKUP_FILE:-tmp/ycsb_neo4j_backup.graphml}"

    # CPU/memory are sampled from the server's OS account. With a wrapped CLI the servers are not
    # local processes, so there is nothing to sample and the two columns report 0 (they are real
    # on the EC2 hosts, where each instance runs under its own neo4j account).
    if [[ -n "${NEO4J_CLI_WRAP:-}${NEO4J_CLI_WRAP_MAIN:-}" ]]; then
        HOST_OS_USER="${HOST_OS_USER:-}"
    else
        HOST_OS_USER="${HOST_OS_USER:-$(registry::info host_os_user)}"
    fi
    # The export lives inside the instances, not next to the runner; BACKUP_FILE only has to be
    # a name the engine can remove after the clean-run phase.
    BACKUP_FILE="${BACKUP_FILE:-./$(basename "$NEO4J_APOC_BACKUP_FILE")}"
}
