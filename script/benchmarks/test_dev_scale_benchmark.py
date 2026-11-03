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


if __name__ == "__main__":
    unittest.main()
