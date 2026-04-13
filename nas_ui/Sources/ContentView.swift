import SwiftUI
import AppKit

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
    @State private var showingConsole = false

    private var sourceValid: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }

    private var destReady: Bool {
        !destPath.isEmpty
    }

    private var usingProfile: Bool {
        !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        !runner.isRunning && (usingProfile || (sourceValid && destReady))
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
        runner.isRunning || hasOutcomeData || showingConsole
    }

    private var workflowSteps: [WorkflowStep] {
        [
            WorkflowStep(
                title: "Choose your source",
                body: "Point the app at the library you want to organize, or reveal a saved profile for repeatable setups.",
                symbol: "folder.badge.plus"
            ),
            WorkflowStep(
                title: "Preview the plan",
                body: "Run a non-destructive preview first so you can inspect what will be copied, skipped, or flagged.",
                symbol: "eye"
            ),
            WorkflowStep(
                title: "Start the transfer",
                body: "When the plan looks right, begin the transfer and monitor progress, issues, and receipts from the workspace.",
                symbol: "arrow.right.circle"
            ),
        ]
    }

    private var statusStyle: StatusStyle {
        if runner.isRunning {
            return StatusStyle(
                title: runner.currentTaskName,
                subtitle: runner.progress > 0
                    ? "The organizer is actively moving through your library. You can monitor progress here without digging through logs."
                    : "Preparing the run and validating the next step.",
                badge: "Running",
                symbol: "arrow.triangle.2.circlepath",
                tint: Color(red: 0.10, green: 0.46, blue: 0.86)
            )
        }

        switch runner.completionStatus {
        case "dry_run_finished":
            return StatusStyle(
                title: "Preview Ready",
                subtitle: "Review the plan before you commit any transfers. Nothing has been copied yet.",
                badge: "Preview",
                symbol: "eye.fill",
                tint: Color(red: 0.16, green: 0.53, blue: 0.47)
            )
        case "finished":
            return StatusStyle(
                title: "Transfer Complete",
                subtitle: "Your library has been organized and the run artifacts are ready to inspect.",
                badge: "Complete",
                symbol: "checkmark.circle.fill",
                tint: Color(red: 0.18, green: 0.60, blue: 0.38)
            )
        case "nothing_to_copy":
            return StatusStyle(
                title: "Already Up to Date",
                subtitle: "The destination already contains everything this run needs.",
                badge: "No Action",
                symbol: "checkmark.seal.fill",
                tint: Color(red: 0.31, green: 0.47, blue: 0.84)
            )
        case "cancelled":
            return StatusStyle(
                title: "Run Cancelled",
                subtitle: "The operation stopped before completion. You can review activity below and resume when ready.",
                badge: "Paused",
                symbol: "pause.circle.fill",
                tint: Color(red: 0.75, green: 0.48, blue: 0.11)
            )
        default:
            return StatusStyle(
                title: "Prepare Your Library",
                subtitle: "Choose a source and destination, preview the changes, then start the transfer when the plan looks right.",
                badge: "Ready",
                symbol: "photo.on.rectangle.angled",
                tint: Color(red: 0.14, green: 0.39, blue: 0.76)
            )
        }
    }

    private var metrics: [MetricItem] {
        [
            MetricItem(
                title: "Discovered",
                value: abbreviatedCount(runner.discoveredCount),
                caption: "Items found in the source",
                symbol: "photo.stack.fill",
                tint: Color(red: 0.17, green: 0.46, blue: 0.84)
            ),
            MetricItem(
                title: "Planned",
                value: abbreviatedCount(runner.plannedCount),
                caption: runner.completionStatus == "dry_run_finished" ? "Ready to review" : "Queued for transfer",
                symbol: "square.and.arrow.down.on.square.fill",
                tint: Color(red: 0.18, green: 0.60, blue: 0.38)
            ),
            MetricItem(
                title: "Already Organized",
                value: abbreviatedCount(runner.alreadyInDestinationCount),
                caption: "Skipped because they already exist",
                symbol: "checkmark.circle",
                tint: Color(red: 0.33, green: 0.47, blue: 0.84)
            ),
            MetricItem(
                title: "Duplicates",
                value: abbreviatedCount(runner.duplicateCount),
                caption: "Routed to duplicate review",
                symbol: "square.on.square",
                tint: Color(red: 0.74, green: 0.44, blue: 0.12)
            ),
            MetricItem(
                title: "Issues",
                value: abbreviatedCount(max(runner.errorCount, runner.hashErrorCount + runner.failedCount)),
                caption: "Warnings, failed copies, or hash issues",
                symbol: "exclamationmark.triangle.fill",
                tint: Color(red: 0.78, green: 0.23, blue: 0.22)
            ),
            MetricItem(
                title: "Completed",
                value: abbreviatedCount(runner.copiedCount),
                caption: "Files copied successfully",
                symbol: "checkmark.circle.fill",
                tint: Color(red: 0.18, green: 0.60, blue: 0.38)
            ),
        ]
    }

    private var bodyGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.98, blue: 0.99),
                Color(red: 0.94, green: 0.96, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        .alert(isPresented: $runner.showingPrompt) {
            Alert(
                title: Text("Confirm Transfer"),
                message: Text(runner.promptMessage),
                primaryButton: .default(Text("Continue")) { runner.answerPrompt(yes: true) },
                secondaryButton: .cancel(Text("Cancel")) { runner.answerPrompt(yes: false) }
            )
        }
        .onChange(of: runner.isRunning) { isRunning in
            withAnimation(.easeInOut(duration: 0.25)) {
                if isRunning {
                    showingConsole = true
                }
            }
        }
    }

    private var backgroundAtmosphere: some View {
        ZStack {
            ambientOrb(
                color: statusStyle.tint.opacity(0.18),
                size: 420,
                offsetX: -420,
                offsetY: -260
            )
            ambientOrb(
                color: Color(red: 0.96, green: 0.72, blue: 0.48).opacity(0.16),
                size: 360,
                offsetX: 420,
                offsetY: -300
            )
            ambientOrb(
                color: Color(red: 0.56, green: 0.77, blue: 0.94).opacity(0.12),
                size: 320,
                offsetX: 360,
                offsetY: 260
            )
        }
        .allowsHitTesting(false)
    }

    private var controlRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                appIdentityCard
                if runner.isRunning {
                    liveRunRailCard
                } else {
                    actionCard
                    sourceDestinationCard
                    if shouldShowAdvancedCard {
                        advancedCard
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 304)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 24, x: 0, y: 14)
    }

    private var appIdentityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAS Organizer")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Preview and organize large photo libraries with calm, auditable control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.title2)
                    .foregroundStyle(statusStyle.tint)
                    .padding(10)
                    .background(statusStyle.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text("Preview first. Transfer when confident.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var sourceDestinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Setup", subtitle: "Choose the source and destination. Saved profiles stay tucked away until needed.")

            pathFieldRow(
                title: "Source Library",
                placeholder: "Choose the folder to organize",
                path: $sourcePath,
                status: sourcePathStatusText,
                badge: sourcePathBadgeText,
                badgeTint: sourcePathBadgeTint,
                statusColor: sourcePathStatusColor,
                icon: "folder.fill.badge.plus",
                action: { selectFolder(for: $sourcePath) }
            )

            pathFieldRow(
                title: "Destination",
                placeholder: "Choose where organized files should go",
                path: $destPath,
                status: usingProfile ? "Ignored while a profile is active" : destinationStatusText,
                badge: destinationBadgeText,
                badgeTint: destinationBadgeTint,
                statusColor: usingProfile ? .secondary : .secondary,
                icon: "externaldrive.fill",
                action: { selectFolder(for: $destPath) }
            )

            DisclosureGroup(isExpanded: $showingProfileField) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Optional profile name", text: $profileName)
                        .textFieldStyle(.roundedBorder)

                    if usingProfile {
                        Label("This profile overrides the manual source and destination for the run.", systemImage: "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text("Saved Profile")
                        .font(.subheadline.weight(.semibold))
                    Button(action: { showingProfileHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingProfileHelp, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Profiles")
                                .font(.headline)
                            Text("Use a profile name to load saved source and destination paths from `nas_profiles.yaml`. When a profile is filled in, it takes priority over the manual fields above.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 280, alignment: .leading)
                        }
                        .padding(18)
                    }
                }
            }
        }
    }

    private var liveRunRailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Live Run", subtitle: "The essentials stay close at hand while the richer monitoring lives in the main workspace.")

            statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)

            sourceDestinationSummary(title: "Source", value: summaryPath(sourcePath, emptyLabel: "Using selected source"), icon: "folder")
            sourceDestinationSummary(title: "Destination", value: summaryPath(destPath, emptyLabel: "Using selected destination"), icon: "externaldrive")

            HStack(spacing: 10) {
                compactRailMetric(title: "Planned", value: abbreviatedCount(runner.plannedCount))
                compactRailMetric(title: "Done", value: abbreviatedCount(runner.copiedCount))
                compactRailMetric(title: "Issues", value: abbreviatedCount(max(runner.errorCount, runner.hashErrorCount + runner.failedCount)))
            }

            Button("Cancel Run", role: .destructive) { runner.cancel() }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.78, green: 0.23, blue: 0.22))
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: actionCardTitle, subtitle: actionCardSubtitle)

            setupChecklistRow

            if runner.isRunning {
                HStack(spacing: 12) {
                    statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)
                    Spacer()
                    Button("Cancel Run", role: .destructive) { runner.cancel() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.78, green: 0.23, blue: 0.22))
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(action: { startRun(dryRun: true) }) {
                            Label("Preview", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!canStart)

                        Button(action: { startRun(dryRun: false) }) {
                            Label("Transfer", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Color(red: 0.11, green: 0.45, blue: 0.83))
                        .disabled(!canStart)
                    }
                }
            }

            Text(actionFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    statusStyle.tint.opacity(0.10),
                    Color.white.opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 1)
        )
    }

    private var advancedCard: some View {
        DisclosureGroup(isExpanded: $showingAdvancedOptions) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $isFastDest) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Cached Destination Scan")
                        Text("Speeds up repeated previews by trusting the local destination cache.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Worker Threads")
                            .font(.subheadline.weight(.semibold))
                        Text("Tune parallel hashing for your storage and network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: $numWorkers, in: 1...32) {
                        Text("\(numWorkers)")
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 28)
                    }
                    .fixedSize()
                }
            }
            .padding(.top, 12)
        } label: {
            sectionHeader(title: "Advanced", subtitle: "Performance controls for repeated runs and slower storage.")
        }
    }

    private var mainWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                if shouldShowOperationalWorkspace {
                    metricsGrid
                    progressCard
                    activityCard
                } else {
                    onboardingCard
                }

                if !runner.isRunning && !runner.completedDest.isEmpty {
                    completionCard
                }
            }
            .frame(maxWidth: 1240, alignment: .top)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(title: "Getting Started", subtitle: "The quiet state stays focused. Set up the library, preview once, then let the workspace expand as the run progresses.")

            VStack(spacing: 12) {
                ForEach(Array(workflowSteps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(index == 0 ? statusStyle.tint.opacity(0.16) : Color.white.opacity(0.72))
                                .frame(width: 38, height: 38)
                            Image(systemName: step.symbol)
                                .foregroundStyle(index == 0 ? statusStyle.tint : Color(red: 0.39, green: 0.50, blue: 0.67))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(step.title)")
                                .font(.headline)
                            Text(step.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        index == 0 ? statusStyle.tint.opacity(0.08) : Color.white.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(index == 0 ? statusStyle.tint.opacity(0.12) : Color.white.opacity(0.42), lineWidth: 1)
                    )
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    statusPill(title: statusStyle.badge, symbol: statusStyle.symbol, tint: statusStyle.tint)

                    Text(statusStyle.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(statusStyle.subtitle)
                        .font(.title3.weight(.regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 10) {
                    quickMetric(value: progressLabel, label: "Overall Progress")
                    if runner.speedMBps > 0 || runner.etaSeconds > 0 {
                        Divider()
                            .frame(width: 120)
                        if runner.speedMBps > 0 {
                            quickMetric(value: String(format: "%.1f MB/s", runner.speedMBps), label: "Throughput")
                        }
                        if runner.etaSeconds > 0 {
                            quickMetric(value: formatETA(runner.etaSeconds), label: "Estimated Time")
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                sourceDestinationSummary(title: "Source", value: summaryPath(sourcePath, emptyLabel: usingProfile ? "Loaded from profile" : "Choose a source folder"), icon: "folder")
                sourceDestinationSummary(title: "Destination", value: summaryPath(destPath, emptyLabel: usingProfile ? "Loaded from profile" : "Choose a destination folder"), icon: "externaldrive")
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    statusStyle.tint.opacity(0.16),
                    Color.white.opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.22))
                .frame(width: 220, height: 140)
                .blur(radius: 10)
                .offset(x: 36, y: -36)
                .mask(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
        }
        .shadow(color: statusStyle.tint.opacity(0.16), radius: 24, x: 0, y: 12)
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
                            .padding(9)
                            .background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Spacer()
                        Text(metric.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(metric.value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(metric.value == "0" ? .secondary : .primary)

                    Text(metric.caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: metric.tint.opacity(0.08), radius: 16, x: 0, y: 10)
            }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(title: "Run Overview", subtitle: "The organizer moves through each phase with clear progress and safety checks.")

            HStack(spacing: 12) {
                ForEach(phaseLabels.indices, id: \.self) { index in
                    phaseNode(index: index)

                    if index < phaseLabels.count - 1 {
                        Capsule()
                            .fill(index < runner.currentPhase ? statusStyle.tint : Color.white.opacity(0.55))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: runner.progress)
                    .progressViewStyle(.linear)
                    .tint(statusStyle.tint)

                HStack {
                    Text(runner.currentTaskName)
                        .font(.headline)
                    Spacer()
                    if runner.errorCount > 0 {
                        Label("\(runner.errorCount) issue\(runner.errorCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 0.78, green: 0.23, blue: 0.22))
                    } else {
                        Text(progressLabel)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                sectionHeader(title: "Activity", subtitle: "A concise summary for humans, with the console available when you need every line.")
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingConsole.toggle() } }) {
                    Label(showingConsole ? "Hide Console" : "Show Console", systemImage: showingConsole ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.bordered)
            }

            summaryHighlights

            if showingConsole {
                logView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
    }

    private var completionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "After This Run", subtitle: "Open the organized destination or inspect the artifacts generated by the run.")

            HStack(spacing: 12) {
                Button(action: openDestInFinder) {
                    Label("Open Destination", systemImage: "folder.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(statusStyle.tint)

                if !runner.completedReport.isEmpty {
                    Button(action: openReport) {
                        Label("Open Report", systemImage: "doc.text.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: openLogsFolder) {
                    Label("Open Logs", systemImage: "tray.full.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
    }

    private var summaryHighlights: some View {
        VStack(alignment: .leading, spacing: 12) {
            highlightRow(
                title: "Current State",
                body: runner.currentTaskName == "Idle"
                    ? "Nothing is running yet. Set up the source and destination, then preview the plan."
                    : runner.currentTaskName
            )
            highlightRow(
                title: "Plan",
                body: runner.plannedCount > 0
                    ? "\(abbreviatedCount(runner.plannedCount)) item\(runner.plannedCount == 1 ? "" : "s") are ready for transfer."
                    : "No transfer plan has been generated yet."
            )
            highlightRow(
                title: "Safety Check",
                body: runner.errorCount > 0 || runner.hashErrorCount > 0 || runner.failedCount > 0
                    ? "There are issues worth reviewing before you trust the outcome."
                    : "No active issues are currently surfaced by the backend."
            )
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if runner.logLines.isEmpty {
                        Text("The console will appear here once the backend begins emitting activity.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(runner.logLines.indices, id: \.self) { index in
                            Text(runner.logLines[index])
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(logLineColor(runner.logLines[index]))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .padding(18)
            }
            .frame(minHeight: 220)
            .background(Color.black.opacity(0.90), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: runner.logLines.count) { _ in
                guard !runner.logLines.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(runner.logLines.count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

    private func pathFieldRow(
        title: String,
        placeholder: String,
        path: Binding<String>,
        status: String,
        badge: String,
        badgeTint: Color,
        statusColor: Color,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                fieldStatusBadge(text: badge, tint: badgeTint)
                Spacer()
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(statusStyle.tint)
                TextField(placeholder, text: path)
                    .textFieldStyle(.roundedBorder)
                Button("Choose", action: action)
                    .buttonStyle(.bordered)
            }
            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var setupChecklistRow: some View {
        HStack(spacing: 8) {
            if usingProfile {
                setupToken(title: "Profile", value: profileName, isReady: true)
                setupToken(title: "Manual Paths", value: "Optional", isReady: false)
            } else {
                setupToken(title: "Source", value: sourceValid ? "Ready" : "Needed", isReady: sourceValid)
                setupToken(title: "Destination", value: destReady ? "Ready" : "Needed", isReady: destReady)
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

    private func setupToken(title: String, value: String, isReady: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isReady ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (isReady ? statusStyle.tint.opacity(0.12) : Color.white.opacity(0.58)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func ambientOrb(color: Color, size: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 80)
            .offset(x: offsetX, y: offsetY)
    }

    private func sourceDestinationSummary(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(statusStyle.tint)
                .padding(9)
                .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func phaseNode(index: Int) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(phaseFill(for: index))
                    .frame(width: 34, height: 34)
                Circle()
                    .stroke(Color.white.opacity(index <= runner.currentPhase ? 0.1 : 0.5), lineWidth: 1)
                    .frame(width: 34, height: 34)

                if index < runner.currentPhase {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(index == runner.currentPhase ? .white : .secondary)
                }
            }

            Text(phaseLabels[index])
                .font(.footnote.weight(index == runner.currentPhase ? .semibold : .regular))
                .foregroundStyle(index <= runner.currentPhase ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 92)
        }
    }

    private func quickMetric(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func compactRailMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func highlightRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func startRun(dryRun: Bool) {
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
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func openDestInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedDest))
    }

    private func openReport() {
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedReport))
    }

    private func openLogsFolder() {
        let logsPath = runner.completedDest + "/.organize_logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: logsPath))
    }

    private var sourcePathStatusText: String {
        if sourcePath.isEmpty {
            return ""
        }
        return sourceValid ? "Source found and ready." : "Source path could not be found."
    }

    private var sourcePathStatusColor: Color {
        if sourcePath.isEmpty { return .secondary }
        return sourceValid ? Color(red: 0.18, green: 0.60, blue: 0.38) : Color(red: 0.78, green: 0.23, blue: 0.22)
    }

    private var destinationStatusText: String {
        if destPath.isEmpty {
            return ""
        }
        return "Files will be arranged into date-based folders here."
    }

    private var actionFootnote: String {
        if runner.isRunning {
            return "The run is underway. Follow the plan, progress, and console activity from the workspace."
        }
        if usingProfile {
            return "This run will use the saved profile named “\(profileName)”."
        }
        return "Preview is non-destructive. Transfer leaves the source untouched."
    }

    private var actionCardTitle: String {
        if usingProfile {
            return "Profile Ready"
        }
        if sourceValid && destReady {
            return "Ready to Run"
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
        return "Choose the library and destination first. Preview is the recommended first move."
    }

    private var sourcePathBadgeText: String {
        if sourcePath.isEmpty {
            return "Required"
        }
        return sourceValid ? "Ready" : "Missing"
    }

    private var sourcePathBadgeTint: Color {
        if sourcePath.isEmpty {
            return .secondary
        }
        return sourceValid ? Color(red: 0.18, green: 0.60, blue: 0.38) : Color(red: 0.78, green: 0.23, blue: 0.22)
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
            return .secondary
        }
        return statusStyle.tint
    }

    private var progressLabel: String {
        if runner.progress > 0 {
            return "\(Int((runner.progress * 100).rounded()))%"
        }
        return runner.isRunning ? "Starting" : "Waiting"
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
            return statusStyle.tint.opacity(0.85)
        }
        return Color.white.opacity(0.72)
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
        .frame(width: 1320, height: 860)
}
