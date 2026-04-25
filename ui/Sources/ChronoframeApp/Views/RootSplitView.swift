#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct RootSplitView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var setupStore: SetupStore
    @ObservedObject private var runSessionStore: RunSessionStore

    init(appState: AppState) {
        self.appState = appState
        self._setupStore = ObservedObject(wrappedValue: appState.setupStore)
        self._runSessionStore = ObservedObject(wrappedValue: appState.runSessionStore)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(
                    min: DesignTokens.Sidebar.minWidth,
                    ideal: DesignTokens.Sidebar.idealWidth,
                    max: DesignTokens.Sidebar.maxWidth
                )
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if runSessionStore.isRunning {
                    Button(role: .destructive) {
                        appState.cancelRun()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                } else if showsRunToolbarActions {
                    Button {
                        Task { await appState.startPreview() }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(!canStartRun)

                    Button {
                        Task { await appState.startTransfer() }
                    } label: {
                        Label("Transfer", systemImage: "arrow.right.circle.fill")
                    }
                    .disabled(!canStartRun)
                }
            }
        }
        .alert(
            runSessionStore.prompt?.title ?? "Chronoframe",
            isPresented: Binding(
                get: { runSessionStore.prompt != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.dismissRunPrompt()
                    }
                }
            )
        ) {
            switch runSessionStore.prompt?.kind {
            case .confirmTransfer:
                Button("Continue") {
                    appState.confirmRunPrompt()
                }
                Button("Cancel", role: .cancel) {
                    appState.dismissRunPrompt()
                }
            case .resumePendingJobs:
                Button("Resume") {
                    appState.confirmRunPrompt()
                }
                Button("Start Fresh") {
                    appState.confirmRunPromptStartFresh()
                }
                Button("Cancel", role: .cancel) {
                    appState.dismissRunPrompt()
                }
            case .blockingError, .none:
                Button("OK", role: .cancel) {
                    appState.dismissRunPrompt()
                }
            }
        } message: {
            Text(runSessionStore.prompt?.message ?? "")
        }
        .alert(
            "Chronoframe Needs Attention",
            isPresented: Binding(
                get: { appState.transientErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.dismissTransientError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.dismissTransientError()
            }
        } message: {
            Text(appState.transientErrorMessage ?? "")
        }
        .onAppear {
            UITestScenario.configureCurrentWindow(for: UITestScenario.current())
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selection {
        case .setup:
            SetupView(appState: appState)
        case .run:
            CurrentRunView(appState: appState)
        case .history:
            RunHistoryView(appState: appState)
        case .profiles:
            ProfilesView(appState: appState)
        }
    }

    private var showsRunToolbarActions: Bool {
        switch appState.selection {
        case .run:
            return true
        case .setup, .history, .profiles:
            return false
        }
    }

    private var canStartRun: Bool {
        setupStore.usingProfile || (!setupStore.sourcePath.isEmpty && !setupStore.destinationPath.isEmpty)
    }
}
