import Foundation
import CoreImage
import ImageIO
import Vision

/// Orchestrates a deduplicate scan against an organized destination. Streams
/// `DeduplicateEvent`s as it works through discovery → identity hashing →
/// feature extraction → clustering. Per-file feature data (Vision feature
/// print, dHash, quality score, capture date, pixel dimensions, pair link)
/// is persisted to the existing `.organize_cache.db` so subsequent scans
/// only hash and feature-print files whose `(size, mtime)` changed.
public final class DeduplicateScanner: @unchecked Sendable {
    private let dateResolver: FileDateResolver
    private let identityHasher: FileIdentityHasher
    private let imageAnalyzer: any DedupeImageAnalyzing
    private var cancelFlag = ManagedAtomicBool()

    public init(
        dateResolver: FileDateResolver = FileDateResolver(),
        identityHasher: FileIdentityHasher = FileIdentityHasher()
    ) {
        self.dateResolver = dateResolver
        self.identityHasher = identityHasher
        self.imageAnalyzer = DefaultDedupeImageAnalyzer(dateResolver: dateResolver)
    }

    init(
        dateResolver: FileDateResolver = FileDateResolver(),
        identityHasher: FileIdentityHasher = FileIdentityHasher(),
        imageAnalyzer: any DedupeImageAnalyzing
    ) {
        self.dateResolver = dateResolver
        self.identityHasher = identityHasher
        self.imageAnalyzer = imageAnalyzer
    }

    public func cancel() {
        cancelFlag.set(true)
    }

    public func scan(configuration: DeduplicateConfiguration) -> AsyncThrowingStream<DeduplicateEvent, Error> {
        cancelFlag.set(false)
        let identityHasher = self.identityHasher
        let imageAnalyzer = self.imageAnalyzer
        let cancelFlag = self.cancelFlag

        return AsyncThrowingStream { continuation in
            Task.detached {
                let started = Date()
                continuation.yield(.startup)

                do {
                    // 1. Discovery — image files only for v1; .mov files are
                    // tracked separately for Live Photo pair linking.
                    let rootURL = URL(fileURLWithPath: configuration.destinationPath)
                    var allPaths: [String] = []
                    try MediaDiscovery.enumerateMediaFiles(at: rootURL) { path in
                        allPaths.append(path)
                    }
                    if cancelFlag.get() { continuation.finish(); return }

                    let imagePaths = allPaths.filter { MediaLibraryRules.isPhotoFile(path: $0) }
                    let movPaths = allPaths.filter {
                        let ext = MediaLibraryRules.normalizedExtension(for: $0)
                        return ext == ".mov" || ext == ".m4v"
                    }
                    continuation.yield(.phaseStarted(phase: .discovery, total: imagePaths.count))
                    continuation.yield(.phaseCompleted(phase: .discovery))

                    // 2. Open the cache database in the destination root.
                    let dbURL = rootURL.appendingPathComponent(".organize_cache.db")
                    let database = try OrganizerDatabase(url: dbURL)
                    try database.ensureDedupeFeaturesSchema()
                    let cache = try database.loadDedupeFeatureMetadataRecords()

                    // 3. Pair detection.
                    let pairs = DeduplicatePairDetector.detectPairs(in: imagePaths + movPaths)

                    // 4. Identity hashing — finds exact duplicates, reuses
                    // FileCache rows when (size, mtime) match.
                    continuation.yield(.phaseStarted(phase: .identityHashing, total: imagePaths.count))
                    let cacheRecords = (try? database.loadCacheRecords(namespace: .destination)) ?? []
                    let cacheIndex = Dictionary(uniqueKeysWithValues: cacheRecords.map { ($0.path, $0) })
                    let identityResults = Self.processIdentityHashes(
                        paths: imagePaths,
                        cacheIndex: cacheIndex,
                        identityHasher: identityHasher,
                        workerCount: configuration.workerCount,
                        cancelFlag: cancelFlag,
                        continuation: continuation
                    )
                    if cancelFlag.get() { continuation.finish(); return }

                    var identityByPath: [String: FileIdentity] = [:]
                    for (index, path) in imagePaths.enumerated() {
                        if let identity = identityResults[index].identity {
                            identityByPath[path] = identity
                        }
                    }
                    continuation.yield(.phaseCompleted(phase: .identityHashing))

                    // 5. Per-file feature extraction (dHash + Vision feature
                    // print + quality scores), with cache reuse.
                    continuation.yield(.phaseStarted(phase: .featureExtraction, total: imagePaths.count))
                    var freshRecords: [DedupeFeatureRecord] = []
                    var candidatesByPath: [String: PhotoCandidate] = [:]
                    let featureStore = LazyDedupeFeaturePrintStore(database: database)
                    var analysisRequests: [DedupeAnalysisRequest] = []

                    for (offset, path) in imagePaths.enumerated() {
                        if cancelFlag.get() { continuation.finish(); return }
                        let url = URL(fileURLWithPath: path)
                        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                        let mtime = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
                        let pairedPath = pairs[path].map { pair in
                            pair.primaryPath == path ? pair.secondaryPath : pair.primaryPath
                        }

                        // Cache hit when (size, mtime) match exactly.
                        if let cached = Self.cachedFeatureRecord(for: path, in: cache),
                           cached.size == size,
                           abs(cached.modificationTime - mtime) < 0.001 {
                            let candidate = PhotoCandidate(
                                path: path,
                                size: size,
                                modificationTime: mtime,
                                captureDate: cached.captureDate,
                                pixelWidth: cached.pixelWidth,
                                pixelHeight: cached.pixelHeight,
                                dhash: cached.dhash,
                                featurePrintData: nil,
                                qualityScore: Self.composite(sharpness: cached.sharpness, faceScore: cached.faceScore, size: size, width: cached.pixelWidth, height: cached.pixelHeight),
                                sharpness: cached.sharpness,
                                faceScore: cached.faceScore,
                                isRaw: DeduplicatePairDetector.rawExtensions.contains(MediaLibraryRules.normalizedExtension(for: path)),
                                isLivePhotoStill: pairs[path]?.kind == .livePhoto,
                                pairedPath: pairedPath
                            )
                            candidatesByPath[path] = candidate
                            if (offset + 1) % 50 == 0 || offset == imagePaths.count - 1 {
                                continuation.yield(.phaseProgress(phase: .featureExtraction, completed: offset + 1, total: imagePaths.count))
                            }
                            continue
                        }

                        analysisRequests.append(
                            DedupeAnalysisRequest(
                                offset: offset,
                                path: path,
                                url: url,
                                size: size,
                                modificationTime: mtime,
                                pairedPath: pairedPath,
                                isRaw: DeduplicatePairDetector.rawExtensions.contains(MediaLibraryRules.normalizedExtension(for: path)),
                                isLivePhotoStill: pairs[path]?.kind == .livePhoto
                            )
                        )
                    }

                    let analysisResults = Self.processAnalysisRequests(
                        analysisRequests,
                        analyzer: imageAnalyzer,
                        workerCount: configuration.workerCount,
                        cancelFlag: cancelFlag
                    )
                    if cancelFlag.get() { continuation.finish(); return }

                    for request in analysisRequests.sorted(by: { $0.offset < $1.offset }) {
                        guard let analysis = analysisResults[request.offset] else { continue }
                        if let message = analysis.featurePrintFailureMessage {
                            continuation.yield(.issue(DeduplicateIssue(severity: .warning, path: request.path, message: message)))
                        }
                        let candidate = PhotoCandidate(
                            path: request.path,
                            size: request.size,
                            modificationTime: request.modificationTime,
                            captureDate: analysis.captureDate,
                            pixelWidth: analysis.pixelWidth,
                            pixelHeight: analysis.pixelHeight,
                            dhash: analysis.dhash,
                            featurePrintData: analysis.featurePrintData,
                            qualityScore: analysis.quality.composite,
                            sharpness: analysis.quality.sharpness,
                            faceScore: analysis.quality.faceScore,
                            isRaw: request.isRaw,
                            isLivePhotoStill: request.isLivePhotoStill,
                            pairedPath: request.pairedPath
                        )
                        candidatesByPath[request.path] = candidate
                        freshRecords.append(
                            DedupeFeatureRecord(
                                path: request.path,
                                size: request.size,
                                modificationTime: request.modificationTime,
                                dhash: analysis.dhash,
                                featurePrintData: analysis.featurePrintData,
                                sharpness: analysis.quality.sharpness,
                                faceScore: analysis.quality.faceScore,
                                pixelWidth: analysis.pixelWidth,
                                pixelHeight: analysis.pixelHeight,
                                captureDate: analysis.captureDate,
                                pairedPath: request.pairedPath
                            )
                        )

                        if (request.offset + 1) % 25 == 0 || request.offset == imagePaths.count - 1 {
                            continuation.yield(.phaseProgress(phase: .featureExtraction, completed: request.offset + 1, total: imagePaths.count))
                            // Flush to disk in batches so a long scan that
                            // gets cancelled or crashes still preserves work.
                            if !freshRecords.isEmpty {
                                try? database.saveDedupeFeatureRecords(freshRecords)
                                freshRecords.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if !freshRecords.isEmpty {
                        try? database.saveDedupeFeatureRecords(freshRecords)
                    }
                    try? database.pruneDedupeFeatureRecords(notIn: Set(imagePaths))
                    continuation.yield(.phaseCompleted(phase: .featureExtraction))

                    // 6. Clustering.
                    continuation.yield(.phaseStarted(phase: .clustering, total: nil))
                    let candidates = Array(candidatesByPath.values)

                    var clusters: [DuplicateCluster] = []
                    if configuration.enableExactDuplicateGroup {
                        var byIdentity: [FileIdentity: [PhotoCandidate]] = [:]
                        for candidate in candidates {
                            guard let identity = identityByPath[candidate.path] else { continue }
                            byIdentity[identity, default: []].append(candidate)
                        }
                        clusters.append(contentsOf: DuplicateClusterer.exactDuplicateClusters(candidatesByIdentity: byIdentity))
                    }

                    let near = DuplicateClusterer.cluster(
                        candidates: candidates,
                        configuration: configuration,
                        featurePrintDataProvider: { path in
                            featureStore.featurePrintData(for: path)
                        }
                    )
                    clusters.append(contentsOf: near)

                    // Drop near-duplicate clusters that are entirely byte-
                    // identical to an exact-duplicate cluster we already
                    // emitted (the exact group supersedes them).
                    let exactPaths = Set(clusters.filter { $0.kind == .exactDuplicate }.flatMap { $0.members.map(\.path) })
                    let dedupedClusters = clusters.filter { cluster in
                        if cluster.kind == .exactDuplicate { return true }
                        return !cluster.members.allSatisfy { exactPaths.contains($0.path) }
                    }

                    for cluster in dedupedClusters {
                        if cancelFlag.get() { continuation.finish(); return }
                        continuation.yield(.clusterDiscovered(cluster))
                    }
                    continuation.yield(.phaseCompleted(phase: .clustering))

                    // 7. Summary.
                    var counts: [ClusterKind: Int] = [:]
                    var totalBytes: Int64 = 0
                    for cluster in dedupedClusters {
                        counts[cluster.kind, default: 0] += 1
                        totalBytes += cluster.bytesIfPruned
                    }
                    continuation.yield(.complete(DeduplicateSummary(
                        clusterCounts: counts,
                        totalRecoverableBytes: totalBytes,
                        totalCandidatesScanned: imagePaths.count,
                        scanDuration: Date().timeIntervalSince(started)
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func composite(
        sharpness: Double,
        faceScore: Double?,
        size: Int64,
        width: Int?,
        height: Int?
    ) -> Double {
        let resolution = Double(max(0, (width ?? 0) * (height ?? 0)))
        let resolutionScore = resolution > 0 ? min(1.0, log2(resolution) / 24.0) : 0.3
        let sizeScore = size > 0 ? min(1.0, log2(Double(size)) / 26.0) : 0.3
        var composite = 0.5 * sharpness + 0.15 * resolutionScore + 0.10 * sizeScore
        if let faceScore {
            composite += 0.25 * faceScore
        } else {
            composite += 0.25 * sharpness
        }
        return composite
    }

    fileprivate static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height else { return nil }
        return (width, height)
    }

    private static func processIdentityHashes(
        paths: [String],
        cacheIndex: [String: FileCacheRecord],
        identityHasher: FileIdentityHasher,
        workerCount: Int,
        cancelFlag: ManagedAtomicBool,
        continuation: AsyncThrowingStream<DeduplicateEvent, Error>.Continuation
    ) -> [ProcessedFileIdentity] {
        guard !paths.isEmpty else { return [] }
        let maxWorkers = max(1, workerCount)
        if maxWorkers == 1 || paths.count == 1 {
            var results: [ProcessedFileIdentity] = []
            results.reserveCapacity(paths.count)
            for (offset, path) in paths.enumerated() {
                if cancelFlag.get() {
                    results.append(ProcessedFileIdentity(identity: nil, size: 0, modificationTime: 0, wasHashed: false))
                    continue
                }
                results.append(identityHasher.processFile(at: path, cachedRecord: cacheIndex[path]))
                if (offset + 1) % 50 == 0 || offset == paths.count - 1 {
                    continuation.yield(.phaseProgress(phase: .identityHashing, completed: offset + 1, total: paths.count))
                }
            }
            return results
        }

        let results = OrderedIdentityResults(count: paths.count)
        let queue = OperationQueue()
        queue.name = "Chronoframe.DeduplicateScanner.identity"
        queue.maxConcurrentOperationCount = maxWorkers

        for (index, path) in paths.enumerated() {
            let cachedRecord = cacheIndex[path]
            queue.addOperation {
                if cancelFlag.get() {
                    _ = results.store(
                        ProcessedFileIdentity(identity: nil, size: 0, modificationTime: 0, wasHashed: false),
                        at: index
                    )
                    return
                }
                let processed = identityHasher.processFile(at: path, cachedRecord: cachedRecord)
                let completed = results.store(processed, at: index)
                if completed % 50 == 0 || completed == paths.count {
                    continuation.yield(.phaseProgress(phase: .identityHashing, completed: completed, total: paths.count))
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return results.values()
    }

    private static func cachedFeatureRecord(
        for path: String,
        in cache: [String: DedupeFeatureRecord]
    ) -> DedupeFeatureRecord? {
        cache[path] ?? cache[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    private static func processAnalysisRequests(
        _ requests: [DedupeAnalysisRequest],
        analyzer: any DedupeImageAnalyzing,
        workerCount: Int,
        cancelFlag: ManagedAtomicBool
    ) -> [Int: DedupeImageAnalysis] {
        guard !requests.isEmpty else { return [:] }
        let maxWorkers = max(1, workerCount)
        if maxWorkers == 1 || requests.count == 1 {
            var results: [Int: DedupeImageAnalysis] = [:]
            for request in requests {
                if cancelFlag.get() { break }
                results[request.offset] = analyzer.analyze(url: request.url, size: request.size)
            }
            return results
        }

        let results = AnalysisResults()
        let queue = OperationQueue()
        queue.name = "Chronoframe.DeduplicateScanner.analysis"
        queue.maxConcurrentOperationCount = maxWorkers

        for request in requests {
            queue.addOperation {
                guard !cancelFlag.get() else { return }
                let analysis = analyzer.analyze(url: request.url, size: request.size)
                results.store(analysis, at: request.offset)
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return results.values()
    }
}

struct DedupeImageAnalysis: Sendable {
    var captureDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var dhash: UInt64?
    var featurePrintData: Data?
    var featurePrintFailureMessage: String?
    var quality: PhotoQualityScore
}

protocol DedupeImageAnalyzing: Sendable {
    func analyze(url: URL, size: Int64) -> DedupeImageAnalysis
}

struct DefaultDedupeImageAnalyzer: DedupeImageAnalyzing {
    var dateResolver: FileDateResolver
    private let resources = DedupeImageAnalyzerResources()

    func analyze(url: URL, size: Int64) -> DedupeImageAnalysis {
        let metadata = Self.imageMetadata(at: url)
        let vision = Self.visionAnalysis(at: url)
        let quality = PhotoQualityScorer.score(
            at: url,
            sizeBytes: size,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            ciContext: resources.ciContext,
            faceScore: vision.faceScore
        )
        return DedupeImageAnalysis(
            captureDate: dateResolver.resolveDate(for: url.path, precomputedPhotoMetadataDate: metadata.captureDate),
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            dhash: metadata.dhash,
            featurePrintData: vision.featurePrintData,
            featurePrintFailureMessage: vision.featurePrintFailureMessage,
            quality: quality
        )
    }

    private static func imageMetadata(at url: URL) -> DedupeImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return DedupeImageMetadata()
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let captureDate = properties.flatMap(captureDate(from:))
        let dhash = thumbnailDHash(from: source)

        return DedupeImageMetadata(
            pixelWidth: width,
            pixelHeight: height,
            dhash: dhash,
            captureDate: captureDate
        )
    }

    private static func captureDate(from properties: [CFString: Any]) -> Date? {
        if
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let rawValue = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            let parsed = NativeMediaMetadataDateReader.parseImagePropertyDate(rawValue)
        {
            return parsed
        }

        if
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let rawValue = tiff[kCGImagePropertyTIFFDateTime] as? String,
            let parsed = NativeMediaMetadataDateReader.parseImagePropertyDate(rawValue)
        {
            return parsed
        }

        return nil
    }

    private static func thumbnailDHash(from source: CGImageSource) -> UInt64? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return PerceptualHash.dhash(from: thumbnail)
    }

    private static func visionAnalysis(at url: URL) -> DedupeVisionAnalysis {
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.imageCropAndScaleOption = .scaleFill
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])

        do {
            try handler.perform([featureRequest, faceRequest])
        } catch {
            return DedupeVisionAnalysis(
                featurePrintData: nil,
                featurePrintFailureMessage: "Feature print failed: \(error.localizedDescription)",
                faceScore: nil
            )
        }

        let featurePrintData: Data?
        let featurePrintFailureMessage: String?
        if let observation = featureRequest.results?.first as? VNFeaturePrintObservation {
            do {
                featurePrintData = try NSKeyedArchiver.archivedData(
                    withRootObject: observation,
                    requiringSecureCoding: true
                )
                featurePrintFailureMessage = nil
            } catch {
                featurePrintData = nil
                featurePrintFailureMessage = "Feature print failed: \(error.localizedDescription)"
            }
        } else {
            featurePrintData = nil
            featurePrintFailureMessage = "Feature print failed: no observation produced"
        }

        return DedupeVisionAnalysis(
            featurePrintData: featurePrintData,
            featurePrintFailureMessage: featurePrintFailureMessage,
            faceScore: PhotoQualityScorer.faceScore(from: faceRequest.results)
        )
    }
}

private final class DedupeImageAnalyzerResources: @unchecked Sendable {
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
}

private struct DedupeImageMetadata {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var dhash: UInt64?
    var captureDate: Date?

    init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        dhash: UInt64? = nil,
        captureDate: Date? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dhash = dhash
        self.captureDate = captureDate
    }
}

private struct DedupeVisionAnalysis {
    var featurePrintData: Data?
    var featurePrintFailureMessage: String?
    var faceScore: Double?
}

private struct DedupeAnalysisRequest: Sendable {
    var offset: Int
    var path: String
    var url: URL
    var size: Int64
    var modificationTime: TimeInterval
    var pairedPath: String?
    var isRaw: Bool
    var isLivePhotoStill: Bool
}

private final class OrderedIdentityResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessedFileIdentity?]
    private var completedCount = 0

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func store(_ result: ProcessedFileIdentity, at index: Int) -> Int {
        lock.lock()
        storage[index] = result
        completedCount += 1
        let completed = completedCount
        lock.unlock()
        return completed
    }

    func values() -> [ProcessedFileIdentity] {
        lock.lock()
        let values = storage.map {
            $0 ?? ProcessedFileIdentity(identity: nil, size: 0, modificationTime: 0, wasHashed: false)
        }
        lock.unlock()
        return values
    }
}

private final class AnalysisResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: DedupeImageAnalysis] = [:]

    func store(_ result: DedupeImageAnalysis, at index: Int) {
        lock.lock()
        storage[index] = result
        lock.unlock()
    }

    func values() -> [Int: DedupeImageAnalysis] {
        lock.lock()
        let values = storage
        lock.unlock()
        return values
    }
}

final class LazyDedupeFeaturePrintStore: @unchecked Sendable {
    private let lock = NSLock()
    private let database: OrganizerDatabase
    private var cache: [String: Data] = [:]
    private var missing: Set<String> = []

    init(database: OrganizerDatabase) {
        self.database = database
    }

    func featurePrintData(for path: String) -> Data? {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        if let cached = cache[standardizedPath] {
            lock.unlock()
            return cached
        }
        if missing.contains(path) {
            lock.unlock()
            return nil
        }
        if missing.contains(standardizedPath) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let lookupPaths = standardizedPath == path ? [path] : [path, standardizedPath]
        let rows = (try? database.loadDedupeFeaturePrintData(for: lookupPaths)) ?? [:]
        let data = rows[path] ?? rows[standardizedPath]

        lock.lock()
        if let data {
            cache[path] = data
            cache[standardizedPath] = data
        } else {
            missing.insert(path)
            missing.insert(standardizedPath)
        }
        lock.unlock()
        return data
    }
}

/// Lock-free atomic Bool wrapper (uses OSAllocatedUnfairLock under the hood).
/// Used to signal cancellation across the detached scan task.
final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
