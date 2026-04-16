import Foundation
import XCTest
@testable import ChronoframeAppCore

final class SetupStoreTests: XCTestCase {
    func testUpdateProfilesSortsAndClearsMissingSelection() {
        let store = SetupStore(
            sourcePath: "/tmp/src",
            destinationPath: "/tmp/dst",
            selectedProfileName: "missing",
            profiles: [Profile(name: "missing", sourcePath: "/tmp/src", destinationPath: "/tmp/dst")]
        )

        store.updateProfiles([
            Profile(name: "zulu", sourcePath: "/tmp/z-src", destinationPath: "/tmp/z-dst"),
            Profile(name: "alpha", sourcePath: "/tmp/a-src", destinationPath: "/tmp/a-dst"),
        ])

        XCTAssertEqual(store.profiles.map(\.name), ["alpha", "zulu"])
        XCTAssertEqual(store.selectedProfileName, "")
        XCTAssertFalse(store.usingProfile)
    }

    func testSelectProfileCopiesPathsAndClearRemovesSelection() {
        let store = SetupStore(profiles: [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ])

        store.selectProfile(named: "  travel  ")

        XCTAssertEqual(store.selectedProfileName, "travel")
        XCTAssertEqual(store.sourcePath, "/Volumes/Card")
        XCTAssertEqual(store.destinationPath, "/Volumes/Trips")
        XCTAssertEqual(store.activeProfile?.name, "travel")

        store.clearProfileSelection()
        XCTAssertEqual(store.selectedProfileName, "")
        XCTAssertNil(store.activeProfile)
    }

    // MARK: - canStartRun logic (mirrors SetupView.canStartRun)

    func testCanStartRunIsFalseWhenBothManualPathsAreEmpty() {
        let store = SetupStore(sourcePath: "", destinationPath: "")
        XCTAssertFalse(store.usingProfile)
        XCTAssertFalse(canStartRun(store), "Should not be able to start without paths or profile")
    }

    func testCanStartRunIsFalseWhenOnlySourceIsSet() {
        let store = SetupStore(sourcePath: "/tmp/src", destinationPath: "")
        XCTAssertFalse(store.usingProfile)
        XCTAssertFalse(canStartRun(store))
    }

    func testCanStartRunIsFalseWhenOnlyDestinationIsSet() {
        let store = SetupStore(sourcePath: "", destinationPath: "/tmp/dst")
        XCTAssertFalse(store.usingProfile)
        XCTAssertFalse(canStartRun(store))
    }

    func testCanStartRunIsTrueWhenBothManualPathsAreSet() {
        let store = SetupStore(sourcePath: "/tmp/src", destinationPath: "/tmp/dst")
        XCTAssertFalse(store.usingProfile)
        XCTAssertTrue(canStartRun(store))
    }

    func testCanStartRunIsTrueWhenProfileIsSelected() {
        let store = SetupStore(profiles: [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ])
        store.selectProfile(named: "travel")
        XCTAssertTrue(store.usingProfile)
        XCTAssertTrue(canStartRun(store), "A selected profile should enable the run buttons even without manual paths")
    }

    func testCanStartRunIsFalseAfterClearingProfile() {
        let store = SetupStore(profiles: [
            Profile(name: "travel", sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Trips")
        ])
        store.selectProfile(named: "travel")
        store.clearProfileSelection()
        // Paths are populated from profile but no longer considered a "profile run"
        // and there are no bookmarked manual paths — usingProfile is false.
        XCTAssertFalse(store.usingProfile)
        // canStartRun is still true because source and destination paths are non-empty.
        XCTAssertTrue(canStartRun(store), "Non-empty paths from cleared profile should still allow run")
    }

    // Helper mirroring SetupView.canStartRun
    private func canStartRun(_ store: SetupStore) -> Bool {
        store.usingProfile || (!store.sourcePath.isEmpty && !store.destinationPath.isEmpty)
    }

    func testMakeConfigurationUsesTrimmedPathsAndPreferenceFlags() {
        let suiteName = "SetupStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = PreferencesStore(defaults: defaults)
        preferences.workerCount = 0
        preferences.useFastDestinationScan = true
        preferences.verifyCopies = true

        let store = SetupStore(
            sourcePath: " /tmp/source ",
            destinationPath: " /tmp/destination ",
            selectedProfileName: "saved"
        )

        let configuration = store.makeConfiguration(preferences: preferences, mode: .transfer)

        XCTAssertEqual(configuration.mode, .transfer)
        XCTAssertEqual(configuration.sourcePath, "/tmp/source")
        XCTAssertEqual(configuration.destinationPath, "/tmp/destination")
        XCTAssertEqual(configuration.profileName, "saved")
        XCTAssertTrue(configuration.useFastDestinationScan)
        XCTAssertTrue(configuration.verifyCopies)
        XCTAssertEqual(configuration.workerCount, 1)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
