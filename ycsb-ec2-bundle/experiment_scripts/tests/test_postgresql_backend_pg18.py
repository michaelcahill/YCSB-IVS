"""PostgreSQL backend regression tests: preflight ordering, dump/restore, metrics and CSV
shape. Every database and OS command is a mock, so no server is needed.

Run: python3 -m unittest discover -s experiment_scripts/tests -v

The tests drive the real stack (experiment.sh + lib/ + lib/backends/postgresql_textarray.sh)
inside a throwaway YCSB_HOME whose build artifacts, launcher and CLI tools are stubs. That
is deliberate: preflight ordering only matters for the entry point users actually run.
"""
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
BACKEND = "postgresql_textarray"

# Stand-ins for psql/createdb/dropdb/pg_dump/ps/java. They record every invocation so a
# test can assert on ORDER (e.g. "no database is dropped before preflight passes").
MOCK_CLI = r'''
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("MOCK_MODE", "ok")
with open(os.environ["MOCK_TRACE"], "a") as trace:
    trace.write(json.dumps([tool, args]) + "\n")
if "--version" in args:
    major = "17" if (mode == "old_client" or (mode == "old_dump" and tool == "pg_dump")) else "18"
    print(f"{tool} (PostgreSQL) {major}.1")
elif tool == "psql":
    assert "-X" in args and "ON_ERROR_STOP=1" in args
    assert "--no-password" in args
    assert "--host=" + os.environ.get("DB_HOST", "localhost") in args
    assert "--port=" + os.environ.get("DB_PORT", "5432") in args
    if mode == "connection_failure":
        sys.exit(2)
    if "-f" in args:
        if mode == "restore_failure":
            print("mock restore SQL error", file=sys.stderr)
            sys.exit(3)
        sys.exit(0)
    if "-c" not in args:
        sys.exit(0)
    sql = args[args.index("-c") + 1]
    if "server_version_num" in sql:
        print("170000" if mode == "old_server" else "180001")
    elif "pg_catalog.pg_roles" in sql:
        print("f" if mode == "no_createdb" else "t")
    elif "pg_has_role" in sql:
        if mode == "wrong_owner":
            print("f")
    elif "track_counts" in sql:
        print("off" if mode == "no_track_counts" else "on")
    elif "pg_relation_size" in sql or "relfilenode" in sql:
        # Relation size sampling: one small heap row plus its index.
        print("usertable|table|8192|8192 bytes")
        print("usertable_pkey|index|16384|16 kB")
    elif "pg_stat_checkpointer" in sql:
        if mode == "metrics_failure":
            print("mock metrics SQL error", file=sys.stderr)
            sys.exit(1)
        # Mirror whatever column count the runner asked for, so the mock keeps
        # working when the metrics query changes.
        ncols = sql[sql.index("SELECT") + len("SELECT"):sql.index("FROM pg_catalog")].count(",") + 1
        values = [str(i) for i in range(1, ncols + 1)]
        if mode == "empty_metrics":
            sys.exit(0)
        if mode == "short_metrics":
            values.pop()
        if mode == "null_metric":
            values[5] = ""
        print("|".join(values))
        if mode == "multiple_metrics":
            print("|".join(values))
    elif "count(*) FROM usertable" in sql:
        db = args[args.index("-d") + 1]
        print("4" if mode == "row_mismatch" and db == "ycsb_backup" else "5")
    else:
        raise AssertionError("Unexpected SQL in mock: " + sql)
elif tool == "pg_dump":
    if mode == "dump_failure":
        print("mock dump failure", file=sys.stderr)
        sys.exit(1)
    assert "--clean" not in args
    print("-- mock dump")
elif tool == "dropdb" and os.environ.get("MOCK_STOP_AT_DROP") == "1":
    # Full-runner probes must never advance into the real workload.
    sys.exit(99)
'''


class PostgreSQLBackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        # A throwaway YCSB_HOME containing the real runner stack.
        self.scripts = self.root / "experiment_scripts"
        self.scripts.mkdir()
        shutil.copyfile(SCRIPTS / "experiment.sh", self.scripts / "experiment.sh")
        shutil.copytree(SCRIPTS / "lib", self.scripts / "lib")

        for name in ("core/target/core.jar", "core/target/dependency/dependency.jar",
                     "jdbc-array/target/array.jar",
                     "jdbc-array/target/dependency/postgresql-mock.jar",
                     "jdbc-binding/conf/postgres.properties"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

        (self.root / "workloads").mkdir()
        (self.root / "workloads/workloada-extend").write_text(
            "recordcount=5\noperationcount=2\nreadallfields=true\nrequestdistribution=uniform\n"
            "readproportion=1\nupdateproportion=0\nscanproportion=0\ninsertproportion=0\nextendproportion=0\n")

        (self.root / "bin").mkdir()
        launcher = self.root / "bin/ycsb.sh"
        launcher.write_text("#!/bin/sh\nexit 98\n")     # never reached: probes stop earlier
        launcher.chmod(0o755)

        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        for tool in ("psql", "createdb", "dropdb", "pg_dump", "ps", "java", "bc"):
            path = self.mockbin / tool
            path.write_text("#!" + sys.executable + "\n" + MOCK_CLI)
            path.chmod(0o755)

        self.trace = self.root / "trace.jsonl"
        self.env = dict(os.environ, PATH=str(self.mockbin) + os.pathsep + os.environ["PATH"],
                        MOCK_TRACE=str(self.trace), DB_HOST="localhost", DB_PORT="5432",
                        PG_MAINTENANCE_DB="postgres")

    # --- helpers -------------------------------------------------------------

    def run_bash(self, code, mode="ok", **extra):
        return subprocess.run(["bash", "-c", code], cwd=self.scripts,
                              env=dict(self.env, MOCK_MODE=mode, **extra),
                              capture_output=True, text=True, timeout=20)

    def run_runner(self, mode="ok", **extra):
        """Run the real entry point; MOCK_STOP_AT_DROP makes the mock abort the first
        time the runner tries to drop a database."""
        env = dict(EXPERIMENT_DIR=str(self.root / "exp"),
                   WORKLOAD_FILE=str(self.root / "workloads/workloada-extend"),
                   DB_PWD="mock_password", TYPE="mock", NUM_EPOCHS="1",
                   STEPS_PER_EPOCH="1", COMPARISON_INTERVAL="1", **extra)
        return self.run_bash("bash experiment.sh " + BACKEND, mode, **env)

    def harness(self, body):
        """Load the runner stack the way experiment.sh does, then run `body`."""
        return (
            "set -euo pipefail\n"
            f"cd {self.scripts}\n"
            # What experiment.sh normally prepares before sourcing the libraries.
            f"export YCSB_HOME={self.root} SCRIPT_DIR={self.scripts}\n"
            f"export YCSB={self.root}/bin/ycsb.sh CONF_DIR={self.scripts}/conf\n"
            f'export WORKLOAD_FILE="${{WORKLOAD_FILE:-{self.root}/workloads/workloada-extend}}"\n'
            f'export EXPERIMENT_DIR="${{EXPERIMENT_DIR:-{self.root}/exp}}"\n'
            "source lib/common.sh; source lib/metrics.sh; source lib/registry.sh\n"
            "source lib/config.sh; source lib/results.sh; source lib/keysizes.sh\n"
            "source lib/workload.sh\n"
            f"registry::load {BACKEND}\n"
            "DB_USERNAME=mock_user DB_PWD=mock_password\n"
            "export DB_NAME=ycsb BACKUP_DB_NAME=ycsb_backup UNCHANGED_DB_NAME=ycsb_unchange\n"
            "export BACKUP_FILE=dump.sql RESTORE_LOG=restore.log\n"
            "config::init_defaults; config::derive_paths\n"
            + body
        )

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    # --- preflight must be read-only and complete before anything is dropped --

    def test_preflight_failures_never_reach_dropdb(self):
        for mode in ("old_client", "old_server", "connection_failure", "no_createdb",
                     "wrong_owner", "metrics_failure", "empty_metrics", "short_metrics",
                     "null_metric", "multiple_metrics"):
            with self.subTest(mode=mode):
                self.trace.write_text("")
                r = self.run_runner(mode, MOCK_STOP_AT_DROP="1")
                self.assertNotEqual(r.returncode, 0)
                self.assertNotEqual(r.returncode, 99, r.stderr)
                self.assertFalse(any(t == "dropdb" and "--version" not in a for t, a in self.calls()),
                                 "a database was dropped despite the preflight failure")
                # Logging starts before preflight so the failure is recorded rather than
                # only echoed; the log must therefore exist and name the failed step.
                logs = list(self.root.glob("exp/**/*results.log"))
                self.assertEqual(len(logs), 1, "expected exactly one run log")
                text = logs[0].read_text()
                self.assertIn("START preflight", text)
                self.assertIn("ERROR", text)

    def test_successful_preflight_reaches_initialization(self):
        self.trace.write_text("")
        r = self.run_runner(MOCK_STOP_AT_DROP="1")
        self.assertEqual(r.returncode, 99, r.stderr)
        calls = self.calls()
        metric_at = next(i for i, (t, a) in enumerate(calls)
                         if t == "psql" and any("pg_stat_checkpointer" in x for x in a))
        drop_at = next(i for i, (t, a) in enumerate(calls)
                       if t == "dropdb" and "--version" not in a)
        self.assertLess(metric_at, drop_at)

    def test_missing_build_artifact_stops_before_initialization(self):
        (self.root / "jdbc-array/target/array.jar").unlink()
        r = self.run_runner(MOCK_STOP_AT_DROP="1")
        self.assertIn("Missing build artifact", r.stdout + r.stderr)
        self.assertNotEqual(r.returncode, 99)

    def test_dump_version_checked_only_when_needed(self):
        # The runner dumps, so a pre-18 pg_dump must be rejected...
        r = self.run_runner("old_dump", MOCK_STOP_AT_DROP="1")
        self.assertIn("pg_dump must be PostgreSQL 18", r.stdout + r.stderr)
        self.assertNotEqual(r.returncode, 99)

        # ... and a caller that passes needs_dump=false must not require it.
        body = ("PG_MAINTENANCE_DB=postgres; TARGET_TABLE=usertable\n"
                "log() { case \"$*\" in START*|END*) ;; *) echo \"$*\" >&2;; esac; }\n"
                "backend::preflight false ycsb ycsb_unchange\n"
                "printf 'PREFLIGHT_OK\\n'\n")
        r = self.run_bash(self.harness(body), "old_dump")
        self.assertNotIn("pg_dump must be PostgreSQL 18", r.stdout + r.stderr)
        self.assertIn("PREFLIGHT_OK", r.stdout)

    # --- metrics and dump/restore -------------------------------------------

    def test_metrics_sql_failure_is_fatal(self):
        r = self.run_bash(self.harness(
            "backend::collect_metrics ycsb\nprintf 'SHOULD_NOT_RUN'\n"), "metrics_failure")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("SHOULD_NOT_RUN", r.stdout)

    def test_restore_success_and_failure_handling(self):
        for mode in ("ok", "dump_failure", "restore_failure", "row_mismatch"):
            with self.subTest(mode=mode):
                self.trace.write_text("")
                r = self.run_bash(self.harness(
                    "backend::dump_restore\nprintf 'VERIFIED'\n"), mode)
                if mode == "ok":
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertIn("Restore verified: 5 rows",
                                  (self.scripts / "restore.log").read_text())
                else:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotIn("VERIFIED", r.stdout)
                    self.assertTrue((self.scripts / "dump.sql").exists())
                    if mode == "dump_failure":
                        self.assertFalse(any(t == "dropdb" for t, _ in self.calls()))
                    if mode == "restore_failure":
                        self.assertIn("mock restore SQL error",
                                      (self.scripts / "restore.log").read_text())

    # --- results CSV ---------------------------------------------------------

    def test_csv_headers_and_values_stay_aligned(self):
        ycsb_output = self.root / "ycsb_summary.txt"
        ycsb_output.write_text(
            "[OVERALL], RunTime(ms), 1\n"
            "[OVERALL], Throughput(ops/sec), 2\n"
            "[INSERT], Operations, 5\n"
            "[INSERT], AverageLatency(us), 10\n"
            "[INSERT], Return=OK, 5\n")
        body = (
            "config::derive_paths\n"
            # derive_paths picks INPUT_FILE from the log directory; the probe supplies a
            # captured YCSB summary instead.
            f"export INPUT_FILE={ycsb_output}\n"
            "mkdir -p \"$(dirname \"$OUTPUT_FILE\")\"\n"
            "cpu=1; memory=2; phase=load; epoch=0; step=0; iteration=0\n"
            "backend::collect_metrics ycsb\n"
            "write_result TRUE\n"
            "phase=run; epoch=1; step=1\n"
            "write_result FALSE\n"
        )
        r = self.run_bash(self.harness(body))
        self.assertEqual(r.returncode, 0, r.stderr)

        output = next((self.root / "exp").glob("**/workload_data/*.csv"))
        with output.open() as stream:
            rows = list(csv.reader(stream))
        self.assertEqual(len(rows), 3)
        self.assertEqual(len(rows[0]), len(set(rows[0])), "duplicate CSV column names")
        stats_start = rows[0].index("blks_read")
        stats_end = rows[0].index("Readprop")
        for row in rows[1:]:
            self.assertEqual(len(row), len(rows[0]))
            # The mock echoes 1..N in SELECT order, so the statistics block must be
            # exactly 1..N in header order. This checks header/value alignment without
            # hardcoding a column list that differs between backends and PG versions.
            stats = row[stats_start:stats_end]
            self.assertEqual(stats, [str(i) for i in range(1, len(stats) + 1)],
                             "statistics columns are misaligned with their values")


if __name__ == "__main__":
    unittest.main()
