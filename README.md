# Chronoframe

**Organize your photos and videos by date — automatically, safely, and with zero risk to your originals.**

Built for anyone sitting on years of messy phone dumps, camera cards, and backup drives who just wants their library in order without the stress of manually dragging files around.

| ![Chronoframe overview](docs/screenshots/ui-overview.png) | ![Folder structure picker](docs/screenshots/ui-folder-structure.png) |
| :---: | :---: |
| Overview — pick a source and destination, preview the plan | Folder structure — choose how your library is laid out |
| ![Live transfer](docs/screenshots/ui-transfer-progress.png) | ![Setup detail](docs/screenshots/ui-setup-detail.png) |
| Transfer — live progress with per-file metrics | Setup detail — saved profiles and advanced options |

> [!NOTE]
> **Meridian Design System:** Chronoframe features a custom "Meridian" visual language — combining photographic precision with a clean timeline-based organizational logic. The hallmark is the amber waypoint dot, representing the exact moment a memory finds its place.

---

## For everyone

### What Chronoframe does

- **Reads** a folder of unsorted photos and videos — from your phone, camera, NAS, or backup drive.
- **Figures out the date** of each file from EXIF, the filename, macOS Spotlight, or the file's modified time.
- **Copies** each file into a clean, date-based folder structure of your choosing — originals are never touched.
- **Skips duplicates** intelligently by comparing the actual file contents, not just filenames.
- **Remembers every run** so you can undo it with a single click if you change your mind.

### Why Chronoframe

- **Your originals are never modified, moved, or deleted.** Chronoframe reads from the source and writes to the destination. That's it.
- **Duplicates are detected by content, not filename.** Two copies of the same photo named `IMG_1234.jpg` and `image.jpg` are recognized as the same file.
- **Every run is revertible.** Chronoframe writes an audit receipt for every transfer. If you want to undo a run, it only deletes files whose contents still match — anything you've edited is left alone.
- **Interrupted runs pick up where they left off.** The plan is saved before copying begins, so a crash, sleep, or yanked USB drive doesn't force you to start over.

### Install

1. Download **`Chronoframe.zip`** from the [Releases page](https://github.com/Nishith/Chronoframe/releases).
2. Unzip and drag **Chronoframe.app** to your Applications folder.
3. Open the app.

> If macOS blocks the app on first launch, right-click it, choose **Open**, and confirm in the dialog.

### Your first run

1. **Pick a source folder** — where your unsorted files live (drag it onto the window, or use `Cmd+O`).
2. **Pick a destination folder** — where the organized library should go.
3. **Click Preview.** Chronoframe scans your files and shows you exactly what will happen. No files are copied yet.
4. **Click Transfer** when the plan looks right. A live progress view shows files discovered, hashed, and copied.

If something goes sideways, the completion screen offers **Revert Last Run** — every file is deleted only after its hash is verified against the audit receipt, so any files you've since edited are preserved.

### Key features

- **Drag-and-drop source selection** — drop a folder, a mix of files, or an entire volume onto the window.
- **Four folder layouts** — `YYYY/MM/DD`, `YYYY/MM`, `YYYY`, or `Flat` — picked per run.
- **Live planning progress** — even on libraries with hundreds of thousands of files, you see progress as the scan happens rather than staring at a spinner.
- **Preview before you commit** — the plan is built and shown before a single byte is copied.
- **One-click revert** — undo any completed run, hash-verified so your edits are safe.
- **Saved profiles** — remember your usual source/destination pairs.
- **Keyboard shortcuts** — `Cmd+O`, `Shift+Cmd+O`, `Cmd+R`, `Cmd+Return`, `Cmd+L`. (Full list [below](#keyboard-shortcuts).)
- **Resumes interrupted runs** automatically — the plan is persisted so you never lose work.

---

## For contributors & power users

The sections below document the CLI, architecture, protocols, and dev loop.

### Command line

Chronoframe's Python backend is a fully-featured CLI. Everything the macOS app does is available here too.

```bash
# Preview what will happen — nothing is copied
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized --dry-run

# Run the organizer
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized

# Undo a run
python3 chronoframe.py --revert ~/Photos/Organized/.organize_logs/audit_receipt_20260417_103000.json
```

Dependencies install automatically on first run, or manually:

```bash
pip3 install -r requirements.txt
```

#### CLI reference

| Flag | Description |
| :--- | :--- |
| `--source PATH` | Source directory to scan |
| `--dest PATH` | Destination root for organized output |
| `--profile NAME` | Load source and destination from `profiles.yaml` |
| `--dry-run` | Build the copy plan and write a CSV without copying |
| `--folder-structure` | Output layout: `YYYY/MM/DD`, `YYYY/MM`, `YYYY`, `YYYY/Mon/Event`, or `Flat` |
| `--verify` | Re-hash each file after copy to verify integrity |
| `--revert PATH` | Undo a previous run using its audit receipt JSON |
| `--rebuild-cache` | Force a full rebuild of the destination index |
| `--fast-dest` | Load destination index from cache instead of scanning |
| `--workers N` | Hashing thread count (default `8`) |
| `--json` | Emit JSON progress events (used by the GUI) |
| `-y`, `--yes` | Auto-confirm all prompts |

### Folder structure options

| Option | Example path |
| :--- | :--- |
| `YYYY/MM/DD` (default) | `2024/06/15/2024-06-15_001.jpg` |
| `YYYY/MM` | `2024/06/2024-06-15_001.jpg` |
| `YYYY` | `2024/2024-06-15_001.jpg` |
| `YYYY/Mon/Event` | `2014/Apr/Tahoe trip/2014-04-10_001.jpg` |
| `Flat` | `2024-06-15_001.jpg` |

`YYYY/Mon/Event` uses the file's immediate parent folder as the leaf. A file under `Source/Tahoe trip/` lands in `Dest/YYYY/Mon/Tahoe trip/`, with `YYYY` and `Mon` taken from the photo's date. Nested source trees collapse to the innermost folder (`Source/Trips/Tahoe trip/p.jpg` → `Dest/YYYY/Mon/Tahoe trip/p.jpg`). Files sitting directly at the source root have no event name and go into `Dest/YYYY/Mon/` instead.

Files without a recognizable date go into `Unknown_Date/`. Source duplicates (same content, different filename) route to `Duplicate/`.

### Keyboard shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Cmd+O` | Choose source folder |
| `Shift+Cmd+O` | Choose destination folder |
| `Shift+Cmd+P` | Toggle saved-profile field |
| `Cmd+R` | Start a preview |
| `Cmd+Return` | Start a transfer |
| `Cmd+L` | Toggle activity pane |

### Configuration profiles

Save frequently used source/destination pairs in a `profiles.yaml` at the project root:

```yaml
default:
  source: "/Volumes/MyDrive/Incoming"
  dest: "/Volumes/MyDrive/Organized_Photos"

mobile_backup:
  source: "/Volumes/MyDrive/Phone_Imports"
  dest: "/Volumes/MyDrive/Organized_Photos"
```

Then run `chronoframe.py --profile mobile_backup`, or pick the profile in the app. If you don't specify `--source`/`--dest`, Chronoframe falls back to the `default` profile.

> `profiles.yaml` is ignored by Git since it contains machine-specific paths.

### Architecture

Chronoframe ships two engines that speak the same JSON event protocol:

```
 ┌────────────────────────┐       ┌────────────────────────┐
 │   macOS app (SwiftUI)  │       │   chronoframe.py CLI   │
 │                        │       │   (Rich terminal UI)   │
 └───────────┬────────────┘       └───────────┬────────────┘
             │                                │
             │ JSON events                    │ JSON events
             ▼                                ▼
 ┌────────────────────────┐       ┌────────────────────────┐
 │   SwiftOrganizerEngine │       │   Python backend       │
 │   (ChronoframeCore)    │       │   (chronoframe/)       │
 │                        │       │                        │
 │  Native, in-process    │       │  EXIF + mdls + SQLite  │
 └────────────────────────┘       └────────────────────────┘
```

- The **macOS app** uses `SwiftOrganizerEngine` (in `ui/Sources/ChronoframeCore/`) for preview and transfer. Discovery, hashing (BLAKE2b), date resolution, planning, and execution are all native Swift — no Python subprocess on the hot path.
- The **Python backend** (`chronoframe/`) still powers the `chronoframe.py` CLI and is the implementation of `--revert` — the app shells out via `BackendRunner.swift` when you click **Revert Last Run**.
- A `HybridOrganizerEngine` in `ui/Sources/ChronoframeAppCore/Services/` selects between the two, so the app can be rebuilt on Python if needed.
- Both engines produce the same JSON event stream and the same on-disk artifacts (`.organize_cache.db`, `.organize_logs/*.json`), so a run started by one can be inspected or reverted by the other.

The Python package is organized as:

| Module | Responsibility |
| :--- | :--- |
| `core.py` | CLI parsing, orchestration, classification, copy planning, execution, revert |
| `io.py` | Atomic copy, retry policy, disk space checks, hash computation, verification |
| `metadata.py` | EXIF extraction, filename date parsing, mdls/Spotlight integration |
| `database.py` | SQLite cache and persistent copy queue |

### Safety & correctness guarantees

- **Source is never modified or deleted.** Chronoframe only reads from the source.
- **Deduplication by content, not filename.** Files are compared using full-file BLAKE2b hashes.
- **Atomic writes.** Every copy is staged to `*.tmp`, flushed with `fsync()`, then renamed into place. An interrupted copy never leaves a partial file at the final path.
- **No overwrites.** If a destination file already exists, the new file is written as `_collision_N` instead.
- **Verification available.** With `--verify`, each copy is re-hashed after writing. Failed verifications remove the bad copy and mark the job as `FAILED`.
- **Safe revert.** `--revert` verifies each destination file's hash before deletion — modified files are preserved.
- **Audit trail.** Every completed run produces a JSON receipt recording source, destination, and hash for each transfer.

### Atomic copy path

`safe_copy_atomic()` in `chronoframe/io.py` performs:

1. Ensure the destination directory exists.
2. Check available disk space (10 MB safety buffer).
3. Choose a collision-safe final path if needed.
4. Copy to `final_path.tmp`.
5. `fsync()` the temporary file.
6. Rename the temp file into place.

The native Swift equivalent in `ui/Sources/ChronoframeCore/TransferExecutor.swift` follows the same sequence.

### Concurrency model

- **Hashing is parallel.** `--workers N` (default `8`) controls the thread pool that hashes source files and destination-index files. Hashing is CPU-light and IO-dominated, so raising this rarely helps beyond 8–16.
- **Copy execution is serial.** A single writer thread consumes the plan. This is intentional — atomic rename semantics depend on one-at-a-time writes to the destination, and the bottleneck in practice is destination IO, not CPU.
- **Two abort thresholds** protect against flapping storage:
  - **5 consecutive failures** → abort the run.
  - **20 total failures** → abort the run.

### Retry & abort policy

Retries use exponential backoff for transient `OSError`s. These errors are treated as **permanent** and fail immediately:

| Error | Meaning |
| :--- | :--- |
| `ENOSPC` | No space left on device |
| `ENOENT` | File not found |
| `ENOTDIR` | Path component is not a directory |
| `EISDIR` | Is a directory |
| `EINVAL` | Invalid argument |
| `EACCES` | Permission denied |
| `EPERM` | Operation not permitted |

Permanent failures surface as the original `OSError` (not wrapped in a `RetryError`) via `tenacity`'s `reraise=True`.

### Resume queue

The destination root contains `.organize_cache.db` — a SQLite database in WAL mode with two tables:

| Table | Contents |
| :--- | :--- |
| `FileCache` | Source/destination path → hash, size, mtime — avoids re-hashing on subsequent runs |
| `CopyJobs` | Persisted copy plan with `PENDING`, `COPIED`, or `FAILED` state per file |

The queue is written **before** transfers begin, so an interrupted run can resume without rebuilding the plan. `--rebuild-cache` forces a full re-scan when you want to be absolutely sure the cache isn't stale.

### Date extraction

Date extraction is layered and degrades gracefully:

1. **EXIF** via `exifread` — most accurate for camera files.
2. **Filename patterns** — e.g. `IMG_20210417_120000.jpg`, `VID_20200101_...`.
3. **macOS Spotlight** via `mdls` — timezone-aware UTC → local conversion.
4. **Filesystem `mtime`** — last resort.

Files without a determinable date are routed to `Unknown_Date/`.

### JSON event protocol

When launched with `--json`, the backend emits one JSON object per line. The SwiftUI app consumes this stream to drive its UI; you can consume it from any other tool the same way.

| Event type | Key fields |
| :--- | :--- |
| `startup` | `status` |
| `task_start` | `task`, `total` |
| `task_progress` | `task`, `completed`, `total`, `bytes_copied`, `bytes_total` |
| `task_complete` | `task`, `found`, `already_in_dst`, `dups`, `errors`, `copied`, `failed`, `reverted`, `skipped` |
| `copy_plan_ready` | `count` |
| `info` / `warning` / `error` | `message` |
| `prompt` | `message` |
| `complete` | `status`, `dest`, `report` |

Example `task_progress` payload during a transfer:

```json
{"type": "task_progress", "task": "copy", "completed": 412, "total": 8193,
 "bytes_copied": 1824251904, "bytes_total": 35280441344}
```

Example terminal `complete` payload:

```json
{"type": "complete", "status": "success",
 "dest": "/Volumes/Photos/Organized",
 "report": ".organize_logs/audit_receipt_20260417_103000.json"}
```

### Audit receipt schema

Every completed transfer writes an audit receipt to `<dest>/.organize_logs/audit_receipt_YYYYMMDD_HHMMSS.json`:

```json
{
  "timestamp": "2026-04-17T10:30:00",
  "total_jobs": 1234,
  "status": "COMPLETED",
  "transfers": [
    {"source": "/Volumes/Incoming/IMG_1234.jpg",
     "dest":   "/Volumes/Photos/Organized/2024/06/15/2024-06-15_001.jpg",
     "hash":   "4f3a…"}
  ]
}
```

`--revert` reads this file, re-hashes each destination, and only deletes files whose hash still matches — edited files are preserved. The schema is stable and safe to parse from external tools.

### Generated files

| File | Purpose |
| :--- | :--- |
| `.organize_cache.db` | SQLite cache and persisted copy queue |
| `.organize_log.txt` | Plain-text run log |
| `.organize_logs/dry_run_report_*.csv` | Dry-run plan export |
| `.organize_logs/audit_receipt_*.json` | Transfer receipt (also used for `--revert`) |

### Building from source

#### macOS app

```bash
cd ui
./build.sh
open "build/Chronoframe.app"
```

For a release archive:

```bash
cd ui
./archive.sh
```

To validate an existing bundle:

```bash
python3 ui/Packaging/validate_app_bundle.py ui/build/Chronoframe.app
```

### Testing

The test suite contains **238 tests** — backend coverage (`test_chronoframe.py`), a packaging smoke test (`test_ui_build.py`), and bundle validator tests (`test_ui_packaging.py`).

```bash
python3 -m unittest test_chronoframe test_ui_build test_ui_packaging -v
```

Coverage includes: hashing and cache reuse, atomic copy and collision handling, retry classification, permission-denied fast-fail (EACCES/EPERM), timezone-aware date parsing (MDLS), destination indexing, classification fallback chains, copy execution and abort thresholds, dry-run reports, audit receipts, revert logic, profile loading, and CLI parsing.

Specialized test suites:

| File | Focus |
| :--- | :--- |
| `test_parity_fixtures.py` | Swift ↔ Python planning parity |
| `test_execution_parity_fixtures.py` | Swift ↔ Python execution parity |
| `test_benchmarks.py` | Hashing/scanning microbenchmarks |

### Repository layout

```text
Chronoframe/
  chronoframe.py               # Bootstrap wrapper (dependency check + launch)
  requirements.txt
  README.md
  chronoframe/                 # Python backend package
    __init__.py
    __main__.py
    core.py                    # Orchestration, classification, revert
    database.py                # SQLite cache and queue
    io.py                      # Atomic copy, retry, hashing
    metadata.py                # Date extraction (EXIF, filename, mdls)
  ui/                          # macOS SwiftUI frontend
    Sources/
      ChronoframeApp/          # SwiftUI views and app scaffold
        App/
        Views/
      ChronoframeAppCore/      # Stores, services, engine selection
        Services/
          OrganizerEngine.swift        # protocol
          SwiftOrganizerEngine.swift   # native engine
          PythonOrganizerEngine.swift  # legacy subprocess engine
          HybridOrganizerEngine.swift  # selects between them
        Stores/
      ChronoframeCore/         # Native engine (hashing, discovery, planning)
        BLAKE2bHasher.swift
        CopyPlanBuilder.swift
        MediaDiscovery.swift
        MediaDateResolver.swift
        TransferExecutor.swift
        …
      BackendRunner.swift      # Python subprocess launcher (revert path)
      ContentView.swift        # Top-level SwiftUI composition
      ChronoframeApp.swift     # @main entry
    Tools/
      IconGenerator.swift
    Packaging/
      validate_app_bundle.py
      Chronoframe.entitlements
    Resources/
      AppIcon.iconset/
      AppIcon.icns
    build.sh                   # Dev build script
    archive.sh                 # Release archive script
    Chronoframe.xcodeproj
  docs/
    screenshots/
  test_chronoframe.py          # Backend tests
  test_ui_build.py             # macOS packaging smoke test
  test_ui_packaging.py         # App-bundle validator tests
```

### Contributing

Dev loop:

1. Make changes to the Python backend under `chronoframe/` or the Swift engine under `ui/Sources/`.
2. Run the test suite: `python3 -m unittest test_chronoframe test_ui_build test_ui_packaging`.
3. For UI changes, rebuild: `cd ui && ./build.sh && open build/Chronoframe.app`.
4. To regenerate the app icon from the vector source: run `ui/Tools/IconGenerator.swift`.

When you add a backend feature, add tests in `test_chronoframe.py` alongside the existing suites (look for the nearest `class` matching your area — e.g. `TestAtomicCopy`, `TestRevertReceipt`). Parity fixtures in `test_parity_fixtures.py` and `test_execution_parity_fixtures.py` exist to keep the Swift and Python engines aligned; if you change behavior in one engine, update the other or the fixture.

### Notes & tradeoffs

- The destination cache is a performance optimization. Use `--rebuild-cache` when you want a guaranteed fresh index.
- `--fast-dest` is for repeated previews against a stable destination — don't rely on it indefinitely without a full rebuild.
- The GUI is macOS-specific, but the Python backend runs on any platform with Python 3.9+.
- Spotlight-based date extraction (`mdls`) is macOS-only. On other platforms, Chronoframe falls through to EXIF, filename, and `mtime`.
- There is no automated release pipeline today; releases are built locally with `./archive.sh` and uploaded to GitHub Releases manually.
