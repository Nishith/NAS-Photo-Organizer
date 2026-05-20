#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import Charts
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
                    LibraryHealthOverview(summary: summary)

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

/// At-a-glance "library shape": a spectrum bar where each health area is one
/// segment colored by its severity, anchored by a big "N of M areas healthy"
/// metric. Reads directly from the existing summary — no engine change — and
/// uses only macOS 13-safe Chart marks (BarMark).
private struct LibraryHealthOverview: View {
    let summary: LibraryHealthSummary

    private var healthyCount: Int {
        summary.cards.filter { $0.severity == .good }.count
    }

    private var totalCount: Int { summary.cards.count }

    var body: some View {
        MeridianSurfaceCard(style: .section) {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                SectionHeading(
                    eyebrow: "Overview",
                    title: "Library Shape",
                    message: "How each area of your destination is holding up right now."
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
                        metric
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                            spectrumBar
                            legend
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                        metric
                        spectrumBar
                        legend
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Library shape: \(healthyCount) of \(totalCount) areas healthy")
    }

    private var metric: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(healthyCount)")
                    .font(DesignTokens.Typography.display)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                Text("/ \(totalCount)")
                    .font(DesignTokens.Typography.title)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
            }
            Text("AREAS HEALTHY")
                .font(DesignTokens.Typography.label)
                .tracking(0.8)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
        }
        .fixedSize()
    }

    private var spectrumBar: some View {
        Chart(summary.cards) { card in
            BarMark(
                x: .value("Weight", 1),
                y: .value("Health", "library"),
                height: .fixed(16)
            )
            .foregroundStyle(color(for: card.severity))
            .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        FlowLegend(cards: summary.cards, color: color(for:))
    }

    private func color(for severity: LibraryHealthSeverity) -> Color {
        switch severity {
        case .good:
            return DesignTokens.ColorSystem.statusSuccess
        case .attention:
            return DesignTokens.ColorSystem.statusWarning
        case .critical:
            return DesignTokens.ColorSystem.statusDanger
        }
    }
}

/// Wrapping legend of health areas with a severity dot per area.
private struct FlowLegend: View {
    let cards: [LibraryHealthCard]
    let color: (LibraryHealthSeverity) -> Color

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(cards) { card in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(card.severity))
                        .frame(width: 7, height: 7)
                    Text(card.title)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
            }
        }
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
