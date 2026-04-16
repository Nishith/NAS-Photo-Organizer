import Foundation
import XCTest
@testable import ChronoframeAppCore

final class PreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistsScalarPreferencesAcrossReinit() {
        let store = PreferencesStore(defaults: defaults)
        store.workerCount = 12
        store.useFastDestinationScan = true
        store.verifyCopies = true
        store.lastManualSourcePath = "/tmp/source"
        store.lastManualDestinationPath = "/tmp/destination"
        store.lastSelectedProfileName = "travel"

        let reloaded = PreferencesStore(defaults: defaults)

        XCTAssertEqual(reloaded.workerCount, 12)
        XCTAssertTrue(reloaded.useFastDestinationScan)
        XCTAssertTrue(reloaded.verifyCopies)
        XCTAssertEqual(reloaded.lastManualSourcePath, "/tmp/source")
        XCTAssertEqual(reloaded.lastManualDestinationPath, "/tmp/destination")
        XCTAssertEqual(reloaded.lastSelectedProfileName, "travel")
    }

    func testLogBufferCapacityClampsToConfiguredBounds() {
        let store = PreferencesStore(defaults: defaults)

        store.logBufferCapacity = 1
        XCTAssertEqual(store.logBufferCapacity, PreferencesStore.minimumLogCapacity)

        store.logBufferCapacity = PreferencesStore.maximumLogCapacity + 500
        XCTAssertEqual(store.logBufferCapacity, PreferencesStore.maximumLogCapacity)
    }

    func testBookmarkRoundTripAndRemoval() {
        let store = PreferencesStore(defaults: defaults)
        let bookmark = FolderBookmark(
            key: "manual.source",
            path: "/Volumes/Card",
            data: Data([0x01, 0x02, 0x03])
        )

        store.storeBookmark(bookmark)
        XCTAssertEqual(store.bookmark(for: "manual.source"), bookmark)

        store.removeBookmark(for: "manual.source")
        XCTAssertNil(store.bookmark(for: "manual.source"))
    }
}
