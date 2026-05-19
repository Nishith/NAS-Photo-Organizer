#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct HealthDashboardView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var healthStore: LibraryHealthStore

    init(appState: AppState) {
        self.appState = appState
        self._healthStore = ObservedObject(wrappedValue: appState.libraryHealthStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                DetailHeroCard(
                    title: "Library Health",
                    message: heroMessage,
                    badgeTitle: badgeTitle,
                    badgeSystemImage: badgeSymbol,
                    tint: badgeTint,
                    systemImage: "heart.text.square"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        SummaryLine(title: "Destination", value: destinationSummary)
                        SummaryLine(title: "Last Check", value: lastCheckSummary)
                    }
                } actions: {
                    Button {
                        Task { await appState.refreshLibraryHealth() }
                    } label: {
                        Label(healthStore.isRefreshing ? "Checking..." : "Check Library", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(healthStore.isRefreshing)
                    .accessibilityIdentifier("refreshLibraryHealthButton")
                }

                if healthStore.isRefreshing {
                    ProgressView("Checking library health...")
                }

                if let summary = healthStore.summary {
                    LibraryHealthHero(summary: summary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(summary.cards) { card in
                            HealthCardView(card: card, appState: appState)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No Health Check Yet",
                        message: "Run a check to see destination readiness, unknown dates, duplicates, interrupted work, and structure drift.",
                        systemImage: "heart.text.square",
                        actionLabel: "Check Library",
                        action: { Task { await appState.refreshLibraryHealth() } }
                    )
                }
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .darkroom()
        .navigationTitle("Health")
        .task {
            // Only auto-refresh on first reach when there's no prior
            // outcome to display. A previous refresh that failed should
            // surface its error and let the user retry explicitly via
            // the "Check Library" button, not silently re-fire on every
            // navigation tap.
            if healthStore.summary == nil && healthStore.errorMessage == nil {
                await appState.refreshLibraryHealth()
            }
        }
    }

    private var heroMessage: String {
        switch healthStore.summary?.overallSeverity {
        case .good:
            return "The destination looks ready. Use the recommendations below for routine review."
        case .critical:
            return "A few items need attention before the next clean run."
        case .attention:
            return "Chronoframe found useful cleanup and review opportunities."
        case nil:
            return "Check the destination for readiness, cleanup opportunities, and safe next actions."
        }
    }

    private var badgeTitle: String {
        switch healthStore.summary?.overallSeverity {
        case .good:
            return "Healthy"
        case .critical:
            return "Needs Attention"
        case .attention:
            return "Review"
        case nil:
            return "Not Checked"
        }
    }

    private var badgeSymbol: String {
        switch healthStore.summary?.overallSeverity {
        case .good:
            return "checkmark.circle.fill"
        case .critical:
            return "exclamationmark.octagon.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        case nil:
            return "circle.dashed"
        }
    }

    private var badgeTint: Color {
        switch healthStore.summary?.overallSeverity {
        case .good:
            return DesignTokens.Status.ready
        case .critical:
            return DesignTokens.Color.danger
        case .attention:
            return DesignTokens.Color.warning
        case nil:
            return DesignTokens.Color.sky
        }
    }

    private var destinationSummary: String {
        if let destinationRoot = healthStore.summary?.destinationRoot, !destinationRoot.isEmpty {
            return destinationRoot
        }
        if !appState.setupStore.destinationPath.isEmpty {
            return appState.setupStore.destinationPath
        }
        return appState.historyStore.destinationRoot.isEmpty ? "Choose a destination in Setup" : appState.historyStore.destinationRoot
    }

    private var lastCheckSummary: String {
        guard let generatedAt = healthStore.summary?.generatedAt else {
            return "Not checked yet"
        }
        return generatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct HealthCardView: View {
    let card: LibraryHealthCard
    let appState: AppState

    var body: some View {
        MeridianSurfaceCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(card.title)
                        .font(DesignTokens.Typography.cardTitle)
                    Spacer()
                    Text(card.value)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(tint)
                }

                Text(card.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = card.action {
                    Button {
                        appState.performLibraryHealthAction(action)
                    } label: {
                        Label(action.title, systemImage: actionSymbol(action))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var tint: Color {
        switch card.severity {
        case .good:
            return DesignTokens.Status.ready
        case .attention:
            return DesignTokens.Color.warning
        case .critical:
            return DesignTokens.Color.danger
        }
    }

    private var symbol: String {
        switch card.severity {
        case .good:
            return "checkmark.circle"
        case .attention:
            return "exclamationmark.triangle"
        case .critical:
            return "exclamationmark.octagon"
        }
    }

    private func actionSymbol(_ action: LibraryHealthAction) -> String {
        switch action {
        case .runPreview:
            return "eye"
        case .reviewUnknownDates:
            return "calendar.badge.exclamationmark"
        case .runDeduplicate:
            return "rectangle.on.rectangle.angled"
        case .openHistory:
            return "clock.arrow.circlepath"
        case .reorganizeDestination:
            return "rectangle.3.offgrid"
        case .refreshDestinationIndex:
            return "arrow.clockwise"
        }
    }
}

/// Hero visualization above the card grid: a readiness dial on the left and
/// a severity breakdown bar on the right. Both derive from the same
/// `summary.cards` collection that drives the detail grid — no engine
/// extension required.
private struct LibraryHealthHero: View {
    let summary: LibraryHealthSummary

    private var counts: (good: Int, attention: Int, critical: Int) {
        var good = 0, attention = 0, critical = 0
        for card in summary.cards {
            switch card.severity {
            case .good: good += 1
            case .attention: attention += 1
            case .critical: critical += 1
            }
        }
        return (good, attention, critical)
    }

    private var total: Int {
        max(summary.cards.count, 1)
    }

    private var readyFraction: Double {
        Double(counts.good) / Double(total)
    }

    var body: some View {
        MeridianSurfaceCard(style: .section) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.lg) {
                readinessDial
                    .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text("Library shape")
                        .font(DesignTokens.Typography.label.weight(.medium))
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                        .tracking(0.8)
                        .textCase(.uppercase)

                    severityBar
                        .frame(height: 14)

                    HStack(spacing: 14) {
                        legend("Healthy", count: counts.good, tint: DesignTokens.ColorSystem.statusSuccess)
                        legend("Review", count: counts.attention, tint: DesignTokens.ColorSystem.statusWarning)
                        legend("Critical", count: counts.critical, tint: DesignTokens.ColorSystem.statusDanger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignTokens.Layout.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.card, style: .continuous)
                    .fill(DesignTokens.ColorSystem.imageStage.opacity(0.6))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Library shape: \(counts.good) healthy, \(counts.attention) needs review, \(counts.critical) critical")
    }

    private var readinessDial: some View {
        // Built from Circle.trim primitives rather than `SectorMark` so the
        // dial works on macOS 13 (SectorMark requires macOS 14).
        ZStack {
            // Track
            Circle()
                .stroke(DesignTokens.ColorSystem.hairline, lineWidth: 12)

            // Critical segment (starts at top, runs clockwise)
            dialSegment(start: 0, fraction: criticalFraction, tint: DesignTokens.ColorSystem.statusDanger)
            // Attention segment
            dialSegment(start: criticalFraction, fraction: attentionFraction, tint: DesignTokens.ColorSystem.statusWarning)
            // Healthy segment
            dialSegment(start: criticalFraction + attentionFraction, fraction: readyFraction, tint: DesignTokens.ColorSystem.statusSuccess)

            VStack(spacing: 2) {
                Text(percentString)
                    .font(DesignTokens.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                    .contentTransition(.numericText())
                Text("Healthy")
                    .font(DesignTokens.Typography.label)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            }
        }
        .padding(6)
    }

    private func dialSegment(start: Double, fraction: Double, tint: Color) -> some View {
        Circle()
            .trim(from: start, to: start + fraction)
            .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
            .rotationEffect(.degrees(-90)) // start at 12 o'clock
    }

    private var attentionFraction: Double {
        Double(counts.attention) / Double(total)
    }

    private var criticalFraction: Double {
        Double(counts.critical) / Double(total)
    }

    private var severityBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                if counts.good > 0 {
                    severitySegment(
                        width: geo.size.width * Double(counts.good) / Double(total),
                        tint: DesignTokens.ColorSystem.statusSuccess
                    )
                }
                if counts.attention > 0 {
                    severitySegment(
                        width: geo.size.width * Double(counts.attention) / Double(total),
                        tint: DesignTokens.ColorSystem.statusWarning
                    )
                }
                if counts.critical > 0 {
                    severitySegment(
                        width: geo.size.width * Double(counts.critical) / Double(total),
                        tint: DesignTokens.ColorSystem.statusDanger
                    )
                }
            }
            .clipShape(Capsule())
        }
    }

    private func severitySegment(width: CGFloat, tint: Color) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: max(width - 2, 4))
    }

    private func legend(_ label: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text("\(count) \(label.lowercased())")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                .monospacedDigit()
        }
    }

    private var percentString: String {
        let pct = Int((readyFraction * 100).rounded())
        return "\(pct)%"
    }
}
