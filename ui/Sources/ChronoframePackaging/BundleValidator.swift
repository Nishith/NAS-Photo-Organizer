import Foundation

public struct SignatureInspection: Codable, Equatable, Sendable {
    public var available: Bool
    public var kind: String
    public var identifier: String?
    public var teamIdentifier: String?
    public var sealedResources: Bool
    public var hardenedRuntime: Bool
    public var timestamped: Bool
    public var authorities: [String]
    public var output: String

    public init(
        available: Bool,
        kind: String,
        identifier: String?,
        teamIdentifier: String?,
        sealedResources: Bool,
        hardenedRuntime: Bool,
        timestamped: Bool,
        authorities: [String] = [],
        output: String = ""
    ) {
        self.available = available
        self.kind = kind
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.sealedResources = sealedResources
        self.hardenedRuntime = hardenedRuntime
        self.timestamped = timestamped
        self.authorities = authorities
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case available
        case kind
        case identifier
        case teamIdentifier = "team_identifier"
        case sealedResources = "sealed_resources"
        case hardenedRuntime = "hardened_runtime"
        case timestamped
        case authorities
        case output
    }
}

public struct GatekeeperInspection: Codable, Equatable, Sendable {
    public var status: String
    public var returncode: Int32
    public var output: String

    public init(status: String, returncode: Int32, output: String) {
        self.status = status
        self.returncode = returncode
        self.output = output
    }
}

public struct BundleValidationResult: Codable, Equatable, Sendable {
    public var bundlePath: String
    public var bundleIdentifier: String?
    public var executablePath: String?
    public var infoPlistPath: String?
    public var distributionReady: Bool
    public var errors: [String]
    public var warnings: [String]
    public var signature: SignatureInspection?
    public var gatekeeper: GatekeeperInspection?

    public init(
        bundlePath: String,
        bundleIdentifier: String? = nil,
        executablePath: String? = nil,
        infoPlistPath: String? = nil,
        distributionReady: Bool = false,
        errors: [String] = [],
        warnings: [String] = [],
        signature: SignatureInspection? = nil,
        gatekeeper: GatekeeperInspection? = nil
    ) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.infoPlistPath = infoPlistPath
        self.distributionReady = distributionReady
        self.errors = errors
        self.warnings = warnings
        self.signature = signature
        self.gatekeeper = gatekeeper
    }

    enum CodingKeys: String, CodingKey {
        case bundlePath = "bundle_path"
        case bundleIdentifier = "bundle_identifier"
        case executablePath = "executable_path"
        case infoPlistPath = "info_plist_path"
        case distributionReady = "distribution_ready"
        case errors
        case warnings
        case signature
        case gatekeeper
    }
}

public enum BundleValidator {
    public static func extractPrefixedValue(_ output: String, prefix: String) -> String? {
        output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line)
            guard text.hasPrefix(prefix + "=") else { return nil }
            return text.split(separator: "=", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        }.first
    }

    public static func inspectCodesign(appURL: URL, runner: ShellCommandRunner = .live) -> SignatureInspection {
        let result = runner.run(
            "/usr/bin/codesign",
            ["-dvvv", "--entitlements", ":-", appURL.path]
        )
        let output = result.combinedOutput
        guard result.returnCode == 0 else {
            return SignatureInspection(
                available: false,
                kind: "unsigned",
                identifier: nil,
                teamIdentifier: nil,
                sealedResources: false,
                hardenedRuntime: false,
                timestamped: false,
                output: output
            )
        }

        let authorities = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line)
            guard text.hasPrefix("Authority=") else { return nil }
            return text.split(separator: "=", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        let kind: String
        if output.contains("Signature=adhoc") {
            kind = "adhoc"
        } else if authorities.contains(where: { $0.hasPrefix("Apple Distribution:") }) {
            kind = "apple-distribution"
        } else if authorities.contains(where: { $0.hasPrefix("3rd Party Mac Developer Application:") }) {
            kind = "apple-distribution"
        } else if authorities.contains(where: { $0.hasPrefix("Developer ID Application:") }) {
            kind = "developer-id"
        } else {
            kind = "unknown"
        }

        return SignatureInspection(
            available: true,
            kind: kind,
            identifier: extractPrefixedValue(output, prefix: "Identifier"),
            teamIdentifier: extractPrefixedValue(output, prefix: "TeamIdentifier"),
            sealedResources: output.contains("Sealed Resources version=2"),
            hardenedRuntime: output.contains("Runtime Version="),
            timestamped: output.contains("Timestamp=") || output.contains("Signed Time="),
            authorities: authorities,
            output: output
        )
    }

    public static func inspectGatekeeper(appURL: URL, runner: ShellCommandRunner = .live) -> GatekeeperInspection {
        let result = runner.run("/usr/sbin/spctl", ["-a", "-vv", appURL.path])
        let output = result.combinedOutput
        let status: String
        if result.returnCode == 0 {
            status = "accepted"
        } else if output.localizedCaseInsensitiveContains("rejected") {
            status = "rejected"
        } else {
            status = "unavailable"
        }
        return GatekeeperInspection(status: status, returncode: result.returnCode, output: output)
    }

    public static func validateAppBundle(
        appURL: URL,
        requireDistributionSigning: Bool = false,
        appStore: Bool = false,
        codesignInspector: ((URL) -> SignatureInspection)? = nil,
        gatekeeperInspector: ((URL) -> GatekeeperInspection)? = nil,
        runner: ShellCommandRunner = .live
    ) -> BundleValidationResult {
        var result = BundleValidationResult(bundlePath: appURL.path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory) else {
            result.errors.append("Bundle does not exist: \(appURL.path)")
            return result
        }
        guard isDirectory.boolValue else {
            result.errors.append("Bundle path is not a directory: \(appURL.path)")
            return result
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        result.infoPlistPath = infoURL.path
        guard fileManager.fileExists(atPath: infoURL.path) else {
            result.errors.append("Missing Info.plist: \(infoURL.path)")
            return result
        }

        let info: [String: Any]
        do {
            let data = try Data(contentsOf: infoURL)
            guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                result.errors.append("Info.plist is not a dictionary: \(infoURL.path)")
                return result
            }
            info = plist
        } catch {
            result.errors.append("Unable to read Info.plist: \(error)")
            return result
        }

        result.bundleIdentifier = info["CFBundleIdentifier"] as? String
        if let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty {
            let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
            result.executablePath = executableURL.path
            if !fileManager.fileExists(atPath: executableURL.path) {
                result.errors.append("Missing app executable: \(executableURL.path)")
            }
        } else {
            result.errors.append("Info.plist is missing CFBundleExecutable.")
        }

        if info["CFBundleIconFile"] as? String != "AppIcon" {
            result.errors.append("Info.plist must declare CFBundleIconFile=AppIcon.")
        }
        if info["CFBundlePackageType"] as? String != "APPL" {
            result.errors.append("Info.plist must declare CFBundlePackageType=APPL.")
        }

        let appIconURL = appURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if !fileManager.fileExists(atPath: appIconURL.path) {
            result.errors.append("Missing packaged resource: \(appIconURL.path)")
        }

        let retiredBackendURL = appURL.appendingPathComponent("Contents/Resources/Backend")
        if fileManager.fileExists(atPath: retiredBackendURL.path) {
            result.errors.append("App bundle must not include retired backend resources: \(retiredBackendURL.path)")
        }

        let signature = codesignInspector?(appURL) ?? inspectCodesign(appURL: appURL, runner: runner)
        result.signature = signature
        applySignatureRules(
            signature,
            result: &result,
            requireDistributionSigning: requireDistributionSigning,
            appStore: appStore
        )

        let gatekeeper = gatekeeperInspector?(appURL) ?? inspectGatekeeper(appURL: appURL, runner: runner)
        result.gatekeeper = gatekeeper
        applyGatekeeperRules(gatekeeper, result: &result, requireDistributionSigning: requireDistributionSigning)

        if appStore {
            result.distributionReady = result.errors.isEmpty
                && signature.available
                && signature.kind == "apple-distribution"
                && signature.hardenedRuntime
        } else {
            result.distributionReady = result.errors.isEmpty
                && signature.available
                && signature.kind == "developer-id"
                && signature.hardenedRuntime
                && signature.timestamped
        }

        return result
    }

    private static func applySignatureRules(
        _ signature: SignatureInspection,
        result: inout BundleValidationResult,
        requireDistributionSigning: Bool,
        appStore: Bool
    ) {
        if !signature.available {
            result.errors.append("codesign inspection failed for the app bundle.")
            return
        }

        if let bundleIdentifier = result.bundleIdentifier,
           let signatureIdentifier = signature.identifier,
           signatureIdentifier != bundleIdentifier {
            result.errors.append("Code signature identifier does not match Info.plist bundle identifier.")
        }
        if !signature.sealedResources {
            result.errors.append("Bundle resources are not sealed by the code signature.")
        }

        if appStore {
            if signature.kind != "apple-distribution" {
                result.errors.append("App Store validation requires an Apple Distribution or 3rd Party Mac Developer Application signature.")
            }
            if !signature.hardenedRuntime {
                result.errors.append("App Store validation requires hardened runtime to be enabled.")
            }
        } else if requireDistributionSigning {
            if signature.kind != "developer-id" {
                result.errors.append("Distribution validation requires a Developer ID Application signature.")
            }
            if !signature.hardenedRuntime {
                result.errors.append("Distribution validation requires hardened runtime to be enabled.")
            }
            if !signature.timestamped {
                result.errors.append("Distribution validation requires a timestamped code signature.")
            }
        } else if signature.kind == "adhoc" {
            result.warnings.append("Bundle is ad hoc signed for local validation only; Developer ID signing is still required for notarization.")
        } else if signature.kind == "unsigned" {
            result.errors.append("Bundle is unsigned.")
        }
    }

    private static func applyGatekeeperRules(
        _ gatekeeper: GatekeeperInspection,
        result: inout BundleValidationResult,
        requireDistributionSigning: Bool
    ) {
        if gatekeeper.status == "rejected" {
            if requireDistributionSigning {
                result.warnings.append("Gatekeeper currently rejects the bundle; notarization may still be pending.")
            } else {
                result.warnings.append("Gatekeeper rejects the local bundle, which is expected for ad hoc-signed development builds.")
            }
        } else if gatekeeper.status == "unavailable" && !gatekeeper.output.isEmpty {
            result.warnings.append("Gatekeeper assessment was unavailable on this machine; inspect the output for details.")
        }
    }
}

public enum BundleValidatorCLI {
    public static func run(
        arguments: [String],
        output: (String) -> Void = { print($0) },
        runner: ShellCommandRunner = .live
    ) -> Int32 {
        var emitJSON = false
        var requireDistributionSigning = false
        var appStore = false
        var appPath: String?

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                emitJSON = true
            case "--require-distribution-signing":
                requireDistributionSigning = true
            case "--app-store":
                appStore = true
            case "-h", "--help":
                output(Self.helpText)
                return 0
            default:
                if argument.hasPrefix("-") {
                    output("Unknown option: \(argument)")
                    output(Self.helpText)
                    return 2
                }
                if appPath == nil {
                    appPath = argument
                } else {
                    output("Unexpected argument: \(argument)")
                    output(Self.helpText)
                    return 2
                }
            }
        }

        guard let appPath else {
            output(Self.helpText)
            return 2
        }

        let result = BundleValidator.validateAppBundle(
            appURL: URL(fileURLWithPath: appPath),
            requireDistributionSigning: requireDistributionSigning,
            appStore: appStore,
            runner: runner
        )

        if emitJSON {
            output(jsonString(for: result))
        } else {
            humanReadableLines(for: result).forEach(output)
        }

        return result.errors.isEmpty ? 0 : 1
    }

    public static let helpText = """
    Usage: ChronoframePackagingTool [--json] [--require-distribution-signing] [--app-store] APP_PATH
    Validate a packaged Chronoframe macOS app bundle.
    """

    public static func jsonString(for result: BundleValidationResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func humanReadableLines(for result: BundleValidationResult) -> [String] {
        var lines: [String] = []
        lines.append("Bundle validation: \(result.errors.isEmpty ? "PASS" : "FAIL")")
        lines.append("Bundle: \(result.bundlePath)")
        lines.append("Identifier: \(result.bundleIdentifier ?? "unknown")")
        if let signature = result.signature {
            lines.append("Signature: \(signature.kind)")
            lines.append("Hardened runtime: \(signature.hardenedRuntime ? "yes" : "no")")
            lines.append("Sealed resources: \(signature.sealedResources ? "yes" : "no")")
        }
        if let gatekeeper = result.gatekeeper {
            lines.append("Gatekeeper: \(gatekeeper.status)")
        }
        if !result.errors.isEmpty {
            lines.append("Errors:")
            lines.append(contentsOf: result.errors.map { "  - \($0)" })
        }
        if !result.warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: result.warnings.map { "  - \($0)" })
        }
        return lines
    }
}
