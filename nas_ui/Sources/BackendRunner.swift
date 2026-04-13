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
}

class BackendRunner: ObservableObject {
    @Published var isRunning = false
    @Published var currentTaskName = "Idle"
    @Published var progress: Double = 0.0
    @Published var logLines: [String] = []
    
    // For handling the Confirm.ask logic
    @Published var showingPrompt = false
    @Published var promptMessage = ""
    
    private var process: Process?
    private var inputPipe: Pipe?
    
    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logLines.append(text)
        }
    }
    
    func start(source: String, dest: String, profile: String, isDryRun: Bool) {
        guard !isRunning else { return }
        isRunning = true
        logLines.removeAll()
        progress = 0.0
        currentTaskName = "Starting Engine..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.runProcess(source: source, dest: dest, profile: profile, isDryRun: isDryRun)
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
        isRunning = false
        currentTaskName = "Cancelled"
    }
    
    private func runProcess(source: String, dest: String, profile: String, isDryRun: Bool) {
        let task = Process()
        let pipe = Pipe()
        let inPipe = Pipe()
        
        self.process = task
        self.inputPipe = inPipe
        
        // In a real .app bundle, we might bundle the python script inside Contents/Resources.
        // For development, we point it to the parent directory script.
        let scriptPath = FileManager.default.currentDirectoryPath + "/organize_nas.py"
        
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", scriptPath, "--json"]
        
        if isDryRun { args.append("--dry-run") }
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
        
        let observer = NotificationCenter.default.addObserver(forName: .NSFileHandleDataAvailable, object: outHandle, queue: nil) { [weak self] notification in
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
        
        // Everything but the last element is guaranteed to be a complete line
        for i in 0..<(lines.count - 1) {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            if let data = line.data(using: .utf8), let event = try? JSONDecoder().decode(JsonEvent.self, from: data) {
                handleEvent(event)
            } else {
                // Not standard JSON emitted by our hook, probably a raw standard error log or rich leak
                self.appendLog(line)
            }
        }
        
        buffer = lines.last ?? ""
    }
    
    private func handleEvent(_ event: JsonEvent) {
        DispatchQueue.main.async {
            switch event.type {
            case "startup":
                self.currentTaskName = "Initializing..."
                self.appendLog("Engine started.")
            case "task_start":
                let t = event.task ?? "Unknown Task"
                self.currentTaskName = "Running: \(t)"
                self.progress = 0.0
                self.appendLog("Started: \(t)")
            case "task_progress":
                if let c = event.completed, let t = event.total, t > 0 {
                    self.progress = Double(c) / Double(t)
                }
            case "task_complete":
                let t = event.task ?? ""
                self.currentTaskName = "Completed: \(t)"
                self.progress = 1.0
                self.appendLog("Completed: \(t)")
                
                if t == "classification" {
                    self.appendLog(" - New files: \(event.new ?? 0)")
                    self.appendLog(" - Already in Dest: \(event.already_in_dst ?? 0)")
                    self.appendLog(" - Duplicates: \(event.dups ?? 0)")
                    self.appendLog(" - Hash Errors: \(event.errors ?? 0)")
                }
            case "copy_plan_ready":
                self.appendLog("Copy plan generated with \(event.count ?? 0) files.")
            case "error":
                self.appendLog("ERROR: \(event.message ?? "")")
            case "prompt":
                self.promptMessage = event.message ?? "Are you sure?"
                self.showingPrompt = true
            case "complete":
                self.isRunning = false
                self.progress = 1.0
                self.currentTaskName = "Done (\(event.status ?? "success"))"
                self.appendLog("Engine finished with status: \(event.status ?? "success")")
            default:
                break
            }
        }
    }
}
