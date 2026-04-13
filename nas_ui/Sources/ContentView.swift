import SwiftUI

struct ContentView: View {
    @StateObject private var runner = BackendRunner()
    
    @State private var sourcePath: String = ""
    @State private var destPath: String = ""
    @State private var profileName: String = ""
    @State private var isDryRun: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 20) {
                Text("NAS Organizer")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.top, 20)
                
                Divider()
                
                Text("Configuration")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source")
                    HStack {
                        TextField("Source Path", text: $sourcePath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Button("Browse") { selectFolder(for: $sourcePath) }
                    }
                    
                    Text("Destination")
                    HStack {
                        TextField("Dest Path", text: $destPath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Button("Browse") { selectFolder(for: $destPath) }
                    }
                    
                    Text("Profile (Optional)")
                    TextField("Profile Name", text: $profileName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Toggle("Dry Run Mode", isOn: $isDryRun)
                    .padding(.top, 10)
                
                Spacer()
                
                Button(action: {
                    if runner.isRunning {
                        runner.cancel()
                    } else {
                        runner.start(source: sourcePath, dest: destPath, profile: profileName, isDryRun: isDryRun)
                    }
                }) {
                    Text(runner.isRunning ? "Cancel" : "Start Transfer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .tint(runner.isRunning ? .red : .blue)
                .disabled(sourcePath.isEmpty && destPath.isEmpty && profileName.isEmpty)
                .padding(.bottom, 20)
            }
            .padding(.horizontal)
            .frame(width: 300)
            .background(Color(NSColor.controlBackgroundColor))
            
            // Main Content Area
            VStack(alignment: .leading, spacing: 0) {
                // Header Status
                HStack {
                    VStack(alignment: .leading) {
                        Text("Status")
                            .font(.headline)
                        Text(runner.currentTaskName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if runner.isRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                
                Divider()
                
                // Progress Bar
                if runner.isRunning || runner.progress > 0 {
                    ProgressView(value: runner.progress)
                        .padding()
                }
                
                // Terminal Log
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(runner.logLines.indices, id: \.self) { i in
                                Text(runner.logLines[i])
                                    .font(.system(.caption, design: .monospaced))
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
            .frame(minWidth: 500, minHeight: 400)
        }
        // Confirmation Dialog
        .alert(isPresented: $runner.showingPrompt) {
            Alert(
                title: Text("Hold on"),
                message: Text(runner.promptMessage),
                primaryButton: .default(Text("Yes")) { runner.answerPrompt(yes: true) },
                secondaryButton: .cancel(Text("No")) { runner.answerPrompt(yes: false) }
            )
        }
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
}

// macOS minimum required layout
#Preview {
    ContentView()
}
