#!/usr/bin/env python3
"""Run synthetic coordinator ownership controls, one fresh Swift process at a time.

Build first: script/swift_test.sh --no-parallel --jobs 2 --filter WorkspaceExportMemoryEvidenceTests
No app is launched, selected, stopped, or attached by this runner.
"""
import argparse
from contextlib import closing
import json
import platform
import resource
import signal
import sqlite3
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from dev_scale_benchmark import REPO, command, reject_symlinks, sha256, synthetic_environment, write_json

MODES = ("history", "export", "combined", "direct", "cleanup", "failure", "cancellation", "termination")


def profile_file_limit():
    # Two generations per invocation; a probe must not fill the shared disk.
    resource.setrlimit(resource.RLIMIT_FSIZE, (2 * 1024**3, 2 * 1024**3))


def expand_fixture(root, count):
    """Expand one framework-created synthetic row while no Swift store is open.

    This is fixture construction only, never a product/store migration. Fail
    closed on schema drift; real SwiftData readers verify both relationships
    and counts in every workload process before the measurement boundary.
    """
    store = root / "source.store"
    with closing(sqlite3.connect(store)) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT * FROM ZTASKEVENT").fetchall()
        if len(rows) != 1:
            raise ValueError("Seed process must produce exactly one event prototype")
        prototype = dict(rows[0])
        required = {"Z_PK", "Z_ENT", "Z_OPT", "ZID", "ZTYPE", "ZPAYLOAD", "ZTIMESTAMP", "ZTASK", "ZRUN"}
        if not required.issubset(prototype) or prototype["ZTYPE"] != "validation.synthetic":
            raise ValueError("Synthetic fixture schema/type drift")
        if prototype["ZID"] != uuid.UUID("20261106-0000-0000-0004-000000000000").bytes:
            raise ValueError("Synthetic UUID encoding drift")
        columns = list(prototype)
        if any(not name.replace("_", "").isalnum() for name in columns):
            raise ValueError("Unexpected fixture column name")
        connection.execute("DELETE FROM ZTASKEVENT")
        def events():
            for index in range(count):
                row = dict(prototype, Z_PK=index + 1,
                           ZID=uuid.UUID(f"20261106-0000-0000-0004-{index:012x}").bytes,
                           ZTIMESTAMP=prototype["ZTIMESTAMP"] + index,
                           ZPAYLOAD=f"Synthetic {index} " + "x" * 128)
                yield tuple(row[name] for name in columns)
        connection.executemany(f"INSERT INTO ZTASKEVENT ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})", events())
        cursor = connection.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_ENT=? AND Z_NAME='TaskEvent'",
                                    (count, prototype["Z_ENT"]))
        if cursor.rowcount != 1:
            raise ValueError("Synthetic primary-key metadata drift")
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("Synthetic fixture integrity failure")
        connection.commit()
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
            raise ValueError("Reusable synthetic fixture must be a self-contained SQLite file")
        counts = {table: connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                  for table in ("ZWORKSPACE", "ZAGENTTASK", "ZTASKRUN", "ZTASKEVENT")}
    return {"store_sha256": sha256(store), "counts": counts, "event_prototype": "SwiftData",
            "event_expansion": "offline SQLite, schema-checked, no open Swift process"}


def inspect_fixture(root, scale):
    reject_symlinks(root)
    if (root / "synthetic-export-fixture.txt").read_text() != f"20261106:{scale}":
        raise ValueError("Synthetic export fixture marker/scale mismatch")
    store = root / "source.store"
    wal = root / "source.store-wal"
    if wal.exists() and wal.stat().st_size:
        raise ValueError("Reusable fixture has pending WAL data")
    with closing(sqlite3.connect(store.as_uri() + "?mode=ro&immutable=1", uri=True)) as connection:
        if connection.execute("PRAGMA journal_mode").fetchone()[0] != "delete":
            raise ValueError("Reusable fixture must be checkpointed and normalized to DELETE journal mode")
        counts = {table: connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                  for table in ("ZWORKSPACE", "ZAGENTTASK", "ZTASKRUN", "ZTASKEVENT", "ZTASKTURNREQUEST")}
        tasks, events = (2200, 75000) if scale == "representative" else (12, 300)
        if any(counts[key] != value for key, value in {"ZWORKSPACE": 2, "ZAGENTTASK": tasks, "ZTASKRUN": tasks, "ZTASKEVENT": events}.items()):
            raise ValueError("Reusable fixture count mismatch")
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("Reusable fixture integrity failure")
    return {"store_sha256": sha256(store), "counts": counts, "reused": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scale", choices=("small", "representative"), default="small")
    parser.add_argument("--fixture", type=Path, help="Reuse a generated, closed, normalized synthetic fixture")
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--blocks", type=int, choices=range(1, 31), default=6)
    parser.add_argument("--assert-teardown", action="store_true")
    parser.add_argument("--profile", action="store_true", help="Synthetic test heap graphs after warmup and final block")
    args = parser.parse_args()
    if args.profile and len(args.modes) != 1:
        parser.error("Profile one mode per invocation (two bounded heap generations)")
    if args.output.exists():
        parser.error("Output must be a new directory")
    if args.fixture and args.output.resolve().is_relative_to(args.fixture.resolve()):
        parser.error("Output must be outside the reusable fixture")
    if shutil.disk_usage(REPO).free < 12 * 1024**3:
        parser.error("Keep at least 12 GiB free before running synthetic fixtures")
    args.output.mkdir(parents=True)
    args.output = args.output.resolve()
    sources = [REPO / "Tests/WorkspaceExportMemoryEvidenceTests.swift",
               REPO / "Astra/Services/Persistence/WorkspaceSavedAutoExport.swift",
               REPO / "script/benchmarks/dev_scale_benchmark.py", Path(__file__).resolve()]
    binaries = list((REPO / ".build").glob("**/ASTRATests.xctest/Contents/MacOS/*"))
    if not binaries:
        parser.error("Build the test bundle before running the evidence matrix")
    manifest = {"commit": command(["git", "rev-parse", "HEAD"], cwd=REPO).strip(),
                "diff": command(["git", "diff", "--", *sources], cwd=REPO),
                "source_sha256": {str(p.relative_to(REPO)): sha256(p) for p in sources},
                "test_binary_sha256": {str(p.relative_to(REPO)): sha256(p) for p in binaries if p.is_file()},
                "toolchain": command(["xcrun", "swift", "--version"], stderr=subprocess.STDOUT), "seed": 20261106,
                "host": platform.platform(), "invocation": __import__("sys").argv,
                "scale": args.scale, "blocks_after_warmup": args.blocks, "results": []}
    for source in sources:
        destination = args.output / "source-snapshot" / source.relative_to(REPO)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
        if sha256(destination) != manifest["source_sha256"][str(source.relative_to(REPO))]:
            raise RuntimeError("Diagnostic source changed while preparing provenance")
    write_json(args.output / "manifest.json", manifest)
    invocation = [str(REPO / "script/swift_test.sh"), "--skip-build", "--no-parallel", "--jobs", "2",
                  "--filter", "WorkspaceExportMemoryEvidenceTests"]
    fixture = args.fixture.resolve() if args.fixture else args.output / "fixture"
    if not args.fixture:
        seed_env = dict(synthetic_environment(), ASTRA_CHANNEL="dev", ASTRA_EXPORT_EVIDENCE="1", ASTRA_EXPORT_SEED_ONLY="1",
                        ASTRA_EXPORT_FIXTURE_ROOT=str(fixture), ASTRA_EXPORT_SCALE=args.scale)
        with (args.output / "fixture-seed.log").open("w") as stream:
            subprocess.run(invocation, cwd=REPO, env=seed_env, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=180)
        expand_fixture(fixture, 75000 if args.scale == "representative" else 300)
    manifest["fixture"] = inspect_fixture(fixture, args.scale)
    write_json(args.output / "manifest.json", manifest)
    failures = 0
    for mode in args.modes:
        if shutil.disk_usage(REPO).free < 12 * 1024**3:
            raise RuntimeError("Stopped before next fixture: less than 12 GiB free")
        env = dict(synthetic_environment(), ASTRA_CHANNEL="dev", ASTRA_EXPORT_EVIDENCE="1", ASTRA_EXPORT_MODE=mode,
                   ASTRA_EXPORT_SEED_ONLY="0", ASTRA_EXPORT_FIXTURE_ROOT=str(fixture),
                   ASTRA_EXPORT_SCALE=args.scale, ASTRA_EXPORT_BLOCKS=str(args.blocks),
                   ASTRA_EXPORT_PROFILE_PAUSE="60" if args.profile else "0",
                   ASTRA_EXPORT_PROFILE_READY_FILE=str(args.output / f"{mode}-ready.json"),
                   ASTRA_EXPORT_ASSERT_TEARDOWN="1" if args.assert_teardown else "0")
        log = args.output / f"{mode}.log"
        print(f"Running {args.scale}/{mode}; log: {log}", flush=True)
        probes_run = []
        with log.open("w") as stream:
            process = subprocess.Popen(invocation, cwd=REPO, env=env, stdout=stream, stderr=subprocess.STDOUT)
            seen = set()
            # SwiftPM can buffer test stdout until test completion. An atomic
            # marker observes the parked child while it is still alive.
            marker = args.output / f"{mode}-ready.json"
            try:
                while process.poll() is None:
                    if not args.profile or not marker.exists():
                        time.sleep(0.1)
                        continue
                    ready = json.loads(marker.read_text())
                    pid, block = str(ready["pid"]), str(ready["block"])
                    if block in seen:
                        time.sleep(0.1)
                        continue
                    seen.add(block)
                    graph = args.output / f"{mode}-{block}.memgraph"
                    probes = [("leaks", ["/usr/bin/leaks", "--noContent", f"--outputGraph={graph}", pid]),
                              ("heap", ["/usr/bin/heap", "--noContent", "-s", pid]),
                              ("vmmap", ["/usr/bin/vmmap", "-summary", pid])]
                    if block != "0":
                        probes.append(("heap-diff", ["/usr/bin/heap", "--noContent", "-s",
                                                   f"--diffFrom={args.output / (mode + '-0.memgraph')}", pid]))
                    for label, probe in probes:
                        with (args.output / f"{mode}-{block}-{label}.txt").open("w") as evidence:
                            try:
                                probe_result = subprocess.run(probe, stdout=evidence, stderr=subprocess.STDOUT, timeout=12,
                                                              preexec_fn=profile_file_limit)
                                probes_run.append({"block": int(block), "probe": label, "returncode": probe_result.returncode})
                            except subprocess.TimeoutExpired:
                                evidence.write("\nPROFILE_TIMEOUT: evidence incomplete\n")
                                probes_run.append({"block": int(block), "probe": label, "returncode": "timeout"})
                returncode = process.wait()
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    process.wait(timeout=15)  # The harness owns descendant cleanup.
        samples = [json.loads(line.removeprefix("EXPORT_EVIDENCE ")) for line in log.read_text().splitlines()
                   if line.startswith("EXPORT_EVIDENCE {")]
        if args.profile and samples:
            graph = args.output / f"{mode}-{args.blocks}.memgraph"
            for index, address in enumerate(samples[-1].get("context_addresses", [])):
                with (args.output / f"{mode}-context-{index}-references.txt").open("w") as evidence:
                    try:
                        subprocess.run(["/usr/bin/leaks", "--noContent", f"--traceTree={address}", str(graph)],
                                       stdout=evidence, stderr=subprocess.STDOUT, timeout=30)
                    except subprocess.TimeoutExpired:
                        evidence.write("\nPROFILE_TIMEOUT: evidence incomplete\n")
        if len(samples) != args.blocks + 1 or returncode:
            failures += 1
        if args.profile and any(not (args.output / f"{mode}-{block}.memgraph").exists() for block in (0, args.blocks)):
            failures += 1
        manifest["results"].append({"mode": mode, "returncode": returncode, "samples": samples,
                                    "command": invocation, "log_sha256": sha256(log), "profile_probes": probes_run})
        write_json(args.output / "manifest.json", manifest)
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
