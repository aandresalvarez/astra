#!/usr/bin/env python3
"""Adapt only the generated export fixture for the existing isolated Dev AX benchmark."""
import argparse
from contextlib import closing
from pathlib import Path
import sqlite3
import uuid

from dev_scale_benchmark import preflight_fixture, reject_symlinks, sha256, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--payload-repeats", type=int, choices=range(36, 257), default=120)
    args = parser.parse_args()
    reject_symlinks(args.source)
    wal = args.source / "source.store-wal"
    if wal.exists() and wal.stat().st_size:
        parser.error("source has pending WAL data")
    if (args.source / "synthetic-export-fixture.txt").read_text() != "20261106:representative":
        parser.error("source must be the generated representative export fixture")
    if args.output.exists():
        parser.error("output must be a new directory")
    root = args.output.resolve()
    root.mkdir(parents=True)
    with closing(sqlite3.connect((args.source / "source.store").resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as source:
        with closing(sqlite3.connect(root / "default.store")) as target:
            source.backup(target)
            target.row_factory = sqlite3.Row
            if target.execute("SELECT count(*) FROM ZTASKTURNREQUEST").fetchone()[0] != 0:
                raise ValueError("App adapter requires the bare fixture before typed request enrichment")
            workspaces = target.execute("SELECT Z_PK,ZNAME FROM ZWORKSPACE ORDER BY Z_PK").fetchall()
            if [row["ZNAME"] for row in workspaces] != ["A Synthetic", "B Empty"]:
                raise ValueError("fixture workspace drift")
            for index, row in enumerate(workspaces):
                number = 1 - index
                folder = root / "Workspaces" / f"Scale {number:02d}"
                folder.mkdir(parents=True)
                wid = uuid.UUID(f"{1000000 + number:08x}-0000-4000-8000-00000000a57b")
                target.execute("UPDATE ZWORKSPACE SET ZNAME=?,ZPRIMARYPATH=?,ZID=?,ZINSTRUCTIONS=? WHERE Z_PK=?",
                               (folder.name, str(folder), wid.bytes, "Synthetic benchmark seed", row["Z_PK"]))
            tasks = target.execute("SELECT Z_PK,ZUPDATEDAT FROM ZAGENTTASK ORDER BY Z_PK").fetchall()
            if len(tasks) != 2200:
                raise ValueError("fixture task count drift")
            for index, row in enumerate(tasks):
                title = "Long thread" if index == 0 else "Short thread" if index == 1 else f"Task {index:04d}"
                tid = uuid.UUID(f"{0x40000000 + index:08x}-0000-4000-8000-000000000001")
                target.execute("UPDATE ZAGENTTASK SET ZTITLE=?,ZID=?,ZWORKSPACE=?,ZSTATUS='completed',ZUPDATEDAT=? WHERE Z_PK=?",
                               (title, tid.bytes, workspaces[0 if index < 2 else 1]["Z_PK"], row["ZUPDATEDAT"] + index, row["Z_PK"]))
            target.execute("UPDATE ZTASKRUN SET ZSTATUS='completed',ZSTOPREASON='completed'")
            prototype = dict(target.execute("SELECT * FROM ZTASKEVENT ORDER BY Z_PK LIMIT 1").fetchone())
            target.executemany("UPDATE ZTASKEVENT SET ZTYPE='user.message',ZCATEGORY='conversation',ZPAYLOAD=? WHERE Z_PK=?",
                               ((f"Synthetic 425/{index}. " + "benchmark text " * args.payload_repeats, index + 1) for index in range(75000)))
            short = dict(prototype, Z_PK=75001, ZTASK=tasks[1]["Z_PK"],
                         ZRUN=target.execute("SELECT Z_PK FROM ZTASKRUN WHERE ZTASK=?", (tasks[1]["Z_PK"],)).fetchone()[0],
                         ZID=uuid.UUID("20261106-0000-0000-0004-0000000124f8").bytes,
                         ZTYPE="user.message", ZCATEGORY="conversation", ZPAYLOAD="Synthetic 426/0. Short thread.")
            columns = list(short)
            target.execute(f"INSERT INTO ZTASKEVENT ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})", tuple(short.values()))
            target.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=75001 WHERE Z_ENT=? AND Z_NAME='TaskEvent'", (short["Z_ENT"],))
            target.commit()
            if target.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ValueError("fixture integrity failure")
            counts = {name: target.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                      for name, table in [("workspaces", "ZWORKSPACE"), ("tasks", "ZAGENTTASK"),
                                          ("events", "ZTASKEVENT"), ("runs", "ZTASKRUN"), ("artifacts", "ZARTIFACT")]}
    write_json(root / "synthetic-fixture.json", {"format": 1, "seed": 20261106, "profile": "no-files"})
    write_json(root / "seed-counts.json", {"seed": 20261106, "profile": "no-files", "verified_counts": counts, "task_folder_files": 0,
                                         "source_sha256": sha256(args.source / "source.store"), "adapter_sha256": sha256(Path(__file__)),
                                         "payload_repeats": args.payload_repeats, "long_thread_events": 75000})
    preflight_fixture(root, "no-files")
    actions = [["click", "contains:TaskRow_Long thread", "content:contains:Synthetic 425/74991.", "present"],
               ["click", "contains:TaskRow_Short thread", "content:contains:Synthetic 426/0.", "present"],
               ["menu", "Collapse Scale 01", "label:Workspace Configuration", "present"],
               ["press", "Workspace Configuration", "content:contains:Synthetic benchmark", "present"],
               ["click", "Edit", "role:AXTextArea", "present"],
               ["set", "role:AXTextArea", "Synthetic benchmark cycle {cycle}"],
               ["click", "Save", "role:AXTextArea", "absent"],
               ["wait-mirror", "Scale 01", "Synthetic benchmark cycle {cycle}"],
               ["click", "Collapse Scale 01", "contains:TaskRow_Long thread", "absent"]]
    write_json(root / "combined-plan.json", {"warmup": actions, "cycle": [["click", "Expand Scale 01", "contains:TaskRow_Long thread", "present"], *actions]})
    print(root)


if __name__ == "__main__":
    main()
