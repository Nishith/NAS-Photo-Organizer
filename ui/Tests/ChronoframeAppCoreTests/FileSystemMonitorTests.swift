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

    func testPollingEventsReturnsNoEventsForUnchangedSnapshot() {
        let snapshot = [
            "/tmp/folder": false,
            "/tmp/folder/photo.heic": true
        ]

        XCTAssertTrue(FileSystemMonitor.pollingEvents(previous: snapshot, current: snapshot).isEmpty)
    }

}
