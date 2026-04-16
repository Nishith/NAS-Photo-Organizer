#!/usr/bin/env python3
"""
Synthetic benchmark harness for the Python reference engine.
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from chronoframe.core import build_dest_index
from chronoframe.database import CacheDB
from chronoframe.io import process_single_file
from chronoframe.metadata import get_file_date

METRIC_SPECS = {
    "hashing.files_per_second": {"unit": "files/s", "higher_is_better": True},
    "classification.files_per_second": {"unit": "files/s", "higher_is_better": True},
    "destination_indexing.cold_entries_per_second": {"unit": "entries/s", "higher_is_better": True},
    "destination_indexing.fast_dest_entries_per_second": {"unit": "entries/s", "higher_is_better": True},
    "preview.files_per_second": {"unit": "files/s", "higher_is_better": True},
}


def parse_args():
    parser = argparse.ArgumentParser(description="Chronoframe synthetic benchmark harness")
    parser.add_argument("--source-count", type=int, default=250, help="Synthetic source-file count")
    parser.add_argument("--dest-count", type=int, default=400, help="Synthetic destination-file count")
    parser.add_argument("--workers", type=int, default=8, help="Thread worker count")
    parser.add_argument("--file-size-kb", type=int, default=64, help="Synthetic file size in KB")
    parser.add_argument("--output", help="Write the benchmark summary JSON to this file")
    parser.add_argument("--baseline", help="Compare the current run against a saved benchmark JSON file")
    parser.add_argument(
        "--budget",
        type=float,
        default=0.05,
        help="Maximum allowed regression versus the baseline, expressed as a decimal fraction",
    )
    parser.add_argument("--keep", action="store_true", help="Keep the generated temp tree for inspection")
    return parser.parse_args()


def make_tree(root, count, size_kb, prefix):
    os.makedirs(root, exist_ok=True)
    payload = (prefix.encode("utf-8") * 1024)[:1024] * size_kb
    created = []

    for index in range(count):
        month = (index % 12) + 1
        day = (index % 28) + 1
        hour = index % 24
        minute = (index * 3) % 60
        second = (index * 7) % 60
        folder = os.path.join(root, f"batch_{index // 100:03d}")
        os.makedirs(folder, exist_ok=True)
        filename = f"VID_2024{month:02d}{day:02d}_{hour:02d}{minute:02d}{second:02d}_{index:05d}.mov"
        path = os.path.join(folder, filename)
        with open(path, "wb") as handle:
            handle.write(payload)
        created.append(path)

    return created


def benchmark_hashing(paths, workers):
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        list(executor.map(lambda path: process_single_file(path, None), paths))
    elapsed = time.perf_counter() - start
    return {
        "seconds": elapsed,
        "files_per_second": 0 if elapsed == 0 else len(paths) / elapsed,
    }


def benchmark_classification(paths, workers):
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        list(executor.map(get_file_date, paths))
    elapsed = time.perf_counter() - start
    return {
        "seconds": elapsed,
        "files_per_second": 0 if elapsed == 0 else len(paths) / elapsed,
    }


def benchmark_destination_indexing(dest_root, workers, file_count):
    db_path = os.path.join(dest_root, ".organize_cache.db")
    cache_db = CacheDB(db_path)
    try:
        start = time.perf_counter()
        build_dest_index(dest_root, cache_db, workers=workers, fast_dest=False)
        cold_elapsed = time.perf_counter() - start

        start = time.perf_counter()
        build_dest_index(dest_root, cache_db, workers=workers, fast_dest=True)
        fast_elapsed = time.perf_counter() - start
    finally:
        cache_db.close()

    return {
        "cold_seconds": cold_elapsed,
        "cold_entries_per_second": 0 if cold_elapsed == 0 else file_count / cold_elapsed,
        "fast_dest_seconds": fast_elapsed,
        "fast_dest_entries_per_second": 0 if fast_elapsed == 0 else file_count / fast_elapsed,
    }


def benchmark_preview(repo_root, source_root, dest_root, workers, source_count):
    command = [
        "python3",
        os.path.join(repo_root, "chronoframe.py"),
        "--source",
        source_root,
        "--dest",
        dest_root,
        "--dry-run",
        "--fast-dest",
        "--workers",
        str(workers),
        "--yes",
        "--json",
    ]

    start = time.perf_counter()
    result = subprocess.run(
        command,
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "CHRONOFRAME_NONINTERACTIVE": "1"},
    )
    elapsed = time.perf_counter() - start

    complete_events = []
    for line in result.stdout.splitlines():
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if payload.get("type") == "complete":
            complete_events.append(payload)

    return {
        "seconds": elapsed,
        "files_per_second": 0 if elapsed == 0 else source_count / elapsed,
        "exit_code": result.returncode,
        "complete_events": len(complete_events),
    }


def nested_lookup(payload: dict[str, Any], path: str) -> Any:
    current: Any = payload
    for segment in path.split("."):
        if not isinstance(current, dict) or segment not in current:
            return None
        current = current[segment]
    return current


def extract_metrics(summary: dict[str, Any]) -> dict[str, dict[str, Any]]:
    metrics: dict[str, dict[str, Any]] = {}
    for metric_name, spec in METRIC_SPECS.items():
        value = nested_lookup(summary, metric_name)
        if value is None:
            continue
        metrics[metric_name] = {
            "value": float(value),
            "unit": spec["unit"],
            "higher_is_better": spec["higher_is_better"],
        }
    return metrics


def compare_to_baseline(
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    max_regression: float = 0.05,
) -> dict[str, Any]:
    candidate_metrics = extract_metrics(candidate)
    baseline_metrics = extract_metrics(baseline)
    checked_metrics = []
    regressions = []
    improvements = []
    missing_metrics = []

    for metric_name in sorted(METRIC_SPECS):
        candidate_metric = candidate_metrics.get(metric_name)
        baseline_metric = baseline_metrics.get(metric_name)

        if candidate_metric is None or baseline_metric is None:
            missing_metrics.append(metric_name)
            continue

        baseline_value = baseline_metric["value"]
        candidate_value = candidate_metric["value"]
        if baseline_value <= 0:
            missing_metrics.append(metric_name)
            continue

        delta_fraction = (candidate_value - baseline_value) / baseline_value
        budget_floor = baseline_value * (1 - max_regression)
        within_budget = candidate_value >= budget_floor

        comparison = {
            "metric": metric_name,
            "baseline": baseline_value,
            "candidate": candidate_value,
            "delta_fraction": delta_fraction,
            "unit": baseline_metric["unit"],
            "within_budget": within_budget,
        }
        checked_metrics.append(comparison)

        if delta_fraction > 0:
            improvements.append(comparison)
        elif not within_budget:
            regressions.append(comparison)

    return {
        "pass": not regressions,
        "max_regression": max_regression,
        "checked_metrics": checked_metrics,
        "regressions": regressions,
        "improvements": improvements,
        "missing_metrics": missing_metrics,
    }


def write_summary(summary: dict[str, Any], output_path: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")


def main():
    args = parse_args()
    temp_root = tempfile.mkdtemp(prefix="chronoframe-bench-")
    exit_code = 0

    try:
        source_root = os.path.join(temp_root, "source")
        dest_root = os.path.join(temp_root, "dest")
        source_paths = make_tree(source_root, args.source_count, args.file_size_kb, "src")
        make_tree(dest_root, args.dest_count, args.file_size_kb, "dst")

        summary = {
            "inputs": {
                "source_count": args.source_count,
                "dest_count": args.dest_count,
                "workers": args.workers,
                "file_size_kb": args.file_size_kb,
            },
            "hashing": benchmark_hashing(source_paths, args.workers),
            "classification": benchmark_classification(source_paths, args.workers),
            "destination_indexing": benchmark_destination_indexing(dest_root, args.workers, args.dest_count),
            "preview": benchmark_preview(REPO_ROOT, source_root, dest_root, args.workers, args.source_count),
        }

        if args.baseline:
            with open(args.baseline, "r", encoding="utf-8") as handle:
                baseline_summary = json.load(handle)
            summary["comparison"] = compare_to_baseline(summary, baseline_summary, max_regression=args.budget)
            if not summary["comparison"]["pass"]:
                exit_code = 1

        if args.output:
            write_summary(summary, args.output)

        print(json.dumps(summary, indent=2))
    finally:
        if args.keep:
            print(json.dumps({"kept_temp_root": temp_root}))
        else:
            shutil.rmtree(temp_root, ignore_errors=True)

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
