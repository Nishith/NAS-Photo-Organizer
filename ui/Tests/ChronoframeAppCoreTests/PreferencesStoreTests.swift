import Foundation
import XCTest
@testable import ChronoframeAppCore

final class PreferencesStoreTests: XCTestCase {
    // Class is intentionally nonisolated so the nonisolated XCTestCase
    // setUp/tearDown overrides compile under Swift 6 strict concurrency
    // (calling `super.setUp()` from a @MainActor subclass triggers
    // "sending main actor-isolated value of type XCTestCase to
    // nonisolated context"). Test methods that touch the @MainActor
    // PreferencesStore are individually marked `@MainActor` instead.
    // `nonisolated(unsafe)` is safe because XCTest invokes setUp,
    // tearDown, and each test method serially on the main thread, so
    // there's no concurrent access in practice.
    private nonisolated(unsafe) var suiteName: String!
    private nonisolated(unsafe) var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    @MainActor
    func testPersistsScalarPreferencesAcrossReinit() {
        let store = PreferencesStore(defaults: defaults)
        store.workerCount = 12
        store.verifyCopies = true
        store.parallelTransferEnabled = true
        store.lastManualSourcePath = "/tmp/source"
        store.lastManualDestinationPath = "/tmp/destination"
        store.lastDeduplicateDestinationPath = "/tmp/dedupe"
        store.lastSelectedProfileName = "travel"

        let reloaded = PreferencesStore(defaults: defaults)

        XCTAssertEqual(reloaded.workerCount, 12)
        XCTAssertTrue(reloaded.verifyCopies)
        XCTAssertTrue(reloaded.parallelTransferEnabled)
        XCTAssertEqual(reloaded.lastManualSourcePath, "/tmp/source")
        XCTAssertEqual(reloaded.lastManualDestinationPath, "/tmp/destination")
        XCTAssertEqual(reloaded.lastDeduplicateDestinationPath, "/tmp/dedupe")
        XCTAssertEqual(reloaded.lastSelectedProfileName, "travel")
    }

    @MainActor
    func testLogBufferCapacityClampsToConfiguredBounds() {
        let store = PreferencesStore(defaults: defaults)

        store.logBufferCapacity = 1
        XCTAssertEqual(store.logBufferCapacity, PreferencesStore.minimumLogCapacity)

        store.logBufferCapacity = PreferencesStore.maximumLogCapacity + 500
        XCTAssertEqual(store.logBufferCapacity, PreferencesStore.maximumLogCapacity)
    }

    @MainActor
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

    // MARK: - Schema migration framework

    @MainActor
    func testInitOnFreshDefaultsStampsCurrentSchemaVersion() {
        XCTAssertEqual(PreferencesStore.storedSchemaVersion(in: defaults), 0)
        _ = PreferencesStore(defaults: defaults)
        XCTAssertEqual(
            PreferencesStore.storedSchemaVersion(in: defaults),
            PreferencesStore.currentPreferencesSchemaVersion
        )
    }

    @MainActor
    func testRunPendingMigrationsIsIdempotentOnAlreadyCurrentDefaults() {
        // First init writes the version.
        _ = PreferencesStore(defaults: defaults)
        // Second invocation is a no-op (current == target).
        PreferencesStore.runPendingMigrations(in: defaults)
        XCTAssertEqual(
            PreferencesStore.storedSchemaVersion(in: defaults),
            PreferencesStore.currentPreferencesSchemaVersion
        )
    }

    @MainActor
    func testLegacyDefaultsWithoutVersionAreMigratedWithoutLosingValues() {
        // Simulate a pre-versioning install: stored values exist but the
        // schema-version key is absent. Construction must seed the
        // version while leaving every existing value intact.
        defaults.set(20, forKey: "workerCount")
        defaults.set("/legacy/source", forKey: "lastManualSourcePath")
        XCTAssertEqual(PreferencesStore.storedSchemaVersion(in: defaults), 0)

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(
            PreferencesStore.storedSchemaVersion(in: defaults),
            PreferencesStore.currentPreferencesSchemaVersion
        )
        XCTAssertEqual(store.workerCount, 20)
        XCTAssertEqual(store.lastManualSourcePath, "/legacy/source")
    }
}
