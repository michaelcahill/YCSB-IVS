#!/usr/bin/env bash
# MongoDB backend — document store, driven by the mongodb binding (site.ycsb.db.MongoDbClient).
# The other half of the study's control group: values live in one document per key, so the
# extend phase grows a document instead of a row.
#
# Sourced by lib/registry.sh, never run directly.
#
# Differences from the legacy experiment_mongodb.sh, all deliberate:
#   * the comparison database is a third **database on the same server** (mongodump/mongorestore
#     with an nsFrom/nsTo mapping). The legacy script required a second mongod on 28018 and
#     restored into a database of the same name, which is why nothing here refers to a second
#     endpoint;
#   * no statistics columns at all, exactly like the legacy header (CPU/Memory come from the
#     OS account that runs mongod);
#   * `supports_query_plan=0`: this runner never wrote a query-plan log, so enabling one would
#     add an artefact the study has no baseline for; backend::explain_sql exists for the case
#     where that changes;
#   * databases are dropped per phase and created implicitly by the load (as before), and the
#     endpoint comes from configuration instead of a hardcoded mongodb://localhost:27017.
#
# Value sizes keep the legacy definitions, including their asymmetry, so results stay
# comparable with runs made before the refactor:
#   * per key: UTF-8 length of the EJSON object holding field0…field9 (so the JSON syntax
#     counts, and it is what the histogram is bucketed from);
#   * total: BSON size of the whole document (including _id), which is what the legacy script
#     divided by 10*recordcount to get fieldlengthaverage.

MONGO_CLI="${MONGO_CLI:-mongosh}"
MONGO_DUMP_CLI="${MONGO_DUMP_CLI:-mongodump}"
MONGO_RESTORE_CLI="${MONGO_RESTORE_CLI:-mongorestore}"

# ---------------------------------------------------------------------------
# Statistics columns: this backend reports none (legacy header had none either)
# ---------------------------------------------------------------------------

metric_field_names=()

backend::metric_names() {
    (( ${#metric_field_names[@]} == 0 )) && return 0
    printf '%s\n' "${metric_field_names[@]}"
}

# Nothing to snapshot for CSV purposes; the phase log still records how big the stored values
# were, which is what these runners compare across phases. scope=global is the preflight probe,
# where no benchmark collection has to exist yet.
backend::collect_metrics() {
    local db="${1:-$DB_NAME}" scope="${2:-all}"
    log "START statistics snapshot database=$db scope=$scope"
    if [[ "$scope" != global ]]; then
        local total
        total=$(backend::total_size "$db") || return 1
        log "DB statistics value size: $total database=$db"
    fi
    log "END statistics snapshot database=$db statistics=0"
}

# ---------------------------------------------------------------------------
# Admin CLI
# ---------------------------------------------------------------------------

# mongo_cli <tool> [args...] - runs a MongoDB admin tool. Nothing is logged verbatim because a
# connection URI can carry credentials.
mongo_cli() {
    local tool="${1:?mongosh, mongodump or mongorestore}"
    shift
    local started=$SECONDS rc=0 action="snapshot"
    case "$tool" in
        *dump*) action="dump" ;;
        *restore*) action="restore" ;;
        *) action="eval" ;;
    esac
    log "START MongoDB operation tool=$tool action=$action"

    local -a wrap=()
    [[ -z "${MONGO_CLI_WRAP:-}" ]] || read -r -a wrap <<< "$MONGO_CLI_WRAP"
    "${wrap[@]}" "$tool" "$@" || rc=$?
    log "END MongoDB operation tool=$tool action=$action status=$rc duration=$((SECONDS-started))s"
    return "$rc"
}

backend::cli() { mongo_cli "$@"; }

# mongosh <uri> --quiet --eval <js>: one JavaScript snippet in, plain text out.
mongo_eval() {
    local db_url="${1:?connection uri required}" js="${2:?javascript required}"
    mongo_cli "$MONGO_CLI" "$db_url" --quiet --eval "$js"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

backend::preflight() {
    local needs_dump="$1"
    shift
    local tool version db
    local seen='|'
    local -a required_tools=(java awk sed grep perl sort bc ps tee date mktemp "$MONGO_CLI")
    [[ "$needs_dump" == true ]] && required_tools+=("$MONGO_DUMP_CLI" "$MONGO_RESTORE_CLI")
    for tool in "${required_tools[@]}"; do
        # A wrapped CLI (container) is checked by connecting below, not on this PATH.
        [[ -n "${MONGO_CLI_WRAP:-}" ]] || command -v "$tool" >/dev/null 2>&1 || {
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

    if ! version=$(mongo_eval "$DB_URL" 'print(db.version());' | tail -n1) || [[ -z "$version" ]]; then
        echo "[ERROR] No MongoDB answer on $DB_HOST:$DB_PORT." >&2
        return 1
    fi
    local min="${MIN_SERVER_VERSION:-$(registry::info min_server_version)}"
    if [[ "$(printf '%s\n%s\n' "$min" "$version" | sort -V | head -1)" != "$min" ]]; then
        echo "[ERROR] These runners require MongoDB >= $min; got $version." >&2
        return 1
    fi

    for db in "$@"; do
        if [[ ! "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || ${#db} -gt 63 ||
              "$db" == admin || "$db" == local || "$db" == config ||
              "$seen" == *"|$db|"* ]]; then
            echo "[ERROR] Unsafe or duplicate benchmark database name: $db" >&2
            return 1
        fi
        seen="$seen$db|"
    done

    # A MongoDB database exists only once it holds data, so the role is tested by writing and
    # dropping a probe database. Nothing here needs collection DDL: _id is unique by definition.
    if ! mongo_eval "$MONGO_PROBE_URL" '
        db.getCollection("_ycsb_probe").insertOne({checked: 1});
        const dropped = db.dropDatabase().ok;
        print(dropped);
    ' | tail -n1 | grep -qx 1; then
        echo "[ERROR] Benchmark role cannot write to and drop a database; each phase recreates its own." >&2
        return 1
    fi

    backend::collect_metrics "$DB_NAME" global >/dev/null || return 1
    echo "[INFO] MongoDB preflight passed on $DB_HOST:$DB_PORT (server=$version)."
}

backend::required_artifacts() {
    printf '%s\n' \
        "$YCSB_HOME/core/target/*.jar" \
        "$YCSB_HOME/core/target/dependency/*.jar" \
        "$YCSB_HOME/$YCSB_BINDING/target/*.jar"
}

# ---------------------------------------------------------------------------
# Databases (MongoDB creates a database with its first document)
# ---------------------------------------------------------------------------

backend::init_db() {
    local db_name="${1:?database required}" url
    [[ "$db_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
        echo "[ERROR] Unsafe database name: $db_name" >&2
        return 1
    }
    url="$MONGO_SERVER/$db_name"
    log "Initializing MongoDB database $db_name..."
    mongo_eval "$url" 'db.dropDatabase();' >/dev/null
    log "Done initializing $db_name."
}

# Archive the benchmark database and restore it under the comparison database's name. The
# legacy script did the same dance against a second mongod; on one server the namespace
# mapping is what keeps the two apart.
#
# Two ways this looks like it works and does not, both found by running it:
#   * mongorestore must be given **no database** in --uri. The database in a connection URI acts
#     as a namespace filter, and every namespace in the archive starts with the *source*
#     database, so pointing at the target restores "0 document(s)" and exits 0;
#   * a renamed restore that finds nothing to do is not an error for mongorestore either, so the
#     document count below is the only thing that catches it.
backend::dump_restore() {
    local source_rows restored_rows
    : > "$RESTORE_LOG"
    source_rows=$(backend::count_documents "$DB_URL") || return 1
    [[ "$source_rows" =~ ^[0-9]+$ ]] || return 1

    if ! mongo_cli "$MONGO_DUMP_CLI" --uri="$DB_URL" --archive > "$BACKUP_FILE" 2>> "$RESTORE_LOG"; then
        echo "[ERROR] Dump failed; see $RESTORE_LOG." >&2
        return 1
    fi
    [[ -s "$BACKUP_FILE" ]] || { echo "[ERROR] Dump produced an empty archive: $BACKUP_FILE." >&2; return 1; }
    if ! mongo_cli "$MONGO_RESTORE_CLI" --uri="$MONGO_SERVER_URL" --archive --drop \
        --nsFrom="$DB_NAME.*" --nsTo="$BACKUP_DB_NAME.*" \
        < "$BACKUP_FILE" >> "$RESTORE_LOG" 2>&1; then
        echo "[ERROR] Restore failed; see $RESTORE_LOG. Dump retained at $BACKUP_FILE." >&2
        return 1
    fi
    restored_rows=$(backend::count_documents "$BACKUP_URL") || return 1
    if [[ "$restored_rows" != "$source_rows" ]]; then
        echo "[ERROR] Restore row count mismatch: source=$source_rows target=$restored_rows." >&2
        return 1
    fi
    echo "[INFO] Restore verified: $restored_rows rows." >> "$RESTORE_LOG"
}

backend::close() {
    log "MongoDB backend: no manual DB close required."
}

# ---------------------------------------------------------------------------
# Size helpers (the two definitions the legacy runners used - see the header comment)
# ---------------------------------------------------------------------------

backend::count_documents() {
    local url="${1:?connection uri required}"
    mongo_eval "$url" "print(db.getCollection('$TARGET_TABLE').countDocuments({}));" | tail -n1
}

backend::total_size() {
    local db="${1:?database required}"
    mongo_eval "$MONGO_SERVER/$db" '
        const stats = db.getCollection("'"$TARGET_TABLE"'").aggregate([
            { $project: { docSize: { $bsonSize: "$$ROOT" } } },
            { $group: { _id: null, totalSize: { $sum: "$docSize" } } }
        ]).toArray();
        print(stats.length ? stats[0].totalSize : 0);
    ' | tail -n1
}

backend::key_sizes() {
    local db="${1:?database required}" out="${2:?output file required}"
    echo "ycsb_key,size" > "$out"
    mongo_eval "$MONGO_SERVER/$db" '
        const cursor = db.getCollection("'"$TARGET_TABLE"'").find({}, {
            _id: 1, field0: 1, field1: 1, field2: 1, field3: 1,
            field4: 1, field5: 1, field6: 1, field7: 1, field8: 1, field9: 1
        });
        while (cursor.hasNext()) {
            const doc = cursor.next();
            const valueOnly = {};
            for (let i = 0; i < 10; i++) {
                const fname = "field" + i;
                if (doc[fname] !== undefined) {
                    valueOnly[fname] = doc[fname];
                }
            }
            print(doc._id + "," + new TextEncoder().encode(EJSON.stringify(valueOnly)).length);
        }
    ' >> "$out"
}

backend::list_keys() {
    local db="${1:?database required}" out="${2:?output file required}"
    mongo_eval "$MONGO_SERVER/$db" \
        "db.getCollection('$TARGET_TABLE').find({}, {_id: 1}).forEach(d => print(d._id));" \
        > "$out"
}

backend::sample_key() {
    local db="${1:?database required}"
    mongo_eval "$MONGO_SERVER/$db" \
        "const d = db.getCollection('$TARGET_TABLE').findOne(); print(d ? d._id : '');" | tail -n1
}

# Not used by the engine for this backend (supports_query_plan=0), but the contract asks for
# it, and mongosh can explain a key lookup in one line.
backend::explain_sql() {
    local db="${1:?database required}" key="${2:?key required}"
    mongo_eval "$MONGO_SERVER/$db" \
        "printjson(db.getCollection('$TARGET_TABLE').find({_id: '$key'}).explain());"
}

backend::delete_keys() {
    local db="${1:?database required}" file="${2:?key file required}" keys
    [[ -s "$file" ]] || return 0
    # JSON array of the keys to remove; keys are generated by YCSB and contain no quotes.
    keys=$(awk '{printf "%s\"%s\"", (NR>1 ? "," : ""), $0}' "$file")
    mongo_eval "$MONGO_SERVER/$db" \
        "print(db.getCollection('$TARGET_TABLE').deleteMany({_id: { \$in: [$keys] }}).deletedCount);"
}

backend::truncate() {
    local db="${1:?database required}"
    mongo_eval "$MONGO_SERVER/$db" \
        "print(db.getCollection('$TARGET_TABLE').deleteMany({}).deletedCount);"
}

# ---------------------------------------------------------------------------
# Backend contract: metadata and defaults
# ---------------------------------------------------------------------------

backend::info() {
    cat <<INFO
display_name=MongoDB (document store)
default_type=mongodb
default_workload=workloada-extend
default_binding=mongodb
default_db=ycsb
min_server_version=4.2
has_dump_restore=1
supports_idle_wait=0
requires_index_wait=0
supports_vacuum=0
supports_query_plan=0
host_os_user=mongod
INFO
}

backend::default_config() {
    DB_NAME="${DB_NAME:-ycsb}"
    BACKUP_DB_NAME="${BACKUP_DB_NAME:-ycsb_backup}"
    UNCHANGED_DB_NAME="${UNCHANGED_DB_NAME:-ycsb_unchange}"
    TARGET_TABLE="${TARGET_TABLE:-usertable}"

    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-27017}"
    # MongoDB is reached through the URI alone (and this deployment runs without auth, like
    # the legacy runners). The binding has no user/password property, so the engine sends only
    # the URL; set MONGO_URL_PARAMS to add options such as "?w=1" or authentication.
    DB_USERNAME="${DB_USERNAME:-}"
    DB_PWD="${DB_PWD:-}"
    BINDING_PARAM_CREDENTIALS=0
    BINDING_PARAM_PREFIX="${BINDING_PARAM_PREFIX:-mongodb}"

    local params="${MONGO_URL_PARAMS:-}"
    MONGO_SERVER="mongodb://$DB_HOST:$DB_PORT"
    DB_URL="$MONGO_SERVER/$DB_NAME$params"
    BACKUP_URL="$MONGO_SERVER/$BACKUP_DB_NAME$params"
    UNCHANGED_DB_URL="$MONGO_SERVER/$UNCHANGED_DB_NAME$params"
    MONGO_PROBE_URL="$MONGO_SERVER/${DB_NAME}_probe$params"
    # For mongorestore, which must not be given a database (see backend::dump_restore).
    MONGO_SERVER_URL="$MONGO_SERVER$params"

    # The binding has no properties file of its own in this tree; the harness passes one to
    # every YCSB invocation, so a two-line default ships next to the binding.
    JDBC_PROPERTIES="${JDBC_PROPERTIES:-$YCSB_HOME/mongodb/conf/mongodb.properties}"

    # With a container wrap there is no local mongod process to sample (they are real on the
    # EC2 host, where mongod runs as its own OS account).
    if [[ -n "${MONGO_CLI_WRAP:-}" ]]; then
        HOST_OS_USER="${HOST_OS_USER:-}"
    else
        HOST_OS_USER="${HOST_OS_USER:-$(registry::info host_os_user)}"
    fi
    BACKUP_FILE="${BACKUP_FILE:-./ycsb_mongodb.archive}"
}
