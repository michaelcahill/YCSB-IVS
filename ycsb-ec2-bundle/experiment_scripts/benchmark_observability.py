#!/usr/bin/env python3
"""Low-overhead observability helpers for the PostgreSQL YCSB-IVS harness.

The bash experiment script remains the benchmark orchestrator. This helper is
intentionally dependency-free and shell-friendly: each subcommand performs one
bounded task and degrades to warnings/files rather than aborting the benchmark.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


SECRET_PATTERNS = [
    (re.compile(r"(db\.passw(?:or)?d=)[^\s]+", re.IGNORECASE), r"\1[REDACTED]"),
    (re.compile(r"((?:PGPASSWORD|DB_PWD|DB_PASS|PASSWORD|passwd|password)=)[^\s]+", re.IGNORECASE), r"\1[REDACTED]"),
    (re.compile(r"(postgres(?:ql)?://[^:/@\s]+:)[^@\s]+(@)", re.IGNORECASE), r"\1[REDACTED]\2"),
]


def redact_secrets(value: Any) -> Any:
    if isinstance(value, str):
        redacted = value
        for pattern, replacement in SECRET_PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        return redacted
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    if isinstance(value, dict):
        return {key: redact_secrets(val) for key, val in value.items()}
    return value


STATS_VIEWS = [
    "pg_stat_database",
    "pg_stat_user_tables",
    "pg_statio_user_tables",
    "pg_stat_user_indexes",
    "pg_stat_wal",
    "pg_stat_bgwriter",
    "pg_stat_checkpointer",
    "pg_stat_io",
    "pg_stat_activity",
]

DESIRED_COLUMNS = {
    "pg_stat_database": [
        "datname",
        "xact_commit",
        "xact_rollback",
        "blks_read",
        "blks_hit",
        "tup_returned",
        "tup_fetched",
        "tup_inserted",
        "tup_updated",
        "tup_deleted",
        "temp_files",
        "temp_bytes",
        "deadlocks",
        "blk_read_time",
        "blk_write_time",
        "session_time",
        "active_time",
        "idle_in_transaction_time",
        "sessions",
        "sessions_abandoned",
        "sessions_fatal",
        "sessions_killed",
        "stats_reset",
    ],
    "pg_stat_user_tables": [
        "schemaname",
        "relname",
        "seq_scan",
        "seq_tup_read",
        "idx_scan",
        "idx_tup_fetch",
        "n_tup_ins",
        "n_tup_upd",
        "n_tup_del",
        "n_tup_hot_upd",
        "n_tup_newpage_upd",
        "n_live_tup",
        "n_dead_tup",
        "n_mod_since_analyze",
        "n_ins_since_vacuum",
        "last_vacuum",
        "last_autovacuum",
        "last_analyze",
        "last_autoanalyze",
        "vacuum_count",
        "autovacuum_count",
        "analyze_count",
        "autoanalyze_count",
    ],
    "pg_statio_user_tables": [
        "schemaname",
        "relname",
        "heap_blks_read",
        "heap_blks_hit",
        "idx_blks_read",
        "idx_blks_hit",
        "toast_blks_read",
        "toast_blks_hit",
        "tidx_blks_read",
        "tidx_blks_hit",
    ],
    "pg_stat_user_indexes": [
        "schemaname",
        "relname",
        "indexrelname",
        "idx_scan",
        "idx_tup_read",
        "idx_tup_fetch",
    ],
    "pg_stat_wal": [
        "wal_records",
        "wal_fpi",
        "wal_bytes",
        "wal_buffers_full",
        "wal_write",
        "wal_sync",
        "wal_write_time",
        "wal_sync_time",
        "stats_reset",
    ],
    "pg_stat_bgwriter": [
        "buffers_clean",
        "maxwritten_clean",
        "buffers_alloc",
        "checkpoints_timed",
        "checkpoints_req",
        "checkpoint_write_time",
        "checkpoint_sync_time",
        "buffers_checkpoint",
        "buffers_backend",
        "buffers_backend_fsync",
        "stats_reset",
    ],
    "pg_stat_checkpointer": [
        "num_timed",
        "num_requested",
        "num_done",
        "restartpoints_timed",
        "restartpoints_req",
        "restartpoints_done",
        "write_time",
        "sync_time",
        "buffers_written",
        "stats_reset",
    ],
    "pg_stat_io": [
        "backend_type",
        "object",
        "context",
        "reads",
        "read_time",
        "writes",
        "write_time",
        "writebacks",
        "writeback_time",
        "extends",
        "extend_time",
        "op_bytes",
        "hits",
        "evictions",
        "reuses",
        "fsyncs",
        "fsync_time",
        "stats_reset",
    ],
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


SQL_UTC_NOW = "to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"


def sql_literal(value: object) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def quote_ident(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def postgres_major_from_version(version_text: object) -> Optional[int]:
    match = re.search(r"PostgreSQL\s+(\d+)", str(version_text or ""))
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value)
    return value.strip("_") or "phase"


def ensure_dirs(run_dir: Path) -> None:
    for rel in [
        "sql",
        "snapshots",
        "samples",
        "ycsb",
        "derived",
        "logs",
    ]:
        (run_dir / rel).mkdir(parents=True, exist_ok=True)


def append_log(run_dir: Path, message: str, name: str = "observability.log") -> None:
    ensure_dirs(run_dir)
    with (run_dir / "logs" / name).open("a", encoding="utf-8") as fh:
        fh.write(f"{utc_now()} {message}\n")


class Pg:
    def __init__(self, user: str, password: str, default_db: str):
        self.user = user
        self.password = password
        self.default_db = default_db

    def run(
        self,
        db: Optional[str],
        sql: str,
        *,
        timeout: int = 30,
        check: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PGPASSWORD"] = self.password
        cmd = [
            "psql",
            "-X",
            "-q",
            "-t",
            "-A",
            "-F",
            "\t",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            self.user,
            "-d",
            db or self.default_db,
            "-c",
            sql,
        ]
        proc = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=timeout)
        if check and proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
        return proc

    def rows(self, db: Optional[str], sql: str, *, timeout: int = 30) -> List[List[str]]:
        proc = self.run(db, sql, timeout=timeout)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
        rows: List[List[str]] = []
        for line in proc.stdout.splitlines():
            if line.strip():
                rows.append(line.split("\t"))
        return rows

    def scalar(self, db: Optional[str], sql: str, *, timeout: int = 30) -> str:
        rows = self.rows(db, sql, timeout=timeout)
        if not rows or not rows[0]:
            return ""
        return rows[0][0]


def pg_from_args(args: argparse.Namespace) -> Pg:
    password = os.environ.get(args.db_password_env, "")
    return Pg(args.db_user, password, args.db_name)


def view_exists(pg: Pg, db: str, view: str) -> bool:
    try:
        return pg.scalar(db, f"SELECT to_regclass('pg_catalog.{view}') IS NOT NULL;") == "t"
    except Exception:
        return False


def view_columns(pg: Pg, db: str, view: str) -> List[str]:
    if not view_exists(pg, db, view):
        return []
    try:
        rows = pg.rows(
            db,
            f"""
            SELECT a.attname
            FROM pg_attribute a
            WHERE a.attrelid = 'pg_catalog.{view}'::regclass
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum;
            """,
        )
        return [r[0] for r in rows if r]
    except Exception:
        return []


def target_where_sql(target_table: str, alias: str = "c") -> str:
    if "." in target_table:
        schema, rel = target_table.split(".", 1)
        return f"{alias}.oid = to_regclass({sql_literal(schema + '.' + rel)})"
    return (
        f"{alias}.relname = {sql_literal(target_table)} "
        "AND EXISTS (SELECT 1 FROM pg_namespace n WHERE n.oid = "
        f"{alias}.relnamespace AND n.nspname = 'public')"
    )


def relation_mapping_rows(pg: Pg, db: str, target_table: str) -> List[List[str]]:
    sql = f"""
    WITH heap AS (
        SELECT n.nspname AS schema_name,
               c.relname AS relation_name,
               c.oid AS relation_oid,
               c.relfilenode,
               c.reltoastrelid
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND ({target_where_sql(target_table, "c")})
        ORDER BY n.nspname = 'public' DESC, n.nspname, c.relname
        LIMIT 1
    ),
    rels AS (
        SELECT 'heap' AS relation_role, schema_name, relation_name, relation_oid, relfilenode
        FROM heap
        UNION ALL
        SELECT 'heap_index', ni.nspname, ci.relname, ci.oid, ci.relfilenode
        FROM heap h
        JOIN pg_index i ON i.indrelid = h.relation_oid
        JOIN pg_class ci ON ci.oid = i.indexrelid
        JOIN pg_namespace ni ON ni.oid = ci.relnamespace
        UNION ALL
        SELECT 'toast_heap', nt.nspname, t.relname, t.oid, t.relfilenode
        FROM heap h
        JOIN pg_class t ON t.oid = h.reltoastrelid
        JOIN pg_namespace nt ON nt.oid = t.relnamespace
        WHERE h.reltoastrelid <> 0
        UNION ALL
        SELECT 'toast_index', ni.nspname, ci.relname, ci.oid, ci.relfilenode
        FROM heap h
        JOIN pg_index i ON i.indrelid = h.reltoastrelid
        JOIN pg_class ci ON ci.oid = i.indexrelid
        JOIN pg_namespace ni ON ni.oid = ci.relnamespace
        WHERE h.reltoastrelid <> 0
    )
    SELECT relation_role,
           schema_name,
           relation_name,
           relation_oid::text,
           relfilenode::text
    FROM rels
    ORDER BY relation_role, relation_name;
    """
    return pg.rows(db, sql)


def write_csv(path: Path, header: Sequence[str], rows: Iterable[Sequence[object]], append: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists()
    mode = "a" if append else "w"
    with path.open(mode, encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        if not append or not exists:
            writer.writerow(header)
        for row in rows:
            writer.writerow(list(row))


def collect_view_snapshot(
    pg: Pg,
    db: str,
    out_dir: Path,
    run_id: str,
    phase_id: str,
    label: str,
    source: str,
    view: str,
    target_table: str,
    append: bool = False,
) -> None:
    cols = [c for c in DESIRED_COLUMNS.get(view, view_columns(pg, db, view)) if c in view_columns(pg, db, view)]
    path = out_dir / f"{view}.csv"
    header = ["run_id", "phase_id", "snapshot_label", "timestamp_utc", "source"] + cols
    if not cols:
        write_csv(path, header + ["message"], [[run_id, phase_id, label, utc_now(), source, "view unavailable"]], append=append)
        return

    where = ""
    if view == "pg_stat_database":
        where = f"WHERE datname = current_database()"
    elif view in ("pg_stat_user_tables", "pg_statio_user_tables"):
        where = f"WHERE relid = (SELECT c.oid FROM pg_class c WHERE {target_where_sql(target_table, 'c')} LIMIT 1)"
    elif view == "pg_stat_user_indexes":
        where = f"WHERE relid = (SELECT c.oid FROM pg_class c WHERE {target_where_sql(target_table, 'c')} LIMIT 1)"

    exprs = [
        sql_literal(run_id),
        sql_literal(phase_id),
        sql_literal(label),
        SQL_UTC_NOW,
        sql_literal(source),
    ]
    exprs.extend([f"COALESCE({quote_ident(c)}::text, '')" for c in cols])
    sql = f"SELECT {', '.join(exprs)} FROM pg_catalog.{view} {where};"
    try:
        rows = pg.rows(db, sql)
        write_csv(path, header, rows, append=append)
    except Exception as exc:
        write_csv(path, header + ["message"], [[run_id, phase_id, label, utc_now(), source, str(exc)]], append=append)


def collect_relation_sizes(
    pg: Pg,
    db: str,
    out_dir: Path,
    run_id: str,
    phase_id: str,
    label: str,
    target_table: str,
    append: bool = False,
) -> None:
    header = [
        "run_id",
        "phase_id",
        "snapshot_label",
        "timestamp_utc",
        "source",
        "table_oid",
        "schema_name",
        "table_name",
        "toast_table_oid",
        "toast_table_name",
        "heap_bytes",
        "index_bytes",
        "total_relation_bytes",
        "toast_heap_bytes",
        "toast_index_bytes",
        "toast_total_bytes",
        "total_bytes",
        "toast_fraction",
    ]
    sql = f"""
    WITH heap AS (
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               c.oid AS table_oid,
               c.reltoastrelid AS toast_oid
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND ({target_where_sql(target_table, "c")})
        ORDER BY n.nspname = 'public' DESC, n.nspname, c.relname
        LIMIT 1
    ),
    sized AS (
        SELECT h.*,
               t.relname AS toast_name,
               pg_relation_size(h.table_oid) AS heap_bytes,
               pg_indexes_size(h.table_oid) AS index_bytes,
               pg_total_relation_size(h.table_oid) AS total_relation_bytes,
               CASE WHEN h.toast_oid = 0 THEN 0 ELSE pg_relation_size(h.toast_oid) END AS toast_heap_bytes,
               CASE WHEN h.toast_oid = 0 THEN 0 ELSE pg_indexes_size(h.toast_oid) END AS toast_index_bytes,
               CASE WHEN h.toast_oid = 0 THEN 0 ELSE pg_total_relation_size(h.toast_oid) END AS toast_total_bytes
        FROM heap h
        LEFT JOIN pg_class t ON t.oid = h.toast_oid
    )
    SELECT {sql_literal(run_id)},
           {sql_literal(phase_id)},
           {sql_literal(label)},
           {SQL_UTC_NOW},
           'relation_sizes',
           table_oid::text,
           schema_name,
           table_name,
           toast_oid::text,
           COALESCE(toast_name, ''),
           heap_bytes::text,
           index_bytes::text,
           total_relation_bytes::text,
           toast_heap_bytes::text,
           toast_index_bytes::text,
           toast_total_bytes::text,
           (heap_bytes + index_bytes + toast_total_bytes)::text,
           CASE
               WHEN (heap_bytes + index_bytes + toast_total_bytes) > 0
               THEN ROUND(toast_total_bytes::numeric / (heap_bytes + index_bytes + toast_total_bytes), 6)::text
               ELSE ''
           END
    FROM sized;
    """
    try:
        rows = pg.rows(db, sql)
        if not rows:
            rows = [[run_id, phase_id, label, utc_now(), "relation_sizes", "", "", "", "", "", "", "", "", "", "", "", "", ""]]
        write_csv(out_dir / "relation_sizes.csv", header, rows, append=append)
    except Exception as exc:
        write_csv(
            out_dir / "relation_sizes.csv",
            header + ["message"],
            [[run_id, phase_id, label, utc_now(), "relation_sizes", "", "", "", "", "", "", "", "", "", "", "", "", "", str(exc)]],
            append=append,
        )


def collect_wait_summary(
    pg: Pg,
    db: str,
    out_dir: Path,
    run_id: str,
    phase_id: str,
    label: str,
    append: bool = False,
) -> None:
    header = [
        "run_id",
        "phase_id",
        "snapshot_label",
        "timestamp_utc",
        "source",
        "backend_type",
        "state",
        "wait_event_type",
        "wait_event",
        "backend_count",
        "active_count",
        "idle_in_transaction_count",
        "max_query_age_seconds",
        "max_xact_age_seconds",
    ]
    sql = f"""
    SELECT {sql_literal(run_id)},
           {sql_literal(phase_id)},
           {sql_literal(label)},
           {SQL_UTC_NOW},
           'pg_stat_activity_waits',
           COALESCE(backend_type, ''),
           COALESCE(state, ''),
           COALESCE(wait_event_type, ''),
           COALESCE(wait_event, ''),
           count(*)::text,
           count(*) FILTER (WHERE state = 'active')::text,
           count(*) FILTER (WHERE state = 'idle in transaction')::text,
           COALESCE(ROUND(max(EXTRACT(EPOCH FROM clock_timestamp() - query_start))::numeric, 3)::text, ''),
           COALESCE(ROUND(max(EXTRACT(EPOCH FROM clock_timestamp() - xact_start))::numeric, 3)::text, '')
    FROM pg_stat_activity
    WHERE datname = current_database()
    GROUP BY backend_type, state, wait_event_type, wait_event
    ORDER BY backend_type, state, wait_event_type, wait_event;
    """
    try:
        write_csv(out_dir / "pg_stat_activity_waits.csv", header, pg.rows(db, sql), append=append)
    except Exception as exc:
        write_csv(
            out_dir / "pg_stat_activity_waits.csv",
            header + ["message"],
            [[run_id, phase_id, label, utc_now(), "pg_stat_activity_waits", "", "", "", "", "", "", "", "", "", str(exc)]],
            append=append,
        )


def append_lsn_marker(pg: Pg, db: str, run_dir: Path, run_id: str, phase_id: str, label: str) -> None:
    header = ["run_id", "phase_id", "label", "timestamp_utc", "db_name", "lsn", "source", "message"]
    try:
        lsn = pg.scalar(db, "SELECT pg_current_wal_lsn();")
        row = [run_id, phase_id, label, utc_now(), db, lsn, "pg_current_wal_lsn", ""]
    except Exception as exc:
        row = [run_id, phase_id, label, utc_now(), db, "", "pg_current_wal_lsn", str(exc)]
    write_csv(run_dir / "snapshots" / "lsn_markers.csv", header, [row], append=True)


def collect_snapshot(args: argparse.Namespace, *, append_samples: bool = False) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    pg = pg_from_args(args)
    out_dir = Path(args.output_path) if getattr(args, "output_path", None) else run_dir / "snapshots" / f"phase_{safe_name(args.phase_id)}_{args.label}"
    out_dir.mkdir(parents=True, exist_ok=True)

    for view in [
        "pg_stat_database",
        "pg_stat_user_tables",
        "pg_statio_user_tables",
        "pg_stat_user_indexes",
        "pg_stat_wal",
        "pg_stat_bgwriter",
        "pg_stat_checkpointer",
        "pg_stat_io",
    ]:
        collect_view_snapshot(
            pg,
            args.db_name,
            out_dir,
            args.run_id,
            args.phase_id,
            args.label,
            view,
            view,
            args.target_table,
            append=append_samples,
        )
    collect_wait_summary(pg, args.db_name, out_dir, args.run_id, args.phase_id, args.label, append=append_samples)
    collect_relation_sizes(pg, args.db_name, out_dir, args.run_id, args.phase_id, args.label, args.target_table, append=append_samples)
    if not append_samples:
        append_lsn_marker(pg, args.db_name, run_dir, args.run_id, args.phase_id, args.label)


def parse_workload_file(path: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    if not path or not Path(path).exists():
        return result
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def collect_ec2_metadata() -> Dict[str, str]:
    base = "http://169.254.169.254/latest"
    result: Dict[str, str] = {}
    try:
        req = urllib.request.Request(base + "/api/token", method="PUT")
        req.add_header("X-aws-ec2-metadata-token-ttl-seconds", "60")
        with urllib.request.urlopen(req, timeout=0.25) as resp:
            token = resp.read().decode("utf-8", errors="replace")
    except Exception:
        return result

    def get(path: str) -> str:
        try:
            req = urllib.request.Request(base + path)
            req.add_header("X-aws-ec2-metadata-token", token)
            with urllib.request.urlopen(req, timeout=0.25) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, TimeoutError, Exception):
            return ""

    result["instance_id"] = get("/meta-data/instance-id")
    result["instance_type"] = get("/meta-data/instance-type")
    result["availability_zone"] = get("/meta-data/placement/availability-zone")
    result["ami_id"] = get("/meta-data/ami-id")
    return {k: v for k, v in result.items() if v}


def command_output(cmd: Sequence[str], cwd: Optional[str] = None, timeout: int = 5) -> str:
    try:
        proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, timeout=timeout)
        if proc.returncode == 0:
            return proc.stdout.strip()
        return proc.stderr.strip()
    except Exception as exc:
        return str(exc)


def manifest_init(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    pg = pg_from_args(args)
    workload = parse_workload_file(args.workload_file)
    version = ""
    try:
        version = pg.scalar(args.db_name, "SELECT version();", timeout=5)
    except Exception:
        pass

    manifest = {
        "run_id": args.run_id,
        "start_time_utc": utc_now(),
        "hostname": socket.gethostname(),
        "working_directory": os.getcwd(),
        "benchmark_script_path": args.script_path,
        "command_line": redact_secrets(args.command_line),
        "git_commit": command_output(["git", "rev-parse", "HEAD"], cwd=args.repo_root),
        "git_dirty_status": command_output(["git", "status", "--short"], cwd=args.repo_root),
        "postgresql": {
            "db_name": args.db_name,
            "db_user": args.db_user,
            "db_url_without_password": redact_secrets(args.db_url),
            "version": version,
            "target_table": args.target_table,
        },
        "os": {
            "kernel": platform.platform(),
            "cpu_summary": command_output(["bash", "-lc", "lscpu 2>/dev/null | sed -n '1,12p'"], timeout=5),
            "memory_summary": command_output(["free", "-h"], timeout=5),
            "disk_summary": command_output(["df", "-h"], timeout=5),
        },
        "ec2_metadata": collect_ec2_metadata(),
        "workload_parameters": workload,
        "benchmark_config": {
            "type": args.type_name,
            "dist": args.dist,
            "scale": args.scale,
            "work": args.work,
            "run_number": args.run_number,
            "value_variant": args.value_variant,
            "ycsb_binding": args.ycsb_binding,
            "field_sql_type": args.field_sql_type,
            "sample_interval_seconds": args.sample_interval_seconds,
            "relation_size_sample_interval_seconds": args.relation_size_sample_interval_seconds,
            "inspect_wal_ranges": args.inspect_wal_ranges,
            "full_visibility_profile": args.full_visibility_profile,
            "require_full_visibility": args.require_full_visibility,
            "pg_prewarm_enabled": args.pg_prewarm_enabled,
            "pg_prewarm_mode": args.pg_prewarm_mode,
            "reset_pg_stats_before_run": args.reset_pg_stats_before_run,
            "skip_continuous_sampling": args.skip_continuous_sampling,
            "phase_value_sizes": args.phase_value_sizes,
        },
    }
    (run_dir / "manifest.json").write_text(json.dumps(redact_secrets(manifest), indent=2, sort_keys=True) + "\n", encoding="utf-8")

    resolved = {
        "run_id": args.run_id,
        "run_dir": str(run_dir),
        "db_name": args.db_name,
        "target_table": args.target_table,
        "workload_file": args.workload_file,
        "output_csv": args.output_csv,
        "log_file": args.log_file,
        "plan_log": args.plan_log,
        "key_size_log": args.key_size_log,
        "sample_interval_seconds": args.sample_interval_seconds,
        "relation_size_sample_interval_seconds": args.relation_size_sample_interval_seconds,
        "environment_without_secrets": {
            k: v
            for k, v in os.environ.items()
            if k
            in {
                "DB_NAME",
                "DB_USERNAME",
                "TYPE",
                "DIST",
                "SCALE",
                "WORK",
                "RUN",
                "VALUE_VARIANT",
                "YCSB_BINDING",
                "FIELD_SQL_TYPE",
                "EXPERIMENT_EPOCHS",
                "EXPERIMENT_RUNS_PER_EPOCH",
                "COMPARISON_INTERVAL",
                "VACUUM_ENABLED",
                "EXTEND_OPERATIONCOUNT",
                "FIELD_LENGTH_ORIGINAL",
                "BENCHRUN_FULL_VISIBILITY",
                "BENCHRUN_REQUIRE_FULL_VISIBILITY",
                "SPIKE_TRIGGER_PREWARM_ENABLED",
                "SPIKE_TRIGGER_PREWARM_MODE",
                "SPIKE_TRIGGER_WALINSPECT_ENABLED",
                "SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED",
                "EXTEND_REQUESTDISTRIBUTION",
                "RUN_REQUESTDISTRIBUTION",
                "RUN_READPROPORTION",
                "RUN_UPDATEPROPORTION",
            }
        },
    }
    (run_dir / "config_resolved.json").write_text(json.dumps(redact_secrets(resolved), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def manifest_finish(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    manifest_path = run_dir / "manifest.json"
    manifest: Dict[str, object] = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            manifest = {}
    manifest["end_time_utc"] = utc_now()
    manifest["exit_status"] = args.exit_status
    if manifest.get("start_time_utc"):
        try:
            start = dt.datetime.fromisoformat(str(manifest["start_time_utc"]).replace("Z", "+00:00"))
            end = dt.datetime.fromisoformat(str(manifest["end_time_utc"]).replace("Z", "+00:00"))
            manifest["duration_seconds"] = round((end - start).total_seconds(), 3)
        except Exception:
            pass
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "exit_status.txt").write_text(f"{args.exit_status}\n", encoding="utf-8")


def preflight(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    pg = pg_from_args(args)
    sql_dir = run_dir / "sql"

    result: Dict[str, object] = {
        "run_id": args.run_id,
        "timestamp_utc": utc_now(),
        "db_name": args.db_name,
        "target_table": args.target_table,
        "can_connect": False,
        "stats_views": {},
        "optional_extensions": {},
        "warnings": [],
    }

    try:
        result["current_database"] = pg.scalar(args.db_name, "SELECT current_database();", timeout=5)
        result["postgres_version"] = pg.scalar(args.db_name, "SELECT version();", timeout=5)
        result["postgres_major_version"] = postgres_major_from_version(result["postgres_version"])
        result["can_connect"] = True
        (sql_dir / "postgres_version.txt").write_text(str(result["postgres_version"]) + "\n", encoding="utf-8")
    except Exception as exc:
        result["warnings"].append(f"connect failed: {exc}")
        (sql_dir / "preflight.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return

    for view in STATS_VIEWS:
        cols = view_columns(pg, args.db_name, view)
        result["stats_views"][view] = {"available": bool(cols), "columns": cols}

    major = result.get("postgres_major_version")
    if isinstance(major, int):
        if major < 16 and not result["stats_views"].get("pg_stat_io", {}).get("available"):
            result["warnings"].append("pg_stat_io is PostgreSQL 16+; this run will rely on pg_stat_database/pg_statio_* plus OS I/O metrics.")
        if major < 17 and not result["stats_views"].get("pg_stat_checkpointer", {}).get("available"):
            result["warnings"].append("pg_stat_checkpointer is PostgreSQL 17+; checkpoint deltas will be read from pg_stat_bgwriter when those columns exist.")

    try:
        settings_rows = pg.rows(
            args.db_name,
            """
            SELECT name, setting, unit, source
            FROM pg_settings
            WHERE name IN (
              'shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem',
              'checkpoint_timeout', 'max_wal_size', 'min_wal_size',
              'wal_compression', 'track_io_timing', 'shared_preload_libraries',
              'autovacuum', 'autovacuum_vacuum_scale_factor', 'autovacuum_analyze_scale_factor',
              'log_checkpoints'
            )
            ORDER BY name;
            """,
        )
        write_csv(sql_dir / "pg_settings.csv", ["name", "setting", "unit", "source"], settings_rows)
    except Exception as exc:
        result["warnings"].append(f"pg_settings failed: {exc}")

    try:
        mapping = relation_mapping_rows(pg, args.db_name, args.target_table)
        write_csv(sql_dir / "relation_mapping.csv", ["relation_role", "schema_name", "relation_name", "relation_oid", "relfilenode"], mapping)
        result["target_table_exists"] = bool(mapping)
        heap = next((row for row in mapping if row and row[0] == "heap"), None)
        toast = next((row for row in mapping if row and row[0] == "toast_heap"), None)
        result["target_table_oid"] = heap[3] if heap else None
        result["toast_table_oid"] = toast[3] if toast else None
        result["has_toast_table"] = toast is not None
    except Exception as exc:
        result["target_table_exists"] = False
        result["warnings"].append(f"relation mapping failed: {exc}")

    for ext in ["pg_stat_statements", "pg_walinspect", "pg_buffercache", "pg_freespacemap", "pg_prewarm"]:
        try:
            installed = pg.scalar(args.db_name, f"SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = {sql_literal(ext)});")
            result["optional_extensions"][ext] = installed == "t"
        except Exception:
            result["optional_extensions"][ext] = False

    (sql_dir / "preflight.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def reset_stats(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    pg = pg_from_args(args)
    attempts = []
    for name, sql in [
        ("pg_stat_reset", "SELECT pg_stat_reset();"),
        ("pg_stat_reset_shared_wal", "SELECT pg_stat_reset_shared('wal');"),
        ("pg_stat_reset_shared_bgwriter", "SELECT pg_stat_reset_shared('bgwriter');"),
    ]:
        try:
            proc = pg.run(args.db_name, sql, timeout=10)
            attempts.append({"name": name, "ok": proc.returncode == 0, "message": (proc.stderr or proc.stdout).strip()})
        except Exception as exc:
            attempts.append({"name": name, "ok": False, "message": str(exc)})
    (run_dir / "sql" / "stats_reset.json").write_text(json.dumps({"timestamp_utc": utc_now(), "attempts": attempts}, indent=2) + "\n", encoding="utf-8")


def phase_metadata(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    header = [
        "run_id",
        "phase_id",
        "phase_dir",
        "event",
        "timestamp_utc",
        "db_name",
        "phase_name",
        "epoch",
        "operation_count",
        "value_size_bytes",
        "logical_bytes_per_op",
        "ycsb_output",
        "exit_status",
    ]
    row = [
        args.run_id,
        args.phase_id,
        safe_name(args.phase_id),
        args.event,
        utc_now(),
        args.db_name,
        args.phase_name,
        args.epoch,
        args.operation_count,
        args.value_size_bytes,
        args.logical_bytes_per_op,
        args.ycsb_output,
        args.exit_status,
    ]
    write_csv(run_dir / "snapshots" / "phase_metadata.csv", header, [row], append=True)


STOP = False


def _stop_handler(signum: int, frame: object) -> None:
    global STOP
    STOP = True


def collect_os_process_top(run_dir: Path, run_id: str, phase_id: str) -> None:
    header = ["run_id", "phase_id", "timestamp_utc", "source", "pid", "comm", "cpu_pct", "rss_kb", "args"]
    try:
        proc = subprocess.run(["ps", "-eo", "pid=,comm=,%cpu=,rss=,args=", "--sort=-%cpu"], text=True, capture_output=True, timeout=5)
        rows = []
        for line in proc.stdout.splitlines():
            parts = line.strip().split(None, 4)
            if len(parts) < 5:
                continue
            pid, comm, cpu, rss, cmd = parts
            haystack = f"{comm} {cmd}".lower()
            if not any(token in haystack for token in ("postgres", "java", "ycsb")):
                continue
            rows.append([run_id, phase_id, utc_now(), "os_process_top", pid, comm, cpu, rss, redact_secrets(cmd)])
            if len(rows) >= 25:
                break
        write_csv(run_dir / "samples" / "os_process_top.csv", header, rows, append=True)
    except Exception as exc:
        append_log(run_dir, f"os_process_top failed: {exc}", "sampler_errors.log")


def collect_df_free(run_dir: Path, phase_id: str) -> None:
    try:
        proc = subprocess.run(["df", "-h"], text=True, capture_output=True, timeout=5)
        with (run_dir / "samples" / "df_free.log").open("a", encoding="utf-8") as fh:
            fh.write(f"===== {utc_now()} phase_id={phase_id} =====\n")
            fh.write(proc.stdout)
            if proc.stderr:
                fh.write(proc.stderr)
            fh.write("\n")
    except Exception as exc:
        append_log(run_dir, f"df_free failed: {exc}", "sampler_errors.log")


def sample_loop(args: argparse.Namespace) -> None:
    signal.signal(signal.SIGTERM, _stop_handler)
    signal.signal(signal.SIGINT, _stop_handler)
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    interval = max(1.0, float(args.sample_interval_seconds))
    relation_interval = max(interval, float(args.relation_size_sample_interval_seconds))
    last_relation = 0.0

    append_log(run_dir, f"sampler start phase_id={args.phase_id} interval={interval}", "sampler.log")
    while not STOP:
        started = time.time()
        try:
            sample_args = argparse.Namespace(**vars(args))
            sample_args.label = "sample"
            sample_args.output_path = str(run_dir / "samples")
            # Relation sizes are sampled separately so expensive size calls can be throttled.
            for view in [
                "pg_stat_database",
                "pg_stat_user_tables",
                "pg_statio_user_tables",
                "pg_stat_user_indexes",
                "pg_stat_wal",
                "pg_stat_bgwriter",
                "pg_stat_checkpointer",
                "pg_stat_io",
            ]:
                pg = pg_from_args(args)
                collect_view_snapshot(
                    pg,
                    args.db_name,
                    run_dir / "samples",
                    args.run_id,
                    args.phase_id,
                    "sample",
                    view,
                    view,
                    args.target_table,
                    append=True,
                )
            collect_wait_summary(pg_from_args(args), args.db_name, run_dir / "samples", args.run_id, args.phase_id, "sample", append=True)
            if started - last_relation >= relation_interval:
                collect_relation_sizes(pg_from_args(args), args.db_name, run_dir / "samples", args.run_id, args.phase_id, "sample", args.target_table, append=True)
                collect_df_free(run_dir, args.phase_id)
                last_relation = started
            collect_os_process_top(run_dir, args.run_id, args.phase_id)
        except Exception as exc:
            append_log(run_dir, f"sampler iteration failed: {exc}", "sampler_errors.log")
        elapsed = time.time() - started
        time.sleep(max(0.1, interval - elapsed))
    append_log(run_dir, f"sampler stop phase_id={args.phase_id}", "sampler.log")


def to_float(value: object) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if text in ("", "NULL", "null", "None"):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def delta(after: Dict[str, str], before: Dict[str, str], name: str) -> Optional[float]:
    a = to_float(after.get(name))
    b = to_float(before.get(name))
    if a is None or b is None:
        return None
    return a - b


def parse_ycsb_output(path_text: str) -> Dict[str, float]:
    metrics: Dict[str, float] = {}
    if not path_text:
        return metrics
    path = Path(path_text)
    if not path.exists():
        return metrics
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("[") or "]," not in line:
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        op = parts[0].strip("[]").lower()
        metric = parts[1]
        value = to_float(parts[2])
        if value is None:
            continue
        key = f"{op}_{metric}".replace("/", "_").replace("(", "_").replace(")", "").replace("%", "pct").replace(" ", "_")
        key = re.sub(r"[^A-Za-z0-9_]+", "_", key).strip("_").lower()
        metrics[key] = value
    # User-facing aggregate, preferring READ when present.
    for prefix in ("read", "update", "insert", "extend", "overall"):
        if f"{prefix}_95thpercentilelatency_us" in metrics:
            metrics.setdefault("latency_p95_ms", metrics[f"{prefix}_95thpercentilelatency_us"] / 1000.0)
        if f"{prefix}_99thpercentilelatency_us" in metrics:
            metrics.setdefault("latency_p99_ms", metrics[f"{prefix}_99thpercentilelatency_us"] / 1000.0)
        if f"{prefix}_maxlatency_us" in metrics:
            metrics.setdefault("latency_max_ms", metrics[f"{prefix}_maxlatency_us"] / 1000.0)
        if f"{prefix}_operations" in metrics:
            metrics["ops_total"] = metrics.get("ops_total", 0.0) + metrics[f"{prefix}_operations"]
    if "overall_runtime_ms" in metrics:
        metrics["duration_seconds"] = metrics["overall_runtime_ms"] / 1000.0
    if "overall_throughput_ops_sec" in metrics:
        metrics["throughput_ops_per_sec"] = metrics["overall_throughput_ops_sec"]
    return metrics


def read_phase_metadata(run_dir: Path) -> Dict[str, Dict[str, str]]:
    path = run_dir / "snapshots" / "phase_metadata.csv"
    result: Dict[str, Dict[str, str]] = {}
    if not path.exists():
        return result
    with path.open(newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            phase_id = row.get("phase_id", "")
            event = row.get("event", "")
            if not phase_id:
                continue
            current = result.setdefault(phase_id, {})
            current.update({k: v for k, v in row.items() if v not in (None, "")})
            if event == "before":
                current["before_time_utc"] = row.get("timestamp_utc", "")
            if event == "after":
                current["after_time_utc"] = row.get("timestamp_utc", "")
                current["exit_status"] = row.get("exit_status", "")
                current["ycsb_output"] = row.get("ycsb_output", current.get("ycsb_output", ""))
    return result


def read_csv_rows(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8", errors="replace") as fh:
        return list(csv.DictReader(fh))


def percentile_nearest(values: List[float], percentile: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int((percentile / 100.0) * len(ordered) + 0.999999) - 1))
    return ordered[index]


def median(values: List[float]) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def unix_ms_to_utc(value: object) -> str:
    try:
        seconds = float(str(value)) / 1000.0
        return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except Exception:
        return ""


def build_spike_windows(run_dir: Path, run_id: str, metadata: Dict[str, Dict[str, str]]) -> List[List[object]]:
    phase_lookup: Dict[Tuple[str, str], str] = {}
    for phase_id, meta in metadata.items():
        key = (meta.get("phase_name", ""), meta.get("epoch", ""))
        if key[0] and key[1] and key not in phase_lookup:
            phase_lookup[key] = phase_id

    grouped: Dict[Tuple[str, str], List[Dict[str, object]]] = {}
    sample_files = [
        path
        for path in sorted((run_dir / "logs" / "toast_spike_trigger").glob("*_read_sample.csv"))
        if not path.name.endswith("_slow_read_sample.csv")
    ]
    for sample_path in sample_files:
        for row in read_csv_rows(sample_path):
            latency_us = to_float(row.get("latency_us"))
            timestamp_ms = to_float(row.get("timestamp_unix_ms"))
            phase = row.get("phase", "")
            epoch = row.get("epoch", "")
            if latency_us is None or timestamp_ms is None or not phase or not epoch:
                continue
            grouped.setdefault((phase, epoch), []).append(
                {
                    "latency_ms": latency_us / 1000.0,
                    "timestamp_ms": timestamp_ms,
                }
            )

    if not grouped:
        return [[run_id, "", "", "", 0, "", "", "", "no timestamped read samples found"]]

    rows: List[List[object]] = []
    for key, samples in sorted(grouped.items()):
        latencies = [float(sample["latency_ms"]) for sample in samples]
        p99 = percentile_nearest(latencies, 99.0)
        max_latency = max(latencies) if latencies else None
        med = median(latencies)
        deviations = [abs(value - (med or 0.0)) for value in latencies]
        mad = median(deviations) or 0.0
        threshold = max(value for value in [p99, (med or 0.0) + 6.0 * mad] if value is not None)
        spikes = [sample for sample in samples if float(sample["latency_ms"]) >= threshold]
        phase_id = phase_lookup.get(key, f"{key[0]}_{key[1]}")
        if spikes:
            start_ms = min(float(sample["timestamp_ms"]) for sample in spikes)
            end_ms = max(float(sample["timestamp_ms"]) for sample in spikes)
            rows.append(
                [
                    run_id,
                    phase_id,
                    unix_ms_to_utc(start_ms),
                    unix_ms_to_utc(end_ms),
                    len(spikes),
                    fmt(max_latency),
                    fmt(p99),
                    key[0].upper(),
                    f"inferred_threshold_ms={fmt(threshold)} samples={len(samples)} source=read_sample",
                ]
            )
        else:
            rows.append([run_id, phase_id, "", "", 0, fmt(max_latency), fmt(p99), key[0].upper(), f"no samples exceeded inferred_threshold_ms={fmt(threshold)}"])
    return rows


def read_first_data_row(path: Path) -> Dict[str, str]:
    rows = read_csv_rows(path)
    return rows[0] if rows else {}


def row_matches(row: Dict[str, str], filters: Dict[str, str]) -> bool:
    for key, expected in filters.items():
        if row.get(key, "").strip().lower() != expected.lower():
            return False
    return True


def filtered_sum(rows: List[Dict[str, str]], column: str, filters: Dict[str, str]) -> Optional[float]:
    matched = False
    total = 0.0
    for row in rows:
        if not row_matches(row, filters):
            continue
        value = to_float(row.get(column))
        if value is None:
            continue
        matched = True
        total += value
    return total if matched else None


def filtered_delta(after_rows: List[Dict[str, str]], before_rows: List[Dict[str, str]], column: str, filters: Dict[str, str]) -> Optional[float]:
    after_sum = filtered_sum(after_rows, column, filters)
    before_sum = filtered_sum(before_rows, column, filters)
    if after_sum is None and before_sum is None:
        return None
    return (after_sum or 0.0) - (before_sum or 0.0)


def fmt(value: Optional[float]) -> str:
    if value is None:
        return ""
    if abs(value - int(value)) < 0.000001:
        return str(int(value))
    return f"{value:.6f}".rstrip("0").rstrip(".")


def safe_div(n: Optional[float], d: Optional[float]) -> Optional[float]:
    if n is None or d is None or d == 0:
        return None
    return n / d


def derive(args: argparse.Namespace) -> None:
    run_dir = Path(args.run_dir)
    ensure_dirs(run_dir)
    derived_dir = run_dir / "derived"
    derived_dir.mkdir(parents=True, exist_ok=True)
    metadata = read_phase_metadata(run_dir)

    columns = [
        "run_id",
        "phase_id",
        "phase_name",
        "db_name",
        "ops_total",
        "duration_seconds",
        "throughput_ops_per_sec",
        "latency_p50_ms",
        "latency_p95_ms",
        "latency_p99_ms",
        "latency_max_ms",
        "total_storage_growth_bytes",
        "heap_growth_bytes",
        "index_growth_bytes",
        "toast_heap_growth_bytes",
        "toast_total_growth_bytes",
        "storage_growth_per_op",
        "storage_growth_per_logical_byte",
        "toast_storage_fraction_before",
        "toast_storage_fraction_after",
        "wal_bytes_delta",
        "wal_records_delta",
        "wal_fpi_delta",
        "wal_buffers_full_delta",
        "wal_bytes_per_op",
        "wal_bytes_per_logical_byte",
        "wal_records_per_op",
        "wal_fpi_per_op",
        "tup_inserted_delta",
        "tup_updated_delta",
        "tup_deleted_delta",
        "dead_tuples_delta",
        "n_dead_tup_after",
        "hot_updates_delta",
        "newpage_updates_delta",
        "hot_update_ratio",
        "newpage_update_ratio",
        "dead_tuples_per_update",
        "heap_blocks_touched_delta",
        "index_blocks_touched_delta",
        "toast_blocks_touched_delta",
        "toast_index_blocks_touched_delta",
        "heap_blocks_per_op",
        "index_blocks_per_op",
        "toast_blocks_per_op",
        "toast_index_blocks_per_op",
        "toast_block_fraction",
        "buffers_clean_delta",
        "buffers_alloc_delta",
        "maxwritten_clean_delta",
        "checkpoint_buffers_written_delta",
        "checkpoint_write_time_delta",
        "checkpoint_sync_time_delta",
        "checkpoint_write_time_per_op",
        "checkpoint_sync_time_per_op",
        "client_backend_relation_reads_delta",
        "client_backend_relation_writes_delta",
        "client_backend_relation_fsyncs_delta",
        "client_backend_relation_evictions_delta",
        "wal_writes_delta",
        "wal_fsyncs_delta",
        "read_time_delta",
        "write_time_delta",
        "fsync_time_delta",
        "p99_latency_ms_per_kb",
        "total_physical_bytes_per_logical_byte",
    ]
    rows = []
    for phase_id, meta in sorted(metadata.items()):
        safe = meta.get("phase_dir") or safe_name(phase_id)
        before_dir = run_dir / "snapshots" / f"phase_{safe}_before"
        after_dir = run_dir / "snapshots" / f"phase_{safe}_after"
        if not before_dir.exists() or not after_dir.exists():
            continue

        before_db = read_first_data_row(before_dir / "pg_stat_database.csv")
        after_db = read_first_data_row(after_dir / "pg_stat_database.csv")
        before_wal = read_first_data_row(before_dir / "pg_stat_wal.csv")
        after_wal = read_first_data_row(after_dir / "pg_stat_wal.csv")
        before_bg = read_first_data_row(before_dir / "pg_stat_bgwriter.csv")
        after_bg = read_first_data_row(after_dir / "pg_stat_bgwriter.csv")
        before_checkpointer = read_first_data_row(before_dir / "pg_stat_checkpointer.csv")
        after_checkpointer = read_first_data_row(after_dir / "pg_stat_checkpointer.csv")
        before_tbl = read_first_data_row(before_dir / "pg_stat_user_tables.csv")
        after_tbl = read_first_data_row(after_dir / "pg_stat_user_tables.csv")
        before_statio = read_first_data_row(before_dir / "pg_statio_user_tables.csv")
        after_statio = read_first_data_row(after_dir / "pg_statio_user_tables.csv")
        before_size = read_first_data_row(before_dir / "relation_sizes.csv")
        after_size = read_first_data_row(after_dir / "relation_sizes.csv")
        before_io_rows = read_csv_rows(before_dir / "pg_stat_io.csv")
        after_io_rows = read_csv_rows(after_dir / "pg_stat_io.csv")

        ycsb = parse_ycsb_output(meta.get("ycsb_output", ""))
        ops = ycsb.get("ops_total") or to_float(meta.get("operation_count"))
        logical_bytes_per_op = to_float(meta.get("logical_bytes_per_op"))
        logical_bytes = ops * logical_bytes_per_op if ops is not None and logical_bytes_per_op is not None else None

        heap_growth = delta(after_size, before_size, "heap_bytes")
        index_growth = delta(after_size, before_size, "index_bytes")
        toast_heap_growth = delta(after_size, before_size, "toast_heap_bytes")
        toast_total_growth = delta(after_size, before_size, "toast_total_bytes")
        total_growth = delta(after_size, before_size, "total_bytes")
        wal_bytes = delta(after_wal, before_wal, "wal_bytes")
        wal_records = delta(after_wal, before_wal, "wal_records")
        wal_fpi = delta(after_wal, before_wal, "wal_fpi")
        wal_buffers_full = delta(after_wal, before_wal, "wal_buffers_full")
        tup_ins = delta(after_db, before_db, "tup_inserted")
        tup_upd = delta(after_db, before_db, "tup_updated")
        tup_del = delta(after_db, before_db, "tup_deleted")
        hot = delta(after_tbl, before_tbl, "n_tup_hot_upd")
        newpage = delta(after_tbl, before_tbl, "n_tup_newpage_upd")
        n_dead_after = to_float(after_tbl.get("n_dead_tup"))
        n_dead_before = to_float(before_tbl.get("n_dead_tup"))
        dead_delta = None if n_dead_after is None or n_dead_before is None else n_dead_after - n_dead_before

        heap_blocks = (delta(after_statio, before_statio, "heap_blks_read") or 0) + (delta(after_statio, before_statio, "heap_blks_hit") or 0)
        index_blocks = (delta(after_statio, before_statio, "idx_blks_read") or 0) + (delta(after_statio, before_statio, "idx_blks_hit") or 0)
        toast_blocks = (delta(after_statio, before_statio, "toast_blks_read") or 0) + (delta(after_statio, before_statio, "toast_blks_hit") or 0)
        toast_index_blocks = (delta(after_statio, before_statio, "tidx_blks_read") or 0) + (delta(after_statio, before_statio, "tidx_blks_hit") or 0)
        block_total = heap_blocks + index_blocks + toast_blocks + toast_index_blocks

        checkpoint_buffers_written = delta(after_checkpointer, before_checkpointer, "buffers_written")
        checkpoint_write_time = delta(after_checkpointer, before_checkpointer, "write_time")
        checkpoint_sync_time = delta(after_checkpointer, before_checkpointer, "sync_time")
        if checkpoint_buffers_written is None:
            checkpoint_buffers_written = delta(after_bg, before_bg, "buffers_checkpoint")
        if checkpoint_write_time is None:
            checkpoint_write_time = delta(after_bg, before_bg, "checkpoint_write_time")
        if checkpoint_sync_time is None:
            checkpoint_sync_time = delta(after_bg, before_bg, "checkpoint_sync_time")

        client_relation = {"backend_type": "client backend", "object": "relation"}
        wal_io = {"object": "wal"}
        client_reads = filtered_delta(after_io_rows, before_io_rows, "reads", client_relation)
        client_writes = filtered_delta(after_io_rows, before_io_rows, "writes", client_relation)
        client_fsyncs = filtered_delta(after_io_rows, before_io_rows, "fsyncs", client_relation)
        client_evictions = filtered_delta(after_io_rows, before_io_rows, "evictions", client_relation)
        client_read_time = filtered_delta(after_io_rows, before_io_rows, "read_time", client_relation)
        client_write_time = filtered_delta(after_io_rows, before_io_rows, "write_time", client_relation)
        client_fsync_time = filtered_delta(after_io_rows, before_io_rows, "fsync_time", client_relation)
        wal_writes = filtered_delta(after_io_rows, before_io_rows, "writes", wal_io)
        wal_fsyncs = filtered_delta(after_io_rows, before_io_rows, "fsyncs", wal_io)

        row = {
            "run_id": args.run_id,
            "phase_id": phase_id,
            "phase_name": meta.get("phase_name", ""),
            "db_name": meta.get("db_name", ""),
            "ops_total": fmt(ops),
            "duration_seconds": fmt(ycsb.get("duration_seconds")),
            "throughput_ops_per_sec": fmt(ycsb.get("throughput_ops_per_sec")),
            "latency_p50_ms": "",
            "latency_p95_ms": fmt(ycsb.get("latency_p95_ms")),
            "latency_p99_ms": fmt(ycsb.get("latency_p99_ms")),
            "latency_max_ms": fmt(ycsb.get("latency_max_ms")),
            "total_storage_growth_bytes": fmt(total_growth),
            "heap_growth_bytes": fmt(heap_growth),
            "index_growth_bytes": fmt(index_growth),
            "toast_heap_growth_bytes": fmt(toast_heap_growth),
            "toast_total_growth_bytes": fmt(toast_total_growth),
            "storage_growth_per_op": fmt(safe_div(total_growth, ops)),
            "storage_growth_per_logical_byte": fmt(safe_div(total_growth, logical_bytes)),
            "toast_storage_fraction_before": before_size.get("toast_fraction", ""),
            "toast_storage_fraction_after": after_size.get("toast_fraction", ""),
            "wal_bytes_delta": fmt(wal_bytes),
            "wal_records_delta": fmt(wal_records),
            "wal_fpi_delta": fmt(wal_fpi),
            "wal_buffers_full_delta": fmt(wal_buffers_full),
            "wal_bytes_per_op": fmt(safe_div(wal_bytes, ops)),
            "wal_bytes_per_logical_byte": fmt(safe_div(wal_bytes, logical_bytes)),
            "wal_records_per_op": fmt(safe_div(wal_records, ops)),
            "wal_fpi_per_op": fmt(safe_div(wal_fpi, ops)),
            "tup_inserted_delta": fmt(tup_ins),
            "tup_updated_delta": fmt(tup_upd),
            "tup_deleted_delta": fmt(tup_del),
            "dead_tuples_delta": fmt(dead_delta),
            "n_dead_tup_after": fmt(n_dead_after),
            "hot_updates_delta": fmt(hot),
            "newpage_updates_delta": fmt(newpage),
            "hot_update_ratio": fmt(safe_div(hot, tup_upd)),
            "newpage_update_ratio": fmt(safe_div(newpage, tup_upd)),
            "dead_tuples_per_update": fmt(safe_div(dead_delta, tup_upd)),
            "heap_blocks_touched_delta": fmt(heap_blocks),
            "index_blocks_touched_delta": fmt(index_blocks),
            "toast_blocks_touched_delta": fmt(toast_blocks),
            "toast_index_blocks_touched_delta": fmt(toast_index_blocks),
            "heap_blocks_per_op": fmt(safe_div(heap_blocks, ops)),
            "index_blocks_per_op": fmt(safe_div(index_blocks, ops)),
            "toast_blocks_per_op": fmt(safe_div(toast_blocks, ops)),
            "toast_index_blocks_per_op": fmt(safe_div(toast_index_blocks, ops)),
            "toast_block_fraction": fmt(safe_div(toast_blocks + toast_index_blocks, block_total)),
            "buffers_clean_delta": fmt(delta(after_bg, before_bg, "buffers_clean")),
            "buffers_alloc_delta": fmt(delta(after_bg, before_bg, "buffers_alloc")),
            "maxwritten_clean_delta": fmt(delta(after_bg, before_bg, "maxwritten_clean")),
            "checkpoint_buffers_written_delta": fmt(checkpoint_buffers_written),
            "checkpoint_write_time_delta": fmt(checkpoint_write_time),
            "checkpoint_sync_time_delta": fmt(checkpoint_sync_time),
            "checkpoint_write_time_per_op": fmt(safe_div(checkpoint_write_time, ops)),
            "checkpoint_sync_time_per_op": fmt(safe_div(checkpoint_sync_time, ops)),
            "client_backend_relation_reads_delta": fmt(client_reads),
            "client_backend_relation_writes_delta": fmt(client_writes),
            "client_backend_relation_fsyncs_delta": fmt(client_fsyncs),
            "client_backend_relation_evictions_delta": fmt(client_evictions),
            "wal_writes_delta": fmt(wal_writes),
            "wal_fsyncs_delta": fmt(wal_fsyncs),
            "read_time_delta": fmt(client_read_time),
            "write_time_delta": fmt(client_write_time),
            "fsync_time_delta": fmt(client_fsync_time),
            "p99_latency_ms_per_kb": fmt(safe_div(ycsb.get("latency_p99_ms"), safe_div(logical_bytes_per_op, 1024.0))),
            "total_physical_bytes_per_logical_byte": fmt(safe_div((total_growth or 0) + (wal_bytes or 0), logical_bytes)),
        }
        rows.append(row)

    write_csv(derived_dir / "phase_deltas.csv", columns, [[row.get(c, "") for c in columns] for row in rows])
    write_csv(derived_dir / "normalized_metrics.csv", columns, [[row.get(c, "") for c in columns] for row in rows])
    spike_rows = build_spike_windows(run_dir, args.run_id, metadata)
    write_csv(
        derived_dir / "spike_windows.csv",
        ["run_id", "phase_id", "start_time_utc", "end_time_utc", "spike_count", "max_latency_ms", "p99_latency_ms", "operation_type", "message"],
        spike_rows,
    )

    preflight_path = run_dir / "sql" / "preflight.json"
    unavailable = []
    expected_unavailable = []
    unexpected_unavailable = []
    compatibility_notes = []
    postgres_major = None
    if preflight_path.exists():
        try:
            preflight_data = json.loads(preflight_path.read_text(encoding="utf-8"))
            postgres_major = preflight_data.get("postgres_major_version") or postgres_major_from_version(preflight_data.get("postgres_version", ""))
            unavailable = [k for k, v in preflight_data.get("stats_views", {}).items() if not v.get("available")]
            if isinstance(postgres_major, int):
                if postgres_major < 16 and "pg_stat_io" in unavailable:
                    expected_unavailable.append("pg_stat_io")
                    compatibility_notes.append("pg_stat_io is PostgreSQL 16+; I/O interpretation falls back to pg_stat_database, pg_statio_* and OS metrics.")
                if postgres_major < 17 and "pg_stat_checkpointer" in unavailable:
                    expected_unavailable.append("pg_stat_checkpointer")
                    compatibility_notes.append("pg_stat_checkpointer is PostgreSQL 17+; checkpoint deltas are sourced from pg_stat_bgwriter on this server.")
            unexpected_unavailable = [name for name in unavailable if name not in set(expected_unavailable)]
        except Exception:
            unavailable = []
            expected_unavailable = []
            unexpected_unavailable = []
    summary_lines = [
        f"# Benchmark Observability Summary",
        "",
        f"- run_id: {args.run_id}",
        f"- generated_utc: {utc_now()}",
        f"- postgresql_major_version: {postgres_major if postgres_major is not None else 'unknown'}",
        f"- phases_with_deltas: {len(rows)}",
        f"- spike_windows: {sum(1 for row in spike_rows if str(row[4]) != '0')}",
        f"- unavailable_metrics: {', '.join(unavailable) if unavailable else 'none recorded'}",
        f"- expected_unavailable_metrics: {', '.join(expected_unavailable) if expected_unavailable else 'none recorded'}",
        f"- unexpected_unavailable_metrics: {', '.join(unexpected_unavailable) if unexpected_unavailable else 'none recorded'}",
        "",
        "These metrics are phase-level deltas from cumulative PostgreSQL counters. They are consistent with changes during the phase, but do not by themselves prove causality.",
        "",
    ]
    if compatibility_notes:
        summary_lines.extend(["## Compatibility Notes", ""])
        summary_lines.extend([f"- {note}" for note in compatibility_notes])
        summary_lines.append("")
    summary_lines.extend(["## Phase Highlights", ""])
    for row in rows[:50]:
        summary_lines.append(
            f"- {row['phase_id']}: wal_bytes/op={row.get('wal_bytes_per_op','')}, "
            f"storage/logical_byte={row.get('storage_growth_per_logical_byte','')}, "
            f"toast_blocks/op={row.get('toast_blocks_per_op','')}, "
            f"hot_update_ratio={row.get('hot_update_ratio','')}, "
            f"p99_ms={row.get('latency_p99_ms','')}"
        )
    summary_lines.extend(
        [
            "",
            "Spike windows are inferred from timestamped JDBC read samples when read sampling is enabled. Treat them as alignment hints, not causal proof.",
        ]
    )
    (derived_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--run-dir", required=True)
        p.add_argument("--run-id", required=True)
        p.add_argument("--db-name", required=True)
        p.add_argument("--db-user", required=True)
        p.add_argument("--db-password-env", default="DB_PWD")
        p.add_argument("--target-table", default="usertable")

    p = sub.add_parser("manifest-init")
    common(p)
    p.add_argument("--script-path", required=True)
    p.add_argument("--repo-root", required=True)
    p.add_argument("--workload-file", required=True)
    p.add_argument("--command-line", default="")
    p.add_argument("--db-url", default="")
    p.add_argument("--type-name", default="")
    p.add_argument("--dist", default="")
    p.add_argument("--scale", default="")
    p.add_argument("--work", default="")
    p.add_argument("--run-number", default="")
    p.add_argument("--value-variant", default="")
    p.add_argument("--ycsb-binding", default="")
    p.add_argument("--field-sql-type", default="")
    p.add_argument("--sample-interval-seconds", default="5")
    p.add_argument("--relation-size-sample-interval-seconds", default="30")
    p.add_argument("--inspect-wal-ranges", default="0")
    p.add_argument("--full-visibility-profile", default="0")
    p.add_argument("--require-full-visibility", default="0")
    p.add_argument("--pg-prewarm-enabled", default="0")
    p.add_argument("--pg-prewarm-mode", default="")
    p.add_argument("--reset-pg-stats-before-run", default="0")
    p.add_argument("--skip-continuous-sampling", default="0")
    p.add_argument("--phase-value-sizes", default="")
    p.add_argument("--output-csv", default="")
    p.add_argument("--log-file", default="")
    p.add_argument("--plan-log", default="")
    p.add_argument("--key-size-log", default="")

    p = sub.add_parser("manifest-finish")
    common(p)
    p.add_argument("--exit-status", required=True)

    p = sub.add_parser("preflight")
    common(p)

    p = sub.add_parser("reset-stats")
    common(p)

    p = sub.add_parser("phase")
    common(p)
    p.add_argument("--phase-id", required=True)
    p.add_argument("--phase-name", required=True)
    p.add_argument("--epoch", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--operation-count", default="")
    p.add_argument("--value-size-bytes", default="")
    p.add_argument("--logical-bytes-per-op", default="")
    p.add_argument("--ycsb-output", default="")
    p.add_argument("--exit-status", default="")

    p = sub.add_parser("snapshot")
    common(p)
    p.add_argument("--phase-id", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--output-path", default="")

    p = sub.add_parser("sample")
    common(p)
    p.add_argument("--phase-id", required=True)
    p.add_argument("--sample-interval-seconds", default="5")
    p.add_argument("--relation-size-sample-interval-seconds", default="30")

    p = sub.add_parser("derive")
    common(p)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "manifest-init":
            manifest_init(args)
        elif args.command == "manifest-finish":
            manifest_finish(args)
        elif args.command == "preflight":
            preflight(args)
        elif args.command == "reset-stats":
            reset_stats(args)
        elif args.command == "phase":
            phase_metadata(args)
        elif args.command == "snapshot":
            collect_snapshot(args)
        elif args.command == "sample":
            sample_loop(args)
        elif args.command == "derive":
            derive(args)
        else:
            parser.error(f"unknown command {args.command}")
    except Exception as exc:
        run_dir = Path(getattr(args, "run_dir", "."))
        append_log(run_dir, f"{args.command} failed: {exc}", "observability_errors.log")
        print(f"benchmark_observability.py: {args.command} failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
