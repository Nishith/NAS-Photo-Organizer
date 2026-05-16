import XCTest
@testable import ChronoframePackaging

final class BundleValidatorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testLocalValidationAcceptsAdhocBundleWithWarning() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            codesignInspector: { _ in .adhoc },
            gatekeeperInspector: { _ in .rejected }
        )

        XCTAssertEqual(result.errors, [])
        XCTAssertFalse(result.distributionReady)
        XCTAssertTrue(result.warnings.contains { $0.contains("ad hoc signed") })
    }

    func testDistributionValidationRequiresDeveloperIDSignature() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            requireDistributionSigning: true,
            codesignInspector: { _ in .adhoc },
            gatekeeperInspector: { _ in .rejected }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("Developer ID Application signature") })
        XCTAssertTrue(result.errors.contains { $0.contains("hardened runtime") })
        XCTAssertTrue(result.errors.contains { $0.contains("timestamped") })
    }

    func testDistributionValidationAcceptsDeveloperIDBundle() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            requireDistributionSigning: true,
            codesignInspector: { _ in .developerID },
            gatekeeperInspector: { _ in .rejectedNotarizationPending }
        )

        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.distributionReady)
        XCTAssertTrue(result.warnings.contains { $0.contains("notarization may still be pending") })
    }

    func testValidationReportsMissingPackagedResources() throws {
        let appURL = try makeMinimalAppBundle()
        try FileManager.default.removeItem(at: appURL.appendingPathComponent("Contents/Resources/AppIcon.icns"))

        let result = BundleValidator.validateAppBundle(
            appURL: appURL,
            codesignInspector: { _ in .adhoc },
            gatekeeperInspector: { _ in .accepted }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("AppIcon.icns") })
    }

    func testInspectCodesignParsesDeveloperIDOutput() {
        let output = [
            "Identifier=com.nishith.chronoframe",
            "TeamIdentifier=ABCDE12345",
            "Authority=Developer ID Application: Example (ABCDE12345)",
            "Authority=Developer ID Certification Authority",
            "Sealed Resources version=2 rules=13 files=7",
            "Runtime Version=14.0.0",
            "Timestamp=Apr 25, 2026 at 12:00:00 PM",
        ].joined(separator: "\n")
        let inspection = BundleValidator.inspectCodesign(
            appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
            runner: .mock(returnCode: 0, stderr: output)
        )

        XCTAssertTrue(inspection.available)
        XCTAssertEqual(inspection.kind, "developer-id")
        XCTAssertEqual(inspection.identifier, "com.nishith.chronoframe")
        XCTAssertEqual(inspection.teamIdentifier, "ABCDE12345")
        XCTAssertTrue(inspection.sealedResources)
        XCTAssertTrue(inspection.hardenedRuntime)
        XCTAssertTrue(inspection.timestamped)
        XCTAssertEqual(inspection.authorities.first, "Developer ID Application: Example (ABCDE12345)")
    }

    func testInspectCodesignReportsUnsignedWhenCommandFails() {
        let inspection = BundleValidator.inspectCodesign(
            appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
            runner: .mock(returnCode: 1, stderr: "not signed")
        )

        XCTAssertFalse(inspection.available)
        XCTAssertEqual(inspection.kind, "unsigned")
        XCTAssertFalse(inspection.sealedResources)
        XCTAssertTrue(inspection.output.contains("not signed"))
    }

    func testInspectCodesignParsesAdhocOutputWithoutPrefixedValues() {
        XCTAssertNil(BundleValidator.extractPrefixedValue("Authority=Local", prefix: "Identifier"))

        let inspection = BundleValidator.inspectCodesign(
            appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
            runner: .mock(
                returnCode: 0,
                stderr: "Signature=adhoc\nSealed Resources version=2 rules=13 files=7"
            )
        )

        XCTAssertTrue(inspection.available)
        XCTAssertEqual(inspection.kind, "adhoc")
        XCTAssertNil(inspection.identifier)
        XCTAssertNil(inspection.teamIdentifier)
    }

    func testInspectGatekeeperClassifiesAcceptedRejectedAndUnavailable() {
        let cases: [(Int32, String, String)] = [
            (0, "accepted", "accepted"),
            (3, "rejected", "rejected"),
            (2, "assessment unavailable", "unavailable"),
        ]

        for (returnCode, output, expectedStatus) in cases {
            let inspection = BundleValidator.inspectGatekeeper(
                appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
                runner: .mock(returnCode: returnCode, stderr: output)
            )
            XCTAssertEqual(inspection.status, expectedStatus)
            XCTAssertEqual(inspection.returncode, returnCode)
            XCTAssertEqual(inspection.output, output)
        }
    }

    func testValidationReportsMissingBundleDirectoryAndInfoPlist() throws {
        let missing = temporaryDirectoryURL.appendingPathComponent("Missing.app")
        var result = BundleValidator.validateAppBundle(appURL: missing)
        XCTAssertTrue(result.errors.contains { $0.contains("does not exist") })

        let plainFile = temporaryDirectoryURL.appendingPathComponent("Chronoframe.app")
        try "not a directory".write(to: plainFile, atomically: true, encoding: .utf8)
        result = BundleValidator.validateAppBundle(appURL: plainFile)
        XCTAssertTrue(result.errors.contains { $0.contains("not a directory") })

        let bundleWithoutInfo = temporaryDirectoryURL.appendingPathComponent("NoInfo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleWithoutInfo, withIntermediateDirectories: true)
        result = BundleValidator.validateAppBundle(appURL: bundleWithoutInfo)
        XCTAssertTrue(result.errors.contains { $0.contains("Missing Info.plist") })
    }

    func testValidationReportsMalformedInfoAndSignatureProblems() throws {
        let appURL = try makeMinimalAppBundle()
        try writeInfoPlist(
            [
                "CFBundleIdentifier": "com.nishith.chronoframe",
                "CFBundleIconFile": "WrongIcon",
                "CFBundlePackageType": "BNDL",
            ],
            to: appURL
        )

        let result = BundleValidator.validateAppBundle(
            appURL: appURL,
            codesignInspector: { _ in .unsignedUnavailable },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("missing CFBundleExecutable") })
        XCTAssertTrue(result.errors.contains { $0.contains("CFBundleIconFile=AppIcon") })
        XCTAssertTrue(result.errors.contains { $0.contains("CFBundlePackageType=APPL") })
        XCTAssertTrue(result.errors.contains { $0.contains("codesign inspection failed") })
        XCTAssertTrue(result.warnings.contains { $0.contains("Gatekeeper assessment was unavailable") })
    }

    func testValidationReportsMissingExecutableNamedByInfoPlist() throws {
        let appURL = try makeMinimalAppBundle()
        try FileManager.default.removeItem(at: appURL.appendingPathComponent("Contents/MacOS/Chronoframe"))

        let result = BundleValidator.validateAppBundle(
            appURL: appURL,
            codesignInspector: { _ in .adhoc },
            gatekeeperInspector: { _ in .accepted }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("Missing app executable") })
    }

    func testValidationReportsSignatureIdentifierMismatchAndUnsealedResources() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            codesignInspector: { _ in
                SignatureInspection(
                    available: true,
                    kind: "unknown",
                    identifier: "com.example.other",
                    teamIdentifier: "ABCDE12345",
                    sealedResources: false,
                    hardenedRuntime: false,
                    timestamped: false,
                    output: "Identifier=com.example.other"
                )
            },
            gatekeeperInspector: { _ in .accepted }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("identifier does not match") })
        XCTAssertTrue(result.errors.contains { $0.contains("resources are not sealed") })
    }

    func testValidationReportsUnsignedAvailableSignature() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            codesignInspector: { _ in
                SignatureInspection(
                    available: true,
                    kind: "unsigned",
                    identifier: "com.nishith.chronoframe",
                    teamIdentifier: nil,
                    sealedResources: true,
                    hardenedRuntime: false,
                    timestamped: false,
                    output: "unsigned"
                )
            },
            gatekeeperInspector: { _ in .accepted }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("Bundle is unsigned") })
    }

    func testCLIEmitsJSONAndFailureExitCode() throws {
        let missing = temporaryDirectoryURL.appendingPathComponent("Missing.app")
        var lines: [String] = []

        let exitCode = BundleValidatorCLI.run(
            arguments: [missing.path, "--json"],
            output: { lines.append($0) },
            runner: .noCommands
        )

        XCTAssertEqual(exitCode, 1)
        let text = lines.joined(separator: "\n")
        let payload = try decodeCLIJSON(lines)
        XCTAssertEqual(payload["distribution_ready"] as? Bool, false)
        XCTAssertTrue(text.contains("Bundle does not exist"))
    }

    func testCLIEmitsHumanReadableErrorsAndWarnings() {
        let fake = BundleValidationResult(
            bundlePath: "/tmp/Chronoframe.app",
            bundleIdentifier: "com.nishith.chronoframe",
            executablePath: "/tmp/Chronoframe.app/Contents/MacOS/Chronoframe",
            infoPlistPath: "/tmp/Chronoframe.app/Contents/Info.plist",
            distributionReady: false,
            errors: ["Missing packaged resource: AppIcon.icns"],
            warnings: ["Gatekeeper assessment was unavailable"],
            signature: .adhoc,
            gatekeeper: .unavailable
        )

        let text = BundleValidatorCLI.humanReadableLines(for: fake).joined(separator: "\n")
        XCTAssertTrue(text.contains("Bundle validation: FAIL"))
        XCTAssertTrue(text.contains("Signature: adhoc"))
        XCTAssertTrue(text.contains("Gatekeeper: unavailable"))
        XCTAssertTrue(text.contains("Errors:"))
        XCTAssertTrue(text.contains("Warnings:"))
    }

    func testAppStoreValidationAcceptsValidMASBundle() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            appStore: true,
            codesignInspector: { _ in .appleDistribution },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.distributionReady)
    }

    func testValidationRejectsBundleWithRetiredBackendResources() throws {
        let appURL = try makeMinimalAppBundle()
        let backendURL = appURL.appendingPathComponent("Contents/Resources/Backend", isDirectory: true)
        try FileManager.default.createDirectory(at: backendURL, withIntermediateDirectories: true)
        try "placeholder".write(
            to: backendURL.appendingPathComponent("legacy-runtime"),
            atomically: true,
            encoding: .utf8
        )

        let result = BundleValidator.validateAppBundle(
            appURL: appURL,
            codesignInspector: { _ in .appleDistribution },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("must not include retired backend resources") })
        XCTAssertFalse(result.distributionReady)
    }

    func testAppStoreValidationRequiresAppleDistributionSigning() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            appStore: true,
            codesignInspector: { _ in .developerID },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("Apple Distribution") })
        XCTAssertFalse(result.distributionReady)
    }

    func testAppStoreValidationRequiresHardenedRuntime() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            appStore: true,
            codesignInspector: { _ in
                SignatureInspection(
                    available: true,
                    kind: "apple-distribution",
                    identifier: "com.nishith.chronoframe",
                    teamIdentifier: "ABCDE12345",
                    sealedResources: true,
                    hardenedRuntime: false,
                    timestamped: false,
                    authorities: ["Apple Distribution: Nishith Nand (ABCDE12345)"],
                    output: "Authority=Apple Distribution: Nishith Nand (ABCDE12345)"
                )
            },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertTrue(result.errors.contains { $0.contains("hardened runtime") })
        XCTAssertFalse(result.distributionReady)
    }

    func testValidationDoesNotRequireRetiredBackendFiles() throws {
        let result = BundleValidator.validateAppBundle(
            appURL: try makeMinimalAppBundle(),
            appStore: true,
            codesignInspector: { _ in .appleDistribution },
            gatekeeperInspector: { _ in .unavailable }
        )

        XCTAssertFalse(result.errors.contains { $0.contains("retired backend") })
    }

    func testInspectCodesignClassifiesAppleDistributionAuthorities() {
        let appleOutput = """
        Identifier=com.nishith.chronoframe
        TeamIdentifier=ABCDE12345
        Authority=Apple Distribution: Nishith Nand (ABCDE12345)
        Sealed Resources version=2 rules=13 files=7
        Runtime Version=14.0.0
        """
        XCTAssertEqual(
            BundleValidator.inspectCodesign(
                appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
                runner: .mock(returnCode: 0, stderr: appleOutput)
            ).kind,
            "apple-distribution"
        )

        let thirdPartyOutput = """
        Identifier=com.nishith.chronoframe
        TeamIdentifier=ABCDE12345
        Authority=3rd Party Mac Developer Application: Nishith Nand (ABCDE12345)
        Sealed Resources version=2 rules=13 files=7
        Runtime Version=14.0.0
        """
        XCTAssertEqual(
            BundleValidator.inspectCodesign(
                appURL: URL(fileURLWithPath: "/tmp/Chronoframe.app"),
                runner: .mock(returnCode: 0, stderr: thirdPartyOutput)
            ).kind,
            "apple-distribution"
        )
    }

    func testCLIAppStoreFlagValidatesMASMode() throws {
        let missing = temporaryDirectoryURL.appendingPathComponent("Missing.app")
        var lines: [String] = []
        let exitCode = BundleValidatorCLI.run(
            arguments: [missing.path, "--app-store", "--json"],
            output: { lines.append($0) },
            runner: .noCommands
        )

        XCTAssertEqual(exitCode, 1)
        let payload = try decodeCLIJSON(lines)
        XCTAssertEqual(payload["distribution_ready"] as? Bool, false)
    }

    private func decodeCLIJSON(_ lines: [String]) throws -> [String: Any] {
        let text = lines.joined(separator: "\n")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        return payload
    }

    private func makeMinimalAppBundle() throws -> URL {
        let appURL = temporaryDirectoryURL.appendingPathComponent("Chronoframe-\(UUID().uuidString).app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Chronoframe")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        try writeInfoPlist(
            [
                "CFBundleExecutable": "Chronoframe",
                "CFBundleIdentifier": "com.nishith.chronoframe",
                "CFBundleIconFile": "AppIcon",
                "CFBundlePackageType": "APPL",
            ],
            to: appURL
        )
        try "binary".write(to: executableURL, atomically: true, encoding: .utf8)
        try "icon".write(to: resourcesURL.appendingPathComponent("AppIcon.icns"), atomically: true, encoding: .utf8)
        return appURL
    }

    private func writeInfoPlist(_ payload: [String: String], to appURL: URL) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: infoURL)
    }
}

private extension SignatureInspection {
    static let adhoc = SignatureInspection(
        available: true,
        kind: "adhoc",
        identifier: "com.nishith.chronoframe",
        teamIdentifier: nil,
        sealedResources: true,
        hardenedRuntime: false,
        timestamped: false,
        output: "Signature=adhoc"
    )

    static let developerID = SignatureInspection(
        available: true,
        kind: "developer-id",
        identifier: "com.nishith.chronoframe",
        teamIdentifier: "ABCDE12345",
        sealedResources: true,
        hardenedRuntime: true,
        timestamped: true,
        authorities: ["Developer ID Application: Example (ABCDE12345)"],
        output: "Authority=Developer ID Application: Example (ABCDE12345)"
    )

    static let appleDistribution = SignatureInspection(
        available: true,
        kind: "apple-distribution",
        identifier: "com.nishith.chronoframe",
        teamIdentifier: "ABCDE12345",
        sealedResources: true,
        hardenedRuntime: true,
        timestamped: false,
        authorities: ["Apple Distribution: Nishith Nand (ABCDE12345)"],
        output: "Authority=Apple Distribution: Nishith Nand (ABCDE12345)"
    )

    static let unsignedUnavailable = SignatureInspection(
        available: false,
        kind: "unsigned",
        identifier: nil,
        teamIdentifier: nil,
        sealedResources: false,
        hardenedRuntime: false,
        timestamped: false,
        output: "code object is not signed"
    )
}

private extension GatekeeperInspection {
    static let accepted = GatekeeperInspection(status: "accepted", returncode: 0, output: "accepted")
    static let rejected = GatekeeperInspection(status: "rejected", returncode: 1, output: "rejected")
    static let rejectedNotarizationPending = GatekeeperInspection(status: "rejected", returncode: 1, output: "not notarized yet")
    static let unavailable = GatekeeperInspection(status: "unavailable", returncode: 2, output: "spctl unavailable")
}

private extension ShellCommandRunner {
    static func mock(returnCode: Int32, stdout: String = "", stderr: String = "") -> ShellCommandRunner {
        ShellCommandRunner { _, _ in
            CommandResult(returnCode: returnCode, standardOutput: stdout, standardError: stderr)
        }
    }

    static let noCommands = ShellCommandRunner { _, _ in
        XCTFail("No external commands should run for this test")
        return CommandResult(returnCode: 127, standardError: "unexpected command")
    }
}
