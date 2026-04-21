# Chronoframe

**Organize your photos and videos by date — automatically, safely, and with zero risk to your originals.**

Chronoframe takes a folder full of unsorted photos and videos (from your phone, camera, NAS, or backup drive) and sorts them into clean, date-based folders. It never moves or deletes your originals — it copies them to a new location, organized the way you choose.

> [!NOTE]
> **Meridian Design System:** Chronoframe uses a restrained Meridian visual language on top of native macOS materials and split-view structure. The hallmark remains the amber waypoint dot, representing the moment a memory finds its place.

## Screenshots

The live macOS app is organized around a calm setup workflow and a dedicated run workspace for preview, transfer, and artifact review.

![Chronoframe setup workspace](docs/screenshots/ui-setup-overview.png)

![Chronoframe run workspace after preview](docs/screenshots/ui-run-preview.png)

## Getting Started

You can use Chronoframe two ways: through the **macOS app** (recommended for most people) or the **command line**.

### macOS App

1. Download `Chronoframe.zip` from the [Releases page](https://github.com/Nishith/Chronoframe/releases).
2. Unzip and drag **Chronoframe.app** to your Applications folder.
3. Open the app, pick your source folder and destination folder, and click **Preview** to see what will happen — no files are copied yet.
4. When you're satisfied with the plan, click **Transfer** to start organizing.

> **Note:** If macOS blocks the app on first launch, right-click it, choose **Open**, and confirm in the dialog.

### Command Line

```bash
# Preview what will happen (no files are copied)
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized --dry-run

# Run the organizer
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized
```

Dependencies are installed automatically on first run, or you can install them manually:

```bash
pip3 install -r requirements.txt
```

## How It Works

1. **Scans** your source folder for photos and videos
2. **Reads the date** from EXIF data, the filename, macOS Spotlight metadata, or the file's modified time — in that order
3. **Skips duplicates** already present in the destination (compared by content, not filename)
4. **Copies each file** into a date-based folder structure you choose
5. **Verifies** files are intact after copying (optional)

Your originals are **never modified, moved, or deleted**.

### Folder Structure Options

Choose how your files are organized in the destination:

| Option | Example Path |
| :--- | :--- |
| `YYYY/MM/DD` (default) | `2024/06/15/2024-06-15_001.jpg` |
| `YYYY/MM` | `2024/06/2024-06-15_001.jpg` |
| `YYYY` | `2024/2024-06-15_001.jpg` |
| `YYYY/Mon/Event` | `2014/Apr/Tahoe trip/2014-04-10_001.jpg` |
| `Flat` | `2024-06-15_001.jpg` |

`YYYY/Mon/Event` uses the file's immediate parent folder as the leaf. A file under `Source/Tahoe trip/` lands in `Dest/YYYY/Mon/Tahoe trip/`, with `YYYY` and `Mon` taken from the photo's date. Nested source trees collapse to the innermost folder (`Source/Trips/Tahoe trip/p.jpg` → `Dest/YYYY/Mon/Tahoe trip/p.jpg`). Files sitting directly at the source root have no event name and go into `Dest/YYYY/Mon/` instead.

Files without a recognizable date go into `Unknown_Date/`. Source duplicates (same content, different filename) are routed into `Duplicate/`.

### Undoing a Run

Made a mistake? You can revert any completed run:

```bash
python3 chronoframe.py --revert /path/to/Organized/.organize_logs/audit_receipt_*.json
```

This deletes only files that still match the original hash — if you've edited a file after it was copied, it won't be touched.

In the macOS app, review the generated report, logs, and destination artifacts after each run from the **Run** and **Run History** workspaces.

---

## Keyboard Shortcuts (macOS App)

| Shortcut | Action |
| :--- | :--- |
| `Cmd+O` | Choose source folder |
| `Shift+Cmd+O` | Choose destination folder |
| `Shift+Cmd+P` | Refresh profiles |
| `Cmd+R` | Start a preview |
| `Cmd+Return` | Start a transfer |
| `Cmd+,` | Open settings |

## Configuration Profiles

Save frequently used source/destination pairs in a `profiles.yaml` file at the project root:

```yaml
default:
  source: "/Volumes/MyDrive/Incoming"
  dest: "/Volumes/MyDrive/Organized_Photos"

mobile_backup:
  source: "/Volumes/MyDrive/Phone_Imports"
  dest: "/Volumes/MyDrive/Organized_Photos"
```

Then run with `--profile mobile_backup` or select the profile name in the app. If you don't specify `--source`/`--dest`, Chronoframe falls back to the `default` profile.

> `profiles.yaml` is ignored by Git since it contains machine-specific paths.

## CLI Reference

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

---

## Technical Details

The sections below cover the internal architecture, safety guarantees, and design decisions for contributors and advanced users.

### Architecture

Chronoframe currently ships as a cross-platform Python CLI plus a native macOS app built from the `ui/` workspace.

- **CLI** — a [Rich](https://github.com/Textualize/rich)-powered terminal interface with live progress bars and colored output
- **macOS app** — a SwiftUI split-view workspace for Setup, Run, Run History, Profiles, and Settings

The macOS app is split into three Swift layers:

- **`ChronoframeCore`** — pure Swift planning, hashing, media discovery, date resolution, transfer, and database primitives
- **`ChronoframeAppCore`** — engine adapters, repositories, stores, runtime-path resolution, folder access, Finder integration, and history indexing
- **`ChronoframeApp`** — scene wiring, commands, split-view navigation, feature views, presentation models, and app-only UI testing helpers

Within the app target, the current structure is intentionally feature-oriented:

- **`AppState`** remains the single root object injected into the UI, but it now acts as a facade over focused collaborators
- **Coordinators** own setup actions, run actions, history actions, and bookmark restoration
- **`Views/Setup`** and **`Views/Run`** contain the thin screen roots, dedicated section subviews, and presentation models (`SetupScreenModel`, `RunWorkspaceModel`)
- **`App/UITesting`** contains deterministic in-memory app scenarios used by XCUITests and the screenshot refresh workflow

The app defaults to the **Swift** organizer engine. For parity checks or backend integration work, you can force the app to launch the Python backend with:

```bash
CHRONOFRAME_APP_ENGINE=python open ui/build/Chronoframe.app
```

The Python backend still lives in `chronoframe/` and provides the CLI plus the fallback/runtime-parity engine path used by the macOS app:

| Module | Responsibility |
| :--- | :--- |
| `core.py` | CLI parsing, orchestration, classification, copy planning, execution, revert |
| `io.py` | Atomic copy, retry policy, disk space checks, hash computation, verification |
| `metadata.py` | EXIF extraction, filename date parsing, mdls/Spotlight integration |
| `database.py` | SQLite cache and persistent copy queue |

### Safety and Correctness Guarantees

- **Source is never modified or deleted.** Chronoframe only reads from the source.
- **Deduplication by content, not filename.** Files are compared using full-file BLAKE2b hashes.
- **Atomic writes.** Every copy is staged to `*.tmp`, flushed with `fsync()`, then renamed into place. An interrupted copy never leaves a partial file at the final path.
- **No overwrites.** If a destination file already exists, the new file is written as `_collision_N` instead.
- **Verification available.** With `--verify`, each copy is re-hashed after writing. Failed verifications remove the bad copy and mark the job as `FAILED`.
- **Safe revert.** `--revert` verifies each destination file's hash before deletion — modified files are preserved.
- **Audit trail.** Every completed run produces a JSON receipt recording source, destination, and hash for each transfer.

### Atomic Copy Path

`safe_copy_atomic()` in `chronoframe/io.py` performs:

1. Ensure the destination directory exists
2. Check available disk space (10 MB safety buffer)
3. Choose a collision-safe final path if needed
4. Copy to `final_path.tmp`
5. `fsync()` the temporary file
6. Rename the temp file into place

### Retry Policy

Retries use exponential backoff for transient `OSError`s. The following errors are treated as **permanent** and fail immediately:

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

### Failure Abort Thresholds

The engine protects against flapping storage or network conditions:

- **5 consecutive failures** → abort
- **20 total failures** → abort

### Resume Queue

The destination root contains `.organize_cache.db` (SQLite, WAL mode), which holds:

- **`FileCache`**: cached source/destination hashes with `size` and `mtime`
- **`CopyJobs`**: persisted copy plan with `PENDING`, `COPIED`, or `FAILED` state

The queue is written before transfers begin, so an interrupted run can resume without rebuilding the plan.

### Date Extraction

Date extraction is layered and degrades gracefully:

1. **EXIF** via `exifread` (most accurate for camera files)
2. **Filename patterns** — `IMG_20210417_120000.jpg`, `VID_20200101_...`, etc.
3. **macOS Spotlight** via `mdls` (timezone-aware UTC conversion to local time)
4. **Filesystem `mtime`** (last resort)

Files without a determinable date are routed to `Unknown_Date/`.

### JSON Event Protocol

When launched with `--json`, the backend emits one JSON object per line. The SwiftUI app consumes this stream to drive its UI.

| Event Type | Key Fields |
| :--- | :--- |
| `startup` | `status` |
| `task_start` | `task`, `total` |
| `task_progress` | `task`, `completed`, `total`, `bytes_copied`, `bytes_total` |
| `task_complete` | `task`, `found`, `already_in_dst`, `dups`, `errors`, `copied`, `failed`, `reverted`, `skipped` |
| `copy_plan_ready` | `count` |
| `info` / `warning` / `error` | `message` |
| `prompt` | `message` |
| `complete` | `status`, `dest`, `report` |

### Generated Files

| File | Purpose |
| :--- | :--- |
| `.organize_cache.db` | SQLite cache and persisted copy queue |
| `.organize_log.txt` | Plain-text run log |
| `.organize_logs/dry_run_report_*.csv` | Dry-run plan export |
| `.organize_logs/audit_receipt_*.json` | Transfer receipt (also used for `--revert`) |

---

## Building from Source

### macOS App

```bash
cd ui
./build.sh
open "build/Chronoframe.app"
```

`ui/build.sh` always writes the full `xcodebuild` output to `ui/build/xcodebuild.log` and prints that path on both success and failure.

For a Release archive:

```bash
cd ui
./archive.sh
```

To validate an existing bundle:

```bash
python3 ui/Packaging/validate_app_bundle.py ui/build/Chronoframe.app
```

### Testing

Chronoframe is tested across the Python backend, the Swift package layers, and deterministic macOS UI scenarios.

Run the Python backend and packaging tests with:

```bash
python3 -m unittest test_chronoframe test_ui_build test_ui_packaging -v
```

Run the Swift package tests with:

```bash
cd ui
swift test
```

Run the deterministic macOS UI scenarios with:

```bash
cd ui
xcodebuild -project Chronoframe.xcodeproj \
  -scheme Chronoframe \
  -configuration Debug \
  -derivedDataPath build/UITestDerivedDataSigned \
  -destination 'platform=macOS,arch=arm64' \
  test -only-testing:ChronoframeUITests
```

Coverage includes: hashing and cache reuse, atomic copy and collision handling, retry classification, permission-denied fast-fail (`EACCES`/`EPERM`), timezone-aware date parsing (`mdls`), destination indexing, classification fallback chains, copy execution and abort thresholds, dry-run reports, audit receipts, revert logic, profile loading, runtime-path resolution, organizer-engine parity, bookmark restoration, app coordinators, screen models, and macOS UI-state rendering.

Additional test files:
- `test_ui_build.py` — macOS packaging smoke tests
- `test_ui_packaging.py` — bundle validator tests
- `ui/Tests/ChronoframeAppCoreTests/*` — Swift engine, stores, repositories, and integration tests
- `ui/Tests/ChronoframeAppTests/*` — app-layer coordinator, presentation-model, and accessibility tests
- `ui/Xcode/UITests/ChronoframeUITests.swift` — deterministic scenario-based macOS UI tests

### Contributor Workflows

Refresh the README screenshots from the deterministic UI harness with:

```bash
bash ui/Tools/refresh_readme_screenshots.sh
```

This is the single supported screenshot refresh path. It launches the built app with the in-memory UI test scenarios, sizes the window consistently, and rewrites:

- `docs/screenshots/ui-setup-overview.png`
- `docs/screenshots/ui-run-preview.png`

The harness uses the launch contract below:

- `CHRONOFRAME_UI_TEST_SCENARIO`
- `CHRONOFRAME_UI_TEST_DISABLE_NOTIFICATIONS=1`

Current built-in scenarios are:

- `setupReady`
- `runPreviewReview`
- `historyPopulated`
- `profilesPopulated`
- `settingsSections`

The screenshot script currently captures `setupReady` and `runPreviewReview`. Because it drives a visible macOS app window, it should be run from an interactive desktop session with Accessibility and Screen Recording permissions available.

## Repository Layout

```text
Chronoframe/
  chronoframe.py              # Bootstrap wrapper (dependency check + launch)
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
    Package.swift              # Swift package entry point
    Sources/
      ChronoframeApp/
        App/
          ChronoframeApp.swift # App entry point and scene wiring
          AppState.swift       # Root facade and coordinator wiring
          AppCommands.swift    # Menu commands and shortcuts
          DesignTokens.swift   # Semantic colors, surfaces, spacing
          Coordinators/
            *.swift            # Setup, run, history, bookmark collaborators
          UITesting/
            *.swift            # Deterministic app scenarios and in-memory doubles
        Views/
          Setup/
            SetupView.swift
            SetupScreenModel.swift
            SetupSectionViews.swift
          Run/
            CurrentRunView.swift
            RunWorkspaceModel.swift
            RunSectionViews.swift
          SidebarView.swift
          RunHistoryView.swift
          ProfilesView.swift
          SettingsView.swift
          RootSplitView.swift
          SharedViews.swift
      ChronoframeAppCore/
        Exports.swift
        Services/              # Engine bridges, folder access, history indexing
        Stores/                # Preferences, setup, logs, run sessions
        Support/               # Runtime path resolution
      ChronoframeCore/
        *.swift                # Shared planning, hashing, media, transfer models
    Tests/
      ChronoframeAppCoreTests/ # Swift core/app-core coverage and backend parity
      ChronoframeAppTests/     # App facade, coordinator, and presentation tests
    Xcode/
      UITests/
        ChronoframeUITests.swift
    Tools/
      IconGenerator.swift
      refresh_readme_screenshots.sh
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
  test_chronoframe.py          # Python backend unit tests
  test_ui_build.py
  test_ui_packaging.py
```

## Notes and Tradeoffs

- The destination cache is a performance optimization. Use `--rebuild-cache` when you want a guaranteed fresh index.
- `--fast-dest` is for repeated previews against a stable destination — don't rely on it indefinitely without a full rebuild.
- The GUI is macOS-specific, but the Python backend runs on any platform with Python 3.9+.
- Spotlight-based date extraction (`mdls`) is macOS-only. On other platforms, Chronoframe falls through to EXIF, filename, and `mtime`.
