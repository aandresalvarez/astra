import importlib.util
from contextlib import closing
import errno
from pathlib import Path
import sqlite3
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("benchmark", Path(__file__).with_name("dev_scale_benchmark.py"))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkIsolationTests(unittest.TestCase):
    def test_disk_full_removes_only_the_partial_app_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.app"
            (source / "Contents").mkdir(parents=True)
            (source / "Contents/Info.plist").write_bytes(b"source sentinel")
            copied = root / "copy.app"
            def operation(args, **kwargs):
                if str(args[0]) == "/bin/cp":
                    shutil.copytree(source, copied)
                    return ""
                raise OSError(errno.ENOSPC, "synthetic disk full")
            with patch.object(benchmark, "command", side_effect=operation):
                with self.assertRaises(OSError):
                    benchmark.stage_bundle(source, copied, {"CFBundleIdentifier": "com.coral.ASTRA.dev"}, "com.coral.ASTRA.dev.scalebench.synthetic")
            self.assertFalse(copied.exists())
            self.assertEqual((source / "Contents/Info.plist").read_bytes(), b"source sentinel")

    def test_charged_footprint_units_and_peak_are_distinct(self):
        parsed = benchmark.parse_memory("Physical footprint: 512.5M\nPhysical footprint (peak): 1.25G\n")
        self.assertEqual(parsed["physical_footprint_bytes"], 537395200)
        self.assertEqual(parsed["peak_physical_footprint_bytes"], 1342177280)
        with self.assertRaises(RuntimeError):
            benchmark.parse_memory("vmmap: attach failed")

    def test_backup_relocates_only_disposable_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            (fixture / "Workspaces/Scale 00").mkdir(parents=True)
            (fixture / "Workspaces/Scale 00/synthetic.txt").write_text("synthetic")
            with closing(sqlite3.connect(fixture / "default.store")) as stored:
                stored.execute("CREATE TABLE ZWORKSPACE (ZPRIMARYPATH TEXT)")
                stored.execute("INSERT INTO ZWORKSPACE VALUES (?)", (str(fixture / "Workspaces/Scale 00"),))
                stored.execute("CREATE TABLE ZARTIFACT (ZPATH TEXT)")
                stored.execute("INSERT INTO ZARTIFACT VALUES (?)", (str(fixture / "Workspaces/Scale 00/synthetic.txt"),))
                stored.commit()
            original = (fixture / "default.store").read_bytes()
            run = root / "run"
            run.mkdir()
            destination = benchmark.prepare_store(fixture, root / "support", run)
            with closing(sqlite3.connect(destination)) as stored:
                self.assertEqual(stored.execute("SELECT ZPRIMARYPATH FROM ZWORKSPACE").fetchone()[0], str(run / "Workspaces/Scale 00"))
                self.assertEqual(stored.execute("SELECT ZPATH FROM ZARTIFACT").fetchone()[0], str(run / "Workspaces/Scale 00/synthetic.txt"))
            self.assertEqual((fixture / "default.store").read_bytes(), original)
            self.assertEqual((run / "Workspaces/Scale 00/synthetic.txt").read_text(), "synthetic")
            empty_run = root / "file-control"
            empty_run.mkdir()
            benchmark.prepare_store(fixture, root / "empty-support", empty_run, include_files=False)
            self.assertEqual(list((empty_run / "Workspaces/Scale 00").iterdir()), [])
            self.assertEqual((fixture / "Workspaces/Scale 00/synthetic.txt").read_text(), "synthetic")


class FixturePathTests(unittest.TestCase):
    def fixture(self, root):
        fixture = root / 'fixture'
        workspace = fixture / 'Workspaces/Scale 00'
        workspace.mkdir(parents=True)
        (workspace / 'synthetic.txt').write_text('synthetic')
        with closing(sqlite3.connect(fixture / 'default.store')) as stored:
            stored.execute('CREATE TABLE ZWORKSPACE (ZPRIMARYPATH TEXT)')
            stored.execute('INSERT INTO ZWORKSPACE VALUES (?)', (str(workspace),))
            stored.execute('CREATE TABLE ZARTIFACT (ZPATH TEXT)')
            stored.execute('INSERT INTO ZARTIFACT VALUES (?)', (str(workspace / 'synthetic.txt'),))
            for table in ['ZAGENTTASK', 'ZTASKEVENT', 'ZTASKRUN']:
                columns = 'Z_PK INTEGER, ZGOAL TEXT' if table == 'ZAGENTTASK' else 'Z_PK INTEGER'
                stored.execute(f'CREATE TABLE {table} ({columns})')
            stored.commit()
        benchmark.write_json(fixture / 'synthetic-fixture.json', {'format': 1, 'profile': 'full', 'seed': 42362})
        benchmark.write_json(fixture / 'seed-counts.json', {'profile': 'full', 'seed': 42362, 'task_folder_files': 1,
            'verified_counts': {'workspaces': 1, 'artifacts': 1, 'tasks': 0, 'events': 0, 'runs': 0}})
        return fixture

    def test_moved_fixture_is_rejected_without_touching_old_location(self):
        for files in [True, False]:
            with self.subTest(include_files=files), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                original = self.fixture(root)
                moved = root / 'moved'
                original.rename(moved)
                original.mkdir()
                sentinel = original / 'user-sentinel'
                sentinel.write_text('preserve')
                before = (moved / 'default.store').read_bytes()
                run = root / 'run'; run.mkdir()
                with self.assertRaisesRegex(ValueError, 're-seeded'):
                    benchmark.prepare_store(moved, root / 'support', run, include_files=files)
                with self.assertRaisesRegex(ValueError, 're-seeded'):
                    benchmark.preflight_fixture(moved, 'full')
                self.assertFalse((run / 'Workspaces').exists())
                self.assertEqual((moved / 'default.store').read_bytes(), before)
                self.assertEqual(sentinel.read_text(), 'preserve')

    def test_invalid_database_paths_are_rejected_in_both_file_modes(self):
        for files in [True, False]:
            for table, column in [('ZWORKSPACE', 'ZPRIMARYPATH'), ('ZARTIFACT', 'ZPATH')]:
                for invalid in ['outside', 'relative', 'parent', 'null', 'prefix']:
                    with self.subTest(files=files, table=table, invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary); fixture = self.fixture(root)
                        values = {'outside': str(root / 'user-data'), 'relative': 'Workspaces/Scale 00',
                            'parent': str(fixture / 'Workspaces/Scale 00/../escape'), 'null': None,
                            'prefix': str(fixture / 'Workspaces-other/Scale 00')}
                        with closing(sqlite3.connect(fixture / 'default.store')) as stored:
                            stored.execute(f'UPDATE {table} SET {column}=?', (values[invalid],)); stored.commit()
                        before = (fixture / 'default.store').read_bytes()
                        run = root / 'run'; run.mkdir()
                        with self.assertRaises(ValueError):
                            benchmark.prepare_store(fixture, root / 'support', run, include_files=files)
                        self.assertEqual((fixture / 'default.store').read_bytes(), before)
                        self.assertFalse((run / 'Workspaces').exists())

    def test_symlink_escapes_are_rejected_even_when_omitting_files(self):
        for files in [True, False]:
            for location in ['file', 'directory', 'workspace-root', 'database']:
                with self.subTest(files=files, location=location), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary); fixture = self.fixture(root)
                    outside = root / 'user-data'; outside.mkdir()
                    sentinel = outside / 'sentinel'; sentinel.write_text('preserve')
                    if location == 'database':
                        (fixture / 'default.store').unlink()
                        (fixture / 'default.store').symlink_to(sentinel)
                    elif location == 'workspace-root':
                        shutil.rmtree(fixture / 'Workspaces')
                        (fixture / 'Workspaces').symlink_to(outside, target_is_directory=True)
                    else:
                        (fixture / 'Workspaces/Scale 00/escape').symlink_to(sentinel if location == 'file' else outside)
                    run = root / 'run'; run.mkdir()
                    with self.assertRaisesRegex(ValueError, 'Symlink'):
                        benchmark.prepare_store(fixture, root / 'support', run, include_files=files)
                    self.assertEqual(sentinel.read_text(), 'preserve')

    def test_rejects_symlink_introduced_while_copying(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); fixture = self.fixture(root)
            outside = root / 'user-data'; outside.write_text('preserve')
            run = root / 'run'; run.mkdir()
            def copy(args, **kwargs):
                shutil.copytree(args[-2], args[-1])
                (run / 'Workspaces/Scale 00/escape').symlink_to(outside)
            with patch.object(benchmark, 'command', side_effect=copy):
                with self.assertRaisesRegex(ValueError, 'Symlink'):
                    benchmark.prepare_store(fixture, root / 'support', run)
            self.assertEqual(outside.read_text(), 'preserve')

    def test_pending_wal_is_rejected_before_copying_or_ignoring_data(self):
        for files in [True, False]:
            with self.subTest(files=files), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); fixture = self.fixture(root)
                wal = fixture / 'default.store-wal'; wal.write_bytes(b'pending data')
                run = root / 'run'; run.mkdir()
                before = {p.name: p.read_bytes() for p in fixture.iterdir() if p.is_file()}
                with self.assertRaisesRegex(ValueError, 'pending WAL'):
                    benchmark.prepare_store(fixture, root / 'support', run, include_files=files)
                self.assertFalse((run / 'Workspaces').exists())
                self.assertEqual({p.name: p.read_bytes() for p in fixture.iterdir() if p.is_file()}, before)


class GoalMetadataTests(unittest.TestCase):
    fixture = FixturePathTests.fixture

    def test_reuse_corrects_reported_bytes_without_rewriting_capture(self):
        import json
        for goal, expected in [('Synthetic goal. ' * 336, 5376), ('é', 2)]:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                fixture = self.fixture(Path(temporary))
                with closing(sqlite3.connect(fixture / 'default.store')) as stored:
                    stored.execute('INSERT INTO ZAGENTTASK VALUES (?, ?)', (1, goal))
                    stored.commit()
                manifest = json.loads((fixture / 'seed-counts.json').read_text())
                manifest['verified_counts']['tasks'] = 1
                manifest['goal_bytes_per_task'] = 5040
                benchmark.write_json(fixture / 'seed-counts.json', manifest)
                before = {p.relative_to(fixture): p.read_bytes() for p in fixture.rglob('*') if p.is_file()}
                result = benchmark.preflight_fixture(fixture, 'full')
                self.assertEqual(result['goal_bytes_per_task'], expected)
                self.assertEqual(result['goal_bytes_per_task_recorded'], 5040)
                self.assertEqual({p.relative_to(fixture): p.read_bytes() for p in fixture.rglob('*') if p.is_file()}, before)

    def test_mixed_goal_sizes_are_not_misreported_as_uniform(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            with closing(sqlite3.connect(fixture / 'default.store')) as stored:
                stored.executemany('INSERT INTO ZAGENTTASK VALUES (?, ?)', [(1, 'a'), (2, 'é')])
                stored.commit()
            manifest = json.loads((fixture / 'seed-counts.json').read_text())
            manifest['verified_counts']['tasks'] = 2
            benchmark.write_json(fixture / 'seed-counts.json', manifest)
            with self.assertRaisesRegex(ValueError, 'one UTF-8 byte size'):
                benchmark.preflight_fixture(fixture, 'full')

    def test_historical_metadata_correction_preserves_every_captured_measurement(self):
        import hashlib
        import json
        for condition in ['full', 'no-files']:
            with self.subTest(condition=condition):
                path = benchmark.REPO / f'docs/performance/baselines/2026-11-02-b7908367-{condition}.json'
                report = json.loads(path.read_text())
                self.assertEqual(report['fixture']['goal_bytes_per_task'], 5376)
                correction, = report.pop('metadata_corrections')
                self.assertEqual(correction['field'], 'fixture.goal_bytes_per_task')
                self.assertEqual(correction['recorded_value'], 5040)
                self.assertEqual(correction['corrected_value'], 5376)
                self.assertFalse(correction['measurement_values_changed'])
                report['fixture']['goal_bytes_per_task'] = correction['recorded_value']
                restored = (json.dumps(report, indent=2, sort_keys=True) + '\n').encode()
                self.assertEqual(hashlib.sha256(restored).hexdigest(), correction['original_summary_sha256'])


class LifecycleTests(unittest.TestCase):
    fixture = FixturePathTests.fixture
    def run_case(self, root, fault=None, cleanup_failure=False, files=True, moved=False):
        import json
        import plistlib
        import sys
        from types import SimpleNamespace
        root = root.resolve()
        fixture = self.fixture(root)
        if moved:
            relocated = root / 'moved'; fixture.rename(relocated); fixture = relocated
        original_files = {p.relative_to(fixture): p.read_bytes() for p in fixture.rglob('*') if p.is_file()}
        source = root / 'user-source.app'
        (source / 'Contents/MacOS').mkdir(parents=True)
        info = {'ASTRAChannel': 'dev', 'CFBundleIdentifier': 'com.coral.ASTRA.dev', 'CFBundleExecutable': 'ASTRA Dev'}
        (source / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (source / 'Contents/MacOS/ASTRA Dev').write_bytes(b'synthetic executable')
        source_info = (source / 'Contents/Info.plist').read_bytes()
        tools = root / 'tools'; tools.mkdir()
        for name in ['ax', 'fixture']:(tools / name).write_text('synthetic tool')
        plan = root / 'plan.json'; benchmark.write_json(plan, {'cycle': []})
        output = root / 'output'
        calls = []; processes = []; logs = []
        def launch(args, **kwargs):
            logs.append(kwargs['stdout'])
            if fault == 'launch': raise OSError(errno.EAGAIN, 'injected launch failure')
            process = unittest.mock.Mock(pid=123456)
            state = {'running': True}
            process.poll.side_effect = lambda: None if state['running'] else 0
            process.terminate.side_effect = lambda: state.update(running=False)
            process.wait.side_effect = lambda **kw: 0
            process.store = kwargs['env']['ASTRA_DEV_APP_SUPPORT_DIR'] + '/Stores/g2/default.store'
            processes.append(process)
            return process
        def operation(args, **kwargs):
            args = [str(x) for x in args]; calls.append(args)
            if args[0] == '/bin/cp':
                shutil.copytree(args[-2], args[-1], symlinks=True); return ''
            if args[:2] == ['/usr/bin/defaults', 'import']:
                if fault == 'import': raise OSError(errno.ENOSPC, 'injected defaults import ENOSPC')
                if fault == 'escape-before-launch':
                    (output / 'run-1/Workspaces/Scale 00/escape').symlink_to(source)
            if args[:2] == ['/usr/bin/defaults', 'delete'] and cleanup_failure:
                raise OSError(errno.EACCES, 'injected defaults cleanup failure')
            if args[0] == '/usr/bin/codesign' and fault == 'stage':
                raise OSError(errno.ENOSPC, 'injected staging ENOSPC')
            if args[0] == '/usr/sbin/sysctl': return '1024'
            if args[0] == '/usr/sbin/lsof': return processes[-1].store
            if args[0] == str(tools / 'ax'):
                if fault == 'workload' and args[2] == 'wait':
                    raise RuntimeError('injected workload failure')
                return '{}'
            return ''
        argv = ['benchmark', '--app', str(source), '--build-dir', str(root), '--output', str(output),
                '--fixture', str(fixture), '--tools', str(tools), '--runs', '1', '--cycles', '1',
                '--idle-seconds', '1', '--plan', str(plan)] + ([] if files else ['--omit-task-files'])
        caught = None
        with patch.object(sys, 'argv', argv), patch.object(Path, 'home', return_value=root / 'fake-home'), \
             patch.object(benchmark, 'command', side_effect=operation), \
             patch.object(benchmark.subprocess, 'Popen', side_effect=launch), \
             patch.object(benchmark.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             patch.object(benchmark.fcntl, 'flock'), patch.object(benchmark.time, 'sleep'), \
             patch.object(benchmark.platform, 'platform', return_value='synthetic-macOS'), \
             patch.object(benchmark, 'memory', return_value=({'physical_footprint_bytes':1,'peak_physical_footprint_bytes':2},'synthetic vmmap')):
            try: benchmark.main()
            except BaseException as error: caught = error
        report = json.loads((output / 'report.json').read_text())
        self.assertFalse((output / 'run-1/ASTRA Scale Benchmark.app').exists())
        self.assertEqual((source / 'Contents/Info.plist').read_bytes(), source_info)
        self.assertEqual({p.relative_to(fixture): p.read_bytes() for p in fixture.rglob('*') if p.is_file()}, original_files)
        self.assertTrue(all(log.closed for log in logs))
        for call in calls:
            if call[:2] == ['/usr/bin/defaults', 'delete']:
                self.assertTrue(call[2].startswith('com.coral.ASTRA.dev.scalebench.'))
        return report, caught, calls, processes

    def test_setup_and_launch_failure_cleanup_and_status(self):
        for fault in ['stage', 'import', 'launch', 'escape-before-launch']:
            for files in [True, False]:
                with self.subTest(fault=fault, files=files), tempfile.TemporaryDirectory() as temporary:
                    report, error, calls, processes = self.run_case(Path(temporary), fault=fault, files=files)
                    self.assertIsNotNone(error)
                    self.assertEqual(report['status'], 'failed')
                    self.assertEqual(report['runs'][0]['status'], 'failed')
                    self.assertTrue(report['failure'])
                    self.assertEqual(processes, [])
                    self.assertEqual(any(c[:2] == ['/usr/bin/defaults','delete'] for c in calls), fault != 'stage')

    def test_preferences_cleanup_failure_cannot_skip_bundle_or_log_cleanup(self):
        for fault in ['import', 'launch', None]:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                report, error, _, processes = self.run_case(Path(temporary), fault=fault, cleanup_failure=True)
                self.assertIsNotNone(error)
                self.assertEqual(report['status'], 'failed')
                self.assertTrue(report['runs'][0]['cleanup_errors'])
                if processes: processes[0].terminate.assert_called_once()

    def test_normal_exit_cleans_up_and_retains_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report, error, _, processes = self.run_case(root)
            self.assertIsNone(error)
            self.assertEqual(report['status'], 'complete')
            self.assertEqual(report['runs'][0]['status'], 'complete')
            self.assertTrue((root / 'output/run-1/preferences.plist').exists())
            self.assertTrue((root / 'output/run-1/app.log').exists())
            processes[0].terminate.assert_called_once()

    def test_workload_failure_stops_owned_child_and_preserves_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, error, _, processes = self.run_case(Path(temporary), fault='workload', cleanup_failure=True)
            self.assertIsInstance(error, RuntimeError)
            self.assertIn('injected workload failure', report['failure'])
            self.assertEqual(report['runs'][0]['status'], 'failed')
            self.assertTrue(report['runs'][0]['cleanup_errors'])
            processes[0].terminate.assert_called_once()

    def test_unstoppable_child_retains_bundle_but_closes_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'owned.app'; bundle.mkdir()
            record = {}
            log = unittest.mock.Mock()
            process = unittest.mock.Mock()
            process.poll.return_value = None
            process.terminate.side_effect = OSError('injected stop failure')
            with patch.object(benchmark, 'command', side_effect=OSError('injected preference cleanup failure')):
                with self.assertRaises(RuntimeError):
                    with benchmark.RunResources(bundle, 'com.coral.ASTRA.dev.scalebench.synthetic', record) as owned:
                        owned.process = process
                        owned.log = log
                        owned.preferences_attempted = True
            self.assertTrue(bundle.exists())
            log.close.assert_called_once()
            self.assertEqual(record['status'], 'failed')
            self.assertEqual(len(record['cleanup_errors']), 3)

    def test_moved_fixture_rejected_before_staging_preferences_or_launch(self):
        for files in [True, False]:
            with self.subTest(files=files), tempfile.TemporaryDirectory() as temporary:
                report, error, calls, processes = self.run_case(Path(temporary), moved=True, files=files)
                self.assertIsInstance(error, ValueError)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(processes, [])
                self.assertFalse(any(c[0] == '/bin/cp' or c[0] == '/usr/bin/defaults' for c in calls))


if __name__ == "__main__":
    unittest.main()
