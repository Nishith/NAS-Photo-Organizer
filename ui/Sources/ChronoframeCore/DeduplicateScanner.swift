import Foundation
import ImageIO

/// Orchestrates a deduplicate scan against an organized destination. Streams
/// `DeduplicateEvent`s as it works through discovery → identity hashing →
/// feature extraction → clustering. Per-file feature data (Vision feature
/// print, dHash, quality score, capture date, pixel dimensions, pair link)
/// is persisted to the existing `.organize_cache.db` so subsequent scans
/// only hash and feature-print files whose `(size, mtime)` changed.
public final class DeduplicateScanner: @unchecked Sendable {
    private let dateResolver: FileDateResolver
    private let identityHasher: FileIdentityHasher
    private var cancelFlag = ManagedAtomicBool()

    public init(
        dateResolver: FileDateResolver = FileDateResolver(),
        identityHasher: FileIdentityHasher = FileIdentityHasher()
    ) {
        self.dateResolver = dateResolver
        self.identityHasher = identityHasher
    }

    public func cancel() {
        cancelFlag.set(true)
    }

    public func scan(configuration: DeduplicateConfiguration) -> AsyncThrowingStream<DeduplicateEvent, Error> {
        cancelFlag.set(false)
        let dateResolver = self.dateResolver
        let identityHasher = self.identityHasher
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
                    var cache = try database.loadDedupeFeatureRecords()

                    // 3. Pair detection.
                    let pairs = DeduplicatePairDetector.detectPairs(in: imagePaths + movPaths)

                    // 4. Identity hashing — finds exact duplicates, reuses
                    // FileCache rows when (size, mtime) match.
                    continuation.yield(.phaseStarted(phase: .identityHashing, total: imagePaths.count))
                    let cacheRecords = (try? database.loadCacheRecords(namespace: .destination)) ?? []
                    var identityByPath: [String: FileIdentity] = [:]
                    let cacheIndex = Dictionary(uniqueKeysWithValues: cacheRecords.map { ($0.path, $0) })

                    for (offset, path) in imagePaths.enumerated() {
                        if cancelFlag.get() { continuation.finish(); return }
                        let processed = identityHasher.processFile(at: path, cachedRecord: cacheIndex[path])
                        if let identity = processed.identity {
                            identityByPath[path] = identity
                        }
                        if (offset + 1) % 50 == 0 || offset == imagePaths.count - 1 {
                            continuation.yield(.phaseProgress(phase: .identityHashing, completed: offset + 1, total: imagePaths.count))
                        }
                    }
                    continuation.yield(.phaseCompleted(phase: .identityHashing))

                    // 5. Per-file feature extraction (dHash + Vision feature
                    // print + quality scores), with cache reuse.
                    continuation.yield(.phaseStarted(phase: .featureExtraction, total: imagePaths.count))
                    var freshRecords: [DedupeFeatureRecord] = []
                    var candidatesByPath: [String: PhotoCandidate] = [:]

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
                        if let cached = cache[path],
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
                                featurePrintData: cached.featurePrintData,
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

                        // Cache miss — compute from scratch.
                        let captureDate = dateResolver.resolveDate(for: path)
                        let dimensions = Self.imageDimensions(at: url)
                        let dhash = PerceptualHash.dhash(at: url)
                        let featurePrintData: Data? = {
                            do { return try VisionFeaturePrinter.featurePrintData(at: url) }
                            catch {
                                continuation.yield(.issue(DeduplicateIssue(severity: .warning, path: path, message: "Feature print failed: \(error.localizedDescription)")))
                                return nil
                            }
                        }()
                        let quality = PhotoQualityScorer.score(
                            at: url,
                            sizeBytes: size,
                            pixelWidth: dimensions?.width,
                            pixelHeight: dimensions?.height
                        )
                        let candidate = PhotoCandidate(
                            path: path,
                            size: size,
                            modificationTime: mtime,
                            captureDate: captureDate,
                            pixelWidth: dimensions?.width,
                            pixelHeight: dimensions?.height,
                            dhash: dhash,
                            featurePrintData: featurePrintData,
                            qualityScore: quality.composite,
                            sharpness: quality.sharpness,
                            faceScore: quality.faceScore,
                            isRaw: DeduplicatePairDetector.rawExtensions.contains(MediaLibraryRules.normalizedExtension(for: path)),
                            isLivePhotoStill: pairs[path]?.kind == .livePhoto,
                            pairedPath: pairedPath
                        )
                        candidatesByPath[path] = candidate
                        freshRecords.append(
                            DedupeFeatureRecord(
                                path: path,
                                size: size,
                                modificationTime: mtime,
                                dhash: dhash,
                                featurePrintData: featurePrintData,
                                sharpness: quality.sharpness,
                                faceScore: quality.faceScore,
                                pixelWidth: dimensions?.width,
                                pixelHeight: dimensions?.height,
                                captureDate: captureDate,
                                pairedPath: pairedPath
                            )
                        )

                        if (offset + 1) % 25 == 0 || offset == imagePaths.count - 1 {
                            continuation.yield(.phaseProgress(phase: .featureExtraction, completed: offset + 1, total: imagePaths.count))
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
                    cache = (try? database.loadDedupeFeatureRecords()) ?? cache
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

                    let near = DuplicateClusterer.cluster(candidates: candidates, configuration: configuration)
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

    private static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
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
