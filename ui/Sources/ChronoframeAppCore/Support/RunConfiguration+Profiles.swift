#if canImport(ChronoframeCore)
import ChronoframeCore
#endif

extension RunConfiguration {
    /// Replaces only the fields that come from a saved profile while preserving
    /// the run-scoped options chosen by the caller, such as folder structure.
    func resolving(profile: Profile) -> RunConfiguration {
        var resolved = self
        resolved.sourcePath = profile.sourcePath
        resolved.destinationPath = profile.destinationPath
        resolved.profileName = profile.name
        return resolved
    }
}
