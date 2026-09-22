"""Monitor tests use mocks only; no live server or experimental workload."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'watch_postgresql18.py'
spec = importlib.util.spec_from_file_location('watcher', MODULE)
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)


class WatcherTests(unittest.TestCase):
    def test_sql_uses_pg18_views_and_toast(self):
        self.assertIn('pg_stat_checkpointer', watcher.SQL)
        self.assertIn('pg_stat_progress_vacuum', watcher.SQL)
        self.assertIn('reltoastrelid', watcher.SQL)
        self.assertNotIn('buffers_backend', watcher.SQL)

    @patch.object(watcher, 'pg_query', return_value='{"vacuum":[]}')
    @patch.object(Path, 'read_text', return_value='raw kernel counters')
    def test_serializable_os_and_database_sample(self, read, query):
        record = json.loads(json.dumps(watcher.sample()))
        self.assertEqual(record['postgres']['vacuum'], [])
        self.assertIn('diskstats', record)
        self.assertIn('timestamp', record)

    @patch.object(watcher, 'pg_query', side_effect=subprocess.TimeoutExpired('psql', 5))
    @patch.object(Path, 'read_text', side_effect=OSError('unavailable'))
    def test_failure_is_explicit_and_os_sample_survives(self, read, query):
        record = watcher.sample()
        self.assertEqual(record['postgres_error'], 'TimeoutExpired')
        self.assertIn('error', record['diskstats'])
        self.assertNotIn('postgres', record)

    @patch.object(watcher.subprocess, 'run')
    def test_connection_environment_and_timeout(self, run):
        run.return_value.stdout = '{}\n'
        self.assertEqual(watcher.pg_query('SELECT 1'), '{}')
        kwargs = run.call_args.kwargs
        self.assertEqual(kwargs['timeout'], 5)
        self.assertIn('statement_timeout', kwargs['env']['PGOPTIONS'])

    @patch.object(Path, 'exists', return_value=True)
    @patch.object(watcher.shutil, 'which', return_value='/bin/psql')
    @patch.object(watcher, 'pg_query', return_value='f')
    def test_insufficient_visibility_fails_preflight(self, query, which, exists):
        with self.assertRaisesRegex(RuntimeError, 'pg_read_all_stats'):
            watcher.check()


if __name__ == '__main__':
    unittest.main()
