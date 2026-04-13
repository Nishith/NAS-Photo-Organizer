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
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn, TimeRemainingColumn, TransferSpeedColumn
from rich.prompt import Confirm
from rich.panel import Panel

from .database import CacheDB
from .io import safe_copy_atomic, process_single_file
from .metadata import get_file_date, ALL_EXTS, SKIP_FILES, HAS_EXIFREAD

SEQ_WIDTH = 3
MAX_CONSECUTIVE_FAILURES = 5

console = Console()

def parse_args():
    parser = argparse.ArgumentParser(description="NAS Photo Organizer v3 - Enterprise L7 UX")
    parser.add_argument("--source", type=str, default=None, help="Source folder")
    parser.add_argument("--dest", type=str, default=None, help="Destination folder")
    parser.add_argument("--profile", type=str, default=None, help="Use paths from nas_profiles.yaml")
    parser.add_argument("--dry-run", action="store_true", help="Generate CSV reports without copying")
    parser.add_argument("--rebuild-cache", action="store_true", help="Force database re-index")
    parser.add_argument("-y", "--yes", action="store_true", help="Skip copy confirmation prompt (unattended)")
    return parser.parse_args()

def load_profile(profile_name):
    yaml_path = os.path.join(os.getcwd(), "nas_profiles.yaml")
    if not os.path.exists(yaml_path):
        console.print(f"[red]Error:[/red] '{yaml_path}' not found. Cannot load profile '{profile_name}'.")
        sys.exit(1)
        
    with open(yaml_path, 'r') as f:
        profiles = yaml.safe_load(f)
        
    if profile_name not in profiles:
        console.print(f"[red]Error:[/red] Profile '{profile_name}' not defined in nas_profiles.yaml")
        sys.exit(1)
        
    return profiles[profile_name].get('source'), profiles[profile_name].get('dest')

def build_dest_index(dst_dir, cache_db, rebuild=False, progress=None, ptask=None):
    import re
    if rebuild:
        cache_db.clear()
        
    cache = cache_db.get_cache_dict(2)
    files_to_check = []
    
    seq_index = defaultdict(int)
    dup_seq_index = defaultdict(int)
    seq_pattern = re.compile(r'^(\d{4}-\d{2}-\d{2})_(\d+)')
    dup_dir = os.path.join(dst_dir, "Duplicate")
    
    if progress and ptask:
        progress.update(ptask, total=None)

    for root, dirs, fnames in os.walk(dst_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if fname.startswith('.') or fname in SKIP_FILES or not fname.endswith(tuple(ALL_EXTS)):
                continue
            path = os.path.join(root, fname)
            files_to_check.append(path)

            m = seq_pattern.match(fname)
            if m:
                date_str, seq = m.group(1), int(m.group(2))
                if path.startswith(dup_dir):
                    if seq > dup_seq_index[date_str]: dup_seq_index[date_str] = seq
                else:
                    if seq > seq_index[date_str]: seq_index[date_str] = seq
                    
            if progress and ptask and len(files_to_check) % 1000 == 0:
                progress.update(ptask, description=f"[cyan]Scanning Dest... ({len(files_to_check)} found)")

    hash_index = {}
    updates = []
    
    if progress and ptask:
        if len(files_to_check) == 0:
            progress.update(ptask, description="[cyan]Index Built (Empty)", total=1, completed=1)
        else:
            progress.update(ptask, description="[cyan]Validating Dest Hashes...", total=len(files_to_check))
        
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        futures = {executor.submit(process_single_file, path, cache.get(path)): path for path in files_to_check}
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

def generate_dry_run_report(jobs, dst, report_path):
    with open(report_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Source", "Destination", "Status", "Hash"])
        for j in jobs:
            writer.writerow([j[0], j[1], j[3], j[2]])
    console.print(f"\n[green]✔ Dry-Run complete.[/green] Generated actionable report: [cyan]{report_path}[/cyan]")
    
def generate_audit_receipt(jobs_executed, dest_path):
    receipt_name = f"audit_receipt_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    rpath = os.path.join(dest_path, receipt_name)
    payload = {
        "timestamp": datetime.now().isoformat(),
        "total_jobs": len(jobs_executed),
        "status": "COMPLETED",
        "transfers": [{"source": src, "dest": dst, "hash": h} for src, dst, h in jobs_executed]
    }
    with open(rpath, 'w') as f:
        json.dump(payload, f, indent=4)
    console.print(f"\n[bold green]✔ Secure Audit Receipt Generated:[/bold green] [cyan]{rpath}[/cyan]")

def main():
    args = parse_args()
    
    # Resolve Paths
    src = args.source
    dst = args.dest
    
    if args.profile:
        src, dst = load_profile(args.profile)
    elif not src or not dst:
        # Fallback implicitly to the 'default' profile if it exists
        yaml_path = os.path.join(os.getcwd(), "nas_profiles.yaml")
        if os.path.exists(yaml_path):
            with open(yaml_path, 'r') as f:
                profiles = yaml.safe_load(f)
                if profiles and 'default' in profiles:
                    src = src or profiles['default'].get('source')
                    dst = dst or profiles['default'].get('dest')
        
    if not src or not dst:
        console.print("[red]Error: Source and Destination must be provided explicitly via --source/--dest OR via a profile mapping![/red]")
        sys.exit(1)
        
    dup = os.path.join(dst, "Duplicate")
    rebuild = args.rebuild_cache
    
    console.print(Panel(f"[bold cyan]NAS Photo Organizer v3 (Enterprise UX)[/bold cyan]\n[white]Source:[/white] {src}\n[white]Dest:[/white]   {dst}", expand=False))
    
    if not HAS_EXIFREAD:
        console.print("[yellow]⚠ 'exifread' not installed. Falling back to native mdls (Slower).[/yellow]")

    cache_db = CacheDB(os.path.join(dst, ".organize_cache.db"))

    # Smart Prompt for Queue
    pending_jobs = cache_db.get_pending_jobs()
    if pending_jobs:
        console.print(f"\n[bold yellow]⚡ Interrupted Session Detected![/bold yellow] Found {len(pending_jobs)} paused jobs in Queue.")
        if args.dry_run:
            console.print("[cyan]Dry Run active: Ignoring pending queue flush.[/cyan]")
        elif args.yes:
            execute_jobs(pending_jobs, cache_db, dst)
            return
        else:
            if Confirm.ask("Would you like to instantly resume exactly where you left off?"):
                execute_jobs(pending_jobs, cache_db, dst)
                console.print("[bold green]Queue Complete![/bold green]")
                return
            else:
                if Confirm.ask("[red]Flush the uncompleted queue?[/red] (This won't delete files)"):
                    cache_db.clear()
                    console.print("[green]Queue Flushed.[/green] Rescanning arrays natively...")

    src_files = []
    # Discovery Phase
    with console.status("[bold blue]Scanning Source Directories...", spinner="dots") as status:
        for root, dirs, fnames in os.walk(src):
            dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
            for fname in sorted(fnames):
                if fname.startswith('.') or fname in SKIP_FILES: pass
                elif os.path.splitext(fname)[1].lower() in ALL_EXTS:
                    src_files.append(os.path.join(root, fname))
                    
    if not src_files:
        console.print("[yellow]No valid media files found in source.[/yellow]")
        return
        
    console.print(f"[green]✔ Found {len(src_files)} valid source files.[/green]")

    # Orchestrating the rich layout
    src_hashes = {}
    src_updates = []
    dest_hash_index = {}
    dest_seq = {}
    dup_seq = {}
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        TimeRemainingColumn(),
        console=console,
        transient=False
    ) as progress:
        
        task_dest = progress.add_task("[cyan]Scanning Destination Array...", total=None)
        dest_hash_index, dest_seq, dup_seq = build_dest_index(dst, cache_db, rebuild, progress, task_dest)
        
        task_src = progress.add_task("[magenta]Hashing Source Payload...", total=len(src_files))
        src_cache = cache_db.get_cache_dict(1)
        
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
            futures = {executor.submit(process_single_file, path, src_cache.get(path)): path for path in src_files}
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

    date_groups = defaultdict(list)
    src_dups = []
    already_in_dst = 0
    src_seen = {}
    
    with console.status("[bold yellow]Classifying Metadata Dates...", spinner="arc"):
        for src_path in src_files:
            h = src_hashes.get(src_path)
            if not h: continue

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
            
    console.print(f"[cyan]ℹ {already_in_dst} files identical in destination (Skipping)[/cyan]")

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

    if args.dry_run:
        report_path = os.path.join(os.getcwd(), f"dry_run_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv")
        generate_dry_run_report(jobs_to_insert, dst, report_path)
        return

    if not jobs_to_insert:
        console.print("[bold green]Everything is up to date! Nothing to copy.[/bold green]")
        return

    console.print(f"\n[bold magenta]► {len(jobs_to_insert)} total files ready for atomic transfer.[/bold magenta]")
    if not args.yes:
        if not Confirm.ask("Execute State Machine and initiate array copy?"):
            return

    cache_db.enqueue_jobs(jobs_to_insert)
    execute_jobs(cache_db.get_pending_jobs(), cache_db, dst)

def execute_jobs(pending_jobs, cache_db, dst_root):
    console.print(f"\n[bold cyan]Processing {len(pending_jobs)} queued jobs natively...[/bold cyan]")
    dest_updates = []
    
    consecutive_fail = 0
    executed_log = []
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
        console=console
    ) as progress:
        task_id = progress.add_task("[green]Atomic Network Transfer...", total=len(pending_jobs))
        
        for src_p, dst_p, h in pending_jobs:
            try:
                result = safe_copy_atomic(src_p, dst_p)
                cache_db.update_job_status(src_p, 'COPIED')
                st = os.stat(result)
                dest_updates.append((result, h, st.st_size, st.st_mtime))
                executed_log.append((src_p, dst_p, h))
                consecutive_fail = 0
                progress.advance(task_id, advance=1) # Note: TransferSpeedColumn expects bytes if measuring bandwidth, but we are using items. To fix, we can advance by size or just use item count. Here we advance by 1
            except Exception as e:
                cache_db.update_job_status(src_p, 'FAILED')
                consecutive_fail += 1
                if consecutive_fail >= MAX_CONSECUTIVE_FAILURES:
                    console.print(f"\n[bold red]Abort: Network fault tolerance breached (> {MAX_CONSECUTIVE_FAILURES} errors).[/bold red]")
                    break

    cache_db.save_batch(2, dest_updates)
    generate_audit_receipt(executed_log, dst_root)
