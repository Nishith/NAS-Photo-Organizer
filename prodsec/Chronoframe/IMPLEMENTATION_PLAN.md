# Chronoframe — Implementation Plans for Top 3

Execution-grade plans for the three highest-leverage findings. Each plans the structural guard FIRST so the regression surface is locked before the fix lands.

---

## Plan 1 — Fix Pair-as-Unit "Keep wins" bypass (Finding #1)

### Objective

Restore the documented Keep-wins invariant: if either half of a `treatRawJpegPairsAsUnit` / `treatLivePhotoPairsAsUnit` pair has an effective Keep, neither half goes to Trash, regardless of whether that Keep is explicit, automatic, or default. Success: a parameterized test matrix covering `(low|medium|high confidence) × (RAW+JPEG | Live Photo HEIC+MOV) × (user marks half Delete | user marks half Keep | user marks neither)` finds zero unmarked-partner deletions.

### Current State

- `DeduplicationPlanner.swift:42-49` defines `DecisionSource.blocksPairDeletion`. `.explicit` and `.automatic` return `true`; `.defaultKeep` returns `false`.
- Step 2 (lines 84-95) only flips a `Delete` back to `Keep` if `partnerInfo.source.blocksPairDeletion`.
- Step 5 (lines 131-135) only short-circuits pair-fanout if `partnerEffective.source.blocksPairDeletion`.
- In low-confidence clusters, `canAutoSelectDeletes == false` → both members get `(decision=.keep, source=.defaultKeep)`. User marks one Delete → other stays `.defaultKeep` → both steps fail to rescue → both trashed.

### Target State

- Pair rescue triggers whenever the partner's effective decision is `.keep`, irrespective of source.
- `DecisionSource` retains semantic meaning for other purposes (UI badges, telemetry) but no longer gates safety decisions.

### Detailed Design

Choice A (minimal): change `.defaultKeep.blocksPairDeletion` to return `true`.

Choice B (clearer): remove `blocksPairDeletion` entirely; pair rescue keys directly on `effective[partner].decision == .keep`.

Recommend **Choice B** — `blocksPairDeletion` was added to distinguish "explicit Keep" from "default Keep" for a UX reason that has since been dropped. The current code shape is a footgun. Removing the indirection makes the invariant obvious to readers.

Code shape after fix in `DeduplicationPlanner.swift`:

```swift
// Step 2
switch (info.decision, partnerInfo.decision) {
case (.keep, .delete):
    effective[partner]?.decision = .keep
case (.delete, .keep):
    effective[path]?.decision = .keep
default:
    break
}

// Step 5
if let partnerEffective = effective[partner], partnerEffective.decision == .keep {
    continue
}
```

Keep `DecisionSource` enum (it's used in tests and may be useful for diagnostics).

### Execution Plan

**Phase 0 — Land structural guard (failing test).**

- File: `ui/Tests/ChronoframeCoreTests/DeduplicationPlannerTests.swift` (or wherever planner tests live; check `DeduplicateTests`).
- Add `func testPairKeepWinsAcrossDecisionSources()` that builds three clusters (high/medium/low confidence), populates `pairedPath` mutually for each member, applies `decisions = [oneHalf: .delete]`, and asserts `DeduplicationPlanner.plan(...).items` contains zero entries for the partner across all configurations.
- Land as `xfail`-equivalent (test is `@MainActor func`; XCTest doesn't have xfail — use `XCTExpectFailure(...) { ... }` and remove the expectation when fix lands, OR land the test in the same PR as the fix).
- Recommended: land in a single PR. The test failing without the fix proves the bug; the test passing with the fix proves the fix.

**Phase 1 — Apply fix.**

- Edit `DeduplicationPlanner.swift:84-95` and `DeduplicationPlanner.swift:131-135` per shape above.
- Run the existing dedupe test suite: `swift test --package-path ui --filter DeduplicateTests`.
- Confirm no other tests regress.

**Phase 2 — Update AGENTS.md** if the wording "explicit Keep" was the source of confusion — restate as "effective Keep".

### Testing Strategy

- Unit: the new `testPairKeepWinsAcrossDecisionSources` matrix.
- Regression: full `DeduplicateTests` suite; confirm executor commit/revert tests still pass.
- Property: optional — generate random cluster shapes with `Fuzz`-style helper and assert "no partner of a Keep is ever in the plan".

### Operational Plan

- No metrics/observability change. This is a pure planner bug.
- Release: ships in the next normal release. No migration. Receipts written before the fix remain decodable.

### Risks and Mitigations

- Risk: removing `blocksPairDeletion` might unbreak existing tests that asserted the bug as feature.
  - Mitigation: read the existing tests first — if any expect the partner to be deleted, the test was codifying the bug; update it.
- Risk: Choice B is slightly larger surface. Mitigation: it's still <20 LOC.

### Resourcing and Sequencing

- One engineer, half a day including test review.
- No cross-team dependencies.

### Definition of Done

- New parameterized test passes.
- Existing `DeduplicateTests` suite passes.
- `script/swift_meaningful_coverage.sh` still ≥95% (DeduplicationPlanner is on the allowlist).
- PR description references AGENTS.md "Pair-as-unit conflict resolution is Keep-wins" invariant.

---

## Plan 2 — Fix `swift_meaningful_coverage.sh` allowlist drift (Finding #2)

### Objective

Make the meaningful coverage gate verifiable: no phantom allowlist entries, no critical safety files outside the gate. Success: the script preflight-fails when any allowlisted basename has zero matches in `ui/Sources`, and the next CI run after the fix exercises `OrganizerDatabase`, `FileIdentityHasher`, `DeduplicateScanner`, `DeduplicatePairDetector`, `MediaDateResolver`, `FileSystemMonitor`, `BookmarkPathResolver`, `BundleValidator`, `EngineDomainModels`.

### Current State

- `script/swift_meaningful_coverage.sh:31` is an allowlist regex.
- It references `BackgroundDedupeMonitor`, `EditVariantDetector`, `ImportDuplicateChecker` — files that don't exist.
- It omits the files listed above. The 95% threshold is computed only over what matched, so it stays green while critical code is untested.

### Target State

Choice A: keep the allowlist, add a preflight that fails on phantom entries, and add the missing critical files.

Choice B: invert to a denylist (UI bodies, app entry, OS wrapper) and require the denied set to be enumerated explicitly.

Recommend **Choice A** as a one-PR fix; track Choice B as a follow-up if denylist coverage proves easier to maintain.

### Detailed Design

Add to `swift_meaningful_coverage.sh` before line 31:

```bash
MEANINGFUL_BASENAMES=(
  BLAKE2bHasher CopyPlanBuilder DryRunPlanner MediaDiscovery PlanningPathBuilder
  DeduplicationPlanner PerceptualHash UserFacingErrorMessage RunHistoryIndexer
  TransferExecutor RevertExecutor DeduplicateExecutor ReorganizeExecutor
  DedupeFeatureCache PreviewReviewModels LibraryHealthScanner ClusterAnnotator
  ClusterConfidenceScorer DuplicateClusterer FingerprintIndex PhotoQualityScorer
  SafetyWarningDetector FaceExpressionAnalyzer
  # Newly added, previously outside the gate:
  OrganizerDatabase FileIdentityHasher DeduplicateScanner DeduplicatePairDetector
  MediaDateResolver FileSystemMonitor BookmarkPathResolver BundleValidator
  EngineDomainModels
)
for f in "${MEANINGFUL_BASENAMES[@]}"; do
  if ! find ui/Sources -name "${f}.swift" -print -quit | grep -q .; then
    echo "Phantom allowlist entry: ${f}" >&2
    exit 2
  fi
done
MEANINGFUL_REGEX="/($(IFS='|'; echo "${MEANINGFUL_BASENAMES[*]}"))\\.swift\$"
```

Replace the literal `MEANINGFUL_REGEX` assignment with this generated one.

`RunConfiguration+Profiles.swift` contains a `+` which the basename loop needs to handle — special-case it or keep it out of the array and grep separately. Simpler: drop `RunConfiguration\+Profiles` from the array and add it to a `MEANINGFUL_EXTRA_REGEX` string concatenated at the end.

### Execution Plan

**Phase 0 — Land the preflight only (no new basenames).** This PR purely surfaces the phantom entries currently in the regex. CI will fail on `BackgroundDedupeMonitor` etc. Fix by removing those three entries from the array. Land. Now the script is honest about what's covered.

**Phase 1 — Add the missing safety-critical files to the allowlist, one PR at a time.** Each addition will surface uncovered lines in the corresponding file; add targeted tests as needed to clear the 95% bar. Recommended order: `OrganizerDatabase` (highest leverage), `FileIdentityHasher`, `MediaDateResolver`, `DeduplicateScanner`, `DeduplicatePairDetector`, `FileSystemMonitor`, `BookmarkPathResolver`, `BundleValidator`, `EngineDomainModels`. Each PR may need to land tests first before the coverage line can pass.

### Testing Strategy

- The script's own preflight is the test for phantom entries.
- For each newly-allowlisted file, add unit tests that bring it ≥95% before flipping the gate on (or use the script's per-file output to identify uncovered ranges).

### Operational Plan

- Run `script/swift_meaningful_coverage.sh` locally before each PR; confirm threshold met.
- CI workflow `.github/workflows/ci.yml` already invokes the script — no workflow change needed.

### Risks and Mitigations

- Risk: adding files to the gate causes CI red. Mitigation: per-PR rollout; each PR includes tests.
- Risk: maintainers may revert the preflight if it blocks a hot fix. Mitigation: add a comment explaining the cost of regressing it; reference this plan in the script.

### Resourcing and Sequencing

- Phase 0: 1 hour.
- Phase 1: per file, 0.5-2 days for test writing. Roughly 1.5-2 engineer-weeks total over multiple PRs.

### Definition of Done

- Phase 0 PR: preflight gates phantom entries; the three phantom basenames are removed.
- Phase 1 PRs: all 9 newly-listed files appear in the script's "Meaningful files" output with ≥95% individually contributing to a ≥95% aggregate.

---

## Plan 3 — Persist PENDING organize receipt for crash recovery (Finding #3)

### Objective

A power-loss or SIGKILL during organize leaves a recoverable PENDING receipt on disk that lists every transfer completed before the crash, so the user can revert from Run History after restart. Success: a fault-injection test that aborts the executor mid-run produces a `audit_receipt_*.json` with `status: "PENDING"` containing all completed-and-verified transfers, and Run History → Revert restores them all.

### Current State

- `TransferExecutor.executeQueuedJobs` instantiates `StreamingAuditReceiptWriter`, which appends transfers to a `<receipt>.transfers.tmp` spool.
- The actual JSON receipt is written only in `finish()` (`TransferExecutor.swift:959-984`), at end-of-run.
- `deinit` calls `discardUnfinishedFiles()` which removes the spool.
- On SIGKILL/power loss, deinit doesn't run; the spool stays orphaned with no metadata, and there's no `audit_receipt_*.json` for the run.
- `chronoframeTmpPattern` cleanup at startup doesn't sweep `.transfers.tmp`.
- `ReorganizeExecutor` and `DeduplicateExecutor` already follow the correct PENDING pattern — use them as templates.

### Target State

- At run start, write `audit_receipt_<ts>_<uuid>.json` with `status: "PENDING"`, empty `transfers: []`, and a `schemaVersion: 2`.
- After every successful transfer, append to the receipt's `transfers` array via an atomic rewrite (or sidecar that the JSON points to — see design choice below) and fsync.
- On clean finish, mutate status to `COMPLETED` and write final tally.
- On abort/failure, mutate status to `ABORTED` / `FAILED`.
- At app startup, scan for `audit_receipt_*.json` with `status: "PENDING"` AND no in-flight Chronoframe process owning them; treat them as "recoverable run" entries in Run History.

### Detailed Design

**Decision: rewrite-receipt-on-every-transfer vs. append-only sidecar.**

`ReorganizeExecutor` rewrites the whole receipt on every move — clean shape but O(N²) bytes. For organize, N can be 50k+. Recommend a hybrid:

- Keep the `<receipt>.transfers.tmp` spool as the durable append-only record (fsync after each append).
- Maintain a small `audit_receipt_<ts>_<uuid>.json` with `status` + run metadata + a `transfersSpoolPath` reference.
- At `finish()`, consolidate the spool into the JSON's `transfers` array and unlink the spool.
- Crash recovery: if a PENDING receipt exists referencing a still-present spool, treat as recoverable; the recovery routine consolidates the spool at startup.

Schema changes (this is why Plan 6 / Finding #6 must land first — the reader must understand `schemaVersion` before any new format ships):

```json
{
  "schemaVersion": 3,
  "status": "PENDING",  // PENDING | COMPLETED | ABORTED | FAILED
  "runId": "...",
  "startedAt": "...",
  "destinationRoot": "...",
  "identityScheme": "blake2b-v1",
  "transfersSpoolPath": ".organize_logs/audit_receipt_<ts>_<uuid>.transfers.tmp",
  "transfers": []  // populated on finalize; reader falls back to spool if empty + status==PENDING
}
```

### Execution Plan

**Phase 0 — Land structural guard (failing test) FIRST.**

- Test: `func testCrashedRunLeavesPendingReceiptWithCompletedTransfers()`.
- Strategy: instantiate `TransferExecutor` with a fault-injected `prepareAtomicCopy` that throws after N transfers (or wire a `Task.cancel()` after N progress events).
- Assert: a single `audit_receipt_*.json` exists in `.organize_logs/`, `status` is `"PENDING"` or `"ABORTED"`, and its consolidated `transfers` list contains exactly N entries with valid hashes pointing at the on-disk destination files.

**Phase 1 — Schema versioning (depends on Plan for Finding #6).** Ship `schemaVersion` decoding first so the new shape doesn't break old binaries in-flight.

**Phase 2 — Implement PENDING writer.**

- Add `StreamingAuditReceiptWriter.writeInitialPendingReceipt()` called from the executor before the first transfer.
- Add `StreamingAuditReceiptWriter.updateStatus(to:)` for COMPLETED/ABORTED/FAILED transitions.
- Replace the existing end-of-run-only JSON write with a consolidation step that reads the spool and writes final JSON.

**Phase 3 — Crash recovery on startup.**

- Add to `RunHistoryIndexer` a step that loads receipts with `status: "PENDING"` and surfaces them in Run History tagged as "Recovered run — completed N of M before interruption".
- Revert path consumes the same receipt format.

**Phase 4 — Sweep orphaned `.transfers.tmp` files** whose parent JSON is `COMPLETED` or missing. Add to engine startup.

### Testing Strategy

- Unit: `testCrashedRunLeavesPendingReceiptWithCompletedTransfers` (Phase 0).
- Unit: receipt status state machine (PENDING → COMPLETED, PENDING → ABORTED, PENDING → FAILED).
- Integration: full organize run with `Task.cancel()` injected at 30%; assert revert restores the 30%.
- Migration: read a v2 receipt (current shape) and confirm it decodes; write a v3 receipt and confirm a v2 reader produces a clear `unsupportedSchema` error (depends on Plan 6 landing first).

### Operational Plan

- New log line at run start: "Wrote PENDING receipt at …". Helps support diagnose crash recovery.
- Run History UI: tag recovered runs visibly so the user knows the run didn't complete normally.
- Rollback: if the new receipt format ships and is wrong, the v3 schema sentinel will at least cause clean refusal rather than silent corruption — combined with Plan 6's `unsupportedSchema`.

### Risks and Mitigations

- Risk: per-transfer fsync of the spool degrades throughput on slow devices. Mitigation: batched fsync (every K transfers + on finish). Measure on representative workloads first.
- Risk: a v3 reader fails to decode a partially-written v3 receipt from an in-flight crash. Mitigation: the JSON header is small + written atomically before any transfers; only the spool grows.
- Risk: orphan-spool cleanup deletes a spool from a still-running process. Mitigation: include the owning process's UUID in the receipt; only sweep spools whose parent JSON is COMPLETED or whose UUID is not present in any other extant PENDING receipt.

### Resourcing and Sequencing

- Phase 0: 1 day (test scaffolding for fault injection).
- Phase 1: blocked on Plan 6, 1-2 days.
- Phase 2: 3-4 days.
- Phase 3: 2 days.
- Phase 4: 1 day.
- Total: ~2 engineer-weeks with sequencing on Plan 6.

### Definition of Done

- Fault-injected test passes; revert restores all completed transfers from a PENDING receipt.
- v2 receipts still decode and revert correctly.
- Orphan sweep runs at startup and doesn't touch live PENDING receipts.
- AGENTS.md updated to document the PENDING-receipt invariant on the organize path.
- Run History UI shows recovered runs with a distinguishable tag.
