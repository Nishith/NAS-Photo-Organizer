#!/usr/bin/env python3
"""Generate normalized dry-run parity outputs for checked-in planning fixtures."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_ROOT = Path(__file__).resolve().parent

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from chronoframe.database import CacheDB
from chronoframe.io import fast_hash


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_fixture_file(root: Path, entry: dict[str, Any]) -> None:
    destination = root / entry["path"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = entry.get("content_text", "").encode("utf-8")
    destination.write_bytes(payload)

    if "mtime_epoch" in entry:
        os.utime(destination, (entry["mtime_epoch"], entry["mtime_epoch"]))


def normalize_path(path: str, source_root: Path, dest_root: Path) -> str:
    source_root_resolved = source_root.resolve()
    dest_root_resolved = dest_root.resolve()
    candidate = Path(path).resolve()

    try:
        return f"source/{candidate.relative_to(source_root_resolved).as_posix()}"
    except ValueError:
        pass

    try:
        return f"dest/{candidate.relative_to(dest_root_resolved).as_posix()}"
    except ValueError:
        pass

    return path


def resolve_fixture_path(spec: str, source_root: Path, dest_root: Path) -> Path:
    if spec.startswith("source/"):
        return source_root / spec.removeprefix("source/")
    if spec.startswith("dest/"):
        return dest_root / spec.removeprefix("dest/")
    raise ValueError(f"Unsupported fixture path spec: {spec}")


def resolve_hash_spec(spec: str, source_root: Path, dest_root: Path) -> str:
    if spec.startswith("actual:"):
        path = resolve_fixture_path(spec.removeprefix("actual:"), source_root, dest_root)
        return fast_hash(str(path))
    return spec


def seed_destination_cache(cache_db: CacheDB, rows: list[dict[str, Any]], source_root: Path, dest_root: Path) -> None:
    updates = []
    for row in rows:
        path = resolve_fixture_path(row["path"], source_root, dest_root)
        updates.append(
            (
                str(path),
                resolve_hash_spec(row["hash"], source_root, dest_root),
                row["size"],
                row["mtime"],
            )
        )
    cache_db.save_batch(2, updates)


def parse_report_rows(report_path: Path, source_root: Path, dest_root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with report_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            rows.append(
                {
                    "source": normalize_path(row["Source"], source_root, dest_root),
                    "destination": normalize_path(row["Destination"], source_root, dest_root),
                    "hash": row["Hash"],
                    "status": row["Status"],
                }
            )
    return rows


def simplify_events(events: list[dict[str, Any]]) -> tuple[list[str], dict[str, Any]]:
    sequence: list[str] = []
    counts = {
        "discovery_found": None,
        "dest_hash_total": None,
        "src_hash_total": None,
        "classification_already_in_dst": None,
        "classification_new": None,
        "classification_dups": None,
        "classification_errors": None,
        "copy_plan_ready": None,
        "complete_status": None,
    }

    for event in events:
        event_type = event.get("type")
        if event_type == "startup":
            sequence.append("startup")
        elif event_type == "task_start":
            sequence.append(f"{event['task']}:start")
            if event["task"] == "dest_hash":
                counts["dest_hash_total"] = event.get("total")
            if event["task"] == "src_hash":
                counts["src_hash_total"] = event.get("total")
        elif event_type == "task_complete":
            sequence.append(f"{event['task']}:complete")
            if event["task"] == "discovery":
                counts["discovery_found"] = event.get("found")
            elif event["task"] == "classification":
                counts["classification_already_in_dst"] = event.get("already_in_dst")
                counts["classification_new"] = event.get("new")
                counts["classification_dups"] = event.get("dups")
                counts["classification_errors"] = event.get("errors")
        elif event_type == "copy_plan_ready":
            sequence.append("copy_plan_ready")
            counts["copy_plan_ready"] = event.get("count")
        elif event_type == "complete":
            sequence.append("complete")
            counts["complete_status"] = event.get("status")

    return sequence, counts


def extract_warning_messages(events: list[dict[str, Any]]) -> list[str]:
    return [event["message"] for event in events if event.get("type") == "warning" and "message" in event]


def run_scenario(manifest_path: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    scenario_dir = manifest_path.parent

    temp_root = Path(tempfile.mkdtemp(prefix=f"{scenario_dir.name}-"))
    source_root = temp_root / "source"
    dest_root = temp_root / "dest"

    try:
        source_root.mkdir(parents=True, exist_ok=True)
        dest_root.mkdir(parents=True, exist_ok=True)

        for entry in manifest["files"]:
            target_root = source_root if entry["root"] == "source" else dest_root
            write_fixture_file(target_root, entry)

        if manifest.get("seed_destination_cache"):
            cache_db = CacheDB(str(dest_root / ".organize_cache.db"))
            try:
                seed_destination_cache(cache_db, manifest["seed_destination_cache"], source_root, dest_root)
            finally:
                cache_db.close()

        command = [
            sys.executable,
            str(REPO_ROOT / "chronoframe.py"),
            "--source",
            str(source_root),
            "--dest",
            str(dest_root),
            "--dry-run",
            "--yes",
            "--json",
            "--workers",
            "1",
        ]
        if manifest.get("fast_dest", False):
            command.append("--fast-dest")

        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "CHRONOFRAME_NONINTERACTIVE": "1"},
        )
        if result.returncode != 0:
            raise RuntimeError(f"Scenario {scenario_dir.name} failed:\n{result.stdout}\n{result.stderr}")

        events = []
        for line in result.stdout.splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            events.append(payload)

        complete_event = next((event for event in reversed(events) if event.get("type") == "complete"), None)
        if complete_event is None:
            raise RuntimeError(f"Scenario {scenario_dir.name} emitted no complete event.")

        report_path = Path(complete_event["report"])
        phase_sequence, counts = simplify_events(events)
        rows = parse_report_rows(report_path, source_root, dest_root)

        return {
            "scenario": scenario_dir.name,
            "description": manifest.get("description", ""),
            "phase_sequence": phase_sequence,
            "counts": counts,
            "warning_messages": extract_warning_messages(events),
            "report_rows": rows,
        }
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def write_expected_outputs(scenario_dir: Path) -> None:
    output = run_scenario(scenario_dir / "manifest.json")
    expected_path = scenario_dir / "expected.json"
    with expected_path.open("w", encoding="utf-8") as handle:
        json.dump(output, handle, indent=2)
        handle.write("\n")


def scenario_dirs() -> list[Path]:
    return sorted(
        path
        for path in FIXTURE_ROOT.iterdir()
        if (path / "manifest.json").is_file() and path.name.startswith("planning_")
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", action="append", help="Only generate the named scenario directory")
    parser.add_argument("--write", action="store_true", help="Write expected.json files in place")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    selected = set(args.scenario or [])
    outputs = []

    for scenario_dir in scenario_dirs():
        if selected and scenario_dir.name not in selected:
            continue
        output = run_scenario(scenario_dir / "manifest.json")
        outputs.append(output)
        if args.write:
            expected_path = scenario_dir / "expected.json"
            with expected_path.open("w", encoding="utf-8") as handle:
                json.dump(output, handle, indent=2)
                handle.write("\n")

    print(json.dumps(outputs, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
