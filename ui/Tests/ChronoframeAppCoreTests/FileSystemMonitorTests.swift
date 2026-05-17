import XCTest
@testable import ChronoframeCore

final class FileSystemMonitorTests: XCTestCase {
    func testFileSystemMonitorEmitsEventsOnCreation() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let monitor = FileSystemMonitor(paths: [temporaryDirectory.path], latency: 0.1)
        let stream = monitor.start()

        let fileURL = temporaryDirectory.appendingPathComponent("test.txt")

        // Use a task to collect events
        let expectation = XCTestExpectation(description: "Wait for FS events")

        actor EventCollector {
            var events: [FileSystemEvent] = []
            func append(_ newEvents: [FileSystemEvent]) { events.append(contentsOf: newEvents) }
            func contains(path: String) -> Bool { events.contains { $0.path.contains(path) } }
            func first(path: String) -> FileSystemEvent? { events.first { $0.path.contains(path) } }
            var isEmpty: Bool { events.isEmpty }
        }
        let collector = EventCollector()

        let task = Task {
            for await events in stream {
                await collector.append(events)
                if await collector.contains(path: "test.txt") {
                    expectation.fulfill()
                }
            }
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        // Trigger event
        try Data("hello".utf8).write(to: fileURL)

        await fulfillment(of: [expectation], timeout: 5.0)

        let isEmpty = await collector.isEmpty
        XCTAssertFalse(isEmpty)
        let firstEvent = await collector.first(path: "test.txt")
        let event = try XCTUnwrap(firstEvent)
        XCTAssertTrue(event.isFile)

        task.cancel()
        monitor.stop()
    }

    func testFileSystemMonitorHandlesDeletion() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorDeleteTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("to_delete.txt")
        try Data("delete me".utf8).write(to: fileURL)

        let monitor = FileSystemMonitor(paths: [temporaryDirectory.path], latency: 0.1)
        let stream = monitor.start()

        let expectation = XCTestExpectation(description: "Wait for deletion event")

        actor EventCollector {
            var events: [FileSystemEvent] = []
            func append(_ newEvents: [FileSystemEvent]) { events.append(contentsOf: newEvents) }
            func containsRemoved(path: String) -> Bool { events.contains { $0.path.contains(path) && $0.isRemoved } }
        }
        let collector = EventCollector()

        let task = Task {
            for await events in stream {
                await collector.append(events)
                if await collector.containsRemoved(path: "to_delete.txt") {
                    expectation.fulfill()
                }
            }
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        // Trigger deletion
        try FileManager.default.removeItem(at: fileURL)

        await fulfillment(of: [expectation], timeout: 5.0)

        task.cancel()
        monitor.stop()
    }

    func testPollingSnapshotIncludesRootsAndNestedItems() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorSnapshotTest-\(UUID().uuidString)")
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        let fileURL = nestedDirectory.appendingPathComponent("image.jpg")
        let rootFileURL = temporaryDirectory.appendingPathComponent("loose.mov")
        let missingURL = temporaryDirectory.appendingPathComponent("missing")

        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: fileURL)
        try Data("mov".utf8).write(to: rootFileURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let snapshot = FileSystemMonitor.pollingSnapshot(paths: [
            temporaryDirectory.path,
            rootFileURL.path,
            missingURL.path
        ])

        XCTAssertEqual(snapshot[temporaryDirectory.path], false)
        XCTAssertEqual(snapshot.first { $0.key.hasSuffix("/Nested") }?.value, false)
        XCTAssertEqual(snapshot.first { $0.key.hasSuffix("/Nested/image.jpg") }?.value, true)
        XCTAssertEqual(snapshot[rootFileURL.path], true)
        XCTAssertNil(snapshot[missingURL.path])
    }

    func testPollingEventsReportsCreatedAndRemovedPathsInStableOrder() {
        let previous = [
            "/tmp/a-old-directory": false,
            "/tmp/z-old-file": true
        ]
        let current = [
            "/tmp/b-new-file": true,
            "/tmp/c-new-directory": false
        ]

        let events = FileSystemMonitor.pollingEvents(previous: previous, current: current)

        XCTAssertEqual(events.map(\.path), [
            "/tmp/b-new-file",
            "/tmp/c-new-directory",
            "/tmp/a-old-directory",
            "/tmp/z-old-file"
        ])
        XCTAssertEqual(events.map(\.isCreated), [true, true, false, false])
        XCTAssertEqual(events.map(\.isRemoved), [false, false, true, true])
        XCTAssertEqual(events.map(\.isFile), [true, false, false, true])
    }

    /// Regression for PHASE2_FINDINGS.md NEW3 — `start()` used to launch
    /// `startPollingFallback()` unconditionally and THEN set up FSEvents,
    /// so every real filesystem change emitted twice (once from the
    /// FSEvents callback, once from the next poll tick). Now the polling
    /// fallback only fires when `FSEventStreamCreate` returns nil.
    func testFileSystemMonitorDoesNotDoubleYieldEventsWhenFSEventsIsActive() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorNoDoubleYield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // Use a very small latency to make FSEvents and the polling
        // fallback both have a realistic chance to fire within the test
        // window, were the bug to regress.
        let monitor = FileSystemMonitor(paths: [temporaryDirectory.path], latency: 0.1)
        let stream = monitor.start()

        actor Counter {
            var perPathCreated: [String: Int] = [:]
            func bump(_ path: String) { perPathCreated[path, default: 0] += 1 }
            func count(_ path: String) -> Int { perPathCreated[path] ?? 0 }
        }
        let counter = Counter()

        let task = Task {
            for await events in stream {
                for event in events where event.isCreated {
                    await counter.bump(event.path)
                }
            }
        }

        // Settle.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Create three files. Each should produce at most one "isCreated"
        // event per path. If the polling fallback is running alongside
        // FSEvents, we'd see two — one from each source.
        let urls = (0..<3).map {
            temporaryDirectory.appendingPathComponent("file-\($0).txt")
        }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }

        // Give both potential producers more than enough time to fire.
        try await Task.sleep(nanoseconds: 800_000_000)

        for url in urls {
            let count = await counter.count(url.path)
            XCTAssertLessThanOrEqual(
                count, 1,
                "NEW3 regression: path \(url.path) emitted \(count) created events; expected ≤1"
            )
        }

        task.cancel()
        monitor.stop()
    }

    /// Regression for PHASE2_FINDINGS.md NEW4 — repeated start/stop
    /// cycles must not crash from unsynchronized continuation mutation.
    /// The classic failure was `__DISPATCH_WAIT_FOR_QUEUE__` SIGTRAP
    /// when `onTermination` fired on the FSEvents queue while `stop()`
    /// tried to take that same queue.
    func testFileSystemMonitorSurvivesRepeatedStartStopCycles() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let monitor = FileSystemMonitor(paths: [temporaryDirectory.path], latency: 0.1)
        for _ in 0..<5 {
            let stream = monitor.start()
            let task = Task {
                for await _ in stream {}
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            monitor.stop()
            task.cancel()
        }
        // Reaching here means no deadlock or trap during teardown.
    }

    /// Regression for PHASE2_FINDINGS.md NEW5 — the FSEvents callback
    /// used to dereference an unmanaged `self` pointer that could outlive
    /// the monitor. With retain/release callbacks installed on the
    /// FSEventStreamContext, the stream holds a +1 retain on `self` while
    /// it's alive. This test exercises the lifetime contract by letting
    /// `monitor` go out of scope while a stream is mid-flight.
    func testFileSystemMonitorReleasesItselfCleanlyWhenDroppedMidStream() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorDrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // Hold a weak reference so we can verify the monitor is actually
        // deallocated after the stream consumer drops.
        weak var weakMonitor: FileSystemMonitor?

        do {
            let monitor = FileSystemMonitor(paths: [temporaryDirectory.path], latency: 0.1)
            weakMonitor = monitor
            let stream = monitor.start()
            try Data("trigger".utf8).write(
                to: temporaryDirectory.appendingPathComponent("triggers-callback.txt")
            )
            // Pull one batch then stop iterating — the AsyncStream's
            // onTermination fires, which calls stop(), which releases the
            // FSEventStream, which fires the release callback, which
            // releases the retained `self`.
            for await _ in stream { break }
            monitor.stop()
        }

        // Give the runtime a tick to clean up.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(weakMonitor, "NEW5 regression: monitor leaked after stream consumer dropped")
    }

    /// Exercises the polling fallback path directly via the
    /// `forcePollingOnly: true` test seam so the fallback's Task loop
    /// (`startPollingFallback`) is covered without having to engineer an
    /// `FSEventStreamCreate` failure (which is rare and platform-
    /// specific in practice).
    func testPollingFallbackEmitsCreatedAndRemovedEvents() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSMonitorPolling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let monitor = FileSystemMonitor(
            paths: [temporaryDirectory.path],
            latency: 0.1,
            forcePollingOnly: true
        )
        let stream = monitor.start()

        actor Sink {
            var created: Set<String> = []
            var removed: Set<String> = []
            func recordCreated(_ p: String) { created.insert(p) }
            func recordRemoved(_ p: String) { removed.insert(p) }
            func sawCreated(_ suffix: String) -> Bool { created.contains { $0.hasSuffix(suffix) } }
            func sawRemoved(_ suffix: String) -> Bool { removed.contains { $0.hasSuffix(suffix) } }
        }
        let sink = Sink()
        let task = Task {
            for await events in stream {
                for event in events {
                    if event.isCreated { await sink.recordCreated(event.path) }
                    if event.isRemoved { await sink.recordRemoved(event.path) }
                }
            }
        }

        let target = temporaryDirectory.appendingPathComponent("poll-target.txt")
        try Data("poll".utf8).write(to: target)
        // Polling interval is `max(latency, 0.1)` = 0.1s; give 3 ticks.
        try await Task.sleep(nanoseconds: 400_000_000)
        let created = await sink.sawCreated("poll-target.txt")
        XCTAssertTrue(created, "Polling fallback should emit a created event for new file")

        try FileManager.default.removeItem(at: target)
        try await Task.sleep(nanoseconds: 400_000_000)
        let removed = await sink.sawRemoved("poll-target.txt")
        XCTAssertTrue(removed, "Polling fallback should emit a removed event for deleted file")

        task.cancel()
        monitor.stop()
    }

    func testPollingEventsReturnsNoEventsForUnchangedSnapshot() {
        let snapshot = [
            "/tmp/folder": false,
            "/tmp/folder/photo.heic": true
        ]

        XCTAssertTrue(FileSystemMonitor.pollingEvents(previous: snapshot, current: snapshot).isEmpty)
    }

}
