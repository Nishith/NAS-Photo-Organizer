#!/usr/bin/env python3
"""Generate normalized execution parity outputs for checked-in fixtures."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_ROOT = Path(__file__).resolve().parent

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from chronoframe.core import RunLogger
from chronoframe.core import execute_jobs
from chronoframe.database import CacheDB
from chronoframe.io import fast_hash


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def scenario_dirs() -> list[Path]:
    return sorted(
        path for path in FIXTURE_ROOT.iterdir()
        if (path / "manifest.json").is_file()
        and (path.name.startswith("execution_") or path.name == "resume_pending_queue")
    )


def write_fixture_file(root: Path, entry: dict[str, Any]) -> None:
    destination = root / entry["path"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(entry.get("content_text", "").encode("utf-8"))

    if "mtime_epoch" in entry:
        os.utime(destination, (entry["mtime_epoch"], entry["mtime_epoch"]))


def resolve_fixture_path(spec: str, source_root: Path, dest_root: Path) -> Path:
    if spec.startswith("source/"):
        return source_root / spec.removeprefix("source/")
    if spec.startswith("dest/"):
        return dest_root / spec.removeprefix("dest/")
    raise ValueError(f"Unsupported fixture path spec: {spec}")


def normalize_path(path: str, source_root: Path, dest_root: Path) -> str:
    candidate = Path(path).resolve()
    source_root_resolved = source_root.resolve()
    dest_root_resolved = dest_root.resolve()

    try:
        return f"source/{candidate.relative_to(source_root_resolved).as_posix()}"
    except ValueError:
        pass

    try:
        return f"dest/{candidate.relative_to(dest_root_resolved).as_posix()}"
    except ValueError:
        pass

    return path


def resolve_job_hash(spec: str, source_root: Path, dest_root: Path) -> str:
    if spec.startswith("actual:"):
        path = resolve_fixture_path(spec.removeprefix("actual:"), source_root, dest_root)
        return fast_hash(str(path))
    return spec


def seed_copy_jobs(cache_db: CacheDB, jobs: list[dict[str, Any]], source_root: Path, dest_root: Path) -> None:
    rows = []
    for job in jobs:
        rows.append(
            (
                str(resolve_fixture_path(job["src"], source_root, dest_root)),
                str(resolve_fixture_path(job["dst"], source_root, dest_root)),
                resolve_job_hash(job["hash"], source_root, dest_root),
                job["status"],
            )
        )
    cache_db.enqueue_jobs(rows)


def strip_timestamp_prefix(line: str) -> str:
    return re.sub(r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] ", "", line.strip())


def load_log_markers(log_path: Path, markers: list[str]) -> dict[str, bool]:
    if not log_path.exists():
        return {marker: False for marker in markers}

    with log_path.open("r", encoding="utf-8") as handle:
        content = "\n".join(strip_timestamp_prefix(line) for line in handle if line.strip())

    return {marker: marker in content for marker in markers}


def read_audit_receipt(dest_root: Path, source_root: Path) -> dict[str, Any]:
    receipt_dir = dest_root / ".organize_logs"
    receipts = sorted(receipt_dir.glob("audit_receipt_*.json"))
    if not receipts:
        return {"present": False, "total_jobs": 0, "transfers": []}

    with receipts[-1].open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    return {
        "present": True,
        "total_jobs": payload.get("total_jobs", 0),
        "status": payload.get("status"),
        "transfers": [
            {
                "source": normalize_path(item["source"], source_root, dest_root),
                "dest": normalize_path(item["dest"], source_root, dest_root),
                "hash": item["hash"],
            }
            for item in payload.get("transfers", [])
        ],
    }


def read_queue_rows(db_path: Path, source_root: Path, dest_root: Path) -> list[dict[str, Any]]:
    connection = sqlite3.connect(db_path)
    try:
        rows = connection.execute(
            "SELECT src_path, dst_path, hash, status FROM CopyJobs ORDER BY src_path, dst_path"
        ).fetchall()
    finally:
        connection.close()

    return [
        {
            "src": normalize_path(src_path, source_root, dest_root),
            "dst": normalize_path(dst_path, source_root, dest_root),
            "hash": hash_value,
            "status": status,
        }
        for src_path, dst_path, hash_value, status in rows
    ]


def read_dest_cache_rows(cache_db: CacheDB, source_root: Path, dest_root: Path) -> list[dict[str, Any]]:
    cache = cache_db.get_cache_dict(2)
    rows = []
    for path, entry in sorted(cache.items()):
        rows.append(
            {
                "path": normalize_path(path, source_root, dest_root),
                "hash": entry["hash"],
                "size": entry["size"],
            }
        )
    return rows


def list_media_files(dest_root: Path, source_root: Path) -> list[str]:
    files = []
    for path in sorted(dest_root.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(dest_root).as_posix()
        if rel.startswith(".organize"):
            continue
        files.append(normalize_path(str(path), source_root, dest_root))
    return files


def simplify_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    event_types = []
    complete_status = None
    for event in events:
        event_type = event.get("type")
        if event_type == "task_start":
            event_types.append(f"{event['task']}:start")
        elif event_type == "task_complete":
            event_types.append(f"{event['task']}:complete")
        elif event_type:
            event_types.append(event_type)

        if event_type == "complete":
            complete_status = event.get("status")

    return {
        "event_types": event_types,
        "complete_status": complete_status,
    }


def run_execute_jobs_scenario(manifest: dict[str, Any], source_root: Path, dest_root: Path, db_path: Path) -> dict[str, Any]:
    cache_db = CacheDB(str(db_path))
    try:
        seed_copy_jobs(cache_db, manifest.get("seed_copy_jobs", []), source_root, dest_root)
        log_path = dest_root / ".organize_log.txt"
        run_log = RunLogger(str(log_path))
        run_log.open()
        try:
            execute_jobs(
                cache_db.get_pending_jobs(),
                cache_db,
                str(dest_root),
                run_log=run_log,
                verify=manifest.get("verify", False),
                workers=1,
            )
        finally:
            run_log.close()

        return {
            "events": None,
            "log_path": log_path,
            "queue_rows": read_queue_rows(db_path, source_root, dest_root),
            "dest_cache_rows": read_dest_cache_rows(cache_db, source_root, dest_root),
            "dest_files": list_media_files(dest_root, source_root),
            "audit_receipt": read_audit_receipt(dest_root, source_root),
        }
    finally:
        cache_db.close()


def render_cli_args(args: list[str], source_root: Path, dest_root: Path) -> list[str]:
    rendered = []
    replacements = {
        "{source_root}": str(source_root),
        "{dest_root}": str(dest_root),
    }
    for arg in args:
        rendered_arg = arg
        for token, replacement in replacements.items():
            rendered_arg = rendered_arg.replace(token, replacement)
        rendered.append(rendered_arg)
    return rendered


def run_main_cli_scenario(manifest: dict[str, Any], source_root: Path, dest_root: Path, db_path: Path) -> dict[str, Any]:
    cache_db = CacheDB(str(db_path))
    try:
        seed_copy_jobs(cache_db, manifest.get("seed_copy_jobs", []), source_root, dest_root)
    finally:
        cache_db.close()

    command = [sys.executable, str(REPO_ROOT / "chronoframe.py"), *render_cli_args(manifest.get("args", []), source_root, dest_root)]
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "CHRONOFRAME_NONINTERACTIVE": "1"},
    )
    if result.returncode != 0:
        raise RuntimeError(f"Scenario failed:\n{result.stdout}\n{result.stderr}")

    events = []
    for line in result.stdout.splitlines():
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.append(payload)

    cache_db = CacheDB(str(db_path))
    try:
        return {
            "events": simplify_events(events),
            "log_path": dest_root / ".organize_log.txt",
            "queue_rows": read_queue_rows(db_path, source_root, dest_root),
            "dest_cache_rows": read_dest_cache_rows(cache_db, source_root, dest_root),
            "dest_files": list_media_files(dest_root, source_root),
            "audit_receipt": read_audit_receipt(dest_root, source_root),
        }
    finally:
        cache_db.close()


def run_scenario(manifest_path: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    scenario_dir = manifest_path.parent
    temp_root = Path(tempfile.mkdtemp(prefix=f"{scenario_dir.name}-"))
    source_root = temp_root / "source"
    dest_root = temp_root / "dest"
    db_path = dest_root / ".organize_cache.db"

    try:
        source_root.mkdir(parents=True, exist_ok=True)
        dest_root.mkdir(parents=True, exist_ok=True)

        for entry in manifest.get("files", []):
            target_root = source_root if entry["root"] == "source" else dest_root
            write_fixture_file(target_root, entry)

        runner = manifest["runner"]
        if runner == "execute_jobs":
            outputs = run_execute_jobs_scenario(manifest, source_root, dest_root, db_path)
        elif runner == "main_cli":
            outputs = run_main_cli_scenario(manifest, source_root, dest_root, db_path)
        else:
            raise ValueError(f"Unsupported runner: {runner}")

        return {
            "scenario": scenario_dir.name,
            "description": manifest.get("description", ""),
            "runner": runner,
            "events": outputs["events"],
            "queue_rows": outputs["queue_rows"],
            "dest_cache_rows": outputs["dest_cache_rows"],
            "dest_files": outputs["dest_files"],
            "audit_receipt": outputs["audit_receipt"],
            "log_markers": load_log_markers(outputs["log_path"], manifest.get("log_markers", [])),
        }
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


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
