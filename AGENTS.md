# Chronoframe Project Memory

This file is project context for future coding agents. Keep it current when architecture, build commands, CI behavior, or workflow assumptions change.

## Project Purpose

Chronoframe is a safe photo/video organizer. It scans an unsorted source folder, resolves each media file's date, and copies files into a date-based destination layout. The central promise is that originals are never modified, moved, or deleted.

Chronoframe ships both:

- A Python CLI/backend at the repo root, launched with `python3 chronoframe.py`.
- A native macOS SwiftUI app under `ui/`, using Swift package targets and an Xcode project.

## Architecture

The Python backend lives in `chronoframe/`.

- `chronoframe/core.py`: CLI orchestration, planning, execution, revert.
- `chronoframe/io.py`: atomic copy, retry policy, disk checks, hashing, verification.
- `chronoframe/metadata.py`: EXIF, filename date parsing, Spotlight/mdls integration.
- `chronoframe/database.py`: SQLite cache and persistent copy queue.

The macOS app lives in `ui/`.

- `ui/Sources/ChronoframeCore/`: native Swift organizing engine.
- `ui/Sources/ChronoframeAppCore/`: app state, stores, engine selection, user-facing services.
- `ui/Sources/ChronoframeApp/`: SwiftUI views and app entry point.
- `ui/Tests/ChronoframeAppCoreTests/` and `ui/Tests/ChronoframeAppTests/`: Swift tests.
- `ui/Chronoframe.xcodeproj/`: Xcode project used by CodeQL and app builds.

Swift package targets:

- `ChronoframeCore`
- `ChronoframeAppCore`
- `ChronoframeApp`
- `ChronoframeAppCoreTests`
- `ChronoframeAppTests`

The app defaults to the native `SwiftOrganizerEngine`. `HybridOrganizerEngine` can select the Python path when needed. The Python backend remains the CLI implementation and is still used by the app for some shell-out flows such as revert.

Shared on-disk artifacts include:

- `.organize_cache.db` (now also hosts a `DedupeFeatures` table caching per-photo Vision feature prints, dHash, and quality scores so dedupe re-scans are incremental)
- `.organize_logs/dry_run_report_*.csv`
- `.organize_logs/audit_receipt_*.json` (organize transfer audit receipt)
- `.organize_logs/dedupe_audit_receipt_*.json` (Deduplicate run audit receipt — used by Run History → Revert)
- `.organize_log.txt`

The macOS app sidebar consolidates the original Setup / Run / Run History flows under a single **Organize** destination (`ui/Sources/ChronoframeApp/Views/Organize/OrganizeContainerView.swift`) and adds a peer **Deduplicate** destination (`ui/Sources/ChronoframeApp/Views/Deduplicate/`). Both share the active organize destination by default; Deduplicate may also point at a user-picked dedicated folder.

## Safety Invariants

Do not weaken these unless the user explicitly asks for a product change.

- The source folder is read-only from Chronoframe's perspective. Never delete, move, rename, or modify source files.
- Copies are written to a temporary file, flushed, then atomically renamed into place.
- Existing destination files are not overwritten. Collisions get a distinct destination name.
- Deduplication is content-based, using BLAKE2b hashes, not filenames.
- `--verify` re-hashes written files and removes a bad copy if verification fails.
- Revert deletes only destination files whose current hash still matches the audit receipt.
- Aborted runs should make it clear that source files were left untouched.
- Failure thresholds intentionally stop bad runs: 5 consecutive failures or 20 total failures.
- Deduplicate moves files to the macOS Trash by default. Hard delete is only available behind an explicit Settings toggle gated by a confirmation dialog.
- The dedupe audit receipt directory (`.organize_logs/`) is preflighted before any deletion. An unwritable destination aborts the commit with `ReceiptPreflightError` and zero files touched.
- Pair-as-unit conflict resolution is **Keep-wins**: if a user explicitly keeps either half of a RAW+JPEG or Live Photo HEIC+MOV pair, neither is deleted, even when the other half is marked Delete.

## Deduplicate Workspace

`ui/Sources/ChronoframeCore/DeduplicateScanner.swift` runs the scan; `DeduplicationPlanner.plan` is the single source of truth for "what files will the executor mutate". Both the commit-footer preview and `DeduplicateExecutor.commit` consume the same `DeduplicationPlan` so what the user sees in the footer is exactly what happens.

- Per-pair-kind toggles (`treatRawJpegPairsAsUnit`, `treatLivePhotoPairsAsUnit`) are honored independently. Disabling RAW pairing must not affect Live Photo behaviour and vice versa.
- The plan carries owning-cluster metadata for **every** mutation, including pair partners that aren't cluster members on their own (Live Photo MOV halves, mainly), so the audit receipt is exhaustive and Run History → Revert can restore everything the executor touched.
- Thumbnails go through `ui/Sources/ChronoframeApp/Views/Components/ThumbnailRenderer.swift` (single QuickLook entry point shared by ContactSheet and DedupeThumbnailLoader). The dedupe loader uses `NSCache<NSString, NSImage>` with `countLimit = 256` for steady-state memory and bumps a `@Published version` so SwiftUI redraws after each insert. `cancelAll()` is called on `.onDisappear` to drop in-flight renders when the user leaves the workspace.
- The dedicated dedupe folder picker stores its bookmark under key `deduplicate.destination`. If the bookmark fails to resolve at bootstrap, both the bookmark and the path are dropped so `deduplicateDestinationPath` falls back to the organize destination instead of silently scanning a dead path.

## Sandbox Status

`ui/Packaging/Chronoframe.entitlements` is currently empty — **App Sandbox is not enabled** in the shipped build. Both organize and dedupe rely on `FolderAccessService.resolveBookmark` calling `startAccessingSecurityScopedResource` once at bootstrap and never `stop`ing (process-wide hold). If sandboxing is enabled later, both flows need an explicit `withSecurityScopedAccess { ... }` lifecycle around their scans. Update both at the same time, not one in isolation.

## User-Facing Error Handling

Recent work improved error handling for nontechnical users. Preserve that tone.

- `ui/Sources/ChronoframeAppCore/Support/UserFacingErrorMessage.swift` is the shared formatter for technical errors.
- Error text should be plain, specific, action-oriented, and reassuring when appropriate.
- Avoid surfacing raw `NSError`, POSIX, SQLite, Python traceback, or Swift decoding language directly in the UI.
- When a run fails, copy should emphasize that originals were left untouched.
- `RunLogStore.append(issue:)` rewrites backend issue strings before showing them.
- `HistoryStore` keeps failed cleanup entries visible and reports manual cleanup guidance when automatic cleanup cannot finish.
- Tests should cover both the user-visible wording and the technical detail retention where useful for diagnostics.

## Build And Test Commands

Use a local cache/home when running SwiftPM tests. It avoids sandbox and module-cache noise.

```bash
/bin/zsh -lc "HOME=$PWD/.tmp/home XDG_CACHE_HOME=$PWD/.tmp/home/Library/Caches CLANG_MODULE_CACHE_PATH=$PWD/.tmp/modulecache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.tmp/modulecache swift test --package-path ui"
```

Swift coverage:

```bash
/bin/zsh -lc "HOME=$PWD/.tmp/home XDG_CACHE_HOME=$PWD/.tmp/home/Library/Caches CLANG_MODULE_CACHE_PATH=$PWD/.tmp/modulecache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.tmp/modulecache swift test --enable-code-coverage --package-path ui"
jq '.data[0].totals.lines' ui/.build/arm64-apple-macosx/debug/codecov/ChronoframeUI.json
```

Meaningful Swift coverage gate (excludes SwiftUI view bodies, app entry points, and OS bridge wrappers; fails below 95%):

```bash
script/swift_meaningful_coverage.sh
```

Local Xcode build:

```bash
xcodebuild -project ui/Chronoframe.xcodeproj -scheme Chronoframe -configuration Debug -derivedDataPath .tmp/ChronoframeDerivedData -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO build
```

CI-like Swift CodeQL build:

```bash
xcodebuild -project ui/Chronoframe.xcodeproj -scheme Chronoframe -configuration Debug -derivedDataPath .tmp/ChronoframeDerivedData-x86 -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES build
```

Python tests:

```bash
python3 -m unittest test_chronoframe test_ui_build test_ui_packaging -v
```

Python coverage:

```bash
python3 -m coverage run -m unittest test_chronoframe test_ui_build test_ui_packaging -v
python3 -m coverage report -m --omit "test_*"
```

Before committing, also run:

```bash
git diff --check
```

## Coverage Reality

Be precise when discussing coverage.

- Python production-only coverage was 96% after the April 2026 error-handling/coverage pass.
- Full Python coverage was 98%.
- `UserFacingErrorMessage.swift` had 98.2% line coverage.
- Raw SwiftPM aggregate coverage was around 62% after the April 2026 meaningful coverage pass because SwiftUI view files are counted but are not all exercised by unit tests.
- `script/swift_meaningful_coverage.sh` enforces 95%+ on deterministic domain algorithms, planning/path building, hashing, indexing, and user-facing formatting. Do not claim project-wide Swift coverage over 95% unless the metric excludes SwiftUI view rendering or includes a broader UI-test coverage story.

## GitHub And CI

- Default branch is `main`, not `master`.
- Use `codex/...` branch names for Codex work unless the user asks otherwise.
- GitHub authentication is configured for `gh` in this workspace.
- CodeQL workflow is `.github/workflows/codeql.yml`.
- CodeQL analyzes Python on Ubuntu and Swift on macOS.
- Swift CodeQL uses manual Xcode build mode. The build command currently uses:

```bash
xcodebuild \
  -project ui/Chronoframe.xcodeproj \
  -scheme Chronoframe \
  -configuration Debug \
  -derivedDataPath "$RUNNER_TEMP/ChronoframeDerivedData" \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  build
```

Swift CodeQL can look stuck for a long time while compiling, especially around `FileIdentityHasher.swift`. In the successful run after PR #21, the Swift analyze job took many minutes but completed.

Important CI trap: SwiftPM tests are not enough. If you add a Swift source file that must compile in the app, make sure it is also included in `ui/Chronoframe.xcodeproj/project.pbxproj`. CodeQL builds the Xcode project, not only the Swift package.

Past Swift CodeQL failures included Swift 6 sendability issues, especially around `NSImage?` crossing async boundaries. Be careful with non-Sendable AppKit types in async groups and actor/nonisolated contexts.

## Recent Known State

As of 2026-04-25:

- `main` was clean and matched `origin/main`.
- PR #20 merged user-facing error handling.
- PR #21 merged coverage improvements.
- Post-merge CodeQL run `24944239628` passed for both Python and Swift on `main`.

Verify freshness before relying on these historical details for a new CI/debugging task.

## Packaging And Launch Notes

- `.codex/environments/environment.toml` is autogenerated. Do not edit it manually.
- Codex's configured Run action calls `./script/build_and_run.sh`.
- `ui/Packaging/validate_app_bundle.py` validates packaged app bundles.
- `test_ui_packaging.py` uses injectable `codesign_inspector` and `gatekeeper_inspector` hooks so tests stay deterministic.

## UI And Design Notes

Chronoframe is a native macOS SwiftUI app with a restrained, work-focused Meridian visual language. The amber waypoint dot is a key brand motif.

When editing UI:

- Keep it native and practical. This is an operational desktop app, not a marketing page.
- Prefer native controls and predictable macOS workflows.
- Avoid nested cards, decorative gradient/orb backgrounds, and visible instructional text that describes obvious UI mechanics.
- Make error and empty states useful to a nontechnical person.

## Files And Directories To Avoid

- `.claude/worktrees/` contains stale generated worktrees. Do not treat it as source of truth.
- `.codex/environments/environment.toml` is autogenerated.
- Ignore generated caches and build outputs unless the task explicitly concerns them:
  - `.coverage`
  - `.tmp/`
  - `.pytest_cache/`
  - `__pycache__/`
  - `ui/.build/`
  - `ui/build/`

## Development Habits That Matter Here

- Prefer `rg` and `rg --files` for searching.
- Use `apply_patch` for manual file edits.
- Preserve user changes in the worktree; do not reset or checkout files unless explicitly asked.
- When debugging CI, inspect the GitHub logs with `gh` if auth is available, then reproduce locally with the closest matching command.
- When adding Swift code, keep SwiftPM and Xcode project membership in sync.
- When changing user-visible failure behavior, add tests that assert the wording a nontechnical user will see.
