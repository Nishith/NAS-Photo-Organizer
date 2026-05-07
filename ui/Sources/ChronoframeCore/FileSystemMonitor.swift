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
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        continuation?.finish()
        continuation = nil
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
