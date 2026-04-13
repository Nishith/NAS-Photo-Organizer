import SwiftUI
import AppKit

// Phase labels for the 5-step progress indicator
private let phaseLabels = ["Discover", "Hash Src", "Index Dst", "Classify", "Copy"]

struct ContentView: View {
    @StateObject private var runner = BackendRunner()

    @State private var sourcePath: String = ""
    @State private var destPath: String = ""
    @State private var profileName: String = ""
    @State private var isFastDest: Bool = false
    @State private var numWorkers: Int = 8

    // Computed path validity
    private var sourceValid: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }
    private var destNonEmpty: Bool { !destPath.isEmpty }
    private var canStart: Bool {
        !runner.isRunning && (!profileName.isEmpty || (sourceValid && destNonEmpty))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainContent
        }
        .alert(isPresented: $runner.showingPrompt) {
            Alert(
                title: Text("Confirm"),
                message: Text(runner.promptMessage),
                primaryButton: .default(Text("Yes")) { runner.answerPrompt(yes: true) },
                secondaryButton: .cancel(Text("No")) { runner.answerPrompt(yes: false) }
            )
        }
    }

    // ── Sidebar ──────────────────────────────────────────────────────────────

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NAS Organizer")
                .font(.title2).fontWeight(.bold)
                .padding(.top, 20)

            Divider()

            Text("Configuration")
                .font(.headline)
                .foregroundColor(.secondary)

            // Source path
            VStack(alignment: .leading, spacing: 4) {
                Text("Source").font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("Source path", text: $sourcePath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(pathBorderColor(valid: sourceValid, empty: sourcePath.isEmpty),
                                        lineWidth: sourcePath.isEmpty ? 0 : 1.5)
                        )
                    Button("Browse") { selectFolder(for: $sourcePath) }
                        .fixedSize()
                }
                if !sourcePath.isEmpty && !sourceValid {
                    Text("Path not found").font(.caption).foregroundColor(.red)
                }
            }

            // Dest path
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination").font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("Destination path", text: $destPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("Browse") { selectFolder(for: $destPath) }
                        .fixedSize()
                }
            }

            // Profile (optional, with help tooltip)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Profile").font(.subheadline).foregroundColor(.secondary)
                    profileHelpButton
                }
                TextField("Profile name (optional)", text: $profileName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            Divider()

            // Options
            Toggle("Fast Dest Mode", isOn: $isFastDest)
                .help("Skip destination network scan — load from cache. Use for repeated dry-run previews.")

            HStack {
                Text("Workers").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                Stepper("\(numWorkers)", value: $numWorkers, in: 1...32)
                    .fixedSize()
            }
            .help("Parallel threads for hashing. Reduce to 2–4 for slow NAS connections.")

            Spacer()

            // Action buttons
            VStack(spacing: 8) {
                if runner.isRunning {
                    Button(action: { runner.cancel() }) {
                        Text("Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .tint(.red)
                } else {
                    // Preview (dry-run)
                    Button(action: { startRun(dryRun: true) }) {
                        Label("Preview", systemImage: "eye")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .disabled(!canStart)
                    .help("Scan and plan without copying any files. Generates a CSV report.")

                    // Start transfer
                    Button(action: { startRun(dryRun: false) }) {
                        Text("Start Transfer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .tint(.blue)
                    .disabled(!canStart)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal)
        .frame(width: 300)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // ── Main Content ─────────────────────────────────────────────────────────

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            phaseIndicator
            Divider()
            logView
            if !runner.isRunning && !runner.completedDest.isEmpty {
                postRunActions
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var statusHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Status").font(.headline)
                Text(runner.currentTaskName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if runner.isRunning && runner.speedMBps > 0 {
                    HStack(spacing: 8) {
                        Text(String(format: "%.1f MB/s", runner.speedMBps))
                            .font(.caption).foregroundColor(.blue)
                        if runner.etaSeconds > 0 {
                            Text("ETA \(formatETA(runner.etaSeconds))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 10) {
                // Error badge
                if runner.errorCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("\(runner.errorCount) error\(runner.errorCount == 1 ? "" : "s")")
                            .font(.caption).foregroundColor(.red)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                if runner.isRunning {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var phaseIndicator: some View {
        HStack(spacing: 0) {
            ForEach(phaseLabels.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        Circle()
                            .fill(phaseCircleColor(index: i))
                            .frame(width: 10, height: 10)
                        Text(phaseLabels[i])
                            .font(.system(size: 9))
                            .foregroundColor(i <= runner.currentPhase ? .primary : Color(NSColor.tertiaryLabelColor))
                    }
                    .frame(maxWidth: .infinity)

                    if i < phaseLabels.count - 1 {
                        Rectangle()
                            .fill(i < runner.currentPhase ? Color.accentColor : Color(NSColor.separatorColor))
                            .frame(height: 1.5)
                            .frame(maxWidth: 40)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))

        // Progress bar below phases
        .overlay(alignment: .bottom) {
            if runner.isRunning || runner.progress > 0 {
                ProgressView(value: runner.progress)
                    .frame(height: 2)
                    .offset(y: 1)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(runner.logLines.indices, id: \.self) { i in
                        Text(runner.logLines[i])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logLineColor(runner.logLines[i]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding()
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: runner.logLines.count) { _ in
                withAnimation {
                    proxy.scrollTo(runner.logLines.count - 1, anchor: .bottom)
                }
            }
        }
    }

    private var postRunActions: some View {
        HStack(spacing: 12) {
            Button(action: openDestInFinder) {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(BorderedButtonStyle())

            if !runner.completedReport.isEmpty {
                Button(action: openReport) {
                    Label("View Report", systemImage: "doc.text")
                }
                .buttonStyle(BorderedButtonStyle())
            }

            Button(action: openLogsFolder) {
                Label("Logs Folder", systemImage: "archivebox")
            }
            .buttonStyle(BorderedButtonStyle())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // ── Profile help popover ──────────────────────────────────────────────

    @State private var showingProfileHelp = false

    private var profileHelpButton: some View {
        Button(action: { showingProfileHelp.toggle() }) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingProfileHelp, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles").font(.headline)
                Text("Define named source/dest pairs in **nas_profiles.yaml** next to organize_nas.py.\n\nExample:\n  mobile_backup:\n    source: /Volumes/phone\n    dest: /Volumes/NAS/Photos\n\nEnter the profile key here to use it instead of the path fields above.")
                    .font(.caption)
                    .frame(width: 260)
            }
            .padding()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private func startRun(dryRun: Bool) {
        runner.start(
            source: sourcePath,
            dest: destPath,
            profile: profileName,
            isDryRun: dryRun,
            isFastDest: isFastDest,
            workers: numWorkers
        )
    }

    private func selectFolder(for binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func openDestInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedDest))
    }

    private func openReport() {
        NSWorkspace.shared.open(URL(fileURLWithPath: runner.completedReport))
    }

    private func openLogsFolder() {
        let logsPath = runner.completedDest + "/.organize_logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: logsPath))
    }

    private func pathBorderColor(valid: Bool, empty: Bool) -> Color {
        if empty { return .clear }
        return valid ? Color.green : Color.red
    }

    private func phaseCircleColor(index: Int) -> Color {
        if index < runner.currentPhase { return Color.accentColor }
        if index == runner.currentPhase { return Color.accentColor.opacity(0.7) }
        return Color(NSColor.separatorColor)
    }

    private func logLineColor(_ line: String) -> Color {
        if line.hasPrefix("ERROR:") { return .red }
        if line.hasPrefix("⚠") || line.hasPrefix("WARNING:") { return Color.orange }
        if line.hasPrefix("ℹ") { return .secondary }
        return .primary
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60  { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

#Preview {
    ContentView()
}
