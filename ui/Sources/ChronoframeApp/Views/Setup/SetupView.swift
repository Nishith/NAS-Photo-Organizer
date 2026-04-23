#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    let appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var preferencesStore: PreferencesStore
    @ObservedObject private var runSessionStore: RunSessionStore
    @State private var isDropTargeted = false
    @AppStorage("didOnboard") private var didOnboard = false

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    private var screenModel: SetupScreenModel {
        SetupScreenModel(
            setupStore: setupStore,
            preferencesStore: preferencesStore,
            isRunInProgress: runSessionStore.isRunning
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionSpacing) {
                SetupHeroSection(
                    model: screenModel,
                    primaryAction: performHeroPrimaryAction,
                    scrollToSource: {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("sourceSection", anchor: .top) }
                    },
                    scrollToDestination: {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("destinationSection", anchor: .top) }
                    }
                )

                if !didOnboard && setupStore.sourcePath.isEmpty {
                    OnboardingCard(onDismiss: { didOnboard = true })
                }

                SetupSourceStepSection(
                    model: screenModel,
                    dropZone: dropZone,
                    chooseSource: { Task { await appState.chooseSourceFolder() } }
                )
                .id("sourceSection")

                SetupDestinationStepSection(
                    model: screenModel,
                    chooseDestination: { Task { await appState.chooseDestinationFolder() } }
                )
                .id("destinationSection")

                if !setupStore.sourcePath.isEmpty {
                    SetupContactSheetSection(sourcePath: setupStore.sourcePath)
                }

                SetupSavedSetupSection(
                    model: screenModel,
                    setupStore: setupStore,
                    refreshProfiles: appState.refreshProfiles,
                    clearSelectedProfile: appState.clearSelectedProfile,
                    openProfiles: { appState.selection = .profiles },
                    onProfileSelection: handleProfileSelection(_:)
                )

                SetupReadinessSection(
                    model: screenModel,
                    preview: { Task { await appState.startPreview() } },
                    transfer: { Task { await appState.startTransfer() } },
                    openSettings: appState.openSettingsWindow,
                    isRunInProgress: runSessionStore.isRunning
                )
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.setupMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .darkroom()
        .navigationTitle("Setup")
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            didOnboard = true
            return handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .fill(DesignTokens.ColorSystem.accentWaypoint.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DesignTokens.ColorSystem.accentWaypoint.opacity(0.55), lineWidth: 2)
                            .padding(8)
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .motion(.easeInOut(duration: Motion.Duration.fast), value: isDropTargeted)
    }

    private var dropZone: SetupDropZone {
        SetupDropZone(
            isActive: setupStore.usingDroppedSource,
            droppedSourceLabel: setupStore.droppedSourceLabel,
            isTargeted: $isDropTargeted,
            onDrop: handleDrop(providers:)
        )
    }

    private func handleProfileSelection(_ selection: String) {
        if selection.isEmpty {
            appState.clearSelectedProfile()
        } else {
            appState.useProfile(named: selection)
        }
    }

    private func performHeroPrimaryAction() {
        switch screenModel.primaryAction {
        case .chooseSource:
            Task { await appState.chooseSourceFolder() }
        case .chooseDestination:
            Task { await appState.chooseDestinationFolder() }
        case .preview:
            Task { await appState.startPreview() }
        }
    }

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
