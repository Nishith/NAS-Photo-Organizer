import XCTest
@testable import ChronoframeAppCore
import ChronoframeCore

@MainActor
final class BackgroundDedupeMonitorTests: XCTestCase {
    func testBackgroundDedupeMonitorStartsAndStops() {
        let monitor = BackgroundDedupeMonitor()
        XCTAssertFalse(monitor.isMonitoring)
        
        let config = DeduplicateConfiguration(destinationPath: "/tmp/fake")
        monitor.startMonitoring(configuration: config)
        XCTAssertTrue(monitor.isMonitoring)
        
        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testBackgroundDedupeMonitorClearsPending() {
        let monitor = BackgroundDedupeMonitor()
        monitor.pendingClusters = [DuplicateCluster(kind: .exactDuplicate, members: [], suggestedKeeperIDs: [], bytesIfPruned: 100)]
        monitor.pendingBytes = 100
        
        XCTAssertEqual(monitor.badgeCount, 1)
        
        monitor.clearPending()
        XCTAssertEqual(monitor.badgeCount, 0)
        XCTAssertEqual(monitor.pendingBytes, 0)
    }

    func testBackgroundDedupeMonitorIncrementalScanTrigger() async throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorTriggerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let monitor = BackgroundDedupeMonitor()
        let config = DeduplicateConfiguration(destinationPath: temporaryDirectory.path)
        
        monitor.startMonitoring(configuration: config)
        
        let fileURL = temporaryDirectory.appendingPathComponent("trigger.jpg")
        try Data("fake image content".utf8).write(to: fileURL)
        
        // Wait for fsMonitor latency (2.0s) plus a bit, so it hits scheduleIncrementalScan
        try await Task.sleep(nanoseconds: 2_500_000_000)
        
        // Direct call to hit runIncrementalScan without waiting 5.0s
        await monitor.runIncrementalScan(changedPaths: [fileURL.path], configuration: config)
        
        monitor.stopMonitoring()
    }
    
    func testBackgroundDedupeMonitorIncrementalScanError() async throws {
        let monitor = BackgroundDedupeMonitor()
        let config = DeduplicateConfiguration(destinationPath: "/non/existent/path")
        
        // Direct call to trigger scanner error and catch block
        await monitor.runIncrementalScan(changedPaths: ["/non/existent/path/trigger.jpg"], configuration: config)
    }
}
