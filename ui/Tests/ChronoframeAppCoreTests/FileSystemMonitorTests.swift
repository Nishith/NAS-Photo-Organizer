import XCTest
import ChronoframeCore

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
        
        // Trigger deletion
        try FileManager.default.removeItem(at: fileURL)
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        task.cancel()
        monitor.stop()
    }
}
