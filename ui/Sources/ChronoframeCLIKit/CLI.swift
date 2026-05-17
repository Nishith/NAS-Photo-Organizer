import ChronoframeAppCore
import ChronoframeCore
import Foundation

public enum CLIError: LocalizedError, Equatable {
    case usage(String)
    case help(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .usage(message):
            return message
        case let .help(message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}

public struct CLIOptions: Equatable, Sendable {
    public static let defaultWorkerCount = 8

    public var sourcePath: String?
    public var destinationPath: String?
    public var profileName: String?
    public var dryRun: Bool
    public var rebuildCache: Bool
    public var verifyCopies: Bool
    public var workerCount: Int
    public var assumeYes: Bool
    public var jsonOutput: Bool
    public var folderStructure: FolderStructure
    public var revertReceiptPath: String?
    public var startFresh: Bool

    public init(
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        profileName: String? = nil,
        dryRun: Bool = false,
        rebuildCache: Bool = false,
        verifyCopies: Bool = true,
        workerCount: Int = CLIOptions.defaultWorkerCount,
        assumeYes: Bool = false,
        jsonOutput: Bool = false,
        folderStructure: FolderStructure = .default,
        revertReceiptPath: String? = nil,
        startFresh: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.profileName = profileName
        self.dryRun = dryRun
        self.rebuildCache = rebuildCache
        self.verifyCopies = verifyCopies
        self.workerCount = workerCount
        self.assumeYes = assumeYes
        self.jsonOutput = jsonOutput
        self.folderStructure = folderStructure
        self.revertReceiptPath = revertReceiptPath
        self.startFresh = startFresh
    }

    public var mode: RunMode {
        revertReceiptPath == nil ? (dryRun ? .preview : .transfer) : .revert
    }

    public func runConfiguration() -> RunConfiguration {
        RunConfiguration(
            mode: mode,
            sourcePath: sourcePath ?? "",
            destinationPath: destinationPath ?? "",
            profileName: profileName,
            verifyCopies: verifyCopies,
            parallelTransferEnabled: true,
            workerCount: workerCount,
            folderStructure: folderStructure
        )
    }
}

public enum CLIParser {
    public static let usage = """
    Usage:
      chronoframe --source PATH --dest PATH [--dry-run] [options]
      chronoframe --profile NAME [--dry-run] [options]
      chronoframe --revert RECEIPT_JSON [--dest DEST_ROOT] [--json]

    Options:
      --source PATH
      --dest PATH
      --profile NAME
      --dry-run
      --rebuild-cache
      --skip-verify
      --workers N
      -y, --yes
      --json
      --folder-structure YYYY/MM/DD|YYYY/MM|YYYY|YYYY/Mon/Event|Flat
      --revert RECEIPT_JSON
      --start-fresh
      -h, --help
    """

    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func requireValue(after flag: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("-") else {
                throw CLIError.usage("Missing value for \(flag).")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "-h", "--help":
                throw CLIError.help(usage)
            case "--source":
                options.sourcePath = try requireValue(after: argument)
            case "--dest":
                options.destinationPath = try requireValue(after: argument)
            case "--profile":
                options.profileName = try requireValue(after: argument)
            case "--dry-run":
                options.dryRun = true
            case "--rebuild-cache":
                options.rebuildCache = true
            case "--skip-verify":
                options.verifyCopies = false
            case "--workers":
                let rawValue = try requireValue(after: argument)
                guard let workerCount = Int(rawValue) else {
                    throw CLIError.usage("--workers must be an integer.")
                }
                options.workerCount = workerCount
            case "-y", "--yes":
                options.assumeYes = true
            case "--json":
                options.jsonOutput = true
            case "--folder-structure":
                let rawValue = try requireValue(after: argument)
                guard let folderStructure = FolderStructure(rawValue: rawValue) else {
                    throw CLIError.usage("Unsupported folder structure: \(rawValue).")
                }
                options.folderStructure = folderStructure
            case "--revert":
                options.revertReceiptPath = try requireValue(after: argument)
            case "--start-fresh":
                options.startFresh = true
            default:
                throw CLIError.usage("Unknown option: \(argument).")
            }

            index += 1
        }

        try validate(options)
        return options
    }

    private static func validate(_ options: CLIOptions) throws {
        let maxWorkers = max(CLIOptions.defaultWorkerCount, ProcessInfo.processInfo.processorCount * 2)
        guard (1...maxWorkers).contains(options.workerCount) else {
            throw CLIError.usage("--workers must be between 1 and \(maxWorkers) (got \(options.workerCount)).")
        }

        if options.revertReceiptPath != nil {
            if options.sourcePath != nil || options.profileName != nil || options.dryRun || options.rebuildCache || options.startFresh {
                throw CLIError.usage("--revert can be combined only with --dest, --json, --workers, and --yes.")
            }
            return
        }

        if let profileName = options.profileName, !profileName.isEmpty {
            return
        }

        guard let source = options.sourcePath, !source.isEmpty else {
            throw CLIError.usage("Provide --source and --dest, or use --profile.")
        }
        guard let destination = options.destinationPath, !destination.isEmpty else {
            throw CLIError.usage("Provide --dest, or use --profile.")
        }
    }
}

public struct ChronoframeCLI {
    public typealias Output = @Sendable (String) -> Void
    public typealias Input = () -> String?

    @MainActor
    public static func run(
        arguments: [String],
        output: Output = { print($0) },
        input: Input = { readLine() }
    ) async -> Int32 {
        do {
            let options = try CLIParser.parse(arguments)
            try await run(options: options, output: output, input: input)
            return 0
        } catch let error as CLIError {
            if case .help = error {
                output(error.localizedDescription)
                return 0
            } else if case .usage = error {
                output(error.localizedDescription)
            } else {
                output(error.localizedDescription)
            }
            return 2
        } catch {
            output(UserFacingErrorMessage.message(for: error))
            return 1
        }
    }

    @MainActor
    public static func run(
        options: CLIOptions,
        output: Output = { print($0) },
        input: Input = { readLine() }
    ) async throws {
        if let receiptPath = options.revertReceiptPath {
            try await runRevert(options: options, receiptPath: receiptPath, output: output)
            return
        }

        let profilesRepository = ProfilesRepository()
        if options.rebuildCache {
            let destination = try destinationForCacheRebuild(options: options, profilesRepository: profilesRepository)
            try clearHashCache(destinationRoot: destination)
            if !options.jsonOutput {
                output("Rebuilt hash cache for \(destination).")
            }
        }

        let engine = SwiftOrganizerEngine(profilesRepository: profilesRepository)
        let configuration = options.runConfiguration()
        let preflight = try await engine.preflight(configuration)
        let stream: AsyncThrowingStream<RunEvent, Error>

        if configuration.mode == .transfer {
            let resumePendingJobs = try transferDecision(
                options: options,
                preflight: preflight,
                output: output,
                input: input
            )
            if options.startFresh || (!resumePendingJobs && preflight.pendingJobCount > 0) {
                try clearCopyJobs(destinationRoot: preflight.resolvedDestinationPath)
            }
            stream = try resumePendingJobs
                ? engine.resume(preflight.configuration)
                : engine.start(preflight.configuration)
        } else {
            stream = try engine.start(preflight.configuration)
        }

        try await consume(stream: stream, jsonOutput: options.jsonOutput, output: output)
    }

    private static func transferDecision(
        options: CLIOptions,
        preflight: RunPreflight,
        output: Output,
        input: Input
    ) throws -> Bool {
        if options.startFresh {
            return false
        }

        // JSON-output mode must not block on interactive prompts. The
        // remaining branches in this function would write a human-language
        // prompt string to `output` (the same stdout channel JSON events
        // use) and then block on `input()` waiting for a `readLine()`.
        // A pipeline consumer like Codex or `jq -c .` would receive a
        // non-JSON line mid-stream (corrupting the parse) and the CLI
        // would hang indefinitely on stdin. Fail fast with a usage error
        // when `--json` is set without `--yes`.
        if options.jsonOutput && !options.assumeYes {
            throw CLIError.usage(
                "--json requires --yes; interactive prompts would otherwise corrupt the JSON output stream."
            )
        }

        if preflight.pendingJobCount > 0 {
            if options.assumeYes {
                return true
            }
            output("Found \(preflight.pendingJobCount) pending copy jobs. Resume them? [Y/n/fresh]")
            let answer = input()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            switch answer {
            case "", "y", "yes":
                return true
            case "fresh", "f", "start-fresh":
                return false
            default:
                throw CLIError.cancelled
            }
        }

        if !options.assumeYes {
            output("Chronoframe will leave the source untouched and transfer into \(preflight.resolvedDestinationPath). Continue? [y/N]")
            let answer = input()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                throw CLIError.cancelled
            }
        }
        return false
    }

    @MainActor
    private static func runRevert(options: CLIOptions, receiptPath: String, output: Output) async throws {
        let receiptURL = URL(fileURLWithPath: receiptPath)
        let destinationRoot = options.destinationPath ?? destinationBoundary(for: receiptURL)
        let engine = SwiftOrganizerEngine()
        let stream = try engine.revert(receiptURL: receiptURL, destinationRoot: destinationRoot)
        try await consume(stream: stream, jsonOutput: options.jsonOutput, output: output)
    }

    private static func consume(
        stream: AsyncThrowingStream<RunEvent, Error>,
        jsonOutput: Bool,
        output: Output
    ) async throws {
        for try await event in stream {
            if jsonOutput {
                output(try JSONLineEmitter.line(for: event))
            } else if let line = HumanLineEmitter.line(for: event) {
                output(line)
            }
        }
    }

    private static func destinationForCacheRebuild(
        options: CLIOptions,
        profilesRepository: ProfilesRepository
    ) throws -> String {
        if let destination = options.destinationPath, !destination.isEmpty {
            return destination
        }

        guard let profileName = options.profileName, !profileName.isEmpty else {
            throw CLIError.usage("--rebuild-cache requires --dest or --profile.")
        }
        guard let profile = try profilesRepository.loadProfiles().first(where: { $0.name == profileName }) else {
            throw OrganizerEngineError.profileNotFound(profileName)
        }
        return profile.destinationPath
    }

    private static func clearHashCache(destinationRoot: String) throws {
        let databaseURL = URL(fileURLWithPath: destinationRoot, isDirectory: true)
            .appendingPathComponent(EngineArtifactLayout.chronoframeDefault.queueDatabaseFilename)
        let database = try OrganizerDatabase(url: databaseURL)
        defer { database.close() }
        try database.clearCache()
    }

    private static func clearCopyJobs(destinationRoot: String) throws {
        let databaseURL = URL(fileURLWithPath: destinationRoot, isDirectory: true)
            .appendingPathComponent(EngineArtifactLayout.chronoframeDefault.queueDatabaseFilename)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        let database = try OrganizerDatabase(url: databaseURL)
        defer { database.close() }
        try database.clearAllJobs()
    }

    private static func destinationBoundary(for receiptURL: URL) -> String {
        let directory = receiptURL.deletingLastPathComponent()
        if directory.lastPathComponent == EngineArtifactLayout.chronoframeDefault.logsDirectoryName {
            return directory.deletingLastPathComponent().path
        }
        return directory.path
    }
}
