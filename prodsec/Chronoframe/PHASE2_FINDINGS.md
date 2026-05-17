# Chronoframe — Phase 2 Findings

Findings surfaced by the second pass: property tests (`DeduplicationPlanner`), fault injection (`DeduplicateExecutor`), real-FileManager integration (`DeduplicateFileOperations.live`), receipt golden-file tests, and targeted probes of three previously-skimmed surfaces (CLI, drag-drop / FileSystemMonitor, SwiftUI views).

The Phase 1 review at [TOP_IMPROVEMENTS.md](TOP_IMPROVEMENTS.md) raised 10 findings + 25 lower-priority notes. This pass adds the following **new** items (a few extend or confirm prior items).

---

## P0 — Ship within one PR cycle

### NEW1 — Cluster fully-emptied by pair fan-out (Phase 1 Finding #1 has a second consequence) ✅ FIXED

- **Surface:** `DeduplicationPlanner.swift:84-95` (step 2 — pair rescue) + `:107-120` (step 4 — direct deletes) + `:122-153` (step 5 — pair expansion)
- **Confirmed by:** `testPropertyNoClusterIsCompletelyEmptiedByThePlan` in `DeduplicationPlannerPropertyTests.swift` (currently skipped pending Finding #1 fix)
- **Failure scenario:** A low/medium-confidence cluster has two members, both paired with each other (RAW+JPEG or Live Photo HEIC+MOV). User marks one half Delete. Step 2's pair rescue does not fire (defaultKeep partner). Step 3's "Per-cluster safety rail: skip any cluster whose effective decisions are all Delete" does NOT trip because only one is Delete. Step 4 plans the explicit Delete. **Step 5 then fans out the partner**, leaving the cluster fully emptied — violating step 3's documented invariant after step 3 ran.
- **Why this is a separate finding:** Phase 1 Finding #1 noted "both files go to Trash" but did not flag that this is also a violation of the cluster-non-empty invariant. The two failures share a root cause (`DecisionSource.defaultKeep.blocksPairDeletion == false`), but the fix must address both invariants explicitly. The order-of-operations bug — step 3's safety rail runs BEFORE step 5's pair expansion — should be considered when writing the fix.
- **Suggested fix:** Re-run the "skip cluster if every member ends up in plan" check AFTER step 5 (or rebuild the safety rail to consider pair-induced deletes), and treat `defaultKeep` as blocking pair deletion per Phase 1 Finding #1.
- **Status:** Fixed in the same commit as Finding #1. `DecisionSource.blocksPairDeletion` removed; step 2's pair-rescue now flips any Keep↔Delete pair regardless of source; step 5's pair-expansion now short-circuits whenever the partner's effective decision is `.keep`. Both `testPropertyPairKeepWinsAcrossAllDecisionSources` and `testPropertyNoClusterIsCompletelyEmptiedByThePlan` are unskipped and passing. AGENTS.md's Keep-wins invariant clarified to make the broader interpretation explicit.

### NEW2 — `--json` mode interleaves human-language prompts on stdout ✅ FIXED

- **Surface:** `ChronoframeCLIKit/CLI.swift:284, 297`; `main.swift:4` (default `output: { print($0) }`)
- **Failure scenario:** `chronoframe --json --source /A --dest /B` (no `--yes`) emits structured JSON events to stdout AND writes prompts like `"Found N pending copy jobs. Resume them? [Y/n/fresh]"` to the same stdout. A piping consumer (`jq -c .` / Codex / a downstream automation) gets a non-JSON line injected mid-stream and aborts on the parse error. The CLI then blocks on `readLine()` from stdin, hanging the pipeline.
- **Severity:** P0 because JSON consumers are explicitly supported (per `JSONLineEmitter.eventVersion=1` introduced in commit `7dca67d`), and Codex's environment relies on this surface.
- **Suggested fix:** When `--json` is set, treat the absence of `--yes` as a usage error (exit 2 with a JSON error event), or emit prompts as `{"type":"prompt", ...}` on stdout and the human-readable variant on stderr.
- **Status:** Fixed. `transferDecision` now throws `CLIError.usage` immediately when `options.jsonOutput && !options.assumeYes`, before any prompt is written. The error path returns exit code 2 without writing the prompt or blocking on `readLine`. Regression test `testJSONWithoutAssumeYesFailsFastInsteadOfHangingOnAPrompt` asserts the CLI never reads stdin and never emits the "Resume them?" / "Continue?" prompt strings in this mode. Pipeline consumers get a clean diagnosis instead of a corrupted stream + hang. Emitting the error as a JSON event (rather than plain text) is left as NEW12 follow-up.

---

## P1 — Reliability / correctness

### NEW3 — `FileSystemMonitor` polling fallback runs simultaneously with FSEvents → every event yielded twice ✅ FIXED

- **Surface:** `FileSystemMonitor.swift:23-86` — `start()` calls `startPollingFallback()` unconditionally then sets up FSEvents; both stream into the same `AsyncStream.Continuation`. Failure-only fallback was the intent (lines 66-77 `continuation.finish()` on FSEvents failure), but the polling loop was wired before the FSEvents create call regardless of outcome.
- **Failure scenario:** Any new file in the watched root produces TWO yielded events — one from the FSEvents callback, one from the next poll tick. Consumers that count events (e.g. duplicate-detection feature 10 in AGENTS.md) over-count.
- **Suggested fix:** Move `startPollingFallback()` into the FSEvents-failure branch only.
- **Status:** Fixed. `start()` now extracts FSEvents setup into `setupFSEvents()` returning a Bool; the polling fallback only runs when that returns false (or when the new internal `forcePollingOnly` test seam is set). Regression test `testFileSystemMonitorDoesNotDoubleYieldEventsWhenFSEventsIsActive` writes three files and asserts each path emits at most one `isCreated` event.

### NEW4 — `FileSystemMonitor.continuation` mutation is unsynchronized between FSEvents callback thread, `stop()` caller, and polling task ✅ FIXED

- **Surface:** `FileSystemMonitor.swift:30-54` (callback), `:100` (`stop()` sets `continuation = nil`), `:107-119` (polling task reads `self.continuation`)
- **Failure scenario:** `@unchecked Sendable` (line 6) bypasses the compile-time check. `stop()` called from a UI cancel handler racing the FSEvents `dispatch_async` callback can produce torn pointer reads / use-after-free on the `AsyncStream.Continuation?`.
- **Suggested fix:** Serialize all `continuation` / `streamRef` / `pollingTask` access on `self.queue` (e.g. `queue.sync { … }` in `stop()`), or convert the type into an actor.
- **Status:** Fixed. State is now guarded by a dedicated `stateLock: NSLock` via the `withState { … }` helper. The original `queue.sync` approach actually crashed with `__DISPATCH_WAIT_FOR_QUEUE__` SIGTRAP because `onTermination` can fire on the FSEvents dispatch queue itself, and `stop()` calling `queue.sync` from that callback context produced a same-queue deadlock. NSLock side-steps that. Regression test `testFileSystemMonitorSurvivesRepeatedStartStopCycles` runs 5 start/stop cycles to exercise the path.

### NEW5 — `FileSystemMonitor` callback uses `Unmanaged.takeUnretainedValue` — callback can outlive the monitor ✅ FIXED

- **Surface:** `FileSystemMonitor.swift:32, 58`
- **Failure scenario:** `deinit` → `stop()` → `FSEventStreamStop`/`Invalidate`/`Release`. The dispatch queue may still have an enqueued callback work item already dispatched (FSEventStream does not synchronously drain). When that callback fires after `deinit` returns, the unretained `self` pointer is dangling.
- **Suggested fix:** Use `passRetained`/`takeRetainedValue` paired with a `context.release` callback that releases the unmanaged reference, or `dispatch_sync(self.queue) {}` after `Invalidate` to flush.
- **Status:** Fixed. `FSEventStreamContext` now installs top-level `fileSystemMonitorRetainCallback` / `fileSystemMonitorReleaseCallback` so the stream holds a +1 retain on `self` for its lifetime. The `takeUnretainedValue` in the FSEvents callback is now safe — the retained reference holds the floor until `FSEventStreamRelease` runs the release callback at `stop()` time. Regression test `testFileSystemMonitorReleasesItselfCleanlyWhenDroppedMidStream` holds a `weak var` and asserts the monitor is deallocated after the stream consumer drops.

### NEW6 — `RunHistoryView.HistorySection.id = UUID()` regenerates on every render → animation/scroll state resets

- **Surface:** `RunHistoryView.swift:65-69, 573-587, 446`
- **Failure scenario:** Each call to the computed `groupedEntries` builds new `HistorySection` structs with fresh `UUID()` identities. `ForEach(id: \.element.id)` rebuilds every section subtree. Hover/animation state resets, scroll position can jump on filter or search changes.
- **Suggested fix:** Use the section date as the identity: `let id: Date` set in the initializer.

### NEW7 — `PreviewReviewPanel` row `@State` never refreshes after Save → UI displays stale event name and date

- **Surface:** `Views/Run/PreviewReviewPanel.swift:108-120`
- **Failure scenario:** User edits event name → clicks Save → store rebuilds the item with `acceptedEventName` set. Row identity (`item.id`) does not change, so SwiftUI does NOT re-init `@State`. DatePicker/TextField still bind to the old `_selectedDate` / `_eventName`. The visible state diverges from the persisted state until that row scrolls off-screen or the filter clears identities.
- **Suggested fix:** Either move date/eventName into the store keyed by `item.id`, or add `.onChange(of: item) { selectedDate = ...; eventName = ... }` to resync.

### NEW8 — `ClusterDetailPane` `NSEvent.addLocalMonitorForEvents` swallows arrow keys app-wide

- **Surface:** `ClusterDetailPane.swift:555-628` (esp. `:595-625`)
- **Failure scenario:** When the Deduplicate detail pane is on screen, ANY left/right arrow press in the window (text fields, scrollers, cluster list table) hits the monitor and is consumed via `return nil`. SwiftUI first-responder never sees the event. Users can't arrow-navigate in input fields while the pane is visible.
- **Suggested fix:** Gate on `NSApp.keyWindow?.firstResponder` being the host or its descendant, or switch to `.onKeyPress(.leftArrow)` / `.onKeyPress(.rightArrow)` in SwiftUI 14+.

### NEW9 — `SliderComparisonView` / `FlickerComparisonView` synchronously load multi-MB NSImage on the main actor

- **Surface:** `ComparisonOverlayView.swift:171-180, 286-295` — `loadImage(at:)` is synchronous; called inside a MainActor-isolated `.task`.
- **Failure scenario:** Comparing two ~60MB RAW/HEIC files blocks the UI thread for hundreds of ms to seconds. The loading spinner is never visible.
- **Suggested fix:** `let image = await Task.detached { NSImage(contentsOfFile: path) }.value`, or route through the existing `ThumbnailRenderer.cgImage` helper (already used by `LargePreviewImage`).

### NEW10 — `DifferenceImageGenerator.generate` runs Core Image pipeline on the main actor

- **Surface:** `Views/Deduplicate/DifferenceImageGenerator.swift:6-7` and call site `ComparisonOverlayView.swift:233-239`
- **Failure scenario:** `@MainActor static func generate(...)` calls `CIImage` decode + `CIDifferenceBlendMode` + `CIExposureAdjust` + `CIContext.createCGImage` synchronously on the main thread. For multi-megapixel inputs this blocks scrolling and animations for seconds.
- **Suggested fix:** Drop `@MainActor`; run on a background queue; hop back to the main actor only to assign `differenceImage`.

### NEW11 — CLI `requireValue` rejects any value starting with `-`

- **Surface:** `ChronoframeCLIKit/CLI.swift:111-118`
- **Failure scenario:** `chronoframe --source "-my-photos"`, `--dest "/Volumes/-Backup"`, or `--workers -4` is misreported as `"Missing value for --source."` There is no `--` end-of-options sentinel and no `--flag=value` form, so a user with a destination path that legitimately starts with `-` cannot run Chronoframe at all.
- **Suggested fix:** Drop the `hasPrefix("-")` check, accept the next argument as a value verbatim. Add `--flag=value` form and `--` terminator.

### NEW12 — CLI `--json` mode prints CLI errors as plain text

- **Surface:** `ChronoframeCLIKit/CLI.swift:209-222`
- **Failure scenario:** With `--json`, errors come out as free-form English (e.g. `"Unknown option: --workrs."`) on stdout. JSON line consumers hit `JSONDecodeError`. `event_version` is also absent on every error path — explicitly contradicting `EventEmitterTests.swift:30-34` which asserts the field is always present.
- **Suggested fix:** Once `--json` is parsed early from argv, emit failures as `{"type":"error","event_version":1,"kind":"usage|operational","message":"…"}` to stderr.

### NEW13 — CLI `--revert` silently accepts and ignores `--skip-verify` / `--folder-structure`

- **Surface:** `ChronoframeCLIKit/CLI.swift:175-180`
- **Failure scenario:** The error message advertises only `--dest`, `--json`, `--workers`, `--yes` as combinable with `--revert`, but the guard only rejects six specific other flags. `chronoframe --revert R --skip-verify` and `--folder-structure YYYY` pass validation and are silently ignored. The user believes they configured the revert; nothing changes.
- **Suggested fix:** Replace the explicit-deny list with a positive whitelist: reject any field outside `{destinationPath, jsonOutput, workerCount, assumeYes}`.

### NEW14 — CLI lacks path normalization (no `~` expansion, no NFC/NFD handling)

- **Surface:** `ChronoframeCLIKit/CLI.swift:127-129, 155, 308`
- **Failure scenario:** Scripts that pass `~/Photos` via `execve` (no shell expansion) — including launchd jobs and Codex's environment — store a literal `~` directory. Equally, `readdir` returns NFD-decomposed filenames on APFS while CLI consumers often pass NFC paths; the CLI doesn't normalize, so path comparisons can disagree across runs.
- **Suggested fix:** After parsing, apply `(path as NSString).expandingTildeInPath` and `precomposedStringWithCanonicalMapping` to source/dest/revert paths.

### NEW15 — CLI integration tests bypass the actual process boundary

- **Surface:** `ChronoframeCLIKitTests/CLIIntegrationTests.swift:39-48` (and every other in-process test)
- **Failure scenario:** Every test invokes `ChronoframeCLI.run(arguments:output:)` in-process. The real `main.swift`, `CommandLine.arguments` parser, `Foundation.exit`, stdout/stderr separation, signal handling, and `print` buffering semantics are never exercised. The `requireValue` bug (NEW11) and the JSON/prompt mixing (NEW2) are invisible to the test suite.
- **Suggested fix:** Add at least one `Process()`-based test against the SwiftPM build product covering `--help`, an unknown flag, and a `--json` happy path.

---

## P2 — Quality

### NEW16 — `ContactSheetLoader.load` races stale results across source-folder changes
`ContactSheetView.swift:253-283` — no `Task.isCancelled` checks between awaits. The slower task wins when the user picks a new source quickly.

### NEW17 — `RapidTriageView` stacks two `.keyboardShortcut` modifiers; only one survives
`RapidTriageView.swift:184-186` — `.keyboardShortcut(.rightArrow)` is silently dropped because `.keyboardShortcut(.return)` is applied after. Right-arrow does nothing despite the affordance text saying "→ Accept".

### NEW18 — `FlickerComparisonView` leaks toggle Tasks on mode switch
`ComparisonOverlayView.swift:296-312` — `startFlicker()` reassigns `flickerTask` without cancelling the previous one; orphaned tasks continue toggling.

### NEW19 — `MediaDiscovery.dropManifest` silently swallows malformed JSON
`MediaDiscovery.swift:201-205` — if the manifest file exists but decode fails, the function returns nil and discovery falls through to a `walk()` that finds zero media in the staging dir. User sees "0 files to organize" with no explanation.

### NEW20 — `DroppedItemStager.stage` doc-comment is stale ("symlink directory")
`DroppedItemStager.swift:90-92, 141-142` — implementation is manifest-based and works correctly. Phase 1 open question resolved as a doc bug, not a data bug.

### NEW21 — Dedupe footer count uses `currentDeletionPlan()` (includes weak-match preselects)
**Phase 1 open question resolved**: `DeduplicateView.swift:272, 299` and `RapidTriageView.swift:27` call `currentDeletionPlan()`, not `reviewedDeletionPlan()`. Only the reviewed-only confirmation dialog title (`DeduplicateView.swift:341`) uses the filtered plan. This makes Phase 1 Finding #10 a real user-visible overcount, not just an internal artifact.

### NEW22 — CLI has no signal handling
SIGINT mid-run aborts without notifying the engine. Exit code is 130 (runtime default) — distinct from the documented "user cancelled" semantics. No SIGTERM handler either.

### NEW23 — `FileSystemMonitor` does not surface watched-directory unmount
`FileSystemMonitor.swift:103-119` — when the watched volume is unmounted, polling continues emitting "removed" events for every previously-seen path (a flood) and never reports the root-disappearance.

### NEW24 — `ClusterListPane.recoverableBytes(for:)` is O(plan.items) per visible row per render
`ClusterListPane.swift:107-111` — for large dedupe sessions, tens of thousands of comparisons per body. Pre-bucket once in the parent.

### NEW25 — `HealthDashboardView` retry-loops on a previously-failed refresh
`HealthDashboardView.swift:71-75` — `.task` re-fires `refreshLibraryHealth()` every time the user navigates to Health if `summary == nil`, regardless of error state.

---

## Closed / answered open questions from Phase 1

| Phase 1 question | Answer |
|---|---|
| Does the dedupe footer call `currentDeletionPlan()` or `reviewedDeletionPlan()`? | **`currentDeletionPlan()`** — confirms Finding #10 is a real user-visible overcount (see NEW21). |
| Is `DroppedItemStager.stage` missing the symlink creation, or is the doc-comment stale? | **Stale doc-comment** — implementation is manifest-based and works end-to-end (see NEW20). |
| Are the failure thresholds for skipped jobs intentional? | Not re-investigated this pass. Still open. |

---

## What the property tests proved

Six property tests against `DeduplicationPlanner`, each with 250 random scenarios per seed (1500 total invocations per test run):

| Property | Status |
|---|---|
| `testPropertyEveryPlanItemPointsToInputCluster` | ✓ passes |
| `testPropertyNonHighConfidenceClustersHaveZeroAutomaticDeletes` | ✓ passes |
| `testPropertyPairKindTogglesActIndependently` | ✓ passes |
| `testPropertyPlanItemsAreUniqueByPath` | ✓ passes |
| `testPropertyPairKeepWinsAcrossAllDecisionSources` | ✗ skipped (Finding #1) |
| `testPropertyNoClusterIsCompletelyEmptiedByThePlan` | ✗ skipped (NEW1, same root cause) |

The four passing properties now lock in their respective invariants against random adversarial inputs — these are the regression guards that Phase 1 recommended.

## What the AGENTS.md → test linter enforces

`script/check_agents_invariants_have_tests.sh` reads the 16 bullets under "## Safety Invariants" in AGENTS.md and fails CI if any bullet has no test method tagged `// AGENTS-INVARIANT: <N>`. All 16 invariants currently have at least one tagged anchor test. Adding a new invariant to AGENTS.md without an associated test now fails the build.

## What still needs deeper testing

- **Cross-process / multi-instance** behavior. Two Chronoframe CLIs against one destination is currently uncovered.
- **Sandboxed-CI run of `FileManager.trashItem`**. The new `testRealTrashAdapterMovesFileToMacOSTrashAndWritesReceipt` test runs locally but may XCTSkip in CI without entitlements — verify the skip path doesn't silently disable coverage.
- **Mutation testing**. Not run this pass; `muter` requires external install. Recommended as a follow-up to surface "covered but not asserted" lines in the planner and executors.
- **CLI subprocess tests**. NEW15 specifically — every "integration" test currently bypasses the binary surface.
