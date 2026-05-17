# Chronoframe Project Memory

This file is project context for future coding agents. Keep it current when architecture, build commands, CI behavior, or workflow assumptions change.

## Project Purpose

Chronoframe is a safe photo/video organizer. It scans an unsorted source folder, resolves each media file's date, and copies files into a date-based destination layout. The central promise is that originals are never modified, moved, or deleted.

Chronoframe is now Swift-first:

- A native macOS SwiftUI app under `ui/`, using Swift package targets and an Xcode project.
- A SwiftPM command-line executable, `ChronoframeCLI`, backed by the same Swift organizing engine.

## Architecture

The macOS app lives in `ui/`.

- `ui/Sources/ChronoframeCore/`: native Swift organizing engine.
- `ui/Sources/ChronoframeAppCore/`: app state, stores, and user-facing services.
- `ui/Sources/ChronoframeApp/`: SwiftUI views and app entry point.
- `ui/Sources/ChronoframeCLIKit/`: reusable Swift command-line parser and runners.
- `ui/Sources/ChronoframeCLI/`: SwiftPM CLI executable entry point.
- `ui/Tests/ChronoframeAppCoreTests/` and `ui/Tests/ChronoframeAppTests/`: Swift tests.
- `ui/Tests/ChronoframeCLIKitTests/`: Swift CLI tests.
- `ui/Chronoframe.xcodeproj/`: Xcode project used by CodeQL and app builds.

Swift package targets:

- `ChronoframeCore`
- `ChronoframeAppCore`
- `ChronoframeCLIKit`
- `ChronoframeApp`
- `ChronoframeCLI`
- `ChronoframeAppCoreTests`
- `ChronoframeAppTests`
- `ChronoframeCLIKitTests`

The app uses `SwiftOrganizerEngine` for preview, transfer, revert, and reorganize. The retired backend, hybrid engine selector, and shell-out flows have been removed.

Shared on-disk artifacts include:

- `.organize_cache.db` (organize source/destination file identity hashes are checkpointed during planning; also hosts a `DedupeFeatures` table caching per-photo Vision feature prints, dHash, and quality scores so dedupe re-scans are incremental)
- `.organize_logs/dry_run_report_*.csv`
- `.organize_logs/audit_receipt_*.json` (organize transfer audit receipt; versioned, UUID-suffixed, status-aware)
- `.organize_logs/dedupe_audit_receipt_*.json` (Deduplicate run audit receipt — used by Run History → Revert)
- `.organize_logs/reorganize_audit_receipt_*.json` (Reorganize move audit receipt — used by Run History → Revert)
- `.organize_log.txt`

The macOS app sidebar consolidates the original Setup / Run / Run History flows under a single **Organize** destination (`ui/Sources/ChronoframeApp/Views/Organize/OrganizeContainerView.swift`) and adds a peer **Deduplicate** destination (`ui/Sources/ChronoframeApp/Views/Deduplicate/`). Both share the active organize destination by default; Deduplicate may also point at a user-picked dedicated folder.

## Safety Invariants

Do not weaken these unless the user explicitly asks for a product change.

- The source folder is read-only from Chronoframe's perspective. Never delete, move, rename, or modify source files.
- Copies are written to a temporary file, flushed, then atomically renamed into place.
- Copy verification defaults on for new runs and profiles. Skipping verification is an advanced opt-out.
- Existing destination files are not overwritten. Collisions get a distinct destination name.
- Deduplication is content-based, using BLAKE2b hashes, not filenames.
- Dedupe dHash-only similarity is never enough for automatic deletion; non-exact weak matches stay review-only with zero preselected deletions unless explicitly confirmed.
- Copy verification re-hashes written files and removes a bad copy if verification fails. The Swift CLI and app verify by default; use `--skip-verify` only for the explicit speed/integrity tradeoff.
- Revert deletes only destination files whose current hash still matches the audit receipt.
- Organize, dedupe, and reorganize receipts are written before mutation where possible, carry statuses (`PENDING`, `COMPLETED`, `ABORTED`, `FAILED` as applicable), and use collision-proof names.
- Aborted runs should make it clear that source files were left untouched.
- Failure thresholds intentionally stop bad runs: 5 consecutive failures or 20 total failures.
- Deduplicate moves files to the macOS Trash only. Hard delete is not available in the production UI or executor commit path.
- The dedupe audit receipt directory (`.organize_logs/`) is preflighted before any deletion. An unwritable destination aborts the commit with `ReceiptPreflightError` and zero files touched.
- Pair-as-unit conflict resolution is **Keep-wins**: when either half of a RAW+JPEG or Live Photo HEIC+MOV pair has an effective Keep — explicit, automatic (the cluster's auto-suggested keeper), or implicit (default-Keep in an unreviewed low/medium-confidence cluster) — neither half is deleted. Pair-fanout deletes a partner only when that partner is itself marked Delete, auto-selected for Delete by a high-confidence cluster, or is a singleton outside any cluster.
- Organize and dedupe traversal must not follow symlinks or aliases by default. Skip symlink files/directories, app bundles, photo libraries, packages, hidden system-like containers, and any path that escapes the selected root.
- Fast destination scans are validating scans: cached records are trusted only when the file still exists and size/mtime still match; stale cache rows are refreshed or removed.

## Deduplicate Workspace

`ui/Sources/ChronoframeCore/DeduplicateScanner.swift` runs the scan; `DeduplicationPlanner.plan` is the single source of truth for "what files will the executor mutate". Both the commit-footer preview and `DeduplicateExecutor.commit` consume the same `DeduplicationPlan` so what the user sees in the footer is exactly what happens.

- Exact hashes and valid Vision feature-print confirmation can produce high-confidence automatic suggestions. dHash-only clusters are intentionally excluded from automatic deletion and must remain review-only.
- Per-pair-kind toggles (`treatRawJpegPairsAsUnit`, `treatLivePhotoPairsAsUnit`) are honored independently. Disabling RAW pairing must not affect Live Photo behaviour and vice versa.
- The plan carries owning-cluster metadata for **every** mutation, including pair partners that aren't cluster members on their own (Live Photo MOV halves, mainly), so the audit receipt is exhaustive and Run History → Revert can restore everything the executor touched.
- `DeduplicateExecutor` preflights `.organize_logs/`, writes a `PENDING` receipt before moving anything to Trash, updates the same receipt as each item moves, and finalizes it to `COMPLETED` or `ABORTED`.
- Thumbnails go through `ui/Sources/ChronoframeApp/Views/Components/ThumbnailRenderer.swift` (single QuickLook entry point shared by ContactSheet and DedupeThumbnailLoader). The dedupe loader uses `NSCache<NSString, NSImage>` with `countLimit = 256` for steady-state memory and bumps a `@Published version` so SwiftUI redraws after each insert. `cancelAll()` is called on `.onDisappear` to drop in-flight renders when the user leaves the workspace.
- The dedicated dedupe folder picker stores its bookmark under key `deduplicate.destination`. If the bookmark fails to resolve at bootstrap, both the bookmark and the path are dropped so `deduplicateDestinationPath` falls back to the organize destination instead of silently scanning a dead path.

## Sandbox Status

`ui/Packaging/Chronoframe.entitlements` enables the App Sandbox with user-selected read/write file access and security-scoped bookmarks for Developer ID distribution. Organize and dedupe rely on stored folder bookmarks; keep scoped access lifecycle changes synchronized across both flows so one mutating path is not sandbox-ready while another is not.

Release packaging defaults to Developer ID signed, hardened-runtime, notarized, stapled artifacts. Local ad hoc archives require the explicit `ui/archive.sh --local` mode and must not be treated as releasable assets.

## User-Facing Error Handling

Recent work improved error handling for nontechnical users. Preserve that tone.

- `ui/Sources/ChronoframeAppCore/Support/UserFacingErrorMessage.swift` is the shared formatter for technical errors.
- Error text should be plain, specific, action-oriented, and reassuring when appropriate.
- Avoid surfacing raw `NSError`, POSIX, SQLite, shell output, or Swift decoding language directly in the UI.
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

Xcode UI tests:

```bash
xcodebuild -project ui/Chronoframe.xcodeproj -scheme Chronoframe -configuration Debug -derivedDataPath .tmp/ChronoframeXcodeTestDerivedData -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO test
```

The shared Xcode scheme runs the macOS UI-test target only. SwiftPM remains the authoritative lane for unit tests across `ChronoframeCore`, `ChronoframeAppCore`, and `ChronoframeApp`.

CI-like Swift CodeQL build:

```bash
xcodebuild -project ui/Chronoframe.xcodeproj -scheme Chronoframe -configuration Debug -derivedDataPath .tmp/ChronoframeDerivedData-x86 -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES build
```

Before committing, also run:

```bash
git diff --check
```

## Coverage Reality

Be precise when discussing coverage.

- `UserFacingErrorMessage.swift` had 98.2% line coverage.
- Raw SwiftPM aggregate coverage was around 62% after the April 2026 meaningful coverage pass because SwiftUI view files are counted but are not all exercised by unit tests.
- `script/swift_meaningful_coverage.sh` enforces 95%+ on deterministic domain algorithms, planning/path building, hashing, indexing, destructive executors, receipt writers, and user-facing formatting. Do not claim project-wide Swift coverage over 95% unless the metric excludes SwiftUI view rendering or includes a broader UI-test coverage story.

## GitHub And CI

- Default branch is `main`, not `master`.
- Use `codex/...` branch names for Codex work unless the user asks otherwise.
- GitHub authentication is configured for `gh` in this workspace.
- CodeQL workflow is `.github/workflows/codeql.yml`.
- CodeQL analyzes Swift on macOS.
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
- Post-merge CodeQL run `24944239628` passed on `main` before the repo became Swift-only.

Verify freshness before relying on these historical details for a new CI/debugging task.

## Packaging And Launch Notes

- `.codex/environments/environment.toml` is autogenerated. Do not edit it manually.
- Codex's configured Run action calls `./script/build_and_run.sh`.
- `ui/archive.sh` defaults to release mode and must fail without Developer ID identity, team ID, notarization credentials, and successful stapling. Use `--local` only for non-release ad hoc archives.
- `ChronoframePackagingTool` validates packaged app bundles.
- `ui/Tests/ChronoframePackagingTests/` uses injectable command runners so signing and Gatekeeper tests stay deterministic.

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
  - `ui/.build/`
  - `ui/build/`

## Development Habits That Matter Here

- Prefer `rg` and `rg --files` for searching.
- Use `apply_patch` for manual file edits.
- Preserve user changes in the worktree; do not reset or checkout files unless explicitly asked.
- When debugging CI, inspect the GitHub logs with `gh` if auth is available, then reproduce locally with the closest matching command.
- When adding Swift code, keep SwiftPM and Xcode project membership in sync.
- When changing user-visible failure behavior, add tests that assert the wording a nontechnical user will see.
