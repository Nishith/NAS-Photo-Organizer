import Foundation
import CoreServices

/// FSEvents-based folder watcher that streams file-system change events.
/// Designed for background duplicate monitoring (Feature 10).
///
/// Threading model
/// ---------------
/// `streamRef`, `continuation`, and `pollingTask` are guarded by
/// `stateLock` (NSLock, recursive-safe in practice because we only
/// hold it across short pointer-snapshot operations and never call out
/// to FSEvents APIs or `Continuation.yield` while holding it).
///
/// Why a lock and not `queue.sync`: `onTermination` on the
/// `AsyncStream.Continuation` can fire on `queue` itself (when stream
/// completion is processed by an iterator pulling on that queue). If
/// `stop()` then called `queue.sync`, dispatch would detect the
/// same-queue deadlock and trap with SIGTRAP via
/// `__DISPATCH_WAIT_FOR_QUEUE__`. NSLock side-steps that entirely.
///
/// Lifetime model
/// --------------
/// The FSEventStream holds a +1 retain on `self` via the retain/release
/// callbacks installed in `FSEventStreamContext`. `self` therefore stays
/// alive for as long as the stream exists, which makes the
/// `takeUnretainedValue` in the FSEvents callback safe — the retained
/// reference holds the floor until `FSEventStreamRelease` triggers the
/// release callback at the end of `stop()`.
///
/// Polling vs FSEvents
/// -------------------
/// Polling is a *fallback*, not a supplement. It only starts when
/// `FSEventStreamCreate` returns nil. Running both at once would yield
/// every event twice — once from FSEvents, once from the next poll tick.
public final class FileSystemMonitor: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    /// When true, `start()` skips the FSEvents path entirely and goes
    /// straight to the polling fallback. Exists so unit tests can
    /// exercise the polling branch without having to engineer an
    /// `FSEventStreamCreate` failure (which is rare in practice).
    /// Production code always uses the FSEvents path.
    private let forcePollingOnly: Bool

    private let queue = DispatchQueue(label: "com.chronoframe.fsmonitor", qos: .utility)
    private let stateLock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var continuation: AsyncStream<[FileSystemEvent]>.Continuation?
    private var pollingTask: Task<Void, Never>?

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public init(paths: [String], latency: TimeInterval = 2.0) {
        self.paths = paths
        self.latency = latency
        self.forcePollingOnly = false
    }

    /// Testing entry point: forces the polling-only fallback path so
    /// tests can verify the polling task without engineering an
    /// FSEventStreamCreate failure.
    init(paths: [String], latency: TimeInterval, forcePollingOnly: Bool) {
        self.paths = paths
        self.latency = latency
        self.forcePollingOnly = forcePollingOnly
    }

    deinit {
        // Tear down without re-entering the queue. By the time deinit
        // runs, the FSEventStream has already been released (it held a
        // strong reference via the retain callback while it was alive),
        // so there's nothing on the queue that depends on `self`.
        teardown()
    }

    public func start() -> AsyncStream<[FileSystemEvent]> {
        stop()

        return AsyncStream { continuation in
            self.withState { self.continuation = continuation }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }

            // Try FSEvents first; only fall back to polling if creation
            // fails. Running both at once would yield every event twice.
            // `forcePollingOnly` is a test seam (see init) that skips the
            // FSEvents branch entirely so the polling path can be
            // exercised without engineering an FSEventStreamCreate fail.
            if self.forcePollingOnly || !self.setupFSEvents() {
                self.startPollingFallback()
            }
        }
    }

    public func stop() {
        teardown()
    }

    private func teardown() {
        // Snapshot under the lock, then tear down outside the lock so the
        // FSEvents APIs and `Continuation.finish` never run while we
        // hold `stateLock` (some of those calls may themselves trigger
        // onTermination handlers that re-enter `stop()`).
        let (stream, continuation, polling): (FSEventStreamRef?, AsyncStream<[FileSystemEvent]>.Continuation?, Task<Void, Never>?) = withState {
            let s = self.streamRef
            let c = self.continuation
            let p = self.pollingTask
            self.streamRef = nil
            self.continuation = nil
            self.pollingTask = nil
            return (s, c, p)
        }
        polling?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation?.finish()
    }

    /// Returns true when the FSEventStream was created and started, false
    /// when `FSEventStreamCreate` returned nil so the caller can start
    /// the polling fallback in its place.
    private func setupFSEvents() -> Bool {
        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
            guard let clientInfo else { return }
            // `takeUnretainedValue` is safe: the retain callback below
            // bumped the refcount when the stream took ownership of the
            // `info` pointer.
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
                // Snapshot the continuation under `stateLock` so we
                // never race the assignment in `start()` or the nil-out
                // in `stop()`. Yielding is done outside the lock — yield
                // itself is documented thread-safe and we don't want to
                // hold `stateLock` across a callback into consumer code.
                let continuation = monitor.withState { monitor.continuation }
                continuation?.yield(events)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: fileSystemMonitorRetainCallback,
            release: fileSystemMonitorReleaseCallback,
            copyDescription: nil
        )

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
            return false
        }

        self.withState { self.streamRef = stream }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        FSEventStreamStart(stream)
        return true
    }

    private func startPollingFallback() {
        var snapshot = Self.pollingSnapshot(paths: paths)
        let interval = max(latency, 0.1)

        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }

                let nextSnapshot = Self.pollingSnapshot(paths: self.paths)
                let events = Self.pollingEvents(previous: snapshot, current: nextSnapshot)
                if !events.isEmpty {
                    let continuation = self.withState { self.continuation }
                    continuation?.yield(events)
                }
                snapshot = nextSnapshot
            }
        }
        self.withState { self.pollingTask = task }
    }

    static func pollingEvents(previous: [String: Bool], current: [String: Bool]) -> [FileSystemEvent] {
        let oldPaths = Set(previous.keys)
        let newPaths = Set(current.keys)

        var events: [FileSystemEvent] = []
        for path in newPaths.subtracting(oldPaths).sorted() {
            events.append(FileSystemEvent(
                path: path,
                isFile: current[path, default: false],
                isCreated: true
            ))
        }

        for path in oldPaths.subtracting(newPaths).sorted() {
            events.append(FileSystemEvent(
                path: path,
                isFile: previous[path, default: false],
                isRemoved: true
            ))
        }

        return events
    }

    static func pollingSnapshot(paths: [String]) -> [String: Bool] {
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

// Top-level C-callable retain/release functions for the FSEventStreamContext.
// Declared at file scope so the @convention(c) conversion is unambiguous.
private func fileSystemMonitorRetainCallback(_ ptr: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let ptr else { return nil }
    _ = Unmanaged<FileSystemMonitor>.fromOpaque(ptr).retain()
    return ptr
}

private func fileSystemMonitorReleaseCallback(_ ptr: UnsafeRawPointer?) {
    guard let ptr else { return }
    Unmanaged<FileSystemMonitor>.fromOpaque(ptr).release()
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
