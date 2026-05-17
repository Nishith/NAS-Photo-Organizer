# Chronoframe — System Understanding

## Overview

Chronoframe is a native macOS SwiftUI photo/video organizer with two destructive workflows (Organize, Deduplicate) and a non-destructive Reorganize. Its core promise is that **source files are never modified, moved, or deleted**, and every destructive action (copies into the destination, dedupe trashing) is logged in an audit receipt so it can be reverted from the in-app Run History. It ships as a sandboxed Developer ID app and a SwiftPM CLI (`ChronoframeCLI`).

## High-Level Architecture

```
ui/Sources/
  ChronoframeCore/        # Pure Swift engine: hashing, planning, executors, SQLite
  ChronoframeAppCore/     # App services + @Published stores (MainActor for most)
  ChronoframeApp/         # SwiftUI views + entry point
  ChronoframeCLIKit/      # Reusable arg parser + runners
  ChronoframeCLI/         # SwiftPM CLI executable
  ChronoframePackaging/   # Bundle validator used by archive scripts
```

Engine components form a planner → executor pipeline:

- `MediaDiscovery` walks the source tree (skipping symlinks, packages, photo libraries, hidden files).
- `MediaDateResolver` derives a canonical date per file from EXIF / mtime / filename.
- `CopyPlanBuilder` + `PlanningPathBuilder` produce destination paths.
- `FileIdentityHasher` (BLAKE2b 512-bit, 128-byte block) hashes contents.
- `TransferExecutor` writes to `<dest>.tmp` (UUID-suffixed in parallel mode), `F_FULLFSYNC`s the file, then `renamex_np(RENAME_EXCL)` atomically. Verifies by re-hashing.
- `DeduplicateScanner` → `DuplicateClusterer` → `ClusterAnnotator` → `ClusterConfidenceScorer` produce clusters of duplicate candidates.
- `DeduplicationPlanner.plan` is the **single source of truth** for "what files will the executor mutate", consumed both by the commit footer and `DeduplicateExecutor`.
- `DeduplicateExecutor` preflights `.organize_logs/`, writes a PENDING JSON receipt, moves files to Trash incrementally, finalizes COMPLETED.
- `RevertExecutor` re-hashes destination files, only unlinks/trashes when hash matches the receipt (per-fd, `O_NOFOLLOW`, inode-pinned).
- `OrganizerDatabase` (SQLite, WAL, single connection w/ FULLMUTEX) hosts the organize cache, dedupe feature-print cache, and run-job rows.

App layer:

- `SwiftOrganizerEngine` is the bridge between MainActor stores and the engine's detached Tasks. Streams `RunEvent` back via `AsyncStream`.
- Stores: `RunSessionStore`, `DeduplicateSessionStore`, `HistoryStore`, `SetupStore`, `PreferencesStore`, `PreviewReviewStore`, `LibraryHealthStore`, `RunLogStore`. Most are `@MainActor` (a few are not — see findings).
- `FolderAccessService` resolves security-scoped bookmarks for the source/destination/dedupe folders and starts/stops the scope around runs.

## Core Flows

**Organize.** User picks source + destination → preview produces a dry-run CSV → user confirms → `TransferExecutor.executeQueuedJobs` walks the SQLite job queue, copies, verifies, writes audit receipt at end. UI streams `RunEvent` for progress.

**Deduplicate.** User chooses scan root (defaults to organize destination, may pick a dedicated folder) → scanner produces clusters with confidence (high/medium/low) → user reviews + approves clusters → `commitReviewed` builds a `DeduplicationPlan` and the executor trashes the non-keepers, writing per-item receipt updates. Cluster ownership in the receipt lets Revert restore everything (including pair partners that aren't cluster members themselves).

**Reorganize.** Hash every file under destination → plan path moves → execute moves → write receipt. No source involvement.

**Revert.** Read `audit_receipt_*.json` / `dedupe_audit_receipt_*.json` / `reorganize_audit_receipt_*.json`. For each entry, hash current target; if it matches the receipt's recorded hash, restore (delete destination for organize/dedupe, move-back for reorganize). Mismatches preserve the file.

## Data Model and Data Lifecycle

- **`.organize_cache.db`** — SQLite. Tables: organize sources, organize destinations, organize jobs, `DedupeFeatures` (per-photo Vision feature print, dHash, quality score, size, mtime).
- **Receipts** under `<destination>/.organize_logs/`:
  - `audit_receipt_<ts>_<uuid>.json` (organize). Schema v2. Carries source path, dest path, hash.
  - `dedupe_audit_receipt_<ts>_<uuid>.json`. Carries trashURL, owning cluster id/kind, pair origin.
  - `reorganize_audit_receipt_<ts>_<uuid>.json`. Carries pre/post path + hash.
- **Streaming spool**: `<receipt-name>.transfers.tmp` is written incrementally during a long organize run and consolidated at `finish()`.
- **`.organize_log.txt`** — append-only human-readable run log.
- Hashes are BLAKE2b-512 today. There is **no algorithm tag** in the receipt schema.

## Security Model

**Trust boundaries.** App is sandboxed; reads via security-scoped bookmarks stored in `UserDefaults`. The CLI runs unsandboxed but is the same Swift code. There is no network surface and no IPC — Chronoframe is a single-user desktop tool.

**Authentication / authorization.** None — local user only.

**Secrets.** Notarization credentials live in the developer's keychain or CI secrets, read by `ui/archive.sh` at release time. No secrets are bundled.

**Data classification.** User's personal photos and videos. Sensitive by user expectation, not regulated (no HIPAA/PCI).

**Security-critical invariants (enforced where stated, or NOT enforced — flagged in findings):**

1. The source folder is read-only from Chronoframe's perspective. Enforced by code shape: no code path writes/deletes/renames inside the configured source root. **Holds in core engine; weakened by `MediaDiscovery.enumerateManifest` which walks arbitrary manifest paths without symlink/package containment checks** (see finding #9).
2. Copies are temp-then-rename, fsynced, hashed-verified. Enforced in `TransferExecutor.safeCopyAtomicOnce` / `prepareAtomicCopy`. **Durability gap**: parent-directory fsync after rename is missing (see finding ranked-out below — durability is acceptable today on APFS but not crash-perfect).
3. Existing destination files are not overwritten. Enforced by `renamex_np(RENAME_EXCL)` + collision-resolved naming.
4. Revert deletes only destination files whose current hash matches the receipt. Enforced in `RevertExecutor.safeRevert` via `O_NOFOLLOW` + inode-pinning + re-hash.
5. Deduplicate moves to Trash only. Enforced — `commit(plan:hardDelete: false)` is the only call site, and `DedupeDecisions.init` overrides any non-false `hardDelete` argument to `false` (curious but defense-in-depth).
6. dHash-only similarity is never automatic deletion. Mostly enforced via `ClusterConfidenceScorer` requiring `visionDistance < 0.10` for `.high`. **Leak**: `currentDeletionPlan()` and `acceptAllSuggestions` include all clusters, so preselected weak-match deletions appear in the footer and can be committed if the user uses the "accept all" affordance (see findings #4, #10).
7. Pair-as-unit is Keep-wins. **Violated**: a default-keep partner does not block pair-induced deletion in the planner (see finding #1).
8. Receipt preflight before any mutation. Enforced on the initial PENDING write only; per-item incremental writes are not preflight-guarded (see finding #7).
9. Receipts versioned and status-aware. Schema version is written but not read (see finding #6).
10. Failure thresholds: 5 consecutive / 20 total. Implemented; `consecutiveFailures` is not reset by skips (P2 semantic ambiguity).

## Reliability and Operational Model

- Single SQLite connection with `SQLITE_OPEN_FULLMUTEX` + WAL + 30s busy timeout. Migrations in single transaction.
- File writes use `F_FULLFSYNC`. Parent-dir fsync after rename is **absent** (durability hole).
- Crashed organize run produces **no audit receipt** (only a `.transfers.tmp` spool which `deinit` may delete; if SIGKILL/power, it stays orphaned). User has no in-app revert affordance for partially-completed runs (see finding #3).
- Cancellation: `SwiftOrganizerEngine.cancelCurrentRun` cancels the Swift Task but does not flip the in-engine `TaskCancellationCheck` flag, so long-running synchronous bodies don't see the signal until they yield (see finding flagged in app-layer report, ranked P1).
- Single-instance is enforced in `applicationWillFinishLaunching`. Cross-instance file races are still theoretically possible during launch overlap (P2).
- Observability: structured log lines via `RunEvent` + `.organize_log.txt`. No metrics/tracing.

## Performance and Capacity Posture

- Hash + verify dominates a transfer run. BLAKE2b is correct; chunk loop verified.
- `ReorganizeExecutor` writes the FULL receipt JSON after every move (O(N²) in bytes). For 50k moves this is hours of redundant I/O (P1).
- Dedupe feature print cache is keyed on `(path, size, mtime)` and is incremental. Cache invalidation is correct.

## Testing and Quality Posture

- SwiftPM unit tests under `ui/Tests/Chronoframe*Tests/` are the authoritative coverage lane.
- `script/swift_meaningful_coverage.sh` enforces 95% on an **allowlisted** set of "meaningful" files. **The allowlist drifts silently**: it currently references three files that don't exist in the source tree (`BackgroundDedupeMonitor`, `EditVariantDetector`, `ImportDuplicateChecker`) and does not include several safety-critical files (`OrganizerDatabase`, `FileIdentityHasher`, `DeduplicateScanner`, `MediaDateResolver`, `FileSystemMonitor`, `BookmarkPathResolver`, `BundleValidator`). The gate is **passable while leaving critical code uncovered** (see finding #2).
- Dedupe commit/revert tests use a `MockDeduplicateFileOperations` whose `trashItem` is `moveItem` — real `FileManager.trashItem` semantics are not exercised.

## Dependency and Supply-Chain Posture

- `ui/Package.swift` has **zero external `.package(...)` deps**. No `Package.resolved` committed (benign today, will matter the moment the first dep lands).
- Build pipeline: SwiftPM for tests/coverage; Xcode project for the app build + CodeQL. AGENTS.md flags that adding a new Swift file requires updating `project.pbxproj` to keep CodeQL building.
- CodeQL **does not run on pull requests** (`.github/workflows/codeql.yml:14` `if: github.event_name != 'pull_request'`). This was a deliberate disablement to dodge timeouts but defeats the gate.
- `archive.sh` notarization passes `--password "$CHRONOFRAME_NOTARY_PASSWORD"` as argv to `xcrun notarytool`, visible via `ps -ef`. Same script does `TMP_DIR="${TMPDIR:-/tmp}/chronoframe-ui-archive"` which becomes `/chronoframe-ui-archive` if `TMPDIR` is set-but-empty.

## Known Risks and Fragile Areas

- Dedupe planner pair-rescue depends on `DecisionSource` tagging — `defaultKeep` was silently treated as not-blocking, which is the single most consequential bug surfaced by this sweep.
- Receipt format has no `schemaVersion` field on the reader side. A future writer change is a runtime hazard.
- Crashed-run recovery: no PENDING organize receipt persists, so a power-lossed transfer leaves files in the destination with no in-app revert path.
- The 95% coverage gate is gameable through allowlist drift — every CI green is partially fictional.
- Sandbox: `FolderAccessService.resolveBookmark` falls back to a synthesized URL if bookmark resolution fails, letting the engine proceed against a path it has no scoped access to. Some callsites (dedupe bootstrap) compensate; manual source/destination paths do not.

## Important Files

- `ui/Sources/ChronoframeCore/TransferExecutor.swift` — atomic copy + verify + receipt writer. Most safety-critical file in the repo.
- `ui/Sources/ChronoframeCore/DeduplicationPlanner.swift` — single source of truth for dedupe mutations. Bug here = data loss.
- `ui/Sources/ChronoframeCore/RevertExecutor.swift` — hash-pinned restore. Decoder shape decides forward-compat.
- `ui/Sources/ChronoframeAppCore/Services/FolderAccessService.swift` — sandbox-scoped access lifecycle.
- `ui/Sources/ChronoframeAppCore/Stores/HistoryStore.swift` — destinationRoot is the implicit handle for "where to find receipts".
- `script/swift_meaningful_coverage.sh` — the gate that's supposed to keep the bar at 95%.

## Breadth Coverage Table

| Top-level dir / area | Status | Notes |
|---|---|---|
| `ui/Sources/ChronoframeCore` | **REVIEWED** | Engine, hashing, planners, executors. All findings sourced here verified file-by-file. |
| `ui/Sources/ChronoframeAppCore/Services` | **REVIEWED** | FolderAccessService, SwiftOrganizerEngine, DroppedItemStager, ProfilesRepository, TransferredSourcesLog, RunHistoryIndexer. |
| `ui/Sources/ChronoframeAppCore/Stores` | **REVIEWED** | All 8 stores read end-to-end by app-layer agent. |
| `ui/Sources/ChronoframeApp/Views` | **SKIMMED** | View bodies — checked only for state-mutation hazards from MainActor invariants. |
| `ui/Sources/ChronoframeApp/App` | **SKIMMED** | App entry, AppState. Spot-checked for security scope lifecycle. |
| `ui/Sources/ChronoframeCLI` / `ChronoframeCLIKit` | **SKIMMED** | Same engine as app; CLI-specific paths not deeply traced. |
| `ui/Sources/ChronoframePackaging` / `ChronoframePackagingTool` | **SKIMMED** | Bundle validator — not user-data-mutating. |
| `ui/Tests/*` | **REVIEWED** | Tests/CI agent specifically checked for mock-boundary theater. |
| `.github/workflows/*` | **REVIEWED** | CI, CodeQL, release workflows read in full. |
| `ui/build.sh`, `ui/archive.sh`, `ui/archive-mas.sh`, `script/build_and_run.sh` | **REVIEWED** | Shell scripts inspected for argv injection / TMPDIR / password leakage. |
| `docs/` | **SKIMMED** | Read FAQ + TECHNICAL.md to cross-check against code; flagged drift in DroppedItemStager doc-comment. |
| `tests/fixtures` | **DEFERRED** | Fixture media files, not code. No findings expected. |
| `ui/Resources` | **DEFERRED** | Asset bundles. |

## Open Questions

- Is the `currentDeletionPlan()`-vs-`reviewedDeletionPlan()` footer choice intentional? The user-facing impact (footer overcounts) depends on which the UI calls. Verification needed in the View layer to confirm whether the leak (finding #10) is a real "user sees inflated number" bug or merely an internal artifact.
- Is `DroppedItemStager.stage` missing the actual symlink creation (data bug), or is the doc-comment stale (cosmetic)? Verify by reading `DryRunPlanner`'s drop-manifest consumer.
- The 5/20 failure threshold semantics for skipped jobs — intended to count or not count toward consecutive failures? AGENTS.md doesn't specify.
