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

    @Published public var dedupeTimeWindowSeconds: Int {
        didSet { persist(dedupeTimeWindowSeconds, key: "dedupeTimeWindowSeconds") }
    }

    @Published public var dedupeSimilarityPreset: DedupeSimilarityPreset {
        didSet { persist(dedupeSimilarityPreset.rawValue, key: "dedupeSimilarityPreset") }
    }

    @Published public var dedupeTreatRawJpegPairsAsUnit: Bool {
        didSet { persist(dedupeTreatRawJpegPairsAsUnit, key: "dedupeTreatRawJpegPairsAsUnit") }
    }

    @Published public var dedupeTreatLivePhotoPairsAsUnit: Bool {
        didSet { persist(dedupeTreatLivePhotoPairsAsUnit, key: "dedupeTreatLivePhotoPairsAsUnit") }
    }

    @Published public var dedupeIncludeExactDuplicates: Bool {
        didSet { persist(dedupeIncludeExactDuplicates, key: "dedupeIncludeExactDuplicates") }
    }

    @Published public var dedupeAllowHardDelete: Bool {
        didSet { persist(dedupeAllowHardDelete, key: "dedupeAllowHardDelete") }
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
        self.dedupeTimeWindowSeconds = defaults.object(forKey: "dedupeTimeWindowSeconds") as? Int ?? 30
        let storedPreset = defaults.string(forKey: "dedupeSimilarityPreset").flatMap(DedupeSimilarityPreset.init(rawValue:))
        self.dedupeSimilarityPreset = storedPreset ?? .balanced
        self.dedupeTreatRawJpegPairsAsUnit = defaults.object(forKey: "dedupeTreatRawJpegPairsAsUnit") as? Bool ?? true
        self.dedupeTreatLivePhotoPairsAsUnit = defaults.object(forKey: "dedupeTreatLivePhotoPairsAsUnit") as? Bool ?? true
        self.dedupeIncludeExactDuplicates = defaults.object(forKey: "dedupeIncludeExactDuplicates") as? Bool ?? true
        self.dedupeAllowHardDelete = defaults.object(forKey: "dedupeAllowHardDelete") as? Bool ?? false
    }

    public func makeDeduplicateConfiguration(destinationPath: String) -> DeduplicateConfiguration {
        DeduplicateConfiguration(
            destinationPath: destinationPath,
            timeWindowSeconds: dedupeTimeWindowSeconds,
            similarityThreshold: dedupeSimilarityPreset.similarityThreshold,
            dhashHammingThreshold: dedupeSimilarityPreset.dhashHammingThreshold,
            treatRawJpegPairsAsUnit: dedupeTreatRawJpegPairsAsUnit,
            treatLivePhotoPairsAsUnit: dedupeTreatLivePhotoPairsAsUnit,
            enableExactDuplicateGroup: dedupeIncludeExactDuplicates,
            workerCount: workerCount
        )
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
