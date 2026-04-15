import Darwin
import Foundation

public struct ProcessedFileIdentity: Equatable, Sendable {
    public var identity: FileIdentity?
    public var size: Int64
    public var modificationTime: TimeInterval
    public var wasHashed: Bool

    public init(
        identity: FileIdentity?,
        size: Int64,
        modificationTime: TimeInterval,
        wasHashed: Bool
    ) {
        self.identity = identity
        self.size = size
        self.modificationTime = modificationTime
        self.wasHashed = wasHashed
    }
}

public struct FileIdentityHasher: Sendable {
    public static let chunkByteCount = 8 * 1024 * 1024

    public init() {}

    public func hashIdentity(at url: URL, knownSize: Int64? = nil) throws -> FileIdentity {
        let size: Int64
        if let knownSize {
            size = knownSize
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        let digest = try hashDigest(at: url, size: size)
        return FileIdentity(size: size, digest: digest)
    }

    public func processFile(at path: String, cachedRecord: FileCacheRecord?) -> ProcessedFileIdentity {
        let url = URL(fileURLWithPath: path)

        guard let fileMetadata = fileMetadata(atPath: path) else {
            return ProcessedFileIdentity(identity: nil, size: 0, modificationTime: 0, wasHashed: false)
        }

        if let cachedRecord,
           cachedRecord.size == fileMetadata.size,
           abs(cachedRecord.modificationTime - fileMetadata.modificationTime) < 0.001 {
            return ProcessedFileIdentity(
                identity: cachedRecord.identity,
                size: fileMetadata.size,
                modificationTime: fileMetadata.modificationTime,
                wasHashed: false
            )
        }

        do {
            let identity = try hashIdentity(at: url, knownSize: fileMetadata.size)
            return ProcessedFileIdentity(
                identity: identity,
                size: fileMetadata.size,
                modificationTime: fileMetadata.modificationTime,
                wasHashed: true
            )
        } catch {
            return ProcessedFileIdentity(
                identity: nil,
                size: 0,
                modificationTime: 0,
                wasHashed: false
            )
        }
    }

    private func hashDigest(at url: URL, size: Int64) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer {
            try? handle.close()
        }

        var hasher = BLAKE2bHasher()
        hasher.update(Data(String(size).utf8))

        while true {
            let chunk = handle.readData(ofLength: Self.chunkByteCount)
            if chunk.isEmpty {
                break
            }
            hasher.update(chunk)
        }

        return hasher.finalizeHexDigest()
    }

    private func fileMetadata(atPath path: String) -> (size: Int64, modificationTime: TimeInterval)? {
        var fileStatus = stat()
        let result = path.withCString { pointer in
            stat(pointer, &fileStatus)
        }
        guard result == 0 else {
            return nil
        }

        let modificationTime = TimeInterval(fileStatus.st_mtimespec.tv_sec)
            + (TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (Int64(fileStatus.st_size), modificationTime)
    }
}
