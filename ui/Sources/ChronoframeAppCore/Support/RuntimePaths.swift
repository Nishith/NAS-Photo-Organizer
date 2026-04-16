import Foundation

public enum AppEnginePreference: String, Equatable, Sendable {
    case swift
    case python
}

public enum RuntimePaths {
    public static func backendRootURL() -> URL? {
        if let bundled = bundledBackendRootURL() {
            return bundled
        }

        if let repositoryRoot = repositoryRootURL() {
            return repositoryRoot
        }

        return nil
    }

    public static func backendScriptURL() -> URL? {
        backendRootURL()?.appendingPathComponent("chronoframe.py")
    }

    public static func profilesFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CHRONOFRAME_PROFILES_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let repositoryRoot = repositoryRootURL() {
            return repositoryRoot.appendingPathComponent("profiles.yaml")
        }

        let appSupport = applicationSupportDirectory().appendingPathComponent("profiles.yaml")
        if !FileManager.default.fileExists(atPath: appSupport.deletingLastPathComponent().path) {
            try? FileManager.default.createDirectory(at: appSupport.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return appSupport
    }

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Chronoframe", isDirectory: true)
    }

    public static func appEnginePreference() -> AppEnginePreference {
        let environment = ProcessInfo.processInfo.environment
        let rawValue = environment["CHRONOFRAME_APP_ENGINE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch rawValue {
        case AppEnginePreference.python.rawValue:
            return .python
        default:
            return .swift
        }
    }

    private static func bundledBackendRootURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let bundled = resourceURL.appendingPathComponent("Backend", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("chronoframe.py").path) {
            return bundled
        }
        return nil
    }

    private static func repositoryRootURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CHRONOFRAME_REPOSITORY_ROOT"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("chronoframe.py").path) {
                return url
            }
        }

        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let script = candidate.appendingPathComponent("chronoframe.py")
            let packageDirectory = candidate.appendingPathComponent("chronoframe", isDirectory: true)
            if FileManager.default.fileExists(atPath: script.path) && FileManager.default.fileExists(atPath: packageDirectory.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }
}
