#!/usr/bin/env bash
# MariaDB backend — InnoDB storage engine, driven by the plain jdbc binding with the
# MariaDB JDBC driver. The relational control group on MariaDB: values grow inside the columns
# of a row, so the extend phase shows InnoDB's behaviour with in-place row growth.
#
# Sourced by lib/registry.sh, never run directly. Everything that is not storage-engine
# specific (CLI wrapper, SHOW GLOBAL STATUS snapshot, preflight, dump/restore, size helpers)
# comes from _mariadb_common.sh.
#
# Differences from the legacy experiment_mariadb_innodb.sh, deliberate:
#   * each phase's database is created and dropped by the runner (the legacy script required
#     all three to exist and only deleted rows);
#   * `btree_height` reports 0 unless INNO_SPACE_TOOL + INNODB_IBD_FILE are configured — the
#     legacy script shelled out to sudo plus ../inno_space/inno inside the run;
#   * CPU/memory are sampled from the OS account named by host_os_user (mysql on the EC2
#     host); the legacy script pgrep'd mariadbd, which fails the same way when the server is
#     not a local process.

# shellcheck source=_mariadb_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_mariadb_common.sh"

backend::info() {
    cat <<INFO
display_name=MariaDB (InnoDB)
default_type=mariadb_innodb
default_workload=workloada-extend
default_binding=jdbc
default_db=ycsb
min_server_version=10.6
has_dump_restore=1
supports_idle_wait=0
requires_index_wait=0
supports_vacuum=0
supports_query_plan=1
host_os_user=mysql
INFO
}

# The ten value columns must survive the extend phase, which rewrites every value longer:
# a VARCHAR(N) column does not fail loudly there, MariaDB reports "Data too long for column"
# on stderr and YCSB still exits 0 (the legacy runners created LONGTEXT columns by hand). As
# in PostgreSQL's TEXT, only the stored bytes count towards the measured value size.
backend::create_table_sql() {
    cat <<'SQL'
CREATE TABLE usertable (
    ycsb_key VARCHAR(255) NOT NULL PRIMARY KEY,
    field0 LONGTEXT, field1 LONGTEXT, field2 LONGTEXT, field3 LONGTEXT, field4 LONGTEXT,
    field5 LONGTEXT, field6 LONGTEXT, field7 LONGTEXT, field8 LONGTEXT, field9 LONGTEXT
) ENGINE=InnoDB;
SQL
}

# Byte length of the ten columns (LENGTHB, so multi-byte characters count as stored).
backend::size_expression() {
    cat <<'SQL'
coalesce(lengthb(field0), 0) + coalesce(lengthb(field1), 0) + coalesce(lengthb(field2), 0) + coalesce(lengthb(field3), 0) + coalesce(lengthb(field4), 0) + coalesce(lengthb(field5), 0) + coalesce(lengthb(field6), 0) + coalesce(lengthb(field7), 0) + coalesce(lengthb(field8), 0) + coalesce(lengthb(field9), 0)
SQL
}

backend::default_config() {
    mariadb::base_config
}
