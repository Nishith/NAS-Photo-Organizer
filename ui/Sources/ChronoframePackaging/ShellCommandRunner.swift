import Foundation

public struct CommandResult: Equatable, Sendable {
    public var returnCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(returnCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.returnCode = returnCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        (standardOutput + standardError).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ShellCommandRunner: Sendable {
    public var run: @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult

    public init(run: @escaping @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult) {
        self.run = run
    }

    public static let live = ShellCommandRunner { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(returnCode: 127, standardError: String(describing: error))
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            returnCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
