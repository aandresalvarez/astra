#!/usr/bin/env python3
"""Produce a small, shareable summary; raw diagnostics stay in the run output."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics


def stats(values):
    ordered = sorted(values)
    return {"n": len(ordered), "median_ms": round(statistics.median(ordered), 2),
            "p95_ms": round(ordered[math.ceil(len(ordered)*.95)-1], 2), "max_ms": round(max(ordered), 2)}


def heap_summary(path):
    text = path.read_text()
    total = re.search(r"All zones: (\d+) nodes \((\d+) bytes\)", text)
    launched = re.search(r"^Launch Time:\s+(.+)$", text, re.MULTILINE)
    sampled = re.search(r"^Date/Time:\s+(.+)$", text, re.MULTILINE)
    wanted = {"AgentTask", "TaskEvent", "TaskRun", "Workspace", "ModelContext", "NSManagedObjectContext", "NSSQLRow"}
    classes = {name: {"count": 0, "bytes": 0} for name in sorted(wanted)}
    for line in text.splitlines():
        match = re.match(r"\s*(\d+)\s+(\d+)\s+\S+\s+(.+?)\s{2,}(?:Swift|ObjC|C)\s+", line)
        if match:
            name = match[3]
            if name.startswith("Swift._DictionaryStorage<SwiftData.PersistentIdentifier, SwiftData.ModelContext.(WeakAnyPersistentObject"):
                name = "SwiftData.ModelContext weak object map"
            if name in wanted or name == "SwiftData.ModelContext weak object map" or name in {
                "SwiftData._KKMDBackingData<ASTRAModels.AgentTask>", "SwiftData._KKMDBackingData<ASTRAModels.TaskEvent>",
                "SwiftData._KKMDBackingData<ASTRAModels.TaskRun>"}:
                classes[name] = {"count": int(match[1]), "bytes": int(match[2])}
    return {"launch_time": launched[1] if launched else None, "sample_time": sampled[1] if sampled else None,
            "malloc_nodes": int(total[1]) if total else None,
            "live_malloc_bytes": int(total[2]) if total else None, "selected_classes": classes}


def leaks_summary(path):
    match = re.search(r"(\d+) leaks for (\d+) total leaked bytes", path.read_text())
    return {"leak_count": int(match[1]), "leaked_bytes": int(match[2])} if match else None


def final_file_counts(root):
    workspaces = root / "Workspaces"
    if not workspaces.is_dir():
        raise ValueError("Retain the synthetic workspace output until the summary is written")
    files = [p for p in workspaces.rglob("*") if p.is_file()]
    return {"workspace_regular_files": len(files),
            "task_folder_regular_files": sum(p.relative_to(workspaces).parts[1:3] == (".astra", "tasks") for p in files)}


def summarize(path):
    report = json.loads(path.read_text())
    if report["status"] != "complete" or len(report["runs"]) != report["requested_runs"]:
        raise ValueError("Only a complete report with every requested run can be summarized")
    groups, probes, saves = {}, {}, []
    for run in report["runs"]:
        for action in run["actions"]:
            if action["cycle"] == 0:
                continue
            result = action["result"]
            latency = result.get("click_to_ax_ready_ms", result.get("press_action_to_ax_ready_ms"))
            if latency is not None:
                key = " / ".join(action["command"][:2]) + " / " + action["command"][-1]
                groups.setdefault(key, []).append(latency)
                probes.setdefault(key, []).append(result["last_ready_probe_ms"])
            if result.get("save_dispatch_to_mirror_ms") is not None:
                saves.append(result["save_dispatch_to_mirror_ms"])
    host = report["host"]
    host = dict(host, power=re.sub(r"\s*\(id=\d+\)", "", host["power"]))
    return {"schema_version": 1, "app_revision": report["app_build"]["ASTRAGitCommit"],
        "app_version": report["app_build"]["CFBundleShortVersionString"], "app_build": report["app_build"]["CFBundleVersion"],
        "app_build_date": report["app_build"]["ASTRABuildDate"], "astra_schema_version": report["app_build"]["ASTRASchemaVersion"],
        "app_channel": report["app_build"]["ASTRAChannel"], "app_linked_channel": report["app_build"]["ASTRALinkedChannel"],
        "fixture": report["fixture"], "omit_task_files": report["omit_task_files"],
        "run_count": len(report["runs"]), "measured_cycles_per_run": report["cycles"], "idle_seconds": report["idle_seconds"],
        "host": {key: host[key] for key in ["os", "hardware", "ram_bytes", "swift", "power", "load_before", "disk_free_bytes"]},
        "input_sha256": report["input_sha256"],
        "cold_process_launch_ms": [round(run["launch_to_ax_ready_ms"], 2) for run in report["runs"]],
        "actions": {key: stats(values) for key, values in groups.items()},
        "final_ready_query_cost": {key: stats(values) for key, values in probes.items()},
        "save_dispatch_to_mirror": stats(saves) if saves else None,
        "memory_by_run": [{"samples": [{key: sample[key] for key in ["stage", "elapsed_s", "physical_footprint_bytes", "peak_physical_footprint_bytes"]}
            for sample in run["memory"]], "heap_exit_status": run["heap_exit_status"], "leaks_exit_status": run["leaks_exit_status"],
            "heap": {stage: heap_summary(path.parent / f"run-{index}" / f"heap-{stage}.txt") for stage in ["warm-idle", "final-idle"]},
            "leaks": leaks_summary(path.parent / f"run-{index}" / "leaks.txt"),
            "final_files": final_file_counts(path.parent / f"run-{index}"),
            "final_counts": run["final_counts"], "initial_task_folder_files": run["initial_task_folder_files"], "load_after": run["load_after"]}
            for index, run in enumerate(report["runs"], 1)]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.report), indent=2, sort_keys=True))
