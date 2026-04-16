#if canImport(ChronoframeCore)
import ChronoframeCore
#endif
import Foundation

public protocol ProfilesRepositorying: AnyObject {
    func profilesFileURL() -> URL
    func loadProfiles() throws -> [Profile]
    func save(profile: Profile) throws
    func deleteProfile(named name: String) throws
}

public final class ProfilesRepository: ProfilesRepositorying, Sendable {
    public init() {}

    public func profilesFileURL() -> URL {
        RuntimePaths.profilesFileURL()
    }

    public func loadProfiles() throws -> [Profile] {
        let url = profilesFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parseProfiles(contents)
    }

    public func save(profile: Profile) throws {
        var profiles = try loadProfiles()
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
        try write(profiles: profiles)
    }

    public func deleteProfile(named name: String) throws {
        let profiles = try loadProfiles().filter { $0.name != name }
        try write(profiles: profiles)
    }

    private func write(profiles: [Profile]) throws {
        let url = profilesFileURL()
        let orderedProfiles = profiles.sorted { lhs, rhs in
            if lhs.name == "default" { return true }
            if rhs.name == "default" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let body = orderedProfiles.map { profile in
            """
            \(profile.name):
              source: "\(escape(profile.sourcePath))"
              dest: "\(escape(profile.destinationPath))"
            """
        }
        .joined(separator: "\n\n")

        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        try (body + (body.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    private func parseProfiles(_ contents: String) -> [Profile] {
        var profiles: [Profile] = []
        var currentName: String?
        var currentSource = ""
        var currentDestination = ""

        func flushProfile() {
            guard let currentName, !currentName.isEmpty else { return }
            profiles.append(Profile(name: currentName, sourcePath: currentSource, destinationPath: currentDestination))
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if !rawLine.hasPrefix(" ") && line.hasSuffix(":") {
                flushProfile()
                currentName = String(line.dropLast())
                currentSource = ""
                currentDestination = ""
                continue
            }

            if line.hasPrefix("source:") {
                currentSource = unescape(extractValue(from: line))
                continue
            }

            if line.hasPrefix("dest:") {
                currentDestination = unescape(extractValue(from: line))
            }
        }

        flushProfile()
        return profiles
    }

    private func extractValue(from line: String) -> String {
        guard let separatorIndex = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func unescape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
