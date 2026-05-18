# Chronoframe — Top Bug Sweep Findings (Refresh Pass)

This pass is a **REFRESH** — prior reviews landed as commit `eae3cf3` ("Implement principal-engineer review wins") and `de2a712` ("Bug sweep fixes and observability improvements"). Most prior P0s appear closed (`safeRevert` inode-pinning, fast-destination removal, TOCTOU fix, 95% coverage). The findings below are **new** or **regressions** uncovered by this sweep, verified file-by-file as of working tree at `claude/tender-wilbur-b44083`.

Recent in-flight commit `4ee99dd` ("Avoid quarantining unreadable revert receipts") interacts with finding #6 (`RevertExecutor` ignores `schemaVersion`) — both touch revert robustness.

---

## Top 10 Highest-Impact Findings

### 1. Pair-as-unit "Keep wins" is bypassed when partner is in default-keep state — silent data loss ✅ FIXED

- **Category:** data integrity / safety invariant
- **Priority:** **P0**
- **Effort:** XS
- **Confidence:** high
- **Problem:** `DeduplicationPlanner.plan` step 2 only flips a `Delete` back to `Keep` when the partner's `DecisionSource.blocksPairDeletion` is true; `.defaultKeep` returns false. In a low/medium-confidence cluster (no auto-suggested deletes), both members start at `(decision=.keep, source=.defaultKeep)`. The user marks one half Delete. Step 2 does NOT rescue the partner. Step 5 also does not short-circuit (the guard at line 131-135 requires `partnerEffective.source.blocksPairDeletion`). The partner is fanned into the plan with `pairOrigin: .rawJpeg` / `.livePhoto`. **Both files go to Trash.**
- **Why it matters:** This is the documented Keep-wins invariant (AGENTS.md "Safety Invariants"). User explicitly chose to delete one half of a pair; the partner was visually shown as Keep in the UI; both are trashed. Revert recovers them, but the user has no signal in the commit footer that the partner is included in the plan unless they read the pair-origin annotation.
- **Evidence:**
  - [ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:42](ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:42) — `DecisionSource.defaultKeep.blocksPairDeletion = false`
  - [ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:86](ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:86) — `case (.keep, .delete): if info.source.blocksPairDeletion { ... }` (won't fire for defaultKeep)
  - [ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:131-135](ui/Sources/ChronoframeCore/DeduplicationPlanner.swift:131) — pair-expansion bypass guard requires `blocksPairDeletion`
- **Root cause:** The `blocksPairDeletion` predicate was scoped to "user/system explicitly chose Keep" rather than "current effective decision is Keep". For pair safety, presence of a Keep in `effective[]` should be sufficient regardless of source.
- **Failure scenario:** RAW1.CR2 + JPEG1.jpg in a medium-confidence pair (RAW+JPEG), `treatRawJpegPairsAsUnit = true`. User reviews the cluster and clicks Delete on RAW1.CR2 because they trust the JPEG more. UI shows JPEG1.jpg as Keep. User approves the cluster, clicks Commit. Planner emits both RAW1 (direct) and JPEG1 (pair fanout). Executor trashes both. User opens the destination expecting JPEG1 and finds nothing.
- **Recommended change:** Treat `.defaultKeep` as also blocking pair-induced deletion. Specifically: in `DeduplicationPlanner.swift:42-48` make `.defaultKeep` return `true` for `blocksPairDeletion`, OR add an explicit guard in step 5: `if effective[partner]?.decision == .keep { continue }` regardless of source.
- **Structural guard:** Add a parameterized test in `DeduplicateTests` matrix-iterating `(cluster confidence × user-marks-half-delete × pair kind)` and asserting that the planner never plans the unmarked partner. Land the test FIRST (failing) to lock the regression surface before fixing the predicate.
- **Expected impact:** Closes the only data-loss surface in the dedupe path.
- **Tradeoffs:** None — this is strictly more conservative than current behavior.
- **Dependencies:** None.
- **Owner discipline:** backend / safety.

---

### 2. `script/swift_meaningful_coverage.sh` regex silently shrinks; 95% gate is partially fictional ✅ FIXED (commit `3eb2647`)

- **Category:** testing / release safety
- **Priority:** **P0**
- **Effort:** S
- **Confidence:** high
- **Problem:** The "meaningful coverage" gate is computed over an **allowlist regex** of filenames at [script/swift_meaningful_coverage.sh:31](script/swift_meaningful_coverage.sh:31). The list references three files that **do not exist** in the source tree: `BackgroundDedupeMonitor`, `EditVariantDetector`, `ImportDuplicateChecker`. It also omits critical safety files that aren't UI bodies: `OrganizerDatabase`, `FileIdentityHasher`, `DeduplicateScanner`, `DeduplicatePairDetector`, `MediaDateResolver`, `FileSystemMonitor`, `BookmarkPathResolver`, `BundleValidator`, `EngineDomainModels`. The denominator is whatever matches; phantom files contribute zero; the gate stays green while critical code is uncovered.
- **Why it matters:** The 95% bar is the project's primary regression gate against unsafe changes. AGENTS.md emphasizes it explicitly. Trust in the gate is load-bearing.
- **Evidence:** `find ui/Sources -name "*.swift"` yields 104 files; none match `BackgroundDedupeMonitor`, `EditVariantDetector`, or `ImportDuplicateChecker`. Several known-safety files (`OrganizerDatabase.swift`, `FileIdentityHasher.swift`) exist but the regex does not include them.
- **Root cause:** Allowlist drift. There is no assertion that every allowlisted name resolves to a real file.
- **Recommended change:** Switch to a **denylist** (exclude SwiftUI view bodies, app entry, OS bridge wrappers) instead of an allowlist; OR keep the allowlist but add a preflight step that fails if any allowlisted basename has zero matching files in `ui/Sources`. Also add `OrganizerDatabase`, `FileIdentityHasher`, `DeduplicateScanner`, `DeduplicatePairDetector`, `MediaDateResolver`, `FileSystemMonitor`, `BookmarkPathResolver`, `BundleValidator` to the gate immediately.
- **Structural guard:** A new step in the same script: `for f in $(grep -oE '[A-Z][A-Za-z0-9+]+' <<< "$MEANINGFUL_REGEX"); do find ui/Sources -name "$f.swift" -print -quit | grep -q . || { echo "Phantom allowlist entry: $f"; exit 2; }; done`.
- **Expected impact:** The coverage gate becomes load-bearing again. Removes a CI-green-but-actually-uncovered hole around the database, hashing, and scanner.
- **Tradeoffs:** Some currently-uncovered files will need tests added — short-term CI red until tests land.
- **Owner:** backend / DX.

---

### 3. Crashed organize run produces no audit receipt → copied files become unrevertable via the app ✅ FIXED

- **Category:** reliability / data integrity
- **Priority:** **P0**
- **Effort:** M
- **Confidence:** high
- **Problem:** `StreamingAuditReceiptWriter` streams transfers into `<receipt-name>.transfers.tmp` and only emits the actual JSON receipt during `finish()` ([ui/Sources/ChronoframeCore/TransferExecutor.swift:959-984](ui/Sources/ChronoframeCore/TransferExecutor.swift:959)). On SIGKILL / power loss / app crash before `finish()` runs, **no receipt is written**. The `.transfers.tmp` spool also has no recovery path — `chronoframeTmpPattern` ([line 178-180](ui/Sources/ChronoframeCore/TransferExecutor.swift:178)) only matches per-file `*.tmp`, not the `.transfers.tmp` spool. On next launch the user sees ~N files in the destination and zero history entries.
- **Why it matters:** The promise is "anything Chronoframe touched, you can revert." A crash-during-organize breaks that promise.
- **Evidence:**
  - [ui/Sources/ChronoframeCore/TransferExecutor.swift:889-1003](ui/Sources/ChronoframeCore/TransferExecutor.swift:889) — `StreamingAuditReceiptWriter` class
  - [ui/Sources/ChronoframeCore/TransferExecutor.swift:994-1003](ui/Sources/ChronoframeCore/TransferExecutor.swift:994) — `discardUnfinishedFiles()` in `deinit`
  - `ReorganizeExecutor` already follows the right pattern: persists receipt incrementally with PENDING status (`writeReorganizeReceipt` at [ui/Sources/ChronoframeCore/ReorganizeExecutor.swift:319-345](ui/Sources/ChronoframeCore/ReorganizeExecutor.swift:319)).
- **Failure scenario:** User starts a 30k-file organize from external drive → power outage 12 minutes in → 8k files in destination → reboot → app shows zero run history → user has no UI affordance to revert the 8k files.
- **Recommended change:** Mirror `ReorganizeExecutor` and `DeduplicateExecutor`: write the receipt header with `status: "PENDING"` at run start, append transfers in-place (or to a sidecar that the receipt header points to), update the receipt status to `COMPLETED` / `ABORTED` / `FAILED` at finalization. At engine startup, scan for PENDING organize receipts and offer recovery.
- **Structural guard:** Test that simulates `kill -9` mid-run (or just throws `CancellationError` deep in the executor) and asserts that a PENDING receipt exists on disk afterwards with the in-flight transfers recorded and revertable.
- **Owner:** backend / safety.

---

### 4. `HistoryStore.refresh` wipes `destinationRoot` before validating input ✅ FIXED

- **Category:** data integrity / state correctness
- **Priority:** **P0**
- **Effort:** XS
- **Confidence:** high
- **Problem:** `refresh(destinationRoot:)` sets `self.destinationRoot = destinationRoot` (untrimmed) BEFORE the empty-trim guard ([ui/Sources/ChronoframeAppCore/Stores/HistoryStore.swift:35-42](ui/Sources/ChronoframeAppCore/Stores/HistoryStore.swift:35)).
- **Why it matters:** Calling `refresh(destinationRoot: "")` or `refresh(destinationRoot: "   ")` clobbers any previously-loaded valid root. Downstream callers that use `historyStore.destinationRoot` as the implicit "where receipts live" handle (e.g., `HistoryCoordinator`'s revert-from-history flow, `removeTransferredSource`) then operate against an empty / whitespace path and fail silently.
- **Failure scenario:** User loads a profile → `historyStore.destinationRoot = "/Volumes/Archive"`. User clears the profile selection in Setup → `SetupCoordinator` calls `historyStore.refresh(destinationRoot: "")` → `historyStore.destinationRoot = ""`. User clicks Revert on a recent run entry that still exists in some other state path → revert resolves the receipt path relative to `""` and bails.
- **Recommended change:** Move the trim/guard BEFORE the assignment:
  ```swift
  let trimmed = destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return }
  self.destinationRoot = trimmed
  self.entries = []
  ...
  ```
- **Structural guard:** Unit test: `historyStore.refresh(destinationRoot: "/valid"); historyStore.refresh(destinationRoot: ""); XCTAssertEqual(historyStore.destinationRoot, "/valid")`.
- **Owner:** backend.

---

### 5. `FolderAccessService.resolveBookmark` silently fabricates a URL when bookmark resolution fails ✅ FIXED

- **Category:** sandbox correctness / reliability
- **Priority:** **P0**
- **Effort:** S
- **Confidence:** high
- **Problem:** On `URL(resolvingBookmarkData:...)` failure, the function returns `ResolvedFolderBookmark(url: URL(fileURLWithPath: bookmark.path))` ([ui/Sources/ChronoframeAppCore/Services/FolderAccessService.swift:102-115](ui/Sources/ChronoframeAppCore/Services/FolderAccessService.swift:102)). The synthesized URL is a plain path — `startAccessingSecurityScopedResource()` returns `false` (no scope was actually claimed), but callers proceed.
- **Why it matters:** In sandboxed builds, the engine then tries to read the source/destination and fails with `EPERM` deep in the file enumeration. The dedupe bootstrap path (`AppState.restoreDeduplicateDestinationBookmark`) compensates by validating and dropping the bookmark when resolution fails, but `BookmarkPathResolver.restoreManualPaths` and `.restoreProfilePaths` do not. So a manually-typed or profile-stored source/destination keeps the stale path live.
- **Failure scenario:** User runs Chronoframe on Mac A with `/Volumes/Drive/Photos` as source. Bookmark is stored. They migrate to Mac B (different volume UUID) → bookmark fails to resolve → resolver returns the fabricated URL → app proceeds → run fails at first file read with a generic `EPERM` user message. Diagnosis is hard because the UI still shows the source path as set correctly.
- **Recommended change:** Have `resolveBookmark` return `nil` on resolution failure. Caller must explicitly handle a missing bookmark (prompt the user to re-pick the folder). Update `BookmarkPathResolver` to drop the cached path when the bookmark won't resolve, matching the dedupe-destination bootstrap behavior.
- **Structural guard:** Test that injects a corrupted bookmark blob and asserts `resolveBookmark` returns `nil` and the caller surfaces a user-facing "Please re-grant access to /path".
- **Owner:** backend / sandbox.

---

### 6. `RevertExecutor` ignores receipt `schemaVersion` — forward-compat hazard, no-op on unknown formats ✅ FIXED

- **Category:** data integrity / release safety
- **Priority:** **P0**
- **Effort:** S
- **Confidence:** high
- **Problem:** The writer emits `"schemaVersion": 2` ([ui/Sources/ChronoframeCore/TransferExecutor.swift:965](ui/Sources/ChronoframeCore/TransferExecutor.swift:965)). The reader's `RevertReceipt` Codable struct has no `schemaVersion` field ([ui/Sources/ChronoframeCore/RevertExecutor.swift:41-73](ui/Sources/ChronoframeCore/RevertExecutor.swift:41)), so the decoder silently drops it. A future writer that emits a v3 with breaking semantics will be decoded by an in-the-wild v2 reader using whatever fields still happen to align.
- **Why it matters:** Receipts are the only crash recovery surface. A mis-decoded receipt could refuse to revert legitimate files (`identity mismatch`) or, worse, target the wrong path. The recent commit `4ee99dd` ("Avoid quarantining unreadable revert receipts") explicitly hardened this surface but did not address the schema gap.
- **Recommended change:** Add `schemaVersion` to `RevertReceipt`. If unknown forward version, throw `RevertError.unsupportedSchema(version:)` with a user-facing message ("This receipt was created by a newer version of Chronoframe — upgrade to revert."). Add an `identityScheme` field at the same time so a future hash-algorithm migration is detectable (currently every receipt's `hash` is implicitly BLAKE2b-512 with no marker).
- **Structural guard:** Test that writes a receipt with `schemaVersion: 99` and asserts the revert path surfaces `unsupportedSchema`. Test that writes a receipt with `identityScheme: "blake2b-v1"` and asserts revert proceeds; with `identityScheme: "blake3-v1"` and asserts it refuses cleanly.
- **Owner:** backend / safety.

---

### 7. Dedupe per-item receipt write failure after successful Trash leaves files unrevertable ✅ FIXED

- **Category:** data integrity / reliability
- **Priority:** **P1**
- **Effort:** S
- **Confidence:** high
- **Problem:** After `trashItem` succeeds, `deletedCount` is incremented and an `itemTrashed` event is emitted; then `writeReceipt(...)` is called inline ([ui/Sources/ChronoframeCore/DeduplicateExecutor.swift:119-139](ui/Sources/ChronoframeCore/DeduplicateExecutor.swift:119)). If `writeReceipt` throws (disk full, `.organize_logs/` permission revoked mid-run), the catch yields `itemFailed` for the SAME path that was already trashed. The on-disk receipt remains the previous one (without `trashURL` recorded for this item). At final-finalize time, if that also fails, the user has files in Trash that the receipt does not know about → revert reports "missing Trash URL".
- **Why it matters:** The preflight catches `.organize_logs/` being unwritable BEFORE the first trash, but doesn't help if writability changes mid-run.
- **Recommended change:** Distinguish post-mutation receipt-write failures from pre-mutation failures. Emit a dedicated `itemTrashedReceiptStale` event class; do not double-count via `itemFailed`. At final-finalize, if persistence still fails, surface a critical event that exposes the in-memory receipt JSON so the user can manually export it.
- **Structural guard:** Inject a `FileOperations` mock whose `trashItem` succeeds but whose `writeReceipt` adapter throws every other call; assert: zero double-counted items, all trashed files appear in the final on-disk receipt or a critical recovery event is emitted.
- **Owner:** backend / safety.

---

### 8. Cross-folder dedup makes revert impossible: containment check rejects `additionalSources` paths ✅ FIXED

- **Category:** data integrity
- **Priority:** **P1**
- **Effort:** S
- **Confidence:** high
- **Problem:** `DeduplicateExecutor.revert` enforces `SafePathContainment.isContained(originalURL, in: boundaryURL)` ([ui/Sources/ChronoframeCore/DeduplicateExecutor.swift:200-226](ui/Sources/ChronoframeCore/DeduplicateExecutor.swift:200)), where `boundaryURL` defaults to `receipt.destinationRoot`. But the scanner ingests `configuration.additionalSources` ([ui/Sources/ChronoframeCore/DeduplicateScanner.swift:355](ui/Sources/ChronoframeCore/DeduplicateScanner.swift:355)), and the receipt currently records only `destinationRoot` as the boundary.
- **Failure scenario:** User scans `~/Pictures/Library` with `additionalSources = ["/Volumes/Drive/Old"]`. A duplicate is detected; the loser lives on `/Volumes/Drive/Old`. Trash succeeds. User clicks Revert → containment check rejects every `/Volumes/Drive/Old/...` entry → files stay in Trash with no in-app affordance to recover.
- **Recommended change:** Persist `additionalSources` paths in the receipt (`schemaVersion` bump). Accept any of them as valid boundaries during revert. As long as the path is one the receipt itself records, containment to *that* path is the right check.
- **Structural guard:** Test that runs dedupe with two roots, plans a delete from each, commits, reverts, and asserts both files restore.
- **Owner:** backend.

---

### 9. `MediaDiscovery.enumerateManifest` walks drop-manifest paths without symlink/package/containment checks ✅ FIXED

- **Category:** safety invariant
- **Priority:** **P1**
- **Effort:** S
- **Confidence:** high
- **Problem:** The drop-manifest path ([ui/Sources/ChronoframeCore/MediaDiscovery.swift:207-225](ui/Sources/ChronoframeCore/MediaDiscovery.swift:207)) does not check whether each `item.path` is a symlink, package, or `.photoslibrary`, and does not enforce containment in `rootURL`. The `walk(directoryURL:)` helper only filters CHILDREN ([ui/Sources/ChronoframeCore/MediaDiscovery.swift:172-174](ui/Sources/ChronoframeCore/MediaDiscovery.swift:172)), not the root itself.
- **Why it matters:** The documented invariant is "Organize and dedupe traversal must not follow symlinks or aliases by default. Skip … packages, photo libraries…". Drop-intake should obey the same rule.
- **Failure scenario:** A `.chronoframe_drop_manifest.json` references `~/Pictures/Photos Library.photoslibrary` with `isDirectory: true`. Discovery walks into Photo Library's internal originals and queues them as sources. Originals are never written (safety holds elsewhere), but library-internal masters get copied into the user's destination — surprising, and a documented-filter violation.
- **Recommended change:** Apply the same `isSymbolicLink || isPackage` resource-value check to each manifest item BEFORE descending. Reject items that fall outside the picker-approved root. Reuse the existing children-filter logic.
- **Structural guard:** Unit test with a synthetic drop manifest containing a `.photoslibrary` path; assert that enumeration emits zero files and a `DirectoryIssue` for the rejected entry.
- **Owner:** backend / safety.

---

### 10. "Accept all suggestions" and the commit footer leak weak-match preselections into the deletion plan ✅ FIXED

- **Category:** safety invariant / UX
- **Priority:** **P1**
- **Effort:** S
- **Confidence:** high
- **Problem:** Two related leaks:
  - `DeduplicateSessionStore.currentDeletionPlan()` plans against ALL clusters, including medium/low-confidence ones, with their suggested-delete decisions ([ui/Sources/ChronoframeAppCore/Stores/DeduplicateSessionStore.swift:82-92](ui/Sources/ChronoframeAppCore/Stores/DeduplicateSessionStore.swift:82) and the suggested-decisions seeding at lines 463-473). The commit footer overcounts.
  - `acceptAllSuggestions` approves every cluster regardless of confidence ([ui/Sources/ChronoframeAppCore/Stores/DeduplicateSessionStore.swift:359-366](ui/Sources/ChronoframeAppCore/Stores/DeduplicateSessionStore.swift:359)), so committing after that action trashes non-keepers in weak clusters too.
- **Why it matters:** AGENTS.md invariant: "Dedupe dHash-only similarity is never enough for automatic deletion; non-exact weak matches stay review-only with zero preselected deletions unless explicitly confirmed." The current code preselects via `suggestedDecisions` for every cluster on scan completion, and `acceptAllSuggestions` lets the user fast-path the entire scan including weak clusters in a single click.
- **Recommended change:** Initialize `decisions` at scan completion from `DeduplicationPlanner.automaticDecisions` (which already filters via `isAutomaticCommitEligible` → high confidence only). Have the footer call `reviewedDeletionPlan()` instead of `currentDeletionPlan()`. Make `acceptAllSuggestions` mirror `acceptAllHighConfidence` semantics, or relabel + reposition it in the UI so the user understands the scope.
- **Structural guard:** Test that builds a session with one high + one medium + one low cluster, simulates the scan-completion seeding, and asserts the medium and low clusters appear in neither `decisions.byPath` (as `.delete`) nor `currentDeletionPlan()`.
- **Owner:** backend / UX.

---

## Other notable findings (P1 / P2, not in Top 10)

Below the cut but still worth tracking — full evidence in the agent reports.

- ✅ **P1 FIXED** `TransferExecutor.safeCopyAtomicOnce` uses a non-unique deterministic `.tmp` filename. Fix: switched to the same `uniqueTemporaryCopyPath` scheme used by the parallel `prepareAtomicCopy` path.
- ✅ **P1 FIXED** No `F_FULLFSYNC` on the parent directory after `renamex_np` or after the final receipt rename. Fix: `renameFile` now opens the parent directory with `O_RDONLY|O_CLOEXEC` and `F_FULLFSYNC`'s it; the streaming audit-receipt finalize fsyncs the receipt's parent too.
- ✅ **P1 FIXED** `ReorganizeExecutor` rewrites the entire receipt JSON after every move (O(N²) bytes). Fix: receipt is now checkpointed every 25 successful moves and at the loop end. On crash, up to 24 completed moves may be missing from the on-disk receipt; revert correctly leaves those files at the destination (treats them as not-yet-completed → no-op).
- ✅ **P1 FIXED** `ReorganizeExecutor` doesn't re-hash sources at move time. Fix: re-hash the source inside the per-move loop before `moveItem` and write the live hash into the receipt.
- ✅ **P1 FIXED** `CodeQL` workflow skips PRs entirely. Fix: restored PR analysis with a paths filter so docs/CI-only PRs don't trigger the slow Swift CodeQL build, but any change to `ui/Sources/**`, `ui/Package.swift`, `ui/Chronoframe.xcodeproj/**`, or the workflow itself does.
- ✅ **P1 FIXED** `ui/archive.sh` passes notarization password as argv. Fix: `CHRONOFRAME_NOTARY_PROFILE` keychain profile is now required; the `--apple-id`/`--password`/`--team-id` fallback was removed.
- ✅ **P1 FIXED** `${TMPDIR:-/tmp}` resolved to empty when `TMPDIR=""`. Fix: explicit `[ -z "${TMPDIR:-}" ] && TMPDIR=/tmp` guard plus trailing-slash normalization in `archive.sh`, `archive-mas.sh`, and `build.sh`.
- ✅ **P1 FIXED** `RunSessionStore.cancelCurrentRun` did not clear `prompt`. Fix: clears `prompt` and resets `.preflighting` status to `.idle`.
- **P1** `RunSessionStore.consume(.complete)` calls `historyStore.refresh` synchronously on MainActor — blocks UI on destinations with many receipts. (Not yet addressed in this pass.)
- ✅ **P1 FIXED** `SwiftOrganizerEngine.cancelCurrentRun` did not flip `TaskCancellationCheck`. Fix: engine now holds the per-run cancellation ref alongside `activeTask` and flips it inside `cancelCurrentRun()`.
- ✅ **P1 FIXED** `DeduplicateSessionStore` surfaced `CancellationError` as `.failed`. Fix: new `applyStreamError` helper sets `.idle` for `CancellationError` / `Task.isCancelled` and only reports `.failed` for real errors.
- ✅ **P1 FIXED** `PreviewReviewStore.load` ignored `isStale`. Fix: the artifact-path short-circuit now also requires `!isStale`.
- ✅ **P1 FIXED** `PreferencesStore`, `SetupStore`, `RunLogStore`, `HistoryStore` are now `@MainActor`. Tests that construct them are tagged accordingly.
- ✅ **P1 FIXED via NEW20** `DroppedItemStager.stage` doc-comment updated to describe the manifest-based implementation (the doc was the bug, not the code).
- **P2** `ClusterConfidenceScorer` can flip to `.high` via a single tight Vision edge for a 3-member transitively-clustered group, auto-deleting members whose similarity wasn't measured.
- **P2** `isAutomaticCommitEligible` ignores `configuration.autoAcceptHighConfidence`. The toggle has no effect.
- **P2** `DedupeDecisions.init` accepts `hardDelete:` parameter and unconditionally writes `false`. Defense-in-depth, but misleading API.
- **P2** `MediaDateResolver.DateClassification.isUnknown` only checks `year < 1900` — accepts year 9999.
- **P2** `TransferExecutor.bytesCopied` uses post-copy source size for accounting; can drift if source changes mid-run.
- **P2** `consecutiveFailures` not reset by skip outcomes — pattern fail/skip/fail/skip/fail trips the threshold.
- **P2** `release-package.yml` trusts `inputs.tag` as checkout `ref` without validating tag-format. Workflow_dispatch can build from arbitrary commits and sign+notarize the artifact.
- **P2** No `Package.resolved` committed. Benign today (zero external deps) but becomes a risk the moment any dep is added.
- **P2** `RunHistoryIndexer.classifyArtifact` switch ordering is correct only because of substring-vs-prefix luck. Comment the dependency or sniff JSON content instead.
- **P2** Dedupe commit/revert tests use a `MockDeduplicateFileOperations` whose `trashItem` is `moveItem`. Real `FileManager.trashItem` semantics (cross-volume Trash, `.Trashes` ACLs) are not covered.

---

## Scoring Table

Scale 1–5 (higher = worse). Priority = SEV × LIK × BLAST × LEV. Tie-break columns shown.

| # | Finding | SEV | LIK | BLAST | LEV | Priority | EFF⁻¹ | REV | CONF |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Pair Keep-wins bypass | 5 | 4 | 3 | 4 | **240** | 5 | 5 | 5 |
| 2 | Coverage allowlist drift | 4 | 5 | 4 | 5 | **400** | 4 | 5 | 5 |
| 3 | Crashed-run no receipt | 5 | 2 | 5 | 4 | **200** | 3 | 4 | 5 |
| 4 | HistoryStore wipes root | 4 | 4 | 3 | 4 | **192** | 5 | 5 | 5 |
| 5 | Bookmark silent fallback | 4 | 3 | 4 | 4 | **192** | 4 | 5 | 5 |
| 6 | Revert schemaVersion gap | 4 | 2 | 5 | 5 | **200** | 4 | 5 | 5 |
| 7 | Dedupe post-trash receipt fail | 4 | 2 | 4 | 4 | **128** | 4 | 4 | 5 |
| 8 | Cross-folder revert blocked | 4 | 3 | 3 | 3 | **108** | 4 | 4 | 5 |
| 9 | Drop-manifest filter bypass | 3 | 3 | 3 | 4 | **108** | 4 | 4 | 5 |
| 10 | Weak-match preselect leakage | 3 | 4 | 3 | 4 | **144** | 4 | 4 | 5 |

Re-ranked by priority: 2, 1, 6, 3, 4/5 (tie), 10, 7, 8/9 (tie). The narrative ordering above front-loads #1 because the failure walkthrough is concrete and ships data loss in a single user action; #2 is the highest "system-of-system" finding (CI gate is fictional) and is one-PR cheap to land first.

---

## Recommended Execution Order

1. **Land #2 (coverage gate fix) first.** Cheap, makes everything else CI-detectable. Bonus: it will immediately surface which currently-allowlisted files do/don't exist.
2. **Land #4 (HistoryStore wipe) and #1 (pair Keep-wins) as small back-to-back PRs.** Each is XS-effort and ships safety.
3. **Land #6 (schemaVersion gate) before #3 (crashed-run receipt).** The PENDING-receipt rollout in #3 will write a new schema shape; the reader must already understand versioning.
4. **#3 (crashed-run receipt), #7 (dedupe receipt failure), #8 (cross-folder revert)** can ship in parallel as they touch disjoint executors.
5. **#5 (bookmark fallback)** can ship anytime — small, contained, and improves diagnostics independently.
6. **#9 (drop-manifest filter)** ships with the symlink/package containment helper extracted into a shared `MediaLibraryRules` predicate so both `walk` and `enumerateManifest` use it.
7. **#10 (weak-match leak)** should ship with a UI re-think — coordinate with the existing AGENTS-documented invariant.

## What Works — Do Not Change

1. **`FileIdentityHasher` + `BLAKE2bHasher`.** Hash chunk boundaries traced end-to-end with multiple input shapes; the `<` (not `<=`) at the streaming boundary correctly reserves the final block for `finalize()` with `f0` set. Don't touch.
2. **`RevertExecutor.safeRevert`'s `O_NOFOLLOW` + inode-pin + re-hash.** Right pattern; recent commits made it more robust against unreadable receipts.
3. **`renamex_np(RENAME_EXCL)` collision-resolved naming with EEXIST retry.** Correctly handles the TOCTOU between collision check and rename.
4. **SQLite single-connection FULLMUTEX + WAL + 30s busy timeout.** Right call for a desktop tool. No threading hazards observed.
5. **`DeduplicateExecutor` preflight before first trash.** The initial PENDING receipt write goes through preflight — the right safety gate. Per-item failure post-trash (finding #7) is a separate, narrower hole.
6. **Single-instance enforcement in `applicationWillFinishLaunching`.** Avoids cross-process destination races.
7. **AGENTS.md as project memory.** Concrete safety invariants enumerated in a way that made this sweep efficient. Keep it current.

## Changes to Avoid Right Now

- **Don't introduce a third hash algorithm** before #6 lands. Receipt portability matters more than algorithm flexibility right now.
- **Don't switch off the allowlist regex in favor of "100% coverage required"** as a knee-jerk to #2 — a denylist (UI bodies, app entry, OS wrappers) is the right shape.
- **Don't refactor `DeduplicationPlanner`** beyond the predicate fix in #1. The five-step pipeline is the right shape; widening the surface invites regressions in the pair-rescue logic.
- **Don't add new dependencies** before committing a `Package.resolved` and an audit gate. Even a single dep needs the lockfile shape established first.
