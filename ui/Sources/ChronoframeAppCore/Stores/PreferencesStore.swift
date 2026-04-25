#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation
import Combine

public final class PreferencesStore: ObservableObject {
    public static let minimumLogCapacity = 250
    public static let maximumLogCapacity = 10_000

    private let defaults: UserDefaults

    @Published public var workerCount: Int {
        didSet { persist(workerCount, key: "workerCount") }
    }

    @Published public var useFastDestinationScan: Bool {
        didSet { persist(useFastDestinationScan, key: "useFastDestinationScan") }
    }

    @Published public var verifyCopies: Bool {
        didSet { persist(verifyCopies, key: "verifyCopies") }
    }

    @Published public var logBufferCapacity: Int {
        didSet {
            let clamped = max(Self.minimumLogCapacity, min(Self.maximumLogCapacity, logBufferCapacity))
            if clamped != logBufferCapacity {
                logBufferCapacity = clamped
                return
            }
            persist(logBufferCapacity, key: "logBufferCapacity")
        }
    }

    @Published public var lastManualSourcePath: String {
        didSet { persist(lastManualSourcePath, key: "lastManualSourcePath") }
    }

    @Published public var lastManualDestinationPath: String {
        didSet { persist(lastManualDestinationPath, key: "lastManualDestinationPath") }
    }

    @Published public var lastSelectedProfileName: String {
        didSet { persist(lastSelectedProfileName, key: "lastSelectedProfileName") }
    }

    @Published public var folderStructure: FolderStructure {
        didSet { persist(folderStructure.rawValue, key: "folderStructure") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workerCount = defaults.object(forKey: "workerCount") as? Int ?? 8
        self.useFastDestinationScan = defaults.object(forKey: "useFastDestinationScan") as? Bool ?? false
        self.verifyCopies = defaults.object(forKey: "verifyCopies") as? Bool ?? false
        self.logBufferCapacity = defaults.object(forKey: "logBufferCapacity") as? Int ?? 2_000
        self.lastManualSourcePath = defaults.string(forKey: "lastManualSourcePath") ?? ""
        self.lastManualDestinationPath = defaults.string(forKey: "lastManualDestinationPath") ?? ""
        self.lastSelectedProfileName = defaults.string(forKey: "lastSelectedProfileName") ?? ""
        let storedStructure = defaults.string(forKey: "folderStructure").flatMap(FolderStructure.init(rawValue:))
        self.folderStructure = storedStructure ?? .yyyyMMDD
    }

    public func bookmark(for key: String) -> FolderBookmark? {
        guard
            let data = defaults.data(forKey: bookmarkDefaultsKey(for: key)),
            let path = defaults.string(forKey: bookmarkPathDefaultsKey(for: key))
        else {
            return nil
        }

        return FolderBookmark(key: key, path: path, data: data)
    }

    public func storeBookmark(_ bookmark: FolderBookmark) {
        defaults.set(bookmark.data, forKey: bookmarkDefaultsKey(for: bookmark.key))
        defaults.set(bookmark.path, forKey: bookmarkPathDefaultsKey(for: bookmark.key))
    }

    public func removeBookmark(for key: String) {
        defaults.removeObject(forKey: bookmarkDefaultsKey(for: key))
        defaults.removeObject(forKey: bookmarkPathDefaultsKey(for: key))
    }

    private func persist(_ value: some Any, key: String) {
        defaults.set(value, forKey: key)
    }

    private func bookmarkDefaultsKey(for key: String) -> String {
        "bookmark.\(key).data"
    }

    private func bookmarkPathDefaultsKey(for key: String) -> String {
        "bookmark.\(key).path"
    }
}
