import os
import sys
import time
import argparse
import concurrent.futures
import json
import csv
import yaml
from datetime import datetime
from collections import defaultdict

from rich.console import Console
from rich.progress import (
    Progress, SpinnerColumn, TextColumn, BarColumn,
    TaskProgressColumn, TimeRemainingColumn, MofNCompleteColumn,
)
from rich.prompt import Confirm
from rich.panel import Panel

from .database import CacheDB
from .io import safe_copy_atomic, process_single_file, verify_copy
from .metadata import get_file_date, ALL_EXTS, SKIP_FILES, HAS_EXIFREAD

SEQ_WIDTH = 3
MAX_CONSECUTIVE_FAILURES = 5
DEFAULT_WORKERS = 8

# Resolve paths relative to the package directory (not cwd)
_PKG_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_DIR = os.path.dirname(_PKG_DIR)

console = Console()


# ── Run Logger ──────────────────────────────────────────────────────────────

class RunLogger:
    """Appends to a persistent plain-text log alongside the DB and audit receipts."""

    def __init__(self, log_path):
        self.log_path = log_path
        self._fh = None

    def open(self):
        try:
            self._fh = open(self.log_path, 'a')
        except OSError:
            self._fh = None

    def close(self):
        if self._fh:
            self._fh.close()
            self._fh = None

    def log(self, message):
        ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        line = f"[{ts}] {message}"
        if self._fh:
            self._fh.write(line + '\n')
            self._fh.flush()

    def warn(self, message):
        self.log(f"WARNING: {message}")

    def error(self, message):
        self.log(f"ERROR: {message}")


# ── CLI ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(description="NAS Photo Organizer v3")
    parser.add_argument("--source", type=str, default=None, help="Source folder")
    parser.add_argument("--dest", type=str, default=None, help="Destination folder")
    parser.add_argument("--profile", type=str, default=None, help="Use paths from nas_profiles.yaml")
    parser.add_argument("--dry-run", action="store_true", help="Generate CSV report without copying")
    parser.add_argument("--rebuild-cache", action="store_true", help="Force database re-index")
    parser.add_argument("--verify", action="store_true", help="Re-hash each file after copy to verify integrity")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"Thread pool size for hashing (default {DEFAULT_WORKERS})")
    parser.add_argument("-y", "--yes", action="store_true", help="Skip confirmation prompts (unattended)")
    return parser.parse_args()


def _find_profiles_yaml():
    """Look for nas_profiles.yaml next to the project root (not cwd)."""
    return os.path.join(_PROJECT_DIR, "nas_profiles.yaml")


def load_profile(profile_name):
    yaml_path = _find_profiles_yaml()
    if not os.path.exists(yaml_path):
        console.print(f"[red]Error:[/red] '{yaml_path}' not found. Cannot load profile '{profile_name}'.")
        sys.exit(1)

    with open(yaml_path, 'r') as f:
        profiles = yaml.safe_load(f)

    if not profiles or profile_name not in profiles:
        console.print(f"[red]Error:[/red] Profile '{profile_name}' not defined in nas_profiles.yaml")
        sys.exit(1)

    return profiles[profile_name].get('source'), profiles[profile_name].get('dest')


# ── Destination Indexing ────────────────────────────────────────────────────

def build_dest_index(dst_dir, cache_db, rebuild=False, workers=DEFAULT_WORKERS,
                     progress=None, ptask=None):
    import re
    if rebuild:
        cache_db.clear_cache(type_id=2)

    cache = cache_db.get_cache_dict(2)
    files_to_check = []

    seq_index = defaultdict(int)
    dup_seq_index = defaultdict(int)
    seq_pattern = re.compile(r'^(\d{4}-\d{2}-\d{2}|Unknown)_(\d+)')
    dup_dir = os.path.join(dst_dir, "Duplicate")
    
    if progress and ptask:
        progress.update(ptask, total=None)

    for root, dirs, fnames in os.walk(dst_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if fname.startswith('.') or fname in SKIP_FILES or os.path.splitext(fname)[1].lower() not in ALL_EXTS:
                continue
            path = os.path.join(root, fname)
            files_to_check.append(path)

            m = seq_pattern.match(fname)
            if m:
                prefix = m.group(1)
                date_str = "Unknown_Date" if prefix == "Unknown" else prefix
                seq = int(m.group(2))
                if path.startswith(dup_dir):
                    if seq > dup_seq_index[date_str]:
                        dup_seq_index[date_str] = seq
                else:
                    if seq > seq_index[date_str]:
                        seq_index[date_str] = seq

            if progress and ptask and len(files_to_check) % 1000 == 0:
                progress.update(ptask, description=f"[cyan]Scanning Dest... ({len(files_to_check)} found)")

    hash_index = {}
    updates = []

    if progress and ptask:
        if len(files_to_check) == 0:
            progress.update(ptask, description="[cyan]Index Built (Empty)", total=1, completed=1)
        else:
            progress.update(ptask, description="[cyan]Validating Dest Hashes...", total=len(files_to_check))

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(process_single_file, path, cache.get(path)): path
            for path in files_to_check
        }
        for future in concurrent.futures.as_completed(futures):
            path = futures[future]
            try:
                h, size, mtime, was_hashed = future.result()
                if h:
                    hash_index[h] = path
                    if was_hashed:
                        updates.append((path, h, size, mtime))
            except Exception:
                pass
            if progress and ptask:
                progress.advance(ptask)

    cache_db.save_batch(2, updates)
    return hash_index, seq_index, dup_seq_index


# ── Reports ─────────────────────────────────────────────────────────────────

def generate_dry_run_report(jobs, dst, report_path):
    with open(report_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Source", "Destination", "Hash", "Status"])
        for src, dst_path, h, status in jobs:
            writer.writerow([src, dst_path, h, status])
    console.print(f"\n[green]Dry-run complete.[/green] Report: [cyan]{report_path}[/cyan]")


def generate_audit_receipt(jobs_executed, dest_path):
    receipt_name = f"audit_receipt_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    log_dir = os.path.join(dest_path, ".organize_logs")
    os.makedirs(log_dir, exist_ok=True)
    rpath = os.path.join(log_dir, receipt_name)
    payload = {
        "timestamp": datetime.now().isoformat(),
        "total_jobs": len(jobs_executed),
        "status": "COMPLETED",
        "transfers": [{"source": src, "dest": dst, "hash": h} for src, dst, h in jobs_executed]
    }
    with open(rpath, 'w') as f:
        json.dump(payload, f, indent=4)
    console.print(f"\n[bold green]Audit receipt:[/bold green] [cyan]{rpath}[/cyan]")


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    # Resolve paths
    src = args.source
    dst = args.dest

    if args.profile:
        src, dst = load_profile(args.profile)
    elif not src or not dst:
        # Fallback to 'default' profile if it exists
        yaml_path = _find_profiles_yaml()
        if os.path.exists(yaml_path):
            with open(yaml_path, 'r') as f:
                profiles = yaml.safe_load(f)
                if profiles and 'default' in profiles:
                    src = src or profiles['default'].get('source')
                    dst = dst or profiles['default'].get('dest')

    if not src or not dst:
        console.print("[red]Error: Source and Destination must be provided via --source/--dest or a profile.[/red]")
        sys.exit(1)

    dup = os.path.join(dst, "Duplicate")
    rebuild = args.rebuild_cache
    workers = max(1, args.workers)

    console.print(Panel(
        f"[bold cyan]NAS Photo Organizer v3[/bold cyan]\n"
        f"[white]Source:[/white]  {src}\n"
        f"[white]Dest:[/white]    {dst}\n"
        f"[white]Workers:[/white] {workers}",
        expand=False,
    ))

    if not HAS_EXIFREAD:
        console.print("[yellow]exifread not installed — falling back to mdls (slower).[/yellow]")

    # Initialize DB and logger
    cache_db = CacheDB(os.path.join(dst, ".organize_cache.db"))
    run_log = RunLogger(os.path.join(dst, ".organize_log.txt"))
    run_log.open()
    run_log.log(f"=== Run started: src={src} dst={dst} dry_run={args.dry_run} ===")

    # Resume interrupted session?
    pending_jobs = cache_db.get_pending_jobs()
    if pending_jobs:
        console.print(f"\n[bold yellow]Interrupted session detected![/bold yellow] {len(pending_jobs)} pending jobs in queue.")
        run_log.log(f"Found {len(pending_jobs)} pending jobs from interrupted session")
        if args.dry_run:
            console.print("[cyan]Dry-run active — ignoring pending queue.[/cyan]")
        elif args.yes:
            execute_jobs(pending_jobs, cache_db, dst, run_log, verify=args.verify)
            run_log.log("Resumed session complete")
            run_log.close()
            cache_db.close()
            return
        else:
            if Confirm.ask("Resume where you left off?"):
                execute_jobs(pending_jobs, cache_db, dst, run_log, verify=args.verify)
                console.print("[bold green]Queue complete![/bold green]")
                run_log.log("Resumed session complete")
                run_log.close()
                cache_db.close()
                return
            else:
                if Confirm.ask("[red]Flush the pending queue?[/red] (No files will be deleted)"):
                    cache_db.clear_jobs()
                    run_log.log("Pending queue flushed by user")
                    console.print("[green]Queue flushed.[/green] Rescanning...")

    # ── Discovery ───────────────────────────────────────────────────────
    src_files = []
    with console.status("[bold blue]Scanning source directories...", spinner="dots"):
        for root, dirs, fnames in os.walk(src):
            dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
            for fname in sorted(fnames):
                if fname.startswith('.') or fname in SKIP_FILES:
                    continue
                if os.path.splitext(fname)[1].lower() in ALL_EXTS:
                    src_files.append(os.path.join(root, fname))

    if not src_files:
        console.print("[yellow]No valid media files found in source.[/yellow]")
        run_log.log("No valid media files found in source")
        run_log.close()
        cache_db.close()
        return

    console.print(f"[green]Found {len(src_files)} source files.[/green]")
    run_log.log(f"Found {len(src_files)} source files")

    # ── Indexing ────────────────────────────────────────────────────────
    src_hashes = {}
    src_updates = []
    dest_hash_index = {}
    dest_seq = {}
    dup_seq = {}

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeRemainingColumn(),
        console=console,
        transient=False,
    ) as progress:

        task_dest = progress.add_task("[cyan]Scanning Destination Array...", total=None)
        dest_hash_index, dest_seq, dup_seq = build_dest_index(
            dst, cache_db, rebuild, workers, progress, task_dest
        )

        task_src = progress.add_task("[magenta]Hashing Source Payload...", total=len(src_files))
        src_cache = cache_db.get_cache_dict(1)

        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(process_single_file, path, src_cache.get(path)): path
                for path in src_files
            }
            for future in concurrent.futures.as_completed(futures):
                path = futures[future]
                try:
                    h, size, mtime, was_hashed = future.result()
                    src_hashes[path] = h
                    if h and was_hashed:
                        src_updates.append((path, h, size, mtime))
                except Exception:
                    pass
                progress.advance(task_src)

    cache_db.save_batch(1, src_updates)

    # ── Classification ──────────────────────────────────────────────────
    date_groups = defaultdict(list)
    src_dups = []
    already_in_dst = 0
    hash_errors = 0
    src_seen = {}

    with console.status("[bold yellow]Classifying by date...", spinner="arc"):
        for src_path in src_files:
            h = src_hashes.get(src_path)
            if not h:
                hash_errors += 1
                continue

            if h in dest_hash_index:
                already_in_dst += 1
                continue

            if h in src_seen:
                src_dups.append((src_path, h))
                continue

            src_seen[h] = src_path
            dt = get_file_date(src_path)
            date_str = dt.strftime('%Y-%m-%d') if dt.year > 1971 else "Unknown_Date"
            date_groups[date_str].append((src_path, h))

    run_log.log(f"Classification: {already_in_dst} already in dest, "
                f"{len(src_seen)} new, {len(src_dups)} internal dups, "
                f"{hash_errors} hash errors")
    console.print(f"[cyan]{already_in_dst} already in destination (skipped)[/cyan]")
    if hash_errors:
        console.print(f"[yellow]{hash_errors} files could not be hashed (skipped)[/yellow]")

    # ── Build copy plan ─────────────────────────────────────────────────
    jobs_to_insert = []
    for date_str in sorted(date_groups.keys()):
        start_seq = dest_seq.get(date_str, 0) + 1
        for i, (src_path, h) in enumerate(date_groups[date_str]):
            seq = start_seq + i
            ext = os.path.splitext(src_path)[1]
            if date_str == 'Unknown_Date':
                filename = f"Unknown_{str(seq).zfill(SEQ_WIDTH)}{ext}"
                dst_path = os.path.join(dst, "Unknown_Date", filename)
            else:
                yyyy, mm, dd = date_str.split('-')
                filename = f"{date_str}_{str(seq).zfill(SEQ_WIDTH)}{ext}"
                dst_path = os.path.join(dst, yyyy, mm, dd, filename)
            jobs_to_insert.append((src_path, dst_path, h, 'PENDING'))

    for src_path, h in src_dups:
        dt = get_file_date(src_path)
        date_str = dt.strftime('%Y-%m-%d') if dt.year > 1971 else "Unknown_Date"
        start_seq = dup_seq.get(date_str, 0) + 1
        dup_seq[date_str] += 1
        ext = os.path.splitext(src_path)[1]

        if date_str == 'Unknown_Date':
            filename = f"Unknown_{str(start_seq).zfill(SEQ_WIDTH)}{ext}"
            dst_path = os.path.join(dup, "Unknown_Date", filename)
        else:
            yyyy, mm, dd = date_str.split('-')
            filename = f"{date_str}_{str(start_seq).zfill(SEQ_WIDTH)}{ext}"
            dst_path = os.path.join(dup, yyyy, mm, dd, filename)
        jobs_to_insert.append((src_path, dst_path, h, 'PENDING'))

    # ── Dry run or execute ──────────────────────────────────────────────
    if args.dry_run:
        log_dir = os.path.join(dst, ".organize_logs")
        os.makedirs(log_dir, exist_ok=True)
        report_path = os.path.join(log_dir, f"dry_run_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv")
        generate_dry_run_report(jobs_to_insert, dst, report_path)
        run_log.log(f"Dry-run report: {len(jobs_to_insert)} planned, report at {report_path}")
        run_log.close()
        cache_db.close()
        return

    if not jobs_to_insert:
        console.print("[bold green]Everything is up to date! Nothing to copy.[/bold green]")
        run_log.log("Nothing to copy — all files already in destination")
        run_log.close()
        cache_db.close()
        return

    console.print(f"\n[bold magenta]{len(jobs_to_insert)} files ready to copy.[/bold magenta]")
    if not args.yes:
        if not Confirm.ask("Proceed with copy?"):
            run_log.log("Copy cancelled by user")
            run_log.close()
            cache_db.close()
            return

    cache_db.enqueue_jobs(jobs_to_insert)
    execute_jobs(cache_db.get_pending_jobs(), cache_db, dst, run_log, verify=args.verify)

    run_log.log("Run complete")
    run_log.close()
    cache_db.close()


def execute_jobs(pending_jobs, cache_db, dst_root, run_log=None, verify=False):
    console.print(f"\n[bold cyan]Copying {len(pending_jobs)} files...[/bold cyan]")
    dest_updates = []

    consecutive_fail = 0
    executed_log = []
    verify_failures = 0

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeRemainingColumn(),
        console=console,
    ) as progress:
        task_id = progress.add_task("[green]Copying...", total=len(pending_jobs))

        for src_p, dst_p, h in pending_jobs:
            try:
                result = safe_copy_atomic(src_p, dst_p)
                if verify:
                    if not verify_copy(src_p, result, h):
                        if run_log:
                            run_log.error(f"Verification failed: {src_p} → {result}")
                        verify_failures += 1
                cache_db.update_job_status(src_p, 'COPIED')
                st = os.stat(result)
                dest_updates.append((result, h, st.st_size, st.st_mtime))
                executed_log.append((src_p, dst_p, h))
                consecutive_fail = 0
            except Exception as e:
                cache_db.update_job_status(src_p, 'FAILED')
                if run_log:
                    run_log.error(f"Copy failed: {src_p} → {dst_p}: {e}")
                consecutive_fail += 1
                if consecutive_fail >= MAX_CONSECUTIVE_FAILURES:
                    msg = f"Aborting: {MAX_CONSECUTIVE_FAILURES} consecutive failures"
                    console.print(f"\n[bold red]{msg}[/bold red]")
                    if run_log:
                        run_log.error(msg)
                    break
            progress.advance(task_id)

    cache_db.save_batch(2, dest_updates)

    if verify and verify_failures > 0:
        console.print(f"[bold yellow]{verify_failures} files failed verification![/bold yellow]")

    generate_audit_receipt(executed_log, dst_root)
