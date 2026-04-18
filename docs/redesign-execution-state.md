# Chronoframe Redesign — Execution State

**Linked plan:** [`~/.claude/plans/vivid-crafting-firefly.md`](../../../../.claude/plans/vivid-crafting-firefly.md)
**Branch:** `claude/stoic-swirles-4e4c34` (worktree `stoic-swirles-4e4c34`)

This document tracks the state of the award-caliber redesign across sessions so work can resume with minimum rework. Update after each phase.

## Status Snapshot

| Phase | Status | Commit/Notes |
|---|---|---|
| 0 · State doc + planning | 🟢 Complete | this file created |
| 1 · Foundation: tokens, typography, dark mode | 🟢 Complete | tokens + Motion.swift, SF Pro, dynamic dark-first palette; 123 Swift tests + 6 Python UI tests green |
| 2 · Surface system + chrome | 🟢 Complete | `DarkroomPanel` added; `MeridianSurfaceCard` visually demoted (no gradient, no shadow, hairline border); sidebar simplified to single-line rows; hero eyebrows removed; `.darkroom()` on all 4 top-level views |
| 3 · Setup redesign + NSPathControl | 🟢 Complete | `PathControl`, `ContactSheetView`, `SetupContactSheetSection`, full-window drop overlay; Xcode project updated with new files and `Components` group |
| 4 · Run timeline + motion | 🟢 Complete | `RunTimelineView` (24×6 proxy dot grid driven by copied/planned ratio), `NowCopyingCard`, `TickerRow` replaces metric grid, `RunPhaseStrip` demotes the 5-dot phase timeline to a 4pt segmented bar, completion haptic wired |
| 5 · History + Profiles + Settings | 🟢 Complete | `SettingsView` → native 3-tab TabView; `ProfilesView` → LazyVGrid of profile tiles with hover-reveal ⋯ menu + status dot; `RunHistoryView` flattened to hairline-separated editorial rows inside a single panel per section |
| 6 · Accessibility, copy pass, onboarding | 🟢 Complete | Accessibility hints on Setup/Run primary actions; VoiceOver rotor on Run issues; copy trimmed per §8 (hero, step messages, drop zone, run panels); `OnboardingCard` gated by `@AppStorage("didOnboard")`; dead `RunPhaseTimeline` removed |

Legend: ⚪ not started · 🟡 in progress · 🟢 complete · 🔴 blocked

---

## Phase Details

### Phase 1 — Foundation ✅

**Goal:** Swap tokens, typography scale, and dark-mode-aware colors. No view redesign yet.

**Deliverables**
- [x] `DesignTokens.swift` rewritten with semantic palette (`ColorSystem.*`) using `NSColor(name:dynamicProvider:)` for macOS 13+ dynamic colors
- [x] Typography moved from SF Rounded (`.rounded` design) to SF Pro (`.default` design)
- [x] New `Spacing` enum added in `DesignTokens`
- [x] New `Motion` enum + `.motion(_:value:)` reduce-motion-aware view modifier (`Motion.swift`)
- [x] `.darkroom()` view modifier applying canvas background + default ink
- [x] Legacy tokens (`Color.sky`, `.aqua`, `.amber`, `.amberWaypoint`, `.mist`, `.cloud`, `.inkPrimary`, etc.) preserved as aliases → resolve to new palette
- [x] Legacy `Typography.heroTitle/sectionTitle/metricValue/statusValue/eyebrow` preserved as aliases
- [x] Console font size bumped 12 → 13pt (was noted as too small on Retina)
- [x] Corner radii retuned: hero 24→20, card 20→14, inner 16→10 (tighter, less consumer-y)

**Files touched**
- `ui/Sources/ChronoframeApp/App/DesignTokens.swift` (rewritten)
- `ui/Sources/ChronoframeApp/App/Motion.swift` (new)

**Verification**
- `swift build` — ✅ clean (8s)
- `swift test` — ✅ 123 tests pass
- `python3 -m pytest test_ui_build.py test_ui_packaging.py` — ✅ 6 pass

**Notes for future phases**
- Minimum deployment is macOS 13; `Color(light:dark:)` requires macOS 14. We use `NSColor(name:dynamicProvider:)` wrapped via `Color(nsColor:)` — works on 13+.
- The legacy `Color.mist` and `Color.cloud` are still literal `Color.white.opacity(...)` — intentional; they're only referenced by the `MeridianSurfaceCard` gradients which get retired in Phase 2.
- The `accessibilityReduceMotion` gate lives in `ReduceMotionAnimationModifier` — use `.motion(_:value:)` everywhere instead of `.animation(_:value:)` for any animation that should respect Reduce Motion.

---

### Phase 2 — Surface system + chrome ✅

**Goal:** Retire hero gradient blocks, demote card weight, simplify sidebar.

**Deliverables**
- [x] `DarkroomPanel` component (canvas/panel/inset/elevated variants) added in `SharedViews.swift` — new preferred surface
- [x] `MeridianSurfaceCard` kept for source compat but **visually demoted**: no shadow, no gradient, only vibrancy + 0.5pt hairline border; inner variants get a 5% tint wash instead of a gradient
- [x] `DetailHeroCard` **retuned in-place**, not removed: no colored tint gradient, smaller 36pt icon, no eyebrow, `Typography.title` instead of `.heroTitle`. Still an anchor block but visually ~half the weight
- [x] Hero eyebrow copy ("Meridian Workflow", "Run Workspace", "Archive", "Saved Setup") deleted
- [x] Hero body copy trimmed across Setup/Run/History/Profiles
- [x] `SidebarView` simplified: single-line rows (subtitle deleted), cleaner trailing status dot instead of overlay-offset hack
- [x] `.darkroom()` applied to SetupView, CurrentRunView, RunHistoryView, ProfilesView
- [x] `MetricTile` updated to use `.monospacedDigit()` + `.contentTransition(.numericText())` for smooth counter transitions
- [x] New `HairlineDivider` component for future use

**Files touched**
- `ui/Sources/ChronoframeApp/Views/SharedViews.swift` (rewritten)
- `ui/Sources/ChronoframeApp/Views/SidebarView.swift` (simplified)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupView.swift` (+ `.darkroom()`)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupSectionViews.swift` (hero copy trim)
- `ui/Sources/ChronoframeApp/Views/Run/CurrentRunView.swift` (+ `.darkroom()`)
- `ui/Sources/ChronoframeApp/Views/Run/RunSectionViews.swift` (hero eyebrow removed)
- `ui/Sources/ChronoframeApp/Views/RunHistoryView.swift` (+ `.darkroom()`, hero trim)
- `ui/Sources/ChronoframeApp/Views/ProfilesView.swift` (+ `.darkroom()`, hero trim)

**Verification**
- `swift build` — ✅ clean
- `swift test` — ✅ 123 tests pass

**Notes for future phases**
- Accessibility identifiers preserved on all interactive controls (tests depend on them).
- `DetailHeroCard` was intentionally retuned rather than removed — Phase 3 (Setup) and Phase 4 (Run) will replace their respective hero cards with their bespoke layouts (contact-sheet pane, run timeline), so deleting the component now would force scope creep into those phases.
- The unified-toolbar principal-item idea was deferred to Phase 3/4 because the hero card is the natural anchor until its replacement ships.
- `DarkroomPanel` is ready for adoption in new views; existing views still use `MeridianSurfaceCard` (which is now structurally equivalent).

---

### Phase 3 — Setup redesign + NSPathControl ✅

**Goal:** Add live contact-sheet thumbnails + full-window drag-drop to Setup; introduce `NSPathControl` wrapper for later adoption.

**Deliverables**
- [x] `PathControl` (`NSViewRepresentable` wrapper around `NSPathControl`) at `Views/Components/PathControl.swift` — ready for adoption
- [x] `ContactSheetView` with `QLThumbnailGenerator`-backed thumbnails (12 cells, 40ms stagger, parallel loading via `TaskGroup`, extension-based media filter)
- [x] `SetupContactSheetSection` added to `SetupSectionViews.swift` — wraps `ContactSheetView` in a `MeridianSurfaceCard` with a "Preview" heading and a contextual empty-state message
- [x] `SetupView` adds a full-window `.onDrop` handler with amber-waypoint tint overlay (8% fill + 55% stroke) while targeted
- [x] Xcode project (`Chronoframe.xcodeproj/project.pbxproj`) updated: new `Components` group + registrations for `Motion.swift`, `PathControl.swift`, `ContactSheetView.swift`

**Files touched**
- `ui/Sources/ChronoframeApp/Views/Components/PathControl.swift` (new)
- `ui/Sources/ChronoframeApp/Views/Components/ContactSheetView.swift` (new)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupView.swift` (contact-sheet section inserted, full-window drop overlay)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupSectionViews.swift` (new `SetupContactSheetSection`)
- `ui/Chronoframe.xcodeproj/project.pbxproj` (new file registrations + `Components` group)

**Verification**
- `swift build` — ✅ clean
- `swift test` — ✅ 123 tests pass
- `python3 -m pytest test_ui_build.py test_ui_packaging.py` — ✅ 6 pass

**Notes for future phases**
- The current three-pane vision (left form / right contact sheet) is deferred: the contact sheet is stacked into the existing vertical flow so the surrounding copy-pass/hero rework in Phase 6 can land without rewriting layout again. Treat the section as transplantable — when the final layout arrives it moves unchanged into the right pane.
- `PathControl` is built and ready but not yet replacing `PathValueView` in Setup; wire it in during the layout rework so the swap happens alongside the form redesign, not as a piecemeal cosmetic change.
- `ContactSheetView` uses its own filesystem enumeration (by extension) rather than the engine's `MediaDiscovery` — intentional: the engine pipeline is expensive and async; this is a lightweight preview loader capped at 12 files. Do not reroute through `MediaDiscovery`.
- `ContactSheetLoader` is `@MainActor`, but `findMediaFiles`/`isLikelyMedia`/`thumbnail` are `nonisolated` so the enumeration runs on a detached task. Required for Swift 6 strict concurrency.

---

### Phase 4 — Run timeline + motion ✅

**Goal:** Replace metric grid with a timeline; add NowCopying card; collapse metrics to a ticker row; demote phase timeline to a slim bar; wire the "developing wash" completion feel.

**Deliverables**
- [x] `RunTimelineView` — 24×6 proxy dot grid at `Views/Run/RunTimelineView.swift`. Dots light `pending → active → complete` driven by `copiedCount / plannedCount`. Active dot pulses (1.15× ring) unless Reduce Motion is on. All dots saturate to success on `.finished`.
- [x] `RunPhaseStrip` — replaces the old 5-dot `RunPhaseTimeline` with a 4pt segmented capsule inside `RunProgressSurface`. Lives next to the existing progress bar; no toolbar rewrite (would have required `RootSplitView` chrome changes not yet in scope).
- [x] `NowCopyingCard` — compact inset card showing current task title, tone pill, and a symbol placeholder. Shown during `preflighting`/`running`/`finished` states.
- [x] `TickerRow` (and `RunTickerSection` wrapper) — replaces the 6-tile metric grid with a single inline middot-separated row. Monospaced digits + `.contentTransition(.numericText())` for smooth updates. Includes a minimal `FlowLayout` for narrow windows.
- [x] Completion haptic — `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, ...)` fires once when status transitions to `.finished`, wired in `CurrentRunView.onChange(of: runSessionStore.status)`.
- [x] Xcode project updated: registrations for `RunTimelineView.swift`, `NowCopyingCard.swift`, `TickerRow.swift`.

**Files touched**
- `ui/Sources/ChronoframeApp/Views/Run/RunTimelineView.swift` (new — includes both `RunTimelineView` and `RunPhaseStrip`)
- `ui/Sources/ChronoframeApp/Views/Run/NowCopyingCard.swift` (new)
- `ui/Sources/ChronoframeApp/Views/Components/TickerRow.swift` (new)
- `ui/Sources/ChronoframeApp/Views/Run/CurrentRunView.swift` (section composition, haptic hook)
- `ui/Sources/ChronoframeApp/Views/Run/RunSectionViews.swift` (added `RunTickerSection`; swapped `RunPhaseTimeline` → `RunPhaseStrip` inside `RunProgressSurface`)
- `ui/Chronoframe.xcodeproj/project.pbxproj`

**Verification**
- `swift build` — ✅ clean
- `swift test` — ✅ 123 tests pass
- `python3 -m pytest test_ui_build.py test_ui_packaging.py` — ✅ 6 pass

**Notes for future phases**
- The plan originally called for a year-row × month-column timeline driven by per-(year,month) aggregates. The engine does not currently stream that data: `RunMetrics` carries flat counts, and per-item events don't flow to the UI. Building that pipeline requires changes inside `ChronoframeAppCore` / `RunSessionStore`, which is explicitly out of scope per §11 of the plan. The proxy dot grid delivers the same visual language (frames finding their place, developing wash on completion) against the data that exists today. When an engine-side aggregator is added, swap the `completedIndex` / `activeIndex` computations in `RunTimelineView` for a real `[(year, month, copied, planned)]` array — the view structure does not need to change.
- The NowCopyingCard's QuickLook thumbnail is intentionally stubbed with an SF Symbol. The engine exposes `currentTaskTitle` as a formatted string but not a current-file URL; adding the URL channel is an engine change. When ready, swap the placeholder `thumbnail` view for a `QLThumbnailGenerator` call (similar pattern to `ContactSheetView`).
- The old `RunPhaseTimeline` view is still defined in `RunSectionViews.swift` but is no longer rendered anywhere. Left in place so existing tests / accessibility identifiers won't break; Phase 6 can delete it as part of dead-code cleanup.
- The "developing wash" sweep across the timeline on completion is currently implemented via the per-dot state transition (all dots settle to `.complete` with the existing `Motion.filmic` animation). A dedicated left-to-right sweep with `Motion.wash` is a nice-to-have upgrade if the base effect lands flat in user testing.

---

### Phase 5 — History + Profiles + Settings ✅

**Goal:** Convert the three remaining screens from a dashboard vocabulary (stacked tinted cards) to an editorial/native vocabulary (one panel per section, hairline separators, hover-reveal actions, native Settings TabView).

**Deliverables**
- [x] `SettingsView` → `TabView` with three tabs: **General** (placeholder copy), **Performance** (worker stepper + cached destination scan toggle + verify-copies toggle), **Diagnostics** (log buffer stepper). Preserves `diagnosticsLogBufferStepper` accessibility identifier + the `onChange(of: logBufferCapacity)` wiring to `appState.runLogStore.capacity`. Keeps `UITestScenario.configureCurrentWindow(..., isSettings: true)` on appear.
- [x] `ProfilesView` → header strip + save-current-paths panel + `LazyVGrid` of profile tiles (adaptive 280–380pt columns). Each tile: name + status dot when active + hover-reveal ⋯ menu (Overwrite/Delete) + two hairline-separated path rows (From/To) + full-width Use button. Preserves `profileName-<name>` and `activeProfileBadge` identifiers.
- [x] `RunHistoryView` flattened: header strip replaces the hero card; reusable sources and artifacts each live inside one `DarkroomPanel` with 0.5pt hairline rows (no nested inner cards). Each row is a single line: icon + title + meta chips + right-aligned mono path + Open button + ⋯ menu. Day sections (`sectionHeader`) are label-style eyebrows. Preserves `historyFilterControl`, `openArtifact_*`, `revealArtifact_*`, `useHistoricalSourceButton`, `revealHistoricalSourceButton` identifiers.

**Files touched**
- `ui/Sources/ChronoframeApp/Views/SettingsView.swift` (rewritten)
- `ui/Sources/ChronoframeApp/Views/ProfilesView.swift` (rewritten)
- `ui/Sources/ChronoframeApp/Views/RunHistoryView.swift` (rewritten)

**Verification**
- `swift build` — ✅ clean
- `swift test` — ✅ 123 tests pass
- `python3 -m pytest test_ui_build.py test_ui_packaging.py` — ✅ 6 pass

**Notes for future phases**
- The plan's "dashed outline New Profile card" was intentionally omitted — the Save Current Paths panel already serves that role (one place to create a profile), and adding a dashed tile would mean two creation UIs. Flag for Phase 6 copy pass if the empty-state rewording calls for it.
- The plan called for a per-run editorial card with throughput sparkline. The engine doesn't persist per-minute throughput samples in the history artifacts that `HistoryStore` exposes (`RunHistoryEntry` is per-artifact, not per-run). Adding this is an engine change (aggregate run records) — out of scope. If/when added, wire under the section header; the current hairline-row layout expects it there.
- Filter segmented control still uses `HistoryFilter` (All/Reports/Receipts/Logs/Other); did not rename to the plan's `All · Preview · Transfer · With errors` wording because those categories don't map to existing `RunHistoryEntryKind` values.
- `SettingsView` is still invoked as a sheet via `RootSplitView` / `AppCommands` (not via a `Settings { }` scene). The `TabView` rework is purely the body; moving to a real Settings scene is an App-struct change and is deferred to keep accessibility tests stable.
- `DetailHeroCard` now has two fewer callers (Profiles, History). Still used by other views — do not delete it in Phase 6 without auditing those call sites first.
- Both `ProfileTile` and the history rows use a borderless ⋯ menu with `menuIndicator(.hidden)` + `.fixedSize()` — this is the pattern to reuse for any future row-level overflow menus.

---

### Phase 6 — Accessibility, copy pass, onboarding ✅

**Goal:** Raise accessibility from "adequate" to "shippable"; trim the 60% of copy flagged in §8; ship a one-card first-run greeting; drop dead code from earlier phases.

**Deliverables**
- [x] Accessibility hints added to the Setup `previewButton` / `transferButton` (already had labels), the Setup hero primary button (dynamic hint based on enabled state), the Setup "Choose Source…" / "Choose Destination…" buttons, and every case of the Run hero primary button (`setup/preview/transfer/cancel/openDestination/showIssues`). Each hint explains *why* the action is disabled when it is.
- [x] VoiceOver rotor on the Run issues list (`accessibilityRotor("Issues") { ForEach(model.issueEntries) { AccessibilityRotorEntry(...) } }`) plus `accessibilityElement(children: .combine)` + a labeled prefix (Error / Warning / Notice) on each issue row. A helper `accessibilityPrefix(for:)` near `RunIssuesPanel` derives the prefix from `RunWorkspaceTone`.
- [x] Copy pass per §8:
  - `SetupHeroSection` title "Set Up Your Library" → "Setup"; hero message deleted (empty string).
  - `SetupSavedSetupSection` "Manual paths stay available below…" helper text deleted.
  - `SetupSourceStepSection` step title "1. Choose Your Source" → "1. Source"; message trimmed to "The library Chronoframe should organize."
  - `SetupDestinationStepSection` title "2. Choose Your Destination" → "2. Destination"; message trimmed.
  - `SetupReadinessSection` eyebrow "Run Readiness" and title "Preview First, Transfer When Confident" → single title "Run"; message "Preview to inspect the plan. Transfer when ready."
  - `SetupDropZone` long explainer paragraphs removed; reduced to single-line headline ("Drop a folder to begin" / "Release to use as source").
  - `RunArtifactsPanel` paragraph "Open the destination, dry-run report, or logs…" deleted.
  - `RunIssuesPanel` header "Issue Review" → "Issues"; `issueWorkspaceSummary` paragraph removed from the panel render.
  - `RunConsolePanel` empty-state "The full backend console will appear here…" → "No activity yet."
- [x] `OnboardingCard` component at `Views/Components/OnboardingCard.swift`. One-shot first-run card: wave icon + headline + one-line subtitle + dismiss X. Gated in `SetupView` by `@AppStorage("didOnboard") && sourcePath.isEmpty`. Auto-sets `didOnboard = true` on drop so the card never reappears once a source is chosen.
- [x] Dead `RunPhaseTimeline` view removed from `RunSectionViews.swift` (noted in Phase 4 follow-ups; no call sites remained).
- [x] Xcode project updated: `Components` group + Sources build phase register `OnboardingCard.swift` (new ID `AA…0147` / `AA…0247`).

**Files touched**
- `ui/Sources/ChronoframeApp/Views/Components/OnboardingCard.swift` (new)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupView.swift` (onboarding wiring, `@AppStorage`)
- `ui/Sources/ChronoframeApp/Views/Setup/SetupSectionViews.swift` (copy pass + accessibility hints)
- `ui/Sources/ChronoframeApp/Views/Run/RunSectionViews.swift` (dead code removal, rotor, accessibility hints, copy trim)
- `ui/Chronoframe.xcodeproj/project.pbxproj` (OnboardingCard registration)

**Verification**
- `swift build` — ✅ clean
- `swift test` — ✅ 123 tests pass
- `python3 -m pytest test_ui_build.py test_ui_packaging.py` — ✅ 6 pass

**Notes / deferred items**
- **Dynamic Type** coverage was not adopted globally. `DesignTokens.Typography` still uses fixed-point `Font.system(size:…)` initializers. Converting to `Font.system(textStyle, design:)` requires per-call-site verification (ScrollView headers, fixed metric layout tiles, monospaced console lines) because some sizes encode fixed visual rhythm that doesn't want to scale. Flagged as the single largest remaining accessibility gap; suggest tackling as a dedicated follow-up task rather than mid-Phase 6.
- **Accessibility Inspector audit** was not run interactively (cannot launch Xcode UI from here). Static changes here — hint additions, rotor, issue-row element combine — are the high-leverage items it would have surfaced. When run manually, expect it to flag low-contrast status pills (`MeridianStatusBadge` tint at 15% + bare tint-colored text) on amber/warning tones in light mode. The fix is in-scope for a follow-up pass: raise the tint-background opacity to 18% and darken the text 8% in light mode.
- **Contrast audit** not executed; same caveat as above.
- **Screenshot regeneration** not executed. `docs/screenshots/` still shows pre-redesign state. This is a mechanical task (launch app with several deterministic scenarios and capture both appearances) — suggest running as part of release-notes prep.
- `accessibilityReduceMotion` gates were already wired in Phases 1/4 via the `.motion(_:value:)` modifier; no new animations were added in Phase 6, so no additional gates needed.
- `OnboardingCard` uses `DarkroomPanel(.panel)` so it adopts the shared surface treatment automatically. If a future Phase moves onboarding elsewhere (Setup empty state, for example), the component is self-contained and transplantable.

---

## Cross-cutting Verification

After each phase:

1. `cd ui && swift build` — must pass.
2. `python3 -m pytest test_ui_build.py test_ui_packaging.py` — must stay green.
3. Launch app, spot-check: Setup populates, Preview runs against a small sample folder, Run view renders without regression.
4. Toggle system appearance (Control Center → Appearance) — no stuck colors.

## Open Questions / Decisions Log

_Add entries here as they come up. Timestamp and decision rationale so future sessions can backtrack._

- _(none yet)_

---

_Last updated: 2026-04-18 — All six phases complete. Follow-up opportunities noted in Phase 6 deferred items: global Dynamic Type rollout, interactive Accessibility Inspector audit, status-pill contrast tuning, and screenshot regeneration._
