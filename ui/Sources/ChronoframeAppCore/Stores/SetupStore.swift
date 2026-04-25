#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public final class SetupStore: ObservableObject {
    @Published public var sourcePath: String
    @Published public var destinationPath: String
    @Published public var selectedProfileName: String
    @Published public var newProfileName: String
    @Published public var profiles: [Profile]

    /// Set when the user populated the source by dragging files/folders
    /// instead of picking a directory. Used to show a friendly label in
    /// the UI and to suppress the transferred-sources history record
    /// (staging paths are ephemeral).
    @Published public var droppedSourceLabel: String?
    @Published public var droppedSourceItemCount: Int

    public init(
        sourcePath: String = "",
        destinationPath: String = "",
        selectedProfileName: String = "",
        newProfileName: String = "",
        profiles: [Profile] = [],
        droppedSourceLabel: String? = nil,
        droppedSourceItemCount: Int = 0
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.selectedProfileName = selectedProfileName
        self.newProfileName = newProfileName
        self.profiles = profiles
        self.droppedSourceLabel = droppedSourceLabel
        self.droppedSourceItemCount = droppedSourceItemCount
    }

    public var usingDroppedSource: Bool {
        droppedSourceLabel != nil
    }

    /// Clears the "source is from drag-and-drop" metadata. Call whenever
    /// the source is replaced via a manual picker, profile, or reset.
    public func clearDroppedSource() {
        droppedSourceLabel = nil
        droppedSourceItemCount = 0
    }

    public var usingProfile: Bool {
        !selectedProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeProfile: Profile? {
        profiles.first { $0.name == selectedProfileName }
    }

    public func updateProfiles(_ profiles: [Profile]) {
        self.profiles = profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if usingProfile, activeProfile == nil {
            selectedProfileName = ""
        }
    }

    public func selectProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedProfileName = trimmed

        guard let profile = profiles.first(where: { $0.name == trimmed }) else { return }
        sourcePath = profile.sourcePath
        destinationPath = profile.destinationPath
        clearDroppedSource()
    }

    public func clearProfileSelection() {
        selectedProfileName = ""
    }

    public func makeConfiguration(preferences: PreferencesStore, mode: RunMode) -> RunConfiguration {
        RunConfiguration(
            mode: mode,
            sourcePath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationPath: destinationPath.trimmingCharacters(in: .whitespacesAndNewlines),
            profileName: usingProfile ? selectedProfileName : nil,
            useFastDestinationScan: preferences.useFastDestinationScan,
            verifyCopies: preferences.verifyCopies,
            workerCount: max(1, preferences.workerCount),
            folderStructure: preferences.folderStructure
        )
    }
}
