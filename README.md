# NAS Photo Organizer v3

> **TL;DR:** A high-performance Python tool that recursively scans, deduplicates, and organizes massive photo/video libraries on network-attached storage into a clean `YYYY/MM/DD` folder structure. Survives network drops, power outages, and partial transfers with atomic writes, SQLite-backed resume queues, and exponential backoff retries. Ships with a beautiful Rich terminal UI, YAML configuration profiles, and full audit logging.

---

## Features

- **Atomic File Transfers** — Files are written to `.tmp` staging buffers, flushed to disk via `os.fsync()`, and only then renamed into place. No more corrupted partial files from network hiccups.
- **Resumable Job Queue** — The entire copy plan is committed to an SQLite database (`CopyJobs` table) before a single byte is written. If interrupted, just re-run the script — it picks up exactly where it stopped.
- **SQLite WAL Mode** — Write-Ahead Logging ensures the database never locks or corrupts, even during crashes.
- **BLAKE2b Hashing** — Fast, hardware-accelerated deduplication using chunked hash digests (first + last 512KB).
- **Multithreaded I/O** — Configurable thread pools for parallel hashing across network drives.
- **Exponential Backoff** — `tenacity`-powered automatic retries on network failures with configurable backoff.
- **Rich Terminal Dashboard** — Animated progress bars with ETA, transfer speed, and file counts. Intelligent prompts for session resumption.
- **YAML Profiles** — Define named source/dest mappings in `nas_profiles.yaml` to manage multiple libraries.
- **Audit Receipts** — Every successful run generates a JSON receipt mapping exact `source → destination` paths.
- **Dry-Run Reports** — Preview the entire copy plan as a CSV spreadsheet before committing.

## Data Safety Rules

1. **Zero Deletion** — The source is never modified or deleted. All operations are read + copy only.
2. **Global Deduplication** — Files already in the destination (matched by size + hash) are silently skipped. Internal duplicates within the source are routed to a separate `Duplicate/YYYY/MM/DD/` directory.
3. **Collision Protection** — If a destination file already exists, the copy is safely renamed with an incrementing `_collision_N` suffix. No data is ever overwritten.

## Date Extraction (Graceful Degradation)

1. **EXIF** — `exifread` extracts `DateTimeOriginal` from photo metadata.
2. **Filename Patterns** — Regex parsing for `IMG_20240101_XXXXXX`, `VID_`, `PANO_`, `BURST_`, etc.
3. **Spotlight (macOS)** — Falls back to `mdls kMDItemContentCreationDate` for formats like `.MOV`.
4. **Modified Time** — Last resort: uses the filesystem `mtime`.

Files that refuse to yield a date are placed in `Unknown_Date/` for manual review.

## Installation & Usage

The bootstrap wrapper `organize_nas.py` handles dependency management automatically. It detects missing packages (`exifread`, `tenacity`, `rich`, `pyyaml`) and offers to install them.

```bash
# Basic usage
python3 organize_nas.py --source /Volumes/NAS/Unsorted --dest /Volumes/NAS/Organized

# Use a named profile from nas_profiles.yaml
python3 organize_nas.py --profile mobile_backup

# Preview without copying
python3 organize_nas.py --dry-run

# Auto-confirm for unattended/cron usage
python3 organize_nas.py -y
```

### CLI Flags

| Flag | Description |
| :--- | :--- |
| `--source PATH` | Source directory to scan |
| `--dest PATH` | Destination directory for organized output |
| `--profile NAME` | Load source/dest from `nas_profiles.yaml` |
| `--dry-run` | Generate a CSV report of planned operations without copying |
| `-y` / `--yes` | Skip confirmation prompts (for cron jobs) |
| `--verify` | Re-hash each file after copy to verify byte-level integrity |
| `--rebuild-cache` | Force a full re-index of the destination |
| `--workers N` | Thread pool size for parallel hashing (default: 8) |

### Configuration Profiles

Define reusable source/dest pairs in `nas_profiles.yaml`:

```yaml
default:
  source: "/Volumes/photo/bkp_1_9"
  dest: "/Volumes/home/Organized_Photos"

mobile_backup:
  source: "/Volumes/home/Mobile_Snapshots"
  dest: "/Volumes/home/Organized_Photos"
```

Running without `--source`/`--dest` automatically loads the `default` profile.

## Project Structure

```
NAS-Photo-Organizer/
├── organize_nas.py          # Bootstrap wrapper (dependency installer)
├── nas_organizer/
│   ├── __init__.py
│   ├── __main__.py          # Entry point
│   ├── core.py              # Main orchestrator, CLI, Rich UI
│   ├── database.py          # SQLite WAL cache + job queue
│   ├── io.py                # Atomic copy, BLAKE2b hashing, retries
│   └── metadata.py          # Date extraction (EXIF, filename, mdls)
├── test_organize_nas.py     # 141 tests, 97% coverage
├── nas_profiles.yaml        # YAML configuration profiles
└── requirements.txt         # Python dependencies
```

## Testing

The project maintains a comprehensive test suite with **141 tests** at **97% code coverage**, including integration tests for the full dry-run and copy pipelines.

```bash
# Run tests
python3 -m unittest test_organize_nas.py -v

# Run with coverage
python3 -m coverage run -m unittest test_organize_nas.py
python3 -m coverage report --show-missing
```

## Generated Artifacts

All logs and reports are stored in `.organize_logs/` within the destination directory:

| File | Purpose |
| :--- | :--- |
| `.organize_cache.db` | SQLite database (hash cache + job queue) |
| `.organize_log.txt` | Plain-text run log with timestamps |
| `.organize_logs/audit_receipt_*.json` | Post-copy audit receipts |
| `.organize_logs/dry_run_report_*.csv` | Dry-run preview spreadsheets |
