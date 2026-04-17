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
    @State private var isDropTargeted: Bool = false

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._preferencesStore = ObservedObject(wrappedValue: appState.preferencesStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a profile or folders, then preview before transferring.")
                    .font(.title3.weight(.semibold))

                Text("Chronoframe leaves the source untouched and writes organized files, queue state, and reports into the destination.")
                    .foregroundStyle(.secondary)

                libraryCard
            }
            .padding(DesignTokens.Layout.contentPadding)
            .frame(maxWidth: DesignTokens.Layout.setupMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Setup")
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Library")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    profilePicker
                    Spacer(minLength: 16)
                    profileActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    profilePicker
                    profileActions
                }
            }

            profileSummary

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                dropZone

                pathCard(
                    title: "Source",
                    value: setupStore.usingDroppedSource
                        ? (setupStore.droppedSourceLabel ?? setupStore.sourcePath)
                        : setupStore.sourcePath,
                    helper: setupStore.usingDroppedSource
                        ? "Dragged items are staged as symlinks; originals stay untouched."
                        : "The organizer never mutates this library.",
                    actionTitle: "Choose Source…"
                ) {
                    Task { await appState.chooseSourceFolder() }
                }

                pathCard(
                    title: "Destination",
                    value: setupStore.destinationPath,
                    helper: "Chronoframe writes queue state, logs, and reports here.",
                    actionTitle: "Choose Destination…"
                ) {
                    Task { await appState.chooseDestinationFolder() }
                }
            }

            Divider()

            runSection
        }
        .padding(DesignTokens.Layout.cardPadding)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var dropZone: some View {
        let isActive = setupStore.usingDroppedSource

        return VStack(spacing: 8) {
            Image(systemName: isActive ? "photo.on.rectangle.angled" : "square.and.arrow.down.on.square")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

            if isActive {
                Text(setupStore.droppedSourceLabel ?? "Dropped items ready")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Drop more items to replace, or click Choose Source to switch back to a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(isDropTargeted ? "Release to use these as the source" : "Drag photos, videos, or folders here")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .primary)
                Text("Alternative to choosing a source. Files are organized into the destination by date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .accessibilityLabel("Drop photos, videos, or folders to use as source")
        .accessibilityIdentifier("dropZone")
    }

    /// Pulls file URLs out of drop providers and forwards them to AppState.
    /// Returns `true` as soon as at least one fileURL is being resolved so
    /// the UI shows an accepted drop; AppState reports any errors via
    /// `transientErrorMessage` once resolution completes.
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

    /// Decodes a file URL from a drop item provider. Drops deliver the
    /// URL as a bookmark `Data` blob under the `public.file-url` type.
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

    private var profilePicker: some View {
        HStack(spacing: 10) {
            Text("Profile")
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

    private var profileSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(setupStore.usingProfile ? "Using a saved profile" : "Using manual source and destination")
                .font(.subheadline.weight(.semibold))

            if setupStore.usingProfile {
                Text("Changes still stay compatible with `profiles.yaml` for the CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Save the current paths as a profile once the setup feels right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button("Refresh Profiles") {
                    appState.refreshProfiles()
                }

                if setupStore.usingProfile {
                    Button("Clear Profile") {
                        appState.clearSelectedProfile()
                    }
                }
            }

            Menu("Profile Actions") {
                Button("Refresh Profiles") {
                    appState.refreshProfiles()
                }

                if setupStore.usingProfile {
                    Button("Clear Profile") {
                        appState.clearSelectedProfile()
                    }
                }
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run")
                .font(.headline)

            Text(canStartRun ? "Preview first to confirm the plan. Transfer stays app-confirmed before the backend begins copying." : "Choose both folders or a saved profile before starting.")
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Text(runOptionsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button {
                        appState.openSettingsWindow()
                    } label: {
                        Label("Adjust Settings…", systemImage: "gearshape")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(runOptionsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        appState.openSettingsWindow()
                    } label: {
                        Label("Adjust Settings…", systemImage: "gearshape")
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    previewButton
                    transferButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    previewButton
                    transferButton
                }
            }
        }
    }

    private var previewButton: some View {
        Button {
            Task { await appState.startPreview() }
        } label: {
            Label("Preview", systemImage: "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
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
        .buttonStyle(.borderedProminent)
        .disabled(!canStartRun || runSessionStore.isRunning)
        .accessibilityIdentifier("transferButton")
        .accessibilityLabel("Transfer")
        .accessibilityHint(canStartRun ? "Copies files from the source to the destination" : "Choose both folders or a saved profile first")
    }

    private var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }

    private var runOptionsSummary: String {
        [
            "\(preferencesStore.workerCount) workers",
            preferencesStore.useFastDestinationScan ? "cached destination scan" : "full destination scan",
            preferencesStore.verifyCopies ? "verification on" : "verification off",
        ]
        .joined(separator: " • ")
    }

    private func pathCard(title: String, value: String, helper: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(helper)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button(actionTitle, action: action)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(helper)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(actionTitle, action: action)
                }
            }

            Text(value.isEmpty ? "Not set" : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .font(.callout.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .accessibilityLabel("\(title) path: \(value.isEmpty ? "not set" : value)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
