import Foundation
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

@MainActor
final class MockOrganizerEngine: OrganizerEngine {
    enum StreamMode {
        case events([RunEvent])
        case fails(Error)
        case pending
    }

    var preflightResult: Result<RunPreflight, Error>
    var startMode: StreamMode
    var resumeMode: StreamMode
    var startConfigurations: [RunConfiguration] = []
    var resumeConfigurations: [RunConfiguration] = []
    var cancelCallCount = 0
    var pendingContinuation: AsyncThrowingStream<RunEvent, Error>.Continuation?

    init(
        preflightResult: Result<RunPreflight, Error>,
        startMode: StreamMode = .events([]),
        resumeMode: StreamMode = .events([])
    ) {
        self.preflightResult = preflightResult
        self.startMode = startMode
        self.resumeMode = resumeMode
    }

    func preflight(_ configuration: RunConfiguration) async throws -> RunPreflight {
        try preflightResult.get()
    }

    func start(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        startConfigurations.append(configuration)
        return try makeStream(for: startMode)
    }

    func resume(_ configuration: RunConfiguration) throws -> AsyncThrowingStream<RunEvent, Error> {
        resumeConfigurations.append(configuration)
        return try makeStream(for: resumeMode)
    }

    func cancelCurrentRun() {
        cancelCallCount += 1
        pendingContinuation?.finish()
        pendingContinuation = nil
    }

    private func makeStream(for mode: StreamMode) throws -> AsyncThrowingStream<RunEvent, Error> {
        switch mode {
        case let .events(events):
            return AsyncThrowingStream { continuation in
                Task { @MainActor in
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
        case let .fails(error):
            throw error
        case .pending:
            return AsyncThrowingStream { continuation in
                self.pendingContinuation = continuation
            }
        }
    }
}

@MainActor
final class MockFolderAccessService: FolderAccessServicing {
    var nextChosenFolder: URL?
    var chooseFolderCalls: [(startingAt: String?, prompt: String)] = []
    var bookmarkURLs: [URL] = []
    var resolvedBookmarks: [String: ResolvedFolderBookmark] = [:]
    var validationFailures: [String: Error] = [:]
    /// Force `makeBookmark` to throw the next time it is called for any
    /// of these bookmark keys. Used to verify that the dedupe folder
    /// picker surfaces a transient error instead of silently swallowing
    /// `try?`.
    var bookmarkCreationFailures: [String: Error] = [:]
    /// Force `resolveBookmark` to return `nil` for any of these keys.
    /// Used to verify that bootstrap clears the stale path when the
    /// stored bookmark no longer resolves.
    var bookmarkResolutionFailures: Set<String> = []

    func chooseFolder(startingAt path: String?, prompt: String) -> URL? {
        chooseFolderCalls.append((startingAt: path, prompt: prompt))
        return nextChosenFolder
    }

    func makeBookmark(for url: URL, key: String) throws -> FolderBookmark {
        if let error = bookmarkCreationFailures[key] {
            throw error
        }
        bookmarkURLs.append(url)
        return FolderBookmark(key: key, path: url.path, data: Data(url.path.utf8))
    }

    func resolveBookmark(_ bookmark: FolderBookmark) -> ResolvedFolderBookmark? {
        if bookmarkResolutionFailures.contains(bookmark.key) {
            return nil
        }
        return resolvedBookmarks[bookmark.key] ?? ResolvedFolderBookmark(url: URL(fileURLWithPath: bookmark.path))
    }

    func validateFolder(_ url: URL, role: FolderRole) throws {
        if let error = validationFailures[url.path] {
            throw error
        }
    }
}

@MainActor
final class MockFinderService: FinderServicing {
    var openedPaths: [String] = []
    var revealedPaths: [String] = []

    func openPath(_ path: String) {
        openedPaths.append(path)
    }

    func revealInFinder(_ path: String) {
        revealedPaths.append(path)
    }
}

final class MockProfilesRepository: ProfilesRepositorying {
    var profiles: [Profile] = []
    var savedProfiles: [Profile] = []
    var deletedProfileNames: [String] = []
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?

    func profilesFileURL() -> URL {
        URL(fileURLWithPath: "/tmp/mock-profiles.yaml")
    }

    func loadProfiles() throws -> [Profile] {
        if let loadError {
            throw loadError
        }
        return profiles
    }

    func save(profile: Profile) throws {
        if let saveError {
            throw saveError
        }
        savedProfiles.append(profile)
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
    }

    func deleteProfile(named name: String) throws {
        if let deleteError {
            throw deleteError
        }
        deletedProfileNames.append(name)
        profiles.removeAll { $0.name == name }
    }
}
