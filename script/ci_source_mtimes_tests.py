#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import ci_source_mtimes as mtimes

OLD = 1_600_000_000_123_456_789
NEW = 1_700_000_000_987_654_321


class SourceMtimeTests(unittest.TestCase):
    def setUp(self):
        # A hook exports GIT_DIR and friends; the fixture repository must not inherit them.
        inherited = {name: value for name, value in os.environ.items() if not name.startswith('GIT_')}
        environment = patch.dict(os.environ, inherited, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve() / 'checkout'
        self.root.mkdir()
        self.manifest = self.root.parent / 'cached-build' / 'ci-source-mtimes.json'
        self.git('init', '--quiet')
        self.write('kept.swift', 'let kept = 1\n', OLD)
        self.write('edited name.swift', 'let edited = 1\n', OLD)
        self.write('removed.swift', 'let removed = 1\n', OLD)
        self.write('tool.sh', '#!/bin/sh\n', OLD)
        self.git('add', '--all')

    def git(self, *arguments):
        subprocess.check_call(['git', '-c', 'core.hooksPath=/dev/null', *arguments], cwd=self.root)

    def write(self, name, text, mtime_ns):
        path = self.root / name
        path.write_text(text)
        os.utime(path, ns=(mtime_ns, mtime_ns))

    def mtime(self, name):
        return (self.root / name).stat().st_mtime_ns

    def fresh_checkout(self):
        """Stamp every tracked file with a new time, as actions/checkout does."""
        for name in ['kept.swift', 'edited name.swift', 'removed.swift', 'tool.sh', 'added.swift']:
            if (self.root / name).exists():
                os.utime(self.root / name, ns=(NEW, NEW))

    def test_first_run_restores_nothing_and_records_the_tree(self):
        self.assertEqual(mtimes.sync(str(self.root), str(self.manifest)), (0, 4))
        files = json.loads(self.manifest.read_text())['files']
        self.assertEqual(files['kept.swift'][1], OLD)
        self.assertEqual(set(files), {'kept.swift', 'edited name.swift', 'removed.swift', 'tool.sh'})

    def test_only_unchanged_content_gets_the_cached_time(self):
        mtimes.sync(str(self.root), str(self.manifest))
        self.fresh_checkout()
        self.write('edited name.swift', 'let edited = 2\n', NEW)
        self.write('added.swift', 'let added = 1\n', NEW)
        (self.root / 'removed.swift').unlink()
        (self.root / 'tool.sh').chmod(0o755)
        os.utime(self.root / 'tool.sh', ns=(NEW, NEW))
        self.git('add', '--all')

        self.assertEqual(mtimes.sync(str(self.root), str(self.manifest)), (1, 3))

        self.assertEqual(self.mtime('kept.swift'), OLD)
        self.assertEqual(self.mtime('edited name.swift'), NEW)
        self.assertEqual(self.mtime('added.swift'), NEW)
        self.assertEqual(self.mtime('tool.sh'), NEW, 'a mode change is a change')
        files = json.loads(self.manifest.read_text())['files']
        self.assertEqual(files['kept.swift'][1], OLD)
        self.assertEqual(files['edited name.swift'][1], NEW)
        self.assertNotIn('removed.swift', files)

    def test_content_restored_to_an_older_version_is_still_a_change(self):
        mtimes.sync(str(self.root), str(self.manifest))
        self.write('kept.swift', 'let kept = 2\n', NEW)
        self.git('add', '--all')
        mtimes.sync(str(self.root), str(self.manifest))
        later = NEW + 5_000_000_000
        self.write('kept.swift', 'let kept = 1\n', later)
        self.git('add', '--all')

        mtimes.sync(str(self.root), str(self.manifest))

        self.assertEqual(self.mtime('kept.swift'), later)

    def test_unusable_manifest_restores_nothing(self):
        self.manifest.parent.mkdir()
        for content in ['', 'not json', '[]', '{"version": 99, "files": {}}',
                        '{"version": 1, "files": {"kept.swift": "bad"}}', '{"version": 1}']:
            with self.subTest(content=content):
                self.fresh_checkout()
                self.manifest.write_text(content)
                self.assertEqual(mtimes.sync(str(self.root), str(self.manifest)), (0, 4))
                self.assertEqual(self.mtime('kept.swift'), NEW)

    def test_command_line_reports_the_counts(self):
        script = Path(mtimes.__file__).resolve()
        output = subprocess.check_output(['python3', str(script), 'sync', str(self.manifest)],
                                         cwd=self.root, text=True)
        self.assertIn('0 unchanged files; 4 new or changed files', output)
        self.assertEqual(subprocess.call(['python3', str(script)], cwd=self.root,
                                         stderr=subprocess.DEVNULL), 2)


if __name__ == '__main__':
    unittest.main()
