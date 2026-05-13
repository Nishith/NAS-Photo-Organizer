import Foundation
import CoreServices

/// FSEvents-based folder watcher that streams file-system change events.
/// Designed for background duplicate monitoring (Feature 10).
public final class FileSystemMonitor: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.chronoframe.fsmonitor", qos: .utility)
    private var continuation: AsyncStream<[FileSystemEvent]>.Continuation?
    private var pollingTask: Task<Void, Never>?

    public init(paths: [String], latency: TimeInterval = 2.0) {
        self.paths = paths
        self.latency = latency
    }

    deinit {
        stop()
    }

    public func start() -> AsyncStream<[FileSystemEvent]> {
        stop()

        return AsyncStream { continuation in
            self.continuation = continuation
            self.startPollingFallback()

            let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let clientInfo else { return }
                let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(clientInfo).takeUnretainedValue()

                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                    return
                }

                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                var events: [FileSystemEvent] = []
                for i in 0..<numEvents {
                    let f = flags[i]
                    events.append(FileSystemEvent(
                        path: paths[i],
                        flags: f,
                        isFile: f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0,
                        isCreated: f & UInt32(kFSEventStreamEventFlagItemCreated) != 0,
                        isModified: f & UInt32(kFSEventStreamEventFlagItemModified) != 0,
                        isRemoved: f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
                    ))
                }

                if !events.isEmpty {
                    monitor.continuation?.yield(events)
                }
            }

            var context = FSEventStreamContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()

            let pathsCF = self.paths as CFArray
            let createFlags: FSEventStreamCreateFlags =
                UInt32(kFSEventStreamCreateFlagFileEvents) |
                UInt32(kFSEventStreamCreateFlagUseCFTypes) |
                UInt32(kFSEventStreamCreateFlagNoDefer)

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsCF,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                self.latency,
                createFlags
            ) else {
                continuation.finish()
                return
            }

            self.streamRef = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil

        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        continuation?.finish()
        continuation = nil
    }

    private func startPollingFallback() {
        var snapshot = Self.snapshot(paths: paths)
        let interval = max(latency, 0.1)

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }

                let nextSnapshot = Self.snapshot(paths: self.paths)
                let oldPaths = Set(snapshot.keys)
                let newPaths = Set(nextSnapshot.keys)

                var events: [FileSystemEvent] = []
                for path in newPaths.subtracting(oldPaths).sorted() {
                    events.append(FileSystemEvent(
                        path: path,
                        isFile: nextSnapshot[path, default: false],
                        isCreated: true
                    ))
                }

                for path in oldPaths.subtracting(newPaths).sorted() {
                    events.append(FileSystemEvent(
                        path: path,
                        isFile: snapshot[path, default: false],
                        isRemoved: true
                    ))
                }

                if !events.isEmpty {
                    self.continuation?.yield(events)
                }
                snapshot = nextSnapshot
            }
        }
    }

    private static func snapshot(paths: [String]) -> [String: Bool] {
        var snapshot: [String: Bool] = [:]
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]

        for rootPath in paths {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
                continue
            }

            snapshot[rootURL.path] = !isDirectory.boolValue

            guard isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsPackageDescendants]
                  )
            else {
                continue
            }

            for case let url as URL in enumerator {
                let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys))
                snapshot[url.path] = resourceValues?.isRegularFile ?? false
            }
        }

        return snapshot
    }
}

public struct FileSystemEvent: Sendable {
    public var path: String
    public var flags: UInt32
    public var isFile: Bool
    public var isCreated: Bool
    public var isModified: Bool
    public var isRemoved: Bool

    public init(
        path: String,
        flags: UInt32 = 0,
        isFile: Bool = false,
        isCreated: Bool = false,
        isModified: Bool = false,
        isRemoved: Bool = false
    ) {
        self.path = path
        self.flags = flags
        self.isFile = isFile
        self.isCreated = isCreated
        self.isModified = isModified
        self.isRemoved = isRemoved
    }
}
