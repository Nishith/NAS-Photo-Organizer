#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI
import UniformTypeIdentifiers

private enum SetupStepState {
    case ready(String)
    case active(String)
    case needed(String)

    var title: String {
        switch self {
        case let .ready(title), let .active(title), let .needed(title):
            return title
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .ready:
            return DesignTokens.Status.success
        case .active:
            return DesignTokens.Status.ready
        case .needed:
            return DesignTokens.Status.warning
        }
    }
}

struct SetupView: View {
    let appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var preferencesStore: PreferencesStore
    @ObservedObject private var runSessionStore: RunSessionStore
    @State private var isDropTargeted = false

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                heroCard
                savedSetupCard
                sourceSetupCard
                destinationSetupCard
                runReadinessCard
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.setupMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Setup")
    }

    private var heroCard: some View {
        DetailHeroCard(
            eyebrow: "Meridian Workflow",
            title: "Set Up Your Library",
            message: "Choose where files come from, where organized copies should go, and preview before anything is transferred.",
            badgeTitle: heroBadgeTitle,
            badgeSystemImage: heroBadgeSymbol,
            tint: heroTint,
            systemImage: "photo.on.rectangle.angled",
            usesBrandMark: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SummaryLine(title: "Source", value: sourceSummaryValue, valueColor: sourceStepState.tint)
                SummaryLine(title: "Destination", value: destinationSummaryValue, valueColor: destinationStepState.tint)
                SummaryLine(title: "Mode", value: modeSummaryValue)
                SummaryLine(title: "Next", value: nextStepSummary, valueColor: heroTint)
            }
        } actions: {
            Button(action: performHeroPrimaryAction) {
                Label(heroActionTitle, systemImage: heroActionSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(heroActionDisabled)
        }
    }

    private var savedSetupCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        eyebrow: "Saved Setup",
                        title: "Profiles for Repeatable Runs",
                        message: "Use a saved source and destination pair when you want the app and CLI to stay in sync."
                    )

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: setupStore.usingProfile ? "Active" : "Optional",
                        systemImage: setupStore.usingProfile ? "checkmark.circle.fill" : "bookmark",
                        tint: setupStore.usingProfile ? DesignTokens.Status.success : DesignTokens.Status.idle
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        profilePickerSection
                        Spacer(minLength: 12)
                        profileActions
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        profilePickerSection
                        profileActions
                    }
                }

                if setupStore.usingProfile, let profile = setupStore.activeProfile {
                    MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.sky) {
                        VStack(alignment: .leading, spacing: 12) {
                            SummaryLine(title: "Selected", value: profile.name)
                            SummaryLine(title: "Source", value: profile.sourcePath)
                            SummaryLine(title: "Destination", value: profile.destinationPath)
                        }
                    }
                } else {
                    Text("Manual paths stay available below, then you can save them as a profile once the setup feels right.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profilePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Profile")
                .font(.subheadline.weight(.semibold))

            Picker(
                "Profile",
                selection: Binding(
                    get: { setupStore.selectedProfileName },
                    set: { selection in
                        if selection.isEmpty {
                            appState.clearSelectedProfile()
                        } else {
                            appState.useProfile(named: selection)
                        }
                    }
                )
            ) {
                Text("Manual Paths").tag("")
                ForEach(setupStore.profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("profilePicker")
            .accessibilityLabel("Profile")
        }
    }

    private var profileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button("Refresh Profiles") {
                    appState.refreshProfiles()
                }

                Button("Manage Profiles") {
                    appState.selection = .profiles
                }

                if setupStore.usingProfile {
                    Button("Clear Selection") {
                        appState.clearSelectedProfile()
                    }
                }
            }

            Menu("Profile Actions") {
                Button("Refresh Profiles") {
                    appState.refreshProfiles()
                }

                Button("Manage Profiles") {
                    appState.selection = .profiles
                }

                if setupStore.usingProfile {
                    Button("Clear Selection") {
                        appState.clearSelectedProfile()
                    }
                }
            }
        }
    }

    private var sourceSetupCard: some View {
        setupStepCard(
            stepTitle: "1. Choose Your Source",
            message: "Point Chronoframe at the library you want to organize. Dragging files or folders in is treated as a first-class source path.",
            stepState: sourceStepState
        ) {
            VStack(alignment: .leading, spacing: 12) {
                dropZone

                sourcePathCard
            }
        }
    }

    private var sourcePathCard: some View {
        MeridianSurfaceCard(style: .inner, tint: sourceStepState.tint) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        PathValueView(
                            title: "Manual Folder Source",
                            value: displayedSourcePath,
                            helper: setupStore.usingDroppedSource
                                ? "Dragged items are staged safely as links. Choose a folder here if you want to switch back to a normal source."
                                : "Chronoframe reads from this library and never mutates the originals."
                        )

                        Spacer(minLength: 12)

                        Button("Choose Source…") {
                            Task { await appState.chooseSourceFolder() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        PathValueView(
                            title: "Manual Folder Source",
                            value: displayedSourcePath,
                            helper: setupStore.usingDroppedSource
                                ? "Dragged items are staged safely as links. Choose a folder here if you want to switch back to a normal source."
                                : "Chronoframe reads from this library and never mutates the originals."
                        )

                        Button("Choose Source…") {
                            Task { await appState.chooseSourceFolder() }
                        }
                    }
                }
            }
        }
    }

    private var destinationSetupCard: some View {
        setupStepCard(
            stepTitle: "2. Choose Your Destination",
            message: "This is where organized copies, receipts, reports, and queue state will be written. The destination becomes the audit trail for each run.",
            stepState: destinationStepState
        ) {
            MeridianSurfaceCard(style: .inner, tint: destinationStepState.tint) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        PathValueView(
                            title: "Destination Folder",
                            value: setupStore.destinationPath,
                            helper: "Chronoframe writes organized files and supporting artifacts here."
                        )

                        Spacer(minLength: 12)

                        Button("Choose Destination…") {
                            Task { await appState.chooseDestinationFolder() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        PathValueView(
                            title: "Destination Folder",
                            value: setupStore.destinationPath,
                            helper: "Chronoframe writes organized files and supporting artifacts here."
                        )

                        Button("Choose Destination…") {
                            Task { await appState.chooseDestinationFolder() }
                        }
                    }
                }
            }
        }
    }

    private var runReadinessCard: some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(
                        eyebrow: "Run Readiness",
                        title: "Preview First, Transfer When Confident",
                        message: "The preview is the trust-building step. Review what Chronoframe plans to copy before starting the transfer."
                    )

                    Spacer(minLength: 12)

                    MeridianStatusBadge(
                        title: canStartRun ? "Ready to Preview" : "Needs Setup",
                        systemImage: canStartRun ? "eye.fill" : "exclamationmark.circle",
                        tint: canStartRun ? DesignTokens.Status.ready : DesignTokens.Status.warning
                    )
                }

                MeridianSurfaceCard(style: .inner, tint: DesignTokens.Color.amber) {
                    VStack(alignment: .leading, spacing: 12) {
                        SummaryLine(title: "Configuration", value: configurationSummary)
                        SummaryLine(title: "Performance", value: performanceSummary)
                        SummaryLine(title: "Safety", value: safetySummary)
                    }
                }

                Text(canStartRun
                     ? "Preview is non-destructive. Transfer still requires an explicit confirmation before the backend begins copying."
                     : "Complete the source and destination, or pick a saved profile, and Chronoframe will guide you into a safe preview.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        previewButton
                        transferButton
                        Button("Adjust Settings…") {
                            appState.openSettingsWindow()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        previewButton
                        transferButton
                        Button("Adjust Settings…") {
                            appState.openSettingsWindow()
                        }
                    }
                }
            }
        }
    }

    private func setupStepCard<Content: View>(
        stepTitle: String,
        message: String,
        stepState: SetupStepState,
        @ViewBuilder content: () -> Content
    ) -> some View {
        MeridianSurfaceCard {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.cardSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeading(title: stepTitle, message: message)
                    Spacer(minLength: 12)
                    MeridianStatusBadge(title: stepState.title, tint: stepState.tint)
                }

                content()
            }
        }
    }

    private var dropZone: some View {
        let active = setupStore.usingDroppedSource

        return MeridianSurfaceCard(style: .inner, tint: isDropTargeted ? DesignTokens.Color.sky : DesignTokens.Color.cloud) {
            VStack(spacing: 10) {
                MeridianLeadIcon(
                    systemImage: active ? "photo.on.rectangle.angled" : "square.and.arrow.down.on.square",
                    tint: isDropTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkMuted
                )

                if active {
                    Text(setupStore.droppedSourceLabel ?? "Dropped items ready")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.Color.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("Chronoframe will organize the staged items as the source while keeping the originals untouched.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(isDropTargeted ? "Release to use these items as the source" : "Drag photos, videos, or folders here")
                        .font(.headline)
                        .foregroundStyle(isDropTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkPrimary)

                    Text("This is the fastest way to start a one-off import. You can still choose a normal folder source below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.innerCard, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? DesignTokens.Color.sky : DesignTokens.Color.inkMuted.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.innerCard, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .accessibilityLabel("Drop photos, videos, or folders to use as source")
        .accessibilityIdentifier("dropZone")
    }

    private var previewButton: some View {
        Button {
            Task { await appState.startPreview() }
        } label: {
            Label("Preview", systemImage: "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStartRun || runSessionStore.isRunning)
        .accessibilityIdentifier("previewButton")
        .accessibilityLabel("Preview")
        .accessibilityHint(canStartRun ? "Generates a copy plan without moving any files" : "Choose both folders or a saved profile first")
    }

    private var transferButton: some View {
        Button {
            Task { await appState.startTransfer() }
        } label: {
            Label("Transfer", systemImage: "arrow.right.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!canStartRun || runSessionStore.isRunning)
        .accessibilityIdentifier("transferButton")
        .accessibilityLabel("Transfer")
        .accessibilityHint(canStartRun ? "Copies files from the source to the destination after confirmation" : "Choose both folders or a saved profile first")
    }

    private var canStartRun: Bool {
        appState.canStartRun
    }

    private var displayedSourcePath: String {
        if setupStore.usingDroppedSource {
            return setupStore.droppedSourceLabel ?? setupStore.sourcePath
        }
        return setupStore.sourcePath
    }

    private var sourceStepState: SetupStepState {
        if setupStore.usingDroppedSource || !setupStore.sourcePath.isEmpty {
            return .ready(setupStore.usingDroppedSource ? "Dropped Source Ready" : "Source Ready")
        }
        return .needed("Source Needed")
    }

    private var destinationStepState: SetupStepState {
        if !setupStore.destinationPath.isEmpty {
            return .ready("Destination Ready")
        }
        return .needed("Destination Needed")
    }

    private var heroTint: SwiftUI.Color {
        if canStartRun {
            return DesignTokens.Status.ready
        }
        if setupStore.usingDroppedSource || !setupStore.sourcePath.isEmpty || !setupStore.destinationPath.isEmpty {
            return DesignTokens.Status.warning
        }
        return DesignTokens.Status.idle
    }

    private var heroBadgeTitle: String {
        if setupStore.usingProfile {
            return "Profile Ready"
        }
        if canStartRun {
            return "Ready to Preview"
        }
        if setupStore.usingDroppedSource || !setupStore.sourcePath.isEmpty || !setupStore.destinationPath.isEmpty {
            return "Continue Setup"
        }
        return "Start Here"
    }

    private var heroBadgeSymbol: String {
        if canStartRun {
            return "checkmark.circle.fill"
        }
        if setupStore.usingDroppedSource {
            return "square.and.arrow.down.on.square.fill"
        }
        return "circle.dashed"
    }

    private var sourceSummaryValue: String {
        if setupStore.usingDroppedSource {
            if setupStore.droppedSourceItemCount > 0 {
                return "\(setupStore.droppedSourceItemCount) dragged item\(setupStore.droppedSourceItemCount == 1 ? "" : "s")"
            }
            return "Dragged items ready"
        }
        if let profile = setupStore.activeProfile {
            return profile.sourcePath
        }
        return setupStore.sourcePath.isEmpty ? "Needed" : "Ready"
    }

    private var destinationSummaryValue: String {
        if let profile = setupStore.activeProfile {
            return profile.destinationPath
        }
        return setupStore.destinationPath.isEmpty ? "Needed" : "Ready"
    }

    private var modeSummaryValue: String {
        if setupStore.usingProfile {
            return "Saved profile: \(setupStore.selectedProfileName)"
        }
        if setupStore.usingDroppedSource {
            return "One-off dragged source"
        }
        return "Manual source and destination"
    }

    private var nextStepSummary: String {
        if setupStore.sourcePath.isEmpty {
            return "Choose or drop a source"
        }
        if setupStore.destinationPath.isEmpty {
            return "Choose a destination"
        }
        return "Preview the plan"
    }

    private var configurationSummary: String {
        if setupStore.usingProfile {
            return "Using the saved profile \(setupStore.selectedProfileName)"
        }
        return setupStore.usingDroppedSource ? "Manual destination with dragged source" : "Manual source and destination"
    }

    private var performanceSummary: String {
        [
            "\(preferencesStore.workerCount) workers",
            preferencesStore.useFastDestinationScan ? "cached destination scan" : "full destination scan",
        ]
        .joined(separator: " • ")
    }

    private var safetySummary: String {
        preferencesStore.verifyCopies
            ? "Verification is enabled after copy"
            : "Verification is disabled for faster throughput"
    }

    private var heroActionTitle: String {
        if setupStore.sourcePath.isEmpty {
            return "Choose Source"
        }
        if setupStore.destinationPath.isEmpty {
            return "Choose Destination"
        }
        return "Preview Plan"
    }

    private var heroActionSymbol: String {
        if setupStore.sourcePath.isEmpty {
            return "folder.badge.plus"
        }
        if setupStore.destinationPath.isEmpty {
            return "externaldrive.badge.plus"
        }
        return "eye"
    }

    private var heroActionDisabled: Bool {
        runSessionStore.isRunning
    }

    private func performHeroPrimaryAction() {
        if setupStore.sourcePath.isEmpty {
            Task { await appState.chooseSourceFolder() }
            return
        }
        if setupStore.destinationPath.isEmpty {
            Task { await appState.chooseDestinationFolder() }
            return
        }
        Task { await appState.startPreview() }
    }

    /// Pulls file URLs out of drop providers and forwards them to AppState.
    /// Returns `true` as soon as at least one file URL is being resolved so
    /// the UI shows an accepted drop; AppState reports any errors once
    /// resolution completes.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            await appState.applyDrop(urls: urls)
        }
        return true
    }

    /// Decodes a file URL from a drop item provider. Drops deliver the URL as
    /// a bookmark `Data` blob under the `public.file-url` type.
    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }
                if let string = item as? String,
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
