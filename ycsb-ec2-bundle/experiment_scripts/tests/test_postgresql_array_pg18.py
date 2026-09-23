"""PG18 runner regression tests. All database/OS commands are isolated mocks.

Run: python3 -m unittest discover -s experiment_scripts/tests -v
"""
import csv
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
# experiment_postgresql_array_baseline.sh is deliberately excluded: it still
# expects the pre-PG16 pg_stat_bgwriter column `buffers_backend` and therefore
# cannot pass a PG18 preflight at all. It is replaced by `--mode baseline` in
# the refactor (REFACTOR_PLAN.md step 6), so repairing it is not worthwhile.
RUNNERS = ("experiment_postgresql_array.sh",)
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


class PG18RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / "experiment_scripts"
        self.scripts.mkdir()
        for name in RUNNERS:
            shutil.copyfile(SCRIPTS / name, self.scripts / name)
        # No real database, Java process or build artifact is used.
        for name in ("core/target/core.jar", "core/target/dependency/dependency.jar",
                     "jdbc-array/target/array.jar", "jdbc-array/target/dependency/postgresql-mock.jar",
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
        launcher.write_text("#!/bin/sh\nexit 98\n")
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

    def run_bash(self, code, mode="ok", **extra):
        return subprocess.run(["bash", "-c", code], cwd=self.scripts,
                              env=dict(self.env, MOCK_MODE=mode, **extra),
                              capture_output=True, text=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def helper_code(self, body, runner=RUNNERS[0]):
        source = (self.scripts / runner).read_text()
        support = source.split("# Begin local PG18 support functions.\n", 1)[1].split(
            "# End local PG18 support functions.", 1)[0]
        return ("set -euo pipefail\nDB_USERNAME=mock_user\nDB_PWD=mock_password\n"
                "DB_NAME=ycsb\nBACKUP_DB_NAME=ycsb_backup\nBACKUP_FILE=dump.sql\n"
                "RESTORE_LOG=restore.log\n" + support + "\n" + body)

    def test_preflight_failures_never_reach_dropdb(self):
        for runner in RUNNERS:
            for mode in ("old_client", "old_server", "connection_failure", "no_createdb",
                         "wrong_owner", "metrics_failure", "empty_metrics", "short_metrics",
                         "null_metric", "multiple_metrics"):
                with self.subTest(runner=runner, mode=mode):
                    self.trace.write_text("")
                    r = self.run_bash("bash " + shlex.quote(runner), mode, MOCK_STOP_AT_DROP="1")
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotEqual(r.returncode, 99, r.stderr)
                    self.assertFalse(any(t == "dropdb" and "--version" not in a for t, a in self.calls()))
                    self.assertFalse(list(self.scripts.glob("*results.log")))

    def test_dump_version_checked_only_when_needed(self):
        # A runner that dumps must reject a pre-18 pg_dump ...
        r = self.run_bash("bash " + RUNNERS[0], "old_dump", MOCK_STOP_AT_DROP="1")
        self.assertIn("pg_dump must be PostgreSQL 18", r.stdout + r.stderr)
        self.assertNotEqual(r.returncode, 99)

        # ... and a caller that passes needs_dump=false must not require it.
        body = (
            "YCSB_HOME=..; YCSB=$YCSB_HOME/bin/ycsb.sh; "
            "WORKLOAD_FILE=$YCSB_HOME/workloads/workloada-extend; "
            "JDBC_PROPERTIES=$YCSB_HOME/jdbc-binding/conf/postgres.properties; "
            "PG_MAINTENANCE_DB=postgres; TARGET_TABLE=usertable\n"
            # The extracted support block uses the runner's log(), which lives
            # outside it; stub it so real preflight failures still surface.
            "log() { case \"$*\" in START*|END*) ;; *) echo \"$*\" >&2;; esac; }\n"
            "postgres_preflight false ycsb ycsb_unchange\n"
            "printf 'PREFLIGHT_OK\\n'\n"
        )
        r = self.run_bash(self.helper_code(body), "old_dump")
        self.assertNotIn("pg_dump must be PostgreSQL 18", r.stdout + r.stderr)
        self.assertIn("PREFLIGHT_OK", r.stdout)

    def test_successful_preflight_reaches_initialization(self):
        for runner in RUNNERS:
            with self.subTest(runner=runner):
                self.trace.write_text("")
                r = self.run_bash("bash " + runner, MOCK_STOP_AT_DROP="1")
                self.assertEqual(r.returncode, 99, r.stderr)
                calls = self.calls()
                metric_at = next(i for i, (t, a) in enumerate(calls) if t == "psql" and any("pg_stat_checkpointer" in x for x in a))
                drop_at = next(i for i, (t, a) in enumerate(calls) if t == "dropdb" and "--version" not in a)
                self.assertLess(metric_at, drop_at)

    def test_missing_build_stops_before_initialization(self):
        (self.root / "jdbc-array/target/array.jar").unlink()
        r = self.run_bash("bash " + RUNNERS[0], MOCK_STOP_AT_DROP="1")
        self.assertIn("Missing build artifact", r.stdout + r.stderr)
        self.assertNotEqual(r.returncode, 99)

    def test_metrics_sql_failure_is_fatal_after_startup_too(self):
        for runner in RUNNERS:
            with self.subTest(runner=runner):
                r = self.run_bash(self.helper_code(
                    "collect_postgres_metrics\nprintf 'SHOULD_NOT_RUN'\n", runner), "metrics_failure")
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn("SHOULD_NOT_RUN", r.stdout)

    def test_csv_headers_and_values_stay_aligned(self):
        for runner in RUNNERS:
            with self.subTest(runner=runner):
                source = (self.scripts / runner).read_text()
                prefix = source.split("# All read-only checks must finish", 1)[0]
                probe = self.scripts / "csv_probe.sh"
                probe.write_text(prefix + "\n" + '''
mkdir -p "$(dirname "$OUTPUT_FILE")"
source "$WORKLOAD_FILE"
cpu=1; memory=2; phase=load; epoch=0; run=0
collect_postgres_metrics
cat > "$INPUT_FILE" <<'DATA'
[OVERALL], RunTime(ms), 1
[OVERALL], Throughput(ops/sec), 2
[INSERT], Operations, 5
[INSERT], AverageLatency(us), 10
[INSERT], Return=OK, 5
DATA
write_result TRUE
phase=run; epoch=1; run=1
write_result FALSE
''')
                r = self.run_bash("bash csv_probe.sh")
                self.assertEqual(r.returncode, 0, r.stderr)
                folder = "Workload_data" if runner == RUNNERS[0] else "Baseline_data"
                output = next((self.root / "analysis/Data" / folder).glob("*.csv"))
                with output.open() as stream:
                    rows = list(csv.reader(stream))
                self.assertEqual(len(rows), 3)
                self.assertEqual(len(rows[0]), len(set(rows[0])))
                stats_start = rows[0].index("blks_read")
                stats_end = rows[0].index("Readprop")
                for row in rows[1:]:
                    self.assertEqual(len(row), len(rows[0]))
                    # The mock echoes 1..N in SELECT order, so the statistics
                    # block must be exactly 1..N in header order. This checks
                    # header/value alignment without hardcoding a column list
                    # that differs between runner generations and PG versions.
                    stats = row[stats_start:stats_end]
                    self.assertEqual(
                        stats, [str(i) for i in range(1, len(stats) + 1)],
                        "statistics columns are misaligned with their values")

    def test_restore_success_and_failure_handling(self):
        for mode in ("ok", "dump_failure", "restore_failure", "row_mismatch"):
            with self.subTest(mode=mode):
                self.trace.write_text("")
                r = self.run_bash(self.helper_code("restore_comparison_database\nprintf 'VERIFIED'\n"), mode)
                if mode == "ok":
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertIn("Restore verified: 5 rows", (self.scripts / "restore.log").read_text())
                else:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotIn("VERIFIED", r.stdout)
                    self.assertTrue((self.scripts / "dump.sql").exists())
                    if mode == "dump_failure":
                        self.assertFalse(any(t == "dropdb" for t, _ in self.calls()))
                    if mode == "restore_failure":
                        self.assertIn("mock restore SQL error", (self.scripts / "restore.log").read_text())


if __name__ == "__main__":
    unittest.main()
