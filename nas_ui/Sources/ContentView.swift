import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let phaseLabels = ["Discover", "Hash Source", "Index Destination", "Classify", "Transfer"]

private struct MetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color
}

private struct StatusStyle {
    let title: String
    let subtitle: String
    let badge: String
    let symbol: String
    let tint: Color
}

private struct WorkflowStep: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let symbol: String
}

private struct MiniStat: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: Color
}

private enum ActivityPane: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case console = "Console"

    var id: String { rawValue }
}

private enum ConsoleFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case issues = "Issues"
    case events = "Events"

    var id: String { rawValue }
}

private enum FocusedInput: Hashable {
    case profile
}

struct ContentView: View {
    @StateObject private var runner = BackendRunner()

    @State private var sourcePath: String = ""
    @State private var destPath: String = ""
    @State private var profileName: String = ""
    @State private var isFastDest: Bool = false
    @State private var numWorkers: Int = 8
    @State private var showingProfileHelp = false
    @State private var showingProfileField = false
    @State private var showingAdvancedOptions = false
    @State private var activityPane: ActivityPane = .summary
    @State private var consoleFilter: ConsoleFilter = .all
    @State private var sourceDropActive = false
    @State private var destDropActive = false

    @FocusState private var focusedInput: FocusedInput?

    private let inkPrimary = Color(red: 0.14, green: 0.18, blue: 0.24)
    private let inkSecondary = Color(red: 0.33, green: 0.40, blue: 0.49)
    private let inkTertiary = Color(red: 0.50, green: 0.56, blue: 0.65)
    private let panelFill = Color.white.opacity(0.68)
    private let panelStroke = Color.white.opacity(0.72)

    private var sourceValid: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }

    private var destReady: Bool {
        !destPath.isEmpty
    }

    private var usingProfile: Bool {
        !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var setupComplete: Bool {
        usingProfile || (sourceValid && destReady)
    }

    private var setupProgressValue: Double {
        if usingProfile { return 1.0 }
        let completed = (sourceValid ? 1 : 0) + (destReady ? 1 : 0)
        return Double(completed) / 2.0
    }

    private var shouldShowAdvancedCard: Bool {
        showingAdvancedOptions ||
        isFastDest ||
        numWorkers != 8 ||
        usingProfile ||
        sourceValid ||
        destReady
    }

    private var canStart: Bool {
        !runner.isRunning && setupComplete
    }

    private var hasOutcomeData: Bool {
        runner.discoveredCount > 0 ||
        runner.plannedCount > 0 ||
        runner.alreadyInDestinationCount > 0 ||
        runner.duplicateCount > 0 ||
        runner.copiedCount > 0 ||
        runner.failedCount > 0 ||
        runner.hashErrorCount > 0 ||
        !runner.completedDest.isEmpty
    }

    private var shouldShowOperationalWorkspace: Bool {
        runner.isRunning || hasOutcomeData
    }

    private var showCompletionCard: Bool {
        !runner.isRunning &&
        runner.completionStatus != "idle" &&
        runner.completionStatus != "running"
    }

    private var activeWorkflowIndex: Int {
        if !setupComplete {
            return 0
        }
        return 1
    }

    private var workflowSteps: [WorkflowStep] {
        [
            WorkflowStep(
                title: "Choose your source",
                body: "Point the app at the library you want to organize, drag a folder in, or reveal a saved profile for repeatable setups.",
                symbol: "folder.badge.plus"
            ),
            WorkflowStep(
                title: "Preview the plan",
                body: "Run a non-destructive preview first so you can inspect what will be copied, skipped, or flagged before any transfer begins.",
                symbol: "eye"
            ),
            WorkflowStep(
                title: "Start the transfer",
                body: "When the plan looks right, begin the transfer and monitor progress, issues, receipts, and logs from the workspace.",
                symbol: "arrow.right.circle"
            ),
        ]
    }

    private var statusStyle: StatusStyle {
        if runner.isRunning {
            return StatusStyle(
                title: runner.currentTaskName,
                subtitle: runner.progress > 0
                    ? "The organizer is moving through your library now, with live progress, throughput, and issue tracking."
                    : "Preparing the run, validating the next step, and bringing the workspace online.",
                badge: "Running",
                symbol: "arrow.triangle.2.circlepath",
                tint: Color(red: 0.11, green: 0.46, blue: 0.88)
            )
        }

        switch runner.completionStatus {
        case "dry_run_finished":
            return StatusStyle(
                title: "Preview Ready",
                subtitle: "The copy plan is ready to review. Nothing has been copied yet.",
                badge: "Preview",
                symbol: "eye.fill",
                tint: Color(red: 0.14, green: 0.58, blue: 0.48)
            )
        case "finished":
            return StatusStyle(
                title: "Transfer Complete",
                subtitle: "The library run completed and the destination, logs, and receipts are ready to inspect.",
                badge: "Complete",
                symbol: "checkmark.circle.fill",
                tint: Color(red: 0.18, green: 0.64, blue: 0.39)
            )
        case "nothing_to_copy":
            return StatusStyle(
                title: "Already Up To Date",
                subtitle: "The destination already contains everything this run needs.",
                badge: "No Action",
                symbol: "checkmark.seal.fill",
                tint: Color(red: 0.30, green: 0.49, blue: 0.85)
            )
        case "cancelled":
            return StatusStyle(
                title: "Run Cancelled",
                subtitle: "The operation stopped before completion. Review the current state and resume when you are ready.",
                badge: "Paused",
                symbol: "pause.circle.fill",
                tint: Color(red: 0.80, green: 0.53, blue: 0.16)
            )
        default:
            return StatusStyle(
                title: "Prepare Your Library",
                subtitle: "Choose a source and destination, preview the changes, then start the transfer when the plan looks right.",
                badge: "Ready",
                symbol: "photo.on.rectangle.angled",
                tint: Color(red: 0.17, green: 0.42, blue: 0.82)
            )
        }
    }

    private var metrics: [MetricItem] {
        [
            MetricItem(
                title: "Discovered",
                value: abbreviatedCount(runner.discoveredCount),
                caption: "Items found in the source library",
                symbol: "photo.stack.fill",
                tint: Color(red: 0.18, green: 0.48, blue: 0.88)
            ),
            MetricItem(
                title: "Planned",
                value: abbreviatedCount(runner.plannedCount),
                caption: runner.completionStatus == "dry_run_finished" ? "Ready for review" : "Queued for transfer",
                symbol: "square.and.arrow.down.on.square.fill",
                tint: Color(red: 0.18, green: 0.62, blue: 0.41)
            ),
            MetricItem(
                title: "Already Organized",
                value: abbreviatedCount(runner.alreadyInDestinationCount),
                caption: "Skipped because they already exist",
                symbol: "checkmark.circle",
                tint: Color(red: 0.31, green: 0.48, blue: 0.84)
            ),
            MetricItem(
                title: "Duplicates",
                value: abbreviatedCount(runner.duplicateCount),
                caption: "Routed into duplicate review paths",
                symbol: "square.on.square",
                tint: Color(red: 0.84, green: 0.55, blue: 0.18)
            ),
            MetricItem(
                title: "Issues",
                value: abbreviatedCount(issueCount),
                caption: "Warnings, failed copies, or hash issues",
                symbol: "exclamationmark.triangle.fill",
                tint: Color(red: 0.84, green: 0.29, blue: 0.26)
            ),
            MetricItem(
                title: "Completed",
                value: abbreviatedCount(runner.copiedCount),
                caption: "Files copied successfully",
                symbol: "checkmark.circle.fill",
                tint: Color(red: 0.18, green: 0.64, blue: 0.39)
            ),
        ]
    }

    private var bodyGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.98, blue: 0.995),
                Color(red: 0.93, green: 0.95, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var issueCount: Int {
        max(runner.errorCount, runner.hashErrorCount + runner.failedCount)
    }

    private var filteredLogLines: [String] {
        switch consoleFilter {
        case .all:
            return runner.logLines
        case .issues:
            return runner.logLines.filter(isIssueLine)
        case .events:
            return runner.logLines.filter { !isIssueLine($0) }
        }
    }

    private var warningLogCount: Int {
        runner.logLines.filter { $0.hasPrefix("⚠") || $0.hasPrefix("WARNING:") }.count
    }

    private var errorLogCount: Int {
        runner.logLines.filter { $0.hasPrefix("ERROR:") }.count
    }

    private var infoLogCount: Int {
        max(0, runner.logLines.count - warningLogCount - errorLogCount)
    }

    private var heroPrimaryValue: String {
        if runner.isRunning {
            if runner.progress > 0 {
                return "\(Int((runner.progress * 100).rounded()))%"
            }
            return "Live"
        }

        switch runner.completionStatus {
        case "finished":
            return abbreviatedCount(runner.copiedCount)
        case "dry_run_finished":
            return abbreviatedCount(runner.plannedCount)
        case "nothing_to_copy":
            return abbreviatedCount(runner.alreadyInDestinationCount)
        case "cancelled":
            return abbreviatedCount(runner.copiedCount)
        default:
            if canStart { return "Ready" }
            return "\(Int((setupProgressValue * 100).rounded()))%"
        }
    }

    private var heroPrimaryLabel: String {
        if runner.isRunning {
            return "Overall Progress"
        }

        switch runner.completionStatus {
        case "finished":
            return "Copied Successfully"
        case "dry_run_finished":
            return "Files In Preview"
        case "nothing_to_copy":
            return "Already Organized"
        case "cancelled":
            return "Transferred Before Pause"
        default:
            return canStart ? "Ready To Preview" : "Setup Complete"
        }
    }

    private var heroMiniStats: [MiniStat] {
        if runner.isRunning {
            return [
                MiniStat(
                    title: "Speed",
                    value: runner.speedMBps > 0 ? String(format: "%.1f MB/s", runner.speedMBps) : "Live",
                    tint: statusStyle.tint
                ),
                MiniStat(
                    title: "ETA",
                    value: runner.etaSeconds > 0 ? formatETA(runner.etaSeconds) : "Calculating",
                    tint: Color(red: 0.43, green: 0.53, blue: 0.68)
                ),
                MiniStat(
                    title: "Issues",
                    value: abbreviatedCount(issueCount),
                    tint: Color(red: 0.82, green: 0.29, blue: 0.25)
                ),
            ]
        }

        switch runner.completionStatus {
        case "finished":
            return [
                MiniStat(title: "Already", value: abbreviatedCount(runner.alreadyInDestinationCount), tint: Color(red: 0.31, green: 0.48, blue: 0.84)),
                MiniStat(title: "Duplicates", value: abbreviatedCount(runner.duplicateCount), tint: Color(red: 0.84, green: 0.55, blue: 0.18)),
                MiniStat(title: "Issues", value: abbreviatedCount(issueCount), tint: Color(red: 0.82, green: 0.29, blue: 0.25)),
            ]
        case "dry_run_finished":
            return [
                MiniStat(title: "Queued", value: abbreviatedCount(runner.plannedCount), tint: statusStyle.tint),
                MiniStat(title: "Duplicates", value: abbreviatedCount(runner.duplicateCount), tint: Color(red: 0.84, green: 0.55, blue: 0.18)),
                MiniStat(title: "Issues", value: abbreviatedCount(issueCount), tint: Color(red: 0.82, green: 0.29, blue: 0.25)),
            ]
        default:
            return [
                MiniStat(title: "Source", value: usingProfile || sourceValid ? "Set" : "Needed", tint: statusStyle.tint),
                MiniStat(title: "Destination", value: usingProfile || destReady ? "Set" : "Needed", tint: Color(red: 0.31, green: 0.48, blue: 0.84)),
                MiniStat(title: "Mode", value: usingProfile ? "Profile" : "Manual", tint: Color(red: 0.56, green: 0.47, blue: 0.82)),
            ]
        }
    }

    private var completionStats: [MiniStat] {
        [
            MiniStat(title: "Copied", value: abbreviatedCount(runner.copiedCount), tint: Color(red: 0.18, green: 0.64, blue: 0.39)),
            MiniStat(title: "Queued", value: abbreviatedCount(runner.plannedCount), tint: statusStyle.tint),
            MiniStat(title: "Duplicates", value: abbreviatedCount(runner.duplicateCount), tint: Color(red: 0.84, green: 0.55, blue: 0.18)),
            MiniStat(title: "Issues", value: abbreviatedCount(issueCount), tint: Color(red: 0.82, green: 0.29, blue: 0.25)),
        ]
    }

    var body: some View {
        ZStack {
            bodyGradient.ignoresSafeArea()
            backgroundAtmosphere

            HStack(spacing: 22) {
                controlRail
                mainWorkspace
            }
            .frame(maxWidth: 1620, maxHeight: .infinity, alignment: .top)
            .padding(20)
        }
        .foregroundStyle(inkPrimary)
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: runner.isRunning)
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: runner.completionStatus)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: activityPane)
        .alert(isPresented: $runner.showingPrompt) {
            Alert(
                title: Text("Confirm Transfer"),
                message: Text(runner.promptMessage),
                primaryButton: .default(Text("Continue")) { runner.answerPrompt(yes: true) },
                secondaryButton: .cancel(Text("Cancel")) { runner.answerPrompt(yes: false) }
            )
        }
        .onChange(of: runner.isRunning) { isRunning in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                if isRunning {
                    activityPane = .summary
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseSourceFolder)) { _ in
            selectFolder(for: $sourcePath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseDestinationFolder)) { _ in
            selectFolder(for: $destPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activateProfileField)) { _ in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                showingProfileField = true
            }
            focusedInput = .profile
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerPreviewRun)) { _ in
            startRun(dryRun: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerTransferRun)) { _ in
            startRun(dryRun: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleActivityPane)) { _ in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                activityPane = activityPane == .summary ? .console : .summary
            }
        }
    }

    private var backgroundAtmosphere: some View {
        ZStack {
            ambientOrb(color: statusStyle.tint.opacity(0.18), size: 420, offsetX: -430, offsetY: -250)
            ambientOrb(color: Color(red: 0.97, green: 0.74, blue: 0.47).opacity(0.15), size: 360, offsetX: 430, offsetY: -290)
            ambientOrb(color: Color(red: 0.62, green: 0.79, blue: 0.95).opacity(0.12), size: 320, offsetX: 390, offsetY: 260)
            ambientOrb(color: Color(red: 0.83, green: 0.88, blue: 1.0).opacity(0.16), size: 280, offsetX: -180, offsetY: 320)
        }
        .allowsHitTesting(false)
    }

    private var controlRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                appIdentityCard
                if runner.isRunning {
                    liveRunRailCard
                } else {
                    actionCard
                    sourceDestinationCard
                    if shouldShowAdvancedCard {
                        advancedCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 320)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 24, x: 0, y: 14)
    }

    private var appIdentityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [statusStyle.tint.opacity(0.24), Color.white.opacity(0.86)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    Image(systemName: "photo.stack.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(statusStyle.tint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("NAS Organizer")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(inkPrimary)
                    Text("Preview and organize large photo libraries with calm, auditable control.")
                        .font(.callout)
                        .foregroundStyle(inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)
                Text("Preview first. Transfer when confident.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(inkSecondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var sourceDestinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Setup",
                subtitle: "Choose the source and destination, or use a saved profile for a repeatable workflow."
            )

            pathFieldRow(
                title: "Source Library",
                placeholder: "Drop a source folder here or type a path",
                path: $sourcePath,
                status: sourceDropActive ? "Release to use this source folder." : sourcePathStatusText,
                badge: sourcePathBadgeText,
                badgeTint: sourcePathBadgeTint,
                statusColor: sourcePathStatusColor,
                icon: "folder.fill.badge.plus",
                shortcutHint: "⌘O",
                dropHint: "Drag a folder here or use Choose.",
                isTargeted: $sourceDropActive,
                isMuted: false,
                action: { selectFolder(for: $sourcePath) },
                dropAction: { providers in handleFolderDrop(providers, into: $sourcePath) }
            )

            pathFieldRow(
                title: "Destination",
                placeholder: "Drop a destination folder here or type a path",
                path: $destPath,
                status: destDropActive ? "Release to use this destination." : destinationStatusText,
                badge: destinationBadgeText,
                badgeTint: destinationBadgeTint,
                statusColor: destinationStatusColor,
                icon: "externaldrive.fill",
                shortcutHint: "⇧⌘O",
                dropHint: "The organizer will create the destination if needed.",
                isTargeted: $destDropActive,
                isMuted: usingProfile,
                action: { selectFolder(for: $destPath) },
                dropAction: { providers in handleFolderDrop(providers, into: $destPath) }
            )

            DisclosureGroup(isExpanded: $showingProfileField) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Optional profile name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedInput, equals: .profile)

                    Text(usingProfile
                         ? "This profile takes precedence over the manual source and destination fields for the next run."
                         : "Use a named profile from nas_profiles.yaml for repeatable source and destination pairings.")
                        .font(.footnote)
                        .foregroundStyle(inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Text("Saved Profile")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(inkPrimary)
                    shortcutBadge("⇧⌘P")
                    Button(action: { showingProfileHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingProfileHelp, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Profiles")
                                .font(.headline)
                            Text("Use a profile name to load saved source and destination paths from `nas_profiles.yaml`. When a profile is filled in, it takes priority over the manual fields above.")
                                .font(.callout)
                                .foregroundStyle(inkSecondary)
                                .frame(width: 280, alignment: .leading)
                        }
                        .padding(18)
                    }
                }
            }
        }
    }

    private var liveRunRailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Live Run",
                subtitle: "The controls that matter most stay close at hand while the detailed monitoring lives in the workspace."
            )

            statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)

            sourceDestinationSummary(
                title: "Source",
                value: summaryPath(sourcePath, emptyLabel: usingProfile ? "Loaded from profile" : "Using selected source"),
                icon: "folder"
            )

            sourceDestinationSummary(
                title: "Destination",
                value: summaryPath(destPath, emptyLabel: usingProfile ? "Loaded from profile" : "Using selected destination"),
                icon: "externaldrive"
            )

            HStack(spacing: 10) {
                compactRailMetric(title: "Planned", value: abbreviatedCount(runner.plannedCount), tint: statusStyle.tint)
                compactRailMetric(title: "Done", value: abbreviatedCount(runner.copiedCount), tint: Color(red: 0.18, green: 0.64, blue: 0.39))
                compactRailMetric(title: "Issues", value: abbreviatedCount(issueCount), tint: Color(red: 0.82, green: 0.29, blue: 0.25))
            }

            Button("Cancel Run", role: .destructive) {
                runner.cancel()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.82, green: 0.29, blue: 0.25))
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: actionCardTitle, subtitle: actionCardSubtitle)

            setupChecklistRow

            HStack(spacing: 10) {
                Button(action: { startRun(dryRun: true) }) {
                    Label("Preview", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canStart)
                .keyboardShortcut("r", modifiers: [.command])

                Button(action: { startRun(dryRun: false) }) {
                    Label("Transfer", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.12, green: 0.45, blue: 0.84))
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: [.command])
            }

            HStack(spacing: 8) {
                shortcutBadge("⌘R Preview")
                shortcutBadge("⌘↩ Transfer")
            }

            Text(actionFootnote)
                .font(.footnote)
                .foregroundStyle(inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    statusStyle.tint.opacity(0.12),
                    Color.white.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
    }

    private var advancedCard: some View {
        DisclosureGroup(isExpanded: $showingAdvancedOptions) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $isFastDest) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use Cached Destination Scan")
                            .foregroundStyle(inkPrimary)
                        Text("Faster for repeated previews when you trust the destination cache and want to skip a full destination scan.")
                            .font(.footnote)
                            .foregroundStyle(inkSecondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Worker Threads")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(inkPrimary)
                        Text("Tune parallel hashing for your storage and network characteristics.")
                            .font(.footnote)
                            .foregroundStyle(inkSecondary)
                    }
                    Spacer()
                    Stepper(value: $numWorkers, in: 1...32) {
                        Text("\(numWorkers)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(inkPrimary)
                            .frame(minWidth: 28)
                    }
                    .fixedSize()
                }
            }
            .padding(.top, 12)
        } label: {
            sectionHeader(title: "Advanced", subtitle: "Performance controls for repeated runs, slower storage, and cache-heavy workflows.")
        }
    }

    private var mainWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard

                Group {
                    if shouldShowOperationalWorkspace {
                        VStack(alignment: .leading, spacing: 20) {
                            metricsGrid
                            progressCard
                            activityCard
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        onboardingCard
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }

                if showCompletionCard {
                    completionCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: 1240, alignment: .top)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)

                    Text(statusStyle.title)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(inkPrimary)

                    Text(statusStyle.subtitle)
                        .font(.title3.weight(.regular))
                        .foregroundStyle(inkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                heroTelemetryCard
            }

            HStack(spacing: 14) {
                sourceDestinationSummary(
                    title: "Source",
                    value: summaryPath(sourcePath, emptyLabel: usingProfile ? "Loaded from profile" : "Choose a source folder"),
                    icon: "folder"
                )
                sourceDestinationSummary(
                    title: "Destination",
                    value: summaryPath(destPath, emptyLabel: usingProfile ? "Loaded from profile" : "Choose a destination folder"),
                    icon: "externaldrive"
                )
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    statusStyle.tint.opacity(0.18),
                    Color.white.opacity(0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.20))
                .frame(width: 240, height: 150)
                .blur(radius: 12)
                .offset(x: 40, y: -38)
                .mask(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .shadow(color: statusStyle.tint.opacity(0.18), radius: 28, x: 0, y: 12)
    }

    private var heroTelemetryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Session")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(inkSecondary)
                Spacer()
                if runner.isRunning {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(statusStyle.tint)
                }
            }

            Text(heroPrimaryValue)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(inkPrimary)
                .contentTransition(.numericText())

            Text(heroPrimaryLabel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(inkSecondary)

            Divider()

            VStack(spacing: 10) {
                ForEach(heroMiniStats) { stat in
                    miniStatRow(stat)
                }
            }
        }
        .frame(width: 250, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.82), lineWidth: 1)
        )
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ],
            spacing: 14
        ) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: metric.symbol)
                            .foregroundStyle(metric.tint)
                            .padding(10)
                            .background(metric.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Spacer()
                        Text(metric.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(inkSecondary)
                    }

                    Text(metric.value)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(metric.value == "0" ? inkSecondary : inkPrimary)
                        .contentTransition(.numericText())

                    Text(metric.caption)
                        .font(.footnote)
                        .foregroundStyle(inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(panelFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(panelStroke, lineWidth: 1)
                )
                .shadow(color: metric.tint.opacity(0.08), radius: 16, x: 0, y: 10)
            }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(title: "Run Overview", subtitle: "The organizer moves through each phase with clear progress and visible safety checks.")

            HStack(spacing: 12) {
                ForEach(phaseLabels.indices, id: \.self) { index in
                    phaseNode(index: index)

                    if index < phaseLabels.count - 1 {
                        Capsule()
                            .fill(index < runner.currentPhase ? statusStyle.tint : Color.white.opacity(0.56))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: runner.progress)
                    .progressViewStyle(.linear)
                    .tint(statusStyle.tint)

                HStack {
                    Text(runner.currentTaskName)
                        .font(.headline)
                        .foregroundStyle(inkPrimary)
                    Spacer()
                    if issueCount > 0 {
                        Label("\(issueCount) issue\(issueCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 0.82, green: 0.29, blue: 0.25))
                    } else {
                        Text(progressLabel)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(inkSecondary)
                    }
                }
            }
        }
        .padding(22)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                sectionHeader(title: "Activity", subtitle: "Switch between a concise narrative summary and the full console stream without leaving the workspace.")
                Spacer()
                Picker("", selection: $activityPane) {
                    ForEach(ActivityPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack(spacing: 10) {
                activityChip(title: "Errors", value: "\(errorLogCount)", tint: Color(red: 0.82, green: 0.29, blue: 0.25))
                activityChip(title: "Warnings", value: "\(warningLogCount)", tint: Color(red: 0.84, green: 0.55, blue: 0.18))
                activityChip(title: "Events", value: "\(infoLogCount)", tint: statusStyle.tint)
                Spacer()
                if activityPane == .console {
                    HStack(spacing: 8) {
                        ForEach(ConsoleFilter.allCases) { filter in
                            filterChip(filter)
                        }
                    }
                }
            }

            Group {
                if activityPane == .summary {
                    summaryHighlights
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    logView
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(22)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var completionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(statusStyle.tint.opacity(0.16))
                        .frame(width: 64, height: 64)
                    Image(systemName: statusStyle.symbol)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(statusStyle.tint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(completionTitle)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(inkPrimary)
                    Text(completionSubtitle)
                        .font(.callout)
                        .foregroundStyle(inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(completionLeadValue)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(inkPrimary)
                        .contentTransition(.numericText())
                    Text(completionLeadLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(inkSecondary)
                }
            }

            HStack(spacing: 12) {
                ForEach(completionStats) { stat in
                    miniStatCard(stat)
                }
            }

            HStack(spacing: 12) {
                if runner.completionStatus == "dry_run_finished", !runner.completedReport.isEmpty {
                    Button(action: openReport) {
                        Label("Open Report", systemImage: "doc.text.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(statusStyle.tint)
                } else {
                    Button(action: openDestInFinder) {
                        Label("Open Destination", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(statusStyle.tint)
                }

                if !runner.completedDest.isEmpty {
                    Button(action: openDestInFinder) {
                        Label("Reveal Destination", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !runner.completedReport.isEmpty {
                    Button(action: openReport) {
                        Label("Report", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: openLogsFolder) {
                    Label("Logs", systemImage: "tray.full.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    statusStyle.tint.opacity(0.12),
                    Color.white.opacity(0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: statusStyle.tint.opacity(0.16), radius: 24, x: 0, y: 12)
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(
                title: "Getting Started",
                subtitle: "The idle state stays focused. Set up the library, preview once, then let the workspace expand as the run progresses."
            )

            VStack(spacing: 12) {
                ForEach(Array(workflowSteps.enumerated()), id: \.element.id) { index, step in
                    let isActive = index == activeWorkflowIndex
                    let isComplete = index < activeWorkflowIndex
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(stepFill(isActive: isActive, isComplete: isComplete))
                                .frame(width: 42, height: 42)

                            Image(systemName: isComplete ? "checkmark" : step.symbol)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(stepSymbolTint(isActive: isActive, isComplete: isComplete))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(step.title)")
                                .font(.headline)
                                .foregroundStyle(inkPrimary)
                            Text(step.body)
                                .font(.callout)
                                .foregroundStyle(inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Text(isComplete ? "Ready" : isActive ? "Next" : "Later")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive || isComplete ? statusStyle.tint : inkTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (isActive || isComplete ? statusStyle.tint.opacity(0.12) : Color.white.opacity(0.54)),
                                in: Capsule()
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(stepFill(isActive: isActive, isComplete: isComplete), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(stepStroke(isActive: isActive, isComplete: isComplete), lineWidth: 1)
                    )
                    .shadow(color: isActive ? statusStyle.tint.opacity(0.10) : Color.clear, radius: 14, x: 0, y: 10)
                }
            }
        }
        .padding(22)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
    }

    private var summaryHighlights: some View {
        VStack(alignment: .leading, spacing: 12) {
            highlightRow(
                title: "Current State",
                body: runner.currentTaskName == "Idle"
                    ? "Nothing is running yet. Finish the setup and start with a preview so the first real move is still non-destructive."
                    : runner.currentTaskName
            )

            highlightRow(
                title: "Plan",
                body: runner.plannedCount > 0
                    ? "\(abbreviatedCount(runner.plannedCount)) item\(runner.plannedCount == 1 ? "" : "s") are queued for the next transfer or preview review."
                    : "No transfer plan has been generated yet."
            )

            highlightRow(
                title: "Safety Check",
                body: issueCount > 0
                    ? "There are surfaced issues worth reviewing before you trust the outcome."
                    : "No active issues are currently surfaced by the backend."
            )
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if filteredLogLines.isEmpty {
                        Text(consoleEmptyStateText)
                            .font(.callout)
                            .foregroundStyle(inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(filteredLogLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(logLineColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .padding(18)
            }
            .frame(minHeight: 240)
            .background(Color.black.opacity(0.90), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: filteredLogLines.count) { _ in
                guard !filteredLogLines.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(filteredLogLines.count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(inkPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(inkSecondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusPill(title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title)
                .fontWeight(.semibold)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.56), in: Capsule())
    }

    private func pathFieldRow(
        title: String,
        placeholder: String,
        path: Binding<String>,
        status: String,
        badge: String,
        badgeTint: Color,
        statusColor: Color,
        icon: String,
        shortcutHint: String,
        dropHint: String,
        isTargeted: Binding<Bool>,
        isMuted: Bool,
        action: @escaping () -> Void,
        dropAction: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(inkPrimary)
                fieldStatusBadge(text: badge, tint: badgeTint)
                Spacer()
                shortcutBadge(shortcutHint)
            }

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isTargeted.wrappedValue ? statusStyle.tint.opacity(0.16) : Color.white.opacity(0.72))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(statusStyle.tint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextField(placeholder, text: path)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .foregroundStyle(inkPrimary)

                    Text(status.isEmpty ? dropHint : status)
                        .font(.footnote)
                        .foregroundStyle(isTargeted.wrappedValue ? statusStyle.tint : statusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Choose", action: action)
                    .buttonStyle(.bordered)
                    .tint(statusStyle.tint)
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [
                        isTargeted.wrappedValue ? statusStyle.tint.opacity(0.14) : Color.white.opacity(0.72),
                        Color.white.opacity(0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        isTargeted.wrappedValue ? statusStyle.tint : Color.white.opacity(0.74),
                        style: StrokeStyle(
                            lineWidth: isTargeted.wrappedValue ? 2 : 1,
                            dash: path.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [7, 5] : []
                        )
                    )
            )
            .shadow(color: isTargeted.wrappedValue ? statusStyle.tint.opacity(0.12) : Color.clear, radius: 12, x: 0, y: 8)
            .opacity(isMuted ? 0.62 : 1.0)
            .onDrop(of: [UTType.fileURL], isTargeted: isTargeted, perform: dropAction)
        }
    }

    @ViewBuilder
    private var setupChecklistRow: some View {
        HStack(spacing: 8) {
            if usingProfile {
                setupToken(title: "Profile", value: profileName, isReady: true, tint: statusStyle.tint)
                setupToken(title: "Manual Paths", value: "Optional", isReady: false, tint: Color(red: 0.50, green: 0.56, blue: 0.65))
            } else {
                setupToken(title: "Source", value: sourceValid ? "Ready" : "Needed", isReady: sourceValid, tint: statusStyle.tint)
                setupToken(title: "Destination", value: destReady ? "Ready" : "Needed", isReady: destReady, tint: Color(red: 0.31, green: 0.48, blue: 0.84))
            }
        }
    }

    private func fieldStatusBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func setupToken(title: String, value: String, isReady: Bool, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isReady ? inkPrimary : inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (isReady ? tint.opacity(0.14) : Color.white.opacity(0.58)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func activityChip(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(inkPrimary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.58), in: Capsule())
    }

    private func filterChip(_ filter: ConsoleFilter) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                consoleFilter = filter
            }
        }) {
            Text(filter.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(consoleFilter == filter ? Color.white : inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    (consoleFilter == filter ? statusStyle.tint : Color.white.opacity(0.54)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func miniStatRow(_ stat: MiniStat) -> some View {
        HStack {
            Text(stat.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Spacer()
            Text(stat.value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(inkPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(stat.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func miniStatCard(_ stat: MiniStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Text(stat.value)
                .font(.headline.weight(.bold))
                .foregroundStyle(inkPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(stat.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ambientOrb(color: Color, size: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 82)
            .offset(x: offsetX, y: offsetY)
    }

    private func sourceDestinationSummary(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(statusStyle.tint)
                .padding(10)
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(inkSecondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(inkPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func phaseNode(index: Int) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(phaseFill(for: index))
                    .frame(width: 36, height: 36)
                    .shadow(color: index == runner.currentPhase ? statusStyle.tint.opacity(0.22) : Color.clear, radius: 12, x: 0, y: 8)
                Circle()
                    .stroke(Color.white.opacity(index <= runner.currentPhase ? 0.10 : 0.52), lineWidth: 1)
                    .frame(width: 36, height: 36)

                if index < runner.currentPhase {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(index == runner.currentPhase ? .white : inkSecondary)
                }
            }
            .scaleEffect(index == runner.currentPhase ? 1.06 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: runner.currentPhase)

            Text(phaseLabels[index])
                .font(.footnote.weight(index == runner.currentPhase ? .semibold : .regular))
                .foregroundStyle(index <= runner.currentPhase ? inkPrimary : inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 96)
        }
    }

    private func compactRailMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(inkPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func highlightRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(inkSecondary)
            Text(body)
                .font(.body)
                .foregroundStyle(inkPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepFill(isActive: Bool, isComplete: Bool) -> Color {
        if isComplete {
            return Color(red: 0.18, green: 0.64, blue: 0.39).opacity(0.10)
        }
        if isActive {
            return statusStyle.tint.opacity(0.10)
        }
        return Color.white.opacity(0.58)
    }

    private func stepStroke(isActive: Bool, isComplete: Bool) -> Color {
        if isComplete {
            return Color(red: 0.18, green: 0.64, blue: 0.39).opacity(0.16)
        }
        if isActive {
            return statusStyle.tint.opacity(0.18)
        }
        return Color.white.opacity(0.48)
    }

    private func stepSymbolTint(isActive: Bool, isComplete: Bool) -> Color {
        if isComplete {
            return Color(red: 0.18, green: 0.64, blue: 0.39)
        }
        if isActive {
            return statusStyle.tint
        }
        return Color(red: 0.42, green: 0.51, blue: 0.64)
    }

    private func startRun(dryRun: Bool) {
        guard canStart else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            activityPane = .summary
        }
        runner.start(
            source: sourcePath,
            dest: destPath,
            profile: profileName,
            isDryRun: dryRun,
            isFastDest: isFastDest,
            workers: numWorkers
        )
    }

    private func selectFolder(for binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func handleFolderDrop(_ providers: [NSItemProvider], into binding: Binding<String>) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?

            switch item {
            case let data as Data:
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            case let url as URL:
                droppedURL = url
            case let nsURL as NSURL:
                droppedURL = nsURL as URL
            case let text as String:
                droppedURL = URL(string: text)
            default:
                droppedURL = nil
            }

            guard let droppedURL, droppedURL.isFileURL else { return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: droppedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }

            DispatchQueue.main.async {
                binding.wrappedValue = droppedURL.path
            }
        }

        return true
    }

    private func openDestInFinder() {
        guard !runner.completedDest.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedDest))
    }

    private func openReport() {
        guard !runner.completedReport.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedReport))
    }

    private func openLogsFolder() {
        guard !runner.completedDest.isEmpty else { return }
        let logsPath = runner.completedDest + "/.organize_logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: logsPath))
    }

    private func isIssueLine(_ line: String) -> Bool {
        line.hasPrefix("ERROR:") || line.hasPrefix("⚠") || line.hasPrefix("WARNING:")
    }

    private var sourcePathStatusText: String {
        if sourcePath.isEmpty {
            return ""
        }
        return sourceValid ? "Source found and ready." : "Source path could not be found."
    }

    private var sourcePathStatusColor: Color {
        if sourcePath.isEmpty { return inkSecondary }
        return sourceValid ? Color(red: 0.18, green: 0.64, blue: 0.39) : Color(red: 0.82, green: 0.29, blue: 0.25)
    }

    private var destinationStatusText: String {
        if usingProfile {
            return "Manual destination is ignored while a profile is active."
        }
        if destPath.isEmpty {
            return ""
        }
        return "Files will be arranged into date-based folders here."
    }

    private var destinationStatusColor: Color {
        usingProfile ? inkSecondary : inkSecondary
    }

    private var actionFootnote: String {
        if runner.isRunning {
            return "The run is underway. Follow the plan, progress, and console activity from the workspace."
        }
        if usingProfile {
            return "This run will use the saved profile named “\(profileName)”."
        }
        return "Preview is non-destructive. Transfer leaves the source untouched and keeps a persisted queue for resuming."
    }

    private var actionCardTitle: String {
        if usingProfile {
            return "Profile Ready"
        }
        if sourceValid && destReady {
            return "Ready To Run"
        }
        return "Start Here"
    }

    private var actionCardSubtitle: String {
        if usingProfile {
            return "Your saved setup can be previewed immediately, then transferred when you are satisfied."
        }
        if sourceValid && destReady {
            return "Everything required for a safe preview is in place."
        }
        if sourceValid || destReady {
            return "One more setup step and you are ready to preview the plan."
        }
        return "Choose the library and destination first. The preview is the recommended first move."
    }

    private var sourcePathBadgeText: String {
        if sourcePath.isEmpty {
            return "Required"
        }
        return sourceValid ? "Ready" : "Missing"
    }

    private var sourcePathBadgeTint: Color {
        if sourcePath.isEmpty {
            return inkSecondary
        }
        return sourceValid ? Color(red: 0.18, green: 0.64, blue: 0.39) : Color(red: 0.82, green: 0.29, blue: 0.25)
    }

    private var destinationBadgeText: String {
        if usingProfile {
            return "Optional"
        }
        if destPath.isEmpty {
            return "Required"
        }
        return "Ready"
    }

    private var destinationBadgeTint: Color {
        if usingProfile || destPath.isEmpty {
            return inkSecondary
        }
        return statusStyle.tint
    }

    private var progressLabel: String {
        if runner.progress > 0 {
            return "\(Int((runner.progress * 100).rounded()))%"
        }
        return runner.isRunning ? "Starting" : "Waiting"
    }

    private var completionTitle: String {
        switch runner.completionStatus {
        case "finished":
            return "Library Organized"
        case "dry_run_finished":
            return "Preview Ready To Review"
        case "nothing_to_copy":
            return "Nothing Left To Do"
        case "cancelled":
            return "Run Paused"
        default:
            return "Run Complete"
        }
    }

    private var completionSubtitle: String {
        switch runner.completionStatus {
        case "finished":
            return "The transfer completed successfully. Open the destination, inspect the receipt, or review the logs."
        case "dry_run_finished":
            return "Your preview is ready. Inspect the report before starting the actual transfer."
        case "nothing_to_copy":
            return "Everything relevant for this run is already present in the destination."
        case "cancelled":
            return "The current state is preserved, so you can inspect the partial outcome and resume when ready."
        default:
            return "The run has finished."
        }
    }

    private var completionLeadValue: String {
        switch runner.completionStatus {
        case "finished":
            return abbreviatedCount(runner.copiedCount)
        case "dry_run_finished":
            return abbreviatedCount(runner.plannedCount)
        case "nothing_to_copy":
            return abbreviatedCount(runner.alreadyInDestinationCount)
        case "cancelled":
            return abbreviatedCount(runner.copiedCount)
        default:
            return abbreviatedCount(runner.copiedCount)
        }
    }

    private var completionLeadLabel: String {
        switch runner.completionStatus {
        case "finished":
            return "Copied"
        case "dry_run_finished":
            return "Planned"
        case "nothing_to_copy":
            return "Already Present"
        case "cancelled":
            return "Copied Before Pause"
        default:
            return "Completed"
        }
    }

    private var consoleEmptyStateText: String {
        switch consoleFilter {
        case .all:
            return "The console will appear here once the backend begins emitting activity."
        case .issues:
            return "No warnings or errors match the current filter."
        case .events:
            return "No non-issue events match the current filter."
        }
    }

    private func summaryPath(_ path: String, emptyLabel: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? emptyLabel : trimmed
    }

    private func phaseFill(for index: Int) -> Color {
        if index < runner.currentPhase {
            return statusStyle.tint
        }
        if index == runner.currentPhase {
            return statusStyle.tint.opacity(0.88)
        }
        return Color.white.opacity(0.74)
    }

    private func logLineColor(_ line: String) -> Color {
        if line.hasPrefix("ERROR:") {
            return Color(red: 1.0, green: 0.53, blue: 0.50)
        }
        if line.hasPrefix("⚠") || line.hasPrefix("WARNING:") {
            return Color(red: 0.98, green: 0.78, blue: 0.35)
        }
        if line.hasPrefix("ℹ") {
            return Color(red: 0.63, green: 0.78, blue: 1.0)
        }
        return Color(red: 0.89, green: 0.92, blue: 0.95)
    }

    private func formatETA(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(value % 60)s" }
        return "\(value / 3600)h \(value % 3600 / 60)m"
    }

    private func abbreviatedCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

#Preview {
    ContentView()
        .frame(width: 1360, height: 900)
}
