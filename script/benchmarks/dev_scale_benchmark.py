#!/usr/bin/env python3
"""Opt-in, external full-app benchmark. Never selects or quits an existing app."""
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import sqlite3
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[2]


def command(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, **kwargs)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def memory(pid):
    # vmmap's charged physical footprint includes compressed pages; RSS does not.
    text = command(["/usr/bin/vmmap", "-summary", pid], stderr=subprocess.STDOUT)
    return parse_memory(text), text


def parse_memory(text):
    def metric(label):
        match = re.search(re.escape(label) + r"\s*([\d.]+)([KMG]?)", text)
        if not match:
            raise RuntimeError(f"Missing vmmap metric: {label}")
        return round(float(match[1]) * {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3}[match[2]])
    return {"physical_footprint_bytes": metric("Physical footprint:"),
            "peak_physical_footprint_bytes": metric("Physical footprint (peak):")}


def compile_tools(build, output):
    modules = build / "Modules" if (build / "Modules").exists() else build
    objects = []
    for module in ["ASTRAModels", "ASTRACore", "ASTRALogging"]:
        combined = build / (module + ".o")
        found = [combined] if combined.exists() else sorted((build / (module + ".build")).glob("*.swift.o"))
        if not found:
            raise RuntimeError(f"Build {module} first with swift build --target ASTRAModels")
        objects.extend(found)
    common = ["xcrun", "swiftc", "-target", "arm64-apple-macosx14.0", "-module-cache-path", output / "module-cache"]
    command(common + ["-parse-as-library", "-I", modules, REPO / "script/benchmarks/DevWorkspaceFixture.swift",
        REPO / "Astra/Views/SidebarTaskFetch.swift", *objects, "-o", output / "fixture"])
    command(common + [REPO / "script/benchmarks/DevScaleAX.swift", "-o", output / "ax"])
    return {str(p.name): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects}


def reject_symlinks(root):
    """Fixtures contain generated regular files/directories, never links."""
    if root.is_symlink():
        raise ValueError(f"Symlink in disposable fixture: {root}")
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            if (Path(directory) / name).is_symlink():
                raise ValueError(f"Symlink in disposable fixture: {Path(directory) / name}")


def confined_path(value, root):
    if not isinstance(value, str) or not value or "\0" in value:
        raise ValueError("Invalid fixture database path")
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Fixture path is outside its current Workspaces root; moved fixtures must be re-seeded")
    # Canonicalize OS aliases such as /var -> /private/var, never substitute text.
    resolved, boundary = path.resolve(), root.resolve()
    if resolved == boundary or not resolved.is_relative_to(boundary):
        raise ValueError("Fixture path is outside its current Workspaces root; moved fixtures must be re-seeded")
    return resolved.relative_to(boundary)


def path_rows(connection, workspace_root):
    rows = {}
    for table, column in [("ZWORKSPACE", "ZPRIMARYPATH"), ("ZARTIFACT", "ZPATH")]:
        columns = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        if column not in columns:
            raise ValueError(f"Fixture schema no longer has {table}.{column}")
        rows[table] = [(rowid, confined_path(value, workspace_root))
                       for rowid, value in connection.execute(f"SELECT rowid, {column} FROM {table}")]
    workspaces = [workspace_root / relative for _, relative in rows["ZWORKSPACE"]]
    if not workspaces or any(not path.is_dir() for path in workspaces):
        raise ValueError("Fixture workspace directory is missing")
    for _, relative in rows["ZARTIFACT"]:
        artifact = workspace_root / relative
        if not any(artifact != path and artifact.is_relative_to(path) for path in workspaces):
            raise ValueError("Artifact is outside the registered fixture workspaces")
    return rows


def open_fixture(fixture):
    # Immutable reads avoid even WAL/shared-memory bookkeeping in reusable input.
    # Never ignore pending WAL data; a completed seed must be checkpointed first.
    wal = fixture / "default.store-wal"
    if wal.exists() and wal.stat().st_size:
        raise ValueError("Reusable fixture has pending WAL data; re-seed a completed fixture")
    return sqlite3.connect((fixture / "default.store").as_uri() + "?mode=ro&immutable=1", uri=True)


def preflight_fixture(fixture, profile):
    reject_symlinks(fixture)
    marker = json.loads((fixture / "synthetic-fixture.json").read_text())
    manifest = json.loads((fixture / "seed-counts.json").read_text())
    if marker.get("format") != 1 or marker.get("profile") != profile or marker.get("seed") != manifest.get("seed") or manifest.get("profile") != profile:
        raise ValueError("Synthetic fixture marker/profile mismatch")
    with closing(open_fixture(fixture)) as source:
        path_rows(source, fixture / "Workspaces")
        counts = {name: source.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                  for name, table in [("workspaces", "ZWORKSPACE"), ("tasks", "ZAGENTTASK"),
                                      ("events", "ZTASKEVENT"), ("runs", "ZTASKRUN"), ("artifacts", "ZARTIFACT")]}
    if counts != manifest["verified_counts"]:
        raise ValueError("Reusable fixture row counts differ from its seed manifest")
    return manifest


def prepare_store(fixture, support, run_root, include_files=True):
    """Validate, then map complete path components in a private backup only."""
    fixture, run_root, support = Path(fixture).absolute(), Path(run_root).absolute(), Path(support).absolute()
    reject_symlinks(fixture)
    reject_symlinks(run_root)
    reject_symlinks(support)
    workspace_root = run_root / "Workspaces"
    destination = support / "Stores/g2/default.store"
    if workspace_root.exists() or destination.exists():
        raise ValueError("Disposable workspace/store destination already exists")
    with closing(open_fixture(fixture)) as source:
        source.execute("BEGIN")
        rows = path_rows(source, fixture / "Workspaces")
        if include_files:
            command(["/bin/cp", "-cR", fixture / "Workspaces", workspace_root])
        else:
            workspace_root.mkdir()
            for _, relative in rows["ZWORKSPACE"]:
                (workspace_root / relative).mkdir(parents=True, exist_ok=True)
        reject_symlinks(workspace_root)
        destination.parent.mkdir(parents=True)
        with closing(sqlite3.connect(destination)) as target:
            source.backup(target)
            for table, column in [("ZWORKSPACE", "ZPRIMARYPATH"), ("ZARTIFACT", "ZPATH")]:
                target.executemany(f"UPDATE {table} SET {column} = ? WHERE rowid = ?",
                                   [(str(workspace_root / relative), rowid) for rowid, relative in rows[table]])
            path_rows(target, workspace_root)
            target.commit()
    return destination


class RunResources:
    """Own cleanup before any bundle, preference import or child can exist."""
    def __init__(self, bundle, identifier, record):
        if not identifier.startswith("com.coral.ASTRA.dev.scalebench."):
            raise ValueError("Refusing cleanup of a non-benchmark preference domain")
        self.bundle, self.identifier, self.record = bundle, identifier, record
        self.process = self.log = None
        self.preferences_attempted = False

    def __enter__(self):
        return self

    def __exit__(self, kind, error, traceback):
        failures = []
        def attempt(label, action):
            try:
                action()
            except BaseException as failure:
                failures.append(f"{label}: {failure}")
        if self.process is not None:
            def stop():
                if self.process.poll() is None:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait(timeout=15)
            attempt("owned process", stop)
        if self.preferences_attempted:
            attempt("owned preferences", lambda: command(["/usr/bin/defaults", "delete", self.identifier]))
        if self.process is None or self.process.poll() is not None:
            attempt("owned bundle", lambda: shutil.rmtree(self.bundle) if self.bundle.exists() else None)
        else:
            failures.append("owned bundle retained because its process could not be stopped")
        if self.log is not None:
            attempt("app log", self.log.close)
        if failures:
            self.record["cleanup_errors"] = failures
        if error is not None or failures:
            self.record["status"] = "failed"
            self.record.setdefault("failure", str(error) if error is not None else "Cleanup failed")
        else:
            self.record["status"] = "plan_preparation" if self.record.get("prepare_only") else "complete"
        if failures and error is None:
            raise RuntimeError("; ".join(failures))
        return False


def stage_bundle(source, bundle, info, identifier):
    try:
        command(["/bin/cp", "-cR", source, bundle])
        copied = dict(info, CFBundleIdentifier=identifier, CFBundleName="ASTRA Scale Benchmark", CFBundleDisplayName="ASTRA Scale Benchmark")
        for key in ["CFBundleURLTypes", "CFBundleDocumentTypes", "NSUserActivityTypes", "NSServices"]:
            copied.pop(key, None)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(copied))
        command(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", bundle], stderr=subprocess.STDOUT)
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", bundle], stderr=subprocess.STDOUT)
    except BaseException:
        # In particular, disk-full must not leave a source-identified app copy.
        shutil.rmtree(bundle, ignore_errors=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Already built ASTRA Dev.app; copied, never replaced")
    parser.add_argument("--build-dir", type=Path, required=True, help="Matching SwiftPM binary output directory (read only)")
    parser.add_argument("--output", type=Path, required=True, help="New disposable output directory")
    parser.add_argument("--profile", choices=["full", "no-files"], default="full")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--cycles", type=int, default=5)
    parser.add_argument("--idle-seconds", type=float, default=15)
    parser.add_argument("--fixture", type=Path, help="Reuse a previously verified synthetic seed")
    parser.add_argument("--omit-task-files", action="store_true", help="Keep the same database; create empty workspace folders for the file-volume control")
    parser.add_argument("--tools", type=Path, help="Reuse this harness's previously compiled tools")
    parser.add_argument("--plan", type=Path, default=Path(__file__).with_name("dev-scale-plan.json"), help="JSON external AX actions; see documentation")
    parser.add_argument("--prepare-only", action="store_true", help="Launch, dump AX tree and supervise the owned app until it exits")
    args = parser.parse_args()
    if args.runs < 1 or args.cycles < 1 or args.idle_seconds < 1:
        parser.error("runs/cycles must be positive and idle >= 1 second")
    source = args.app.resolve()
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if info.get("ASTRAChannel") != "dev" or info.get("CFBundleIdentifier") != "com.coral.ASTRA.dev":
        parser.error("source must be the standard development bundle")
    output = args.output.resolve()
    if output.exists():
        parser.error("output must not exist (no overwrites or shared build mutations)")
    if output.is_relative_to(source) or (args.fixture and output.is_relative_to(args.fixture.resolve())):
        parser.error("output must be outside the source app and reusable fixture")
    capacity_root = output.parent
    while not capacity_root.exists():
        capacity_root = capacity_root.parent
    if shutil.disk_usage(capacity_root).free < 700 * 1024**2:
        parser.error("less than 700 MiB free; defer until capacity is available")
    output.mkdir(parents=True)
    write_json(output / "synthetic-benchmark.json", {"format": 1, "owner": str(output)})
    report = {"schema_version": 1, "status": "running", "runs": []}
    try:
        execute_benchmark(args, source, info, output, report)
    except BaseException as error:
        report["status"] = "failed"
        report["failure"] = str(error)
        raise
    finally:
        write_json(output / "report.json", report)


def execute_benchmark(args, source, info, output, report):
    with open("/private/tmp/astra-dev-scale-benchmark.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        tools = args.tools.resolve() if args.tools else output
        hashes = {} if args.tools else compile_tools(args.build_dir.resolve(), output)
        if args.fixture and args.fixture.is_symlink():
            raise ValueError("Reusable fixture root must not be a symlink")
        fixture = args.fixture.resolve() if args.fixture else output / "fixture-data"
        if not args.fixture:
            with (output / "seed.log").open("w") as log:
                subprocess.run([str(tools / "fixture"), "seed", str(fixture), args.profile], stdout=log, stderr=log, check=True)
        manifest = preflight_fixture(fixture, args.profile)
        host = {"os": platform.platform(), "machine": platform.machine(),
                "hardware": command(["/usr/sbin/sysctl", "-n", "hw.model"]).strip(),
                "ram_bytes": int(command(["/usr/sbin/sysctl", "-n", "hw.memsize"])),
                "swift": command(["xcrun", "swift", "--version"]).strip(),
                "power": command(["/usr/bin/pmset", "-g", "batt"]).strip(),
                "load_before": os.getloadavg(), "disk_free_bytes": shutil.disk_usage(output).free,
                "processes_before": command(["/bin/ps", "-axo", "pid,pcpu,rss,comm"]).splitlines()}
        report.update({"schema_version": 1, "status": "running", "fixture": manifest, "host": host,
                  "app_build": info, "harness_revision": command(["git", "rev-parse", "HEAD"], cwd=REPO).strip(),
                  "linked_object_sha256": hashes, "requested_runs": args.runs, "cycles": args.cycles,
                  "idle_seconds": args.idle_seconds, "omit_task_files": args.omit_task_files,
                  "invocation": __import__("sys").argv, "runs": []})
        report["input_sha256"] = {p.name: sha256(p) for p in [Path(__file__),
            Path(__file__).with_name("DevScaleAX.swift"), Path(__file__).with_name("DevWorkspaceFixture.swift"),
            args.plan, tools / "ax", tools / "fixture", source / "Contents/MacOS" / info["CFBundleExecutable"]]}
        write_json(output / "report.json", report)
        plan = json.loads(args.plan.read_text()) if args.plan else []
        for index in range(1, args.runs + 1):
            token = uuid.uuid4().hex
            run_root = output / f"run-{index}"
            support = Path.home() / "Library/Application Support/ASTRA Scale Benchmark" / token / "AstraDev"
            bundle = run_root / "ASTRA Scale Benchmark.app"
            identifier = "com.coral.ASTRA.dev.scalebench." + token
            record = {"support": str(support), "bundle_identifier": identifier, "status": "setup", "actions": [], "memory": []}
            report["runs"].append(record)
            with RunResources(bundle, identifier, record) as owned:
                run_root.mkdir()
                support.mkdir(parents=True)
                write_json(support.parent / "synthetic-benchmark.json", {"owner": str(output)})
                destination = prepare_store(fixture, support, run_root, include_files=not args.omit_task_files)
                initial_files = sum(p.is_file() for p in (run_root / "Workspaces").rglob("*"))
                expected_files = 0 if args.omit_task_files else manifest["task_folder_files"]
                if initial_files != expected_files:
                    raise RuntimeError("Disposable workspace clone has unexpected file count")
                stage_bundle(source, bundle, info, identifier)
                preferences = {"astra.hasCompletedOnboarding": True, "skipPermissions": True,
                    "workspacesRoot": str(run_root / "Workspaces"), "lastSelectedWorkspacePath": str(run_root / "Workspaces/Scale 01"),
                    "lastSelectedWorkspaceID": "000F4241-0000-4000-8000-00000000A57B"}
                preference_file = run_root / "preferences.plist"
                preference_file.write_bytes(plistlib.dumps(preferences))
                owned.preferences_attempted = True
                command(["/usr/bin/defaults", "import", identifier, preference_file])
                environment = dict(os.environ, ASTRA_DEV_APP_SUPPORT_DIR=str(support))
                log = owned.log = (run_root / "app.log").open("w")
                started = time.monotonic_ns()
                reject_symlinks(run_root / "Workspaces")
                reject_symlinks(destination.parent)
                with closing(sqlite3.connect(destination.as_uri() + "?mode=ro", uri=True)) as checked:
                    path_rows(checked, run_root / "Workspaces")
                process = owned.process = subprocess.Popen([str(bundle / "Contents/MacOS" / info["CFBundleExecutable"])], env=environment, stdout=log, stderr=log)
                record.update(pid=process.pid, initial_task_folder_files=initial_files)
                def ax(*parts):
                    return json.loads(command([tools / "ax", process.pid, *parts]))
                def sample(stage):
                    measured, raw = memory(process.pid)
                    record["memory"].append(dict(stage=stage, elapsed_s=(time.monotonic_ns()-started)/1e9, **measured))
                    (run_root / f"vmmap-{stage}.txt").write_text(raw)
                    if stage in ["warm-idle", "final-idle"]:
                        # Live allocation counts/sizes by class, between timed actions.
                        # These distinguish heap growth from charged allocator pages.
                        with (run_root / f"heap-{stage}.txt").open("w") as heap_log:
                            result = subprocess.run(["/usr/bin/heap", "--noContent", "-s", str(process.pid)], stdout=heap_log, stderr=heap_log, timeout=60)
                        record.setdefault("heap_exit_status", {})[stage] = result.returncode
                    write_json(output / "report.json", report)
                try:
                    ax("wait", "contains:TaskRow_Long thread", "present")
                    record["launch_to_ax_ready_ms"] = (time.monotonic_ns() - started) / 1e6
                    # Verify actual open descriptors, not just requested environment.
                    descriptors = command(["/usr/sbin/lsof", "-a", "-p", process.pid, "-Fn"])
                    (run_root / "open-files.txt").write_text(descriptors)
                    if str(destination) not in descriptors or re.search(r"/Application Support/Astra(?:Dev)?/Stores/", descriptors):
                        raise RuntimeError("App did not exclusively open the disposable store")
                    write_json(run_root / "ax-launch.json", ax("dump"))
                    sample("launch")
                    if args.prepare_only:
                        record["prepare_only"] = True
                        report["status"] = "plan_preparation"
                        write_json(output / "report.json", report)
                        print(json.dumps(record, indent=2), flush=True)
                        process.wait()  # Keep the launch environment supervised during inspection.
                        return
                    if not plan:
                        raise RuntimeError("A verified AX action plan is required; use --prepare-only to inspect")
                    last_save_dispatch = None
                    def perform(action, cycle):
                        nonlocal last_save_dispatch
                        action = [part.replace("{cycle}", str(cycle)) for part in action]
                        if action[0] == "wait-mirror":
                            mirror = run_root / "Workspaces" / action[1] / ".astra/.astra-workspace.json"
                            before = time.monotonic_ns()
                            while time.monotonic_ns() - before < 60_000_000_000:
                                if mirror.exists() and json.loads(mirror.read_text()).get("instructions") == action[2]:
                                    observed = time.monotonic_ns()
                                    return {"mirror_ready_ms": (observed - before)/1e6,
                                            "save_dispatch_to_mirror_ms": (observed-last_save_dispatch)/1e6 if last_save_dispatch else None,
                                            "mirror_bytes": mirror.stat().st_size,
                                            "instruction_verified": True}
                                time.sleep(0.02)
                            raise RuntimeError("Workspace save never reached its mirror")
                        if action[:2] == ["click", "Save"]:
                            last_save_dispatch = time.monotonic_ns()
                        return ax(*action)
                    for action in plan.get("warmup", []):
                        result = perform(action, 0)
                        record["actions"].append(dict(cycle=0, command=action, result=result))
                    time.sleep(args.idle_seconds)
                    sample("warm-idle")
                    for cycle in range(1, args.cycles + 1):
                        for action in plan["cycle"]:
                            result = perform(action, cycle)
                            record["actions"].append(dict(cycle=cycle, command=action, result=result))
                            write_json(output / "report.json", report)
                        sample(f"cycle-{cycle}")
                        time.sleep(args.idle_seconds)
                        sample(f"idle-{cycle}")
                    record["load_after"] = os.getloadavg()
                    with closing(sqlite3.connect(f"file:{destination}?mode=ro", uri=True)) as stored:
                        record["final_counts"] = {name: stored.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                            for name, table in [("workspaces", "ZWORKSPACE"), ("tasks", "ZAGENTTASK"), ("events", "ZTASKEVENT"), ("runs", "ZTASKRUN"), ("artifacts", "ZARTIFACT")]}
                    if record["final_counts"] != manifest["verified_counts"]:
                        raise RuntimeError("Benchmark unexpectedly changed fixture row counts")
                    with (run_root / "leaks.txt").open("w") as leak_log:
                        result = subprocess.run(["/usr/bin/leaks", "--noContent", "-q", str(process.pid)], stdout=leak_log, stderr=leak_log)
                        record["leaks_exit_status"] = result.returncode
                    sample("final-idle")
                except BaseException as error:
                    record["failure"] = str(error)
                    report["status"] = "failed"
                    if process.poll() is None:
                        try:
                            write_json(run_root / "ax-failure.json", ax("dump"))
                        except (ValueError, subprocess.CalledProcessError):
                            pass
                    raise
        report["status"] = "complete"
        write_json(output / "report.json", report)
        print(output / "report.json")


if __name__ == "__main__":
    main()
