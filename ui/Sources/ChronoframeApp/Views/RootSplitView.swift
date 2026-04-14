#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

struct RootSplitView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.runSessionStore.isRunning {
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
                    .disabled(!appState.canStartRun)

                    Button {
                        Task { await appState.startTransfer() }
                    } label: {
                        Label("Transfer", systemImage: "arrow.right.circle.fill")
                    }
                    .disabled(!appState.canStartRun)
                }
            }
        }
        .alert(
            appState.runSessionStore.prompt?.title ?? "Chronoframe",
            isPresented: Binding(
                get: { appState.runSessionStore.prompt != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.dismissRunPrompt()
                    }
                }
            )
        ) {
            switch appState.runSessionStore.prompt?.kind {
            case .confirmTransfer, .resumePendingJobs:
                Button("Continue") {
                    Task { await appState.confirmRunPrompt() }
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
            Text(appState.runSessionStore.prompt?.message ?? "")
        }
        .alert(
            "Problem",
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
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selection {
        case .setup:
            SetupView(appState: appState)
        case .currentRun:
            CurrentRunView(appState: appState)
        case .history:
            RunHistoryView(appState: appState)
        case .profiles:
            ProfilesView(appState: appState)
        }
    }

    private var showsRunToolbarActions: Bool {
        switch appState.selection {
        case .currentRun:
            return true
        case .setup, .history, .profiles:
            return false
        }
    }
}
