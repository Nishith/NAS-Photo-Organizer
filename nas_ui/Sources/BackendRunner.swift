import Foundation
import Combine

struct JsonEvent: Decodable {
    var type: String?
    var status: String?
    var task: String?
    var completed: Int?
    var total: Int?
    var found: Int?
    var message: String?
    var count: Int?
    var already_in_dst: Int?
    var new: Int?
    var dups: Int?
    var errors: Int?
    var bytes_copied: Int?
    var bytes_total: Int?
    var dest: String?
    var report: String?
    var copied: Int?
    var failed: Int?
}

// Maps backend task names to UI phase indices (0-based)
private let taskPhaseMap: [String: Int] = [
    "discovery": 0,
    "src_hash":  1,
    "dest_hash": 2,
    "classification": 3,
    "copy": 4,
]

class BackendRunner: ObservableObject {
    @Published var isRunning = false
    @Published var currentTaskName = "Idle"
    @Published var progress: Double = 0.0
    @Published var logLines: [String] = []

    // Phase tracking (0=Discover, 1=Hash Src, 2=Index Dst, 3=Classify, 4=Copy; -1=idle)
    @Published var currentPhase: Int = -1

    // Transfer speed and ETA
    @Published var speedMBps: Double = 0.0
    @Published var etaSeconds: Double = -1

    // Error tracking for persistent badge
    @Published var errorCount: Int = 0
    @Published var discoveredCount: Int = 0
    @Published var plannedCount: Int = 0
    @Published var alreadyInDestinationCount: Int = 0
    @Published var duplicateCount: Int = 0
    @Published var hashErrorCount: Int = 0
    @Published var copiedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var completionStatus: String = "idle"

    // Set on completion so UI can offer "Open in Finder"
    @Published var completedDest: String = ""
    @Published var completedReport: String = ""

    // For handling the Confirm.ask logic
    @Published var showingPrompt = false
    @Published var promptMessage = ""

    private var process: Process?
    private var inputPipe: Pipe?

    // Speed calculation state
    private var speedLastTime: Date = Date()
    private var speedLastBytes: Int = 0

    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logLines.append(text)
        }
    }

    func start(source: String, dest: String, profile: String, isDryRun: Bool,
               isFastDest: Bool, workers: Int) {
        guard !isRunning else { return }
        isRunning = true
        logLines.removeAll()
        progress = 0.0
        currentPhase = -1
        errorCount = 0
        speedMBps = 0.0
        etaSeconds = -1
        completedDest = ""
        completedReport = ""
        currentTaskName = "Starting Engine..."
        discoveredCount = 0
        plannedCount = 0
        alreadyInDestinationCount = 0
        duplicateCount = 0
        hashErrorCount = 0
        copiedCount = 0
        failedCount = 0
        completionStatus = "running"
        speedLastBytes = 0
        speedLastTime = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            self.runProcess(source: source, dest: dest, profile: profile,
                            isDryRun: isDryRun, isFastDest: isFastDest, workers: workers)
        }
    }

    func answerPrompt(yes: Bool) {
        guard let inputPipe = self.inputPipe else { return }
        let answer = yes ? "y\n" : "n\n"
        if let data = answer.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        self.showingPrompt = false
    }

    func cancel() {
        process?.terminate()
        DispatchQueue.main.async {
            self.isRunning = false
            self.currentTaskName = "Cancelled"
            self.speedMBps = 0.0
            self.etaSeconds = -1
            self.completionStatus = "cancelled"
        }
    }

    private func runProcess(source: String, dest: String, profile: String,
                            isDryRun: Bool, isFastDest: Bool, workers: Int) {
        let task = Process()
        let pipe = Pipe()
        let inPipe = Pipe()

        self.process = task
        self.inputPipe = inPipe

        // Resolve the script relative to the running .app bundle (which lives in nas_ui/build/)
        let bundleURL = Bundle.main.bundleURL
        let scriptPath = bundleURL
            .deletingLastPathComponent() // removes .app
            .deletingLastPathComponent() // removes build/
            .deletingLastPathComponent() // removes nas_ui/
            .appendingPathComponent("organize_nas.py")
            .path

        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", scriptPath, "--json", "--yes",
                    "--workers", "\(workers)"]

        if isDryRun  { args.append("--dry-run") }
        if isFastDest { args.append("--fast-dest") }
        if !profile.isEmpty {
            args.append(contentsOf: ["--profile", profile])
        } else {
            args.append(contentsOf: ["--source", source, "--dest", dest])
        }

        task.arguments = args
        task.standardOutput = pipe
        task.standardInput = inPipe
        task.standardError = pipe

        let outHandle = pipe.fileHandleForReading
        outHandle.waitForDataInBackgroundAndNotify()

        var buffer = ""

        let observer = NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable, object: outHandle, queue: nil
        ) { [weak self] _ in
            let data = outHandle.availableData
            if data.count > 0 {
                if let str = String(data: data, encoding: .utf8) {
                    buffer += str
                    self?.processBuffer(&buffer)
                }
                outHandle.waitForDataInBackgroundAndNotify()
            } else {
                // EOF
                DispatchQueue.main.async {
                    self?.isRunning = false
                }
            }
        }

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            self.appendLog("Failed to launch Python backend: \(error)")
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }

        NotificationCenter.default.removeObserver(observer)
        self.inputPipe = nil
    }

    private func processBuffer(_ buffer: inout String) {
        let lines = buffer.components(separatedBy: .newlines)
        guard lines.count > 1 else { return }

        for i in 0..<(lines.count - 1) {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let data = line.data(using: .utf8),
               let event = try? JSONDecoder().decode(JsonEvent.self, from: data) {
                handleEvent(event)
            } else {
                self.appendLog(line)
            }
        }

        let tail = lines.last ?? ""
        // Guard against unbounded buffer growth from a malformed (no-newline) backend output.
        buffer = tail.count < 10 * 1024 * 1024 ? tail : ""
    }

    private func handleEvent(_ event: JsonEvent) {
        DispatchQueue.main.async {
            switch event.type {
            case "startup":
                self.currentTaskName = "Initializing..."
                self.appendLog("Engine started.")

            case "task_start":
                let t = event.task ?? "unknown"
                self.currentPhase = taskPhaseMap[t] ?? self.currentPhase
                self.currentTaskName = self.phaseLabel(for: t)
                self.progress = 0.0
                self.speedMBps = 0.0
                self.etaSeconds = -1
                if t == "copy" {
                    self.speedLastTime = Date()
                    self.speedLastBytes = 0
                }

            case "task_progress":
                let t = event.task ?? ""
                if let c = event.completed, let total = event.total, total > 0 {
                    self.progress = Double(c) / Double(total)
                }
                // Compute MB/s and ETA during copy phase
                if t == "copy",
                   let bc = event.bytes_copied, let bt = event.bytes_total, bt > 0 {
                    let now = Date()
                    let elapsed = now.timeIntervalSince(self.speedLastTime)
                    if elapsed >= 0.5 {
                        let delta = bc - self.speedLastBytes
                        self.speedMBps = Double(delta) / elapsed / 1_000_000
                        if self.speedMBps > 0 {
                            self.etaSeconds = Double(bt - bc) / (self.speedMBps * 1_000_000)
                        }
                        self.speedLastTime = now
                        self.speedLastBytes = bc
                    }
                }

            case "task_complete":
                let t = event.task ?? ""
                self.progress = 1.0
                self.speedMBps = 0.0
                self.etaSeconds = -1
                if t == "discovery" {
                    self.discoveredCount = event.found ?? self.discoveredCount
                }
                if t == "classification" {
                    self.alreadyInDestinationCount = event.already_in_dst ?? 0
                    self.duplicateCount = event.dups ?? 0
                    self.hashErrorCount = event.errors ?? 0
                    self.appendLog("Classification complete:")
                    self.appendLog("  New files:        \(event.new ?? 0)")
                    self.appendLog("  Already in dest:  \(event.already_in_dst ?? 0)")
                    self.appendLog("  Duplicates:       \(event.dups ?? 0)")
                    if (event.errors ?? 0) > 0 {
                        self.appendLog("  Hash errors:      \(event.errors!)")
                    }
                } else if t == "copy" {
                    self.copiedCount = event.copied ?? 0
                    self.failedCount = event.failed ?? 0
                    self.appendLog("Copy complete: \(event.copied ?? 0) succeeded, \(event.failed ?? 0) failed.")
                }

            case "copy_plan_ready":
                self.plannedCount = event.count ?? 0
                self.appendLog("Plan ready: \(event.count ?? 0) files queued for copy.")

            case "info":
                self.appendLog("ℹ \(event.message ?? "")")

            case "warning":
                self.appendLog("⚠ \(event.message ?? "")")

            case "error":
                self.errorCount += 1
                self.appendLog("ERROR: \(event.message ?? "")")

            case "prompt":
                self.promptMessage = event.message ?? "Are you sure?"
                self.showingPrompt = true

            case "complete":
                self.isRunning = false
                self.progress = 1.0
                self.speedMBps = 0.0
                self.etaSeconds = -1
                self.completedDest = event.dest ?? ""
                self.completedReport = event.report ?? ""
                self.completionStatus = event.status ?? "done"
                let statusLabel: String
                switch event.status {
                case "finished":         statusLabel = "Done"
                case "dry_run_finished": statusLabel = "Preview complete"
                case "nothing_to_copy":  statusLabel = "Already up to date"
                case "cancelled":        statusLabel = "Cancelled"
                default:                 statusLabel = event.status ?? "Done"
                }
                self.currentTaskName = statusLabel
                self.appendLog("Finished: \(statusLabel)")

            default:
                break
            }
        }
    }

    private func phaseLabel(for task: String) -> String {
        switch task {
        case "discovery":     return "Discovering files..."
        case "src_hash":      return "Hashing source..."
        case "dest_hash":     return "Indexing destination..."
        case "classification":return "Classifying by date..."
        case "copy":          return "Copying files..."
        default:              return "Running: \(task)"
        }
    }
}
