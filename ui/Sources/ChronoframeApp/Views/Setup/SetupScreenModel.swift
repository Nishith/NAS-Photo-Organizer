import SwiftUI
#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif

enum SetupScreenTone: String, Equatable {
    case idle
    case ready
    case warning
    case success
    case sky
    case amber
    case muted

    var color: SwiftUI.Color {
        switch self {
        case .idle:
            return DesignTokens.Status.idle
        case .ready:
            return DesignTokens.Status.ready
        case .warning:
            return DesignTokens.Status.warning
        case .success:
            return DesignTokens.Status.success
        case .sky:
            return DesignTokens.Color.sky
        case .amber:
            return DesignTokens.Color.amber
        case .muted:
            return DesignTokens.Color.inkMuted
        }
    }
}

enum SetupStepState: Equatable {
    case ready(String, SetupScreenTone)
    case active(String, SetupScreenTone)
    case needed(String, SetupScreenTone)

    var title: String {
        switch self {
        case let .ready(title, _), let .active(title, _), let .needed(title, _):
            return title
        }
    }

    var tone: SetupScreenTone {
        switch self {
        case let .ready(_, tone), let .active(_, tone), let .needed(_, tone):
            return tone
        }
    }
}

enum SetupPrimaryAction: Equatable {
    case chooseSource
    case chooseDestination
    case preview

    var title: String {
        switch self {
        case .chooseSource:
            return "Choose Source"
        case .chooseDestination:
            return "Choose Destination"
        case .preview:
            return "Preview Plan"
        }
    }

    var systemImage: String {
        switch self {
        case .chooseSource:
            return "folder.badge.plus"
        case .chooseDestination:
            return "externaldrive.badge.plus"
        case .preview:
            return "eye"
        }
    }
}

struct SetupScreenContext {
    var sourcePath: String
    var destinationPath: String
    var selectedProfileName: String
    var activeProfile: Profile?
    var usingDroppedSource: Bool
    var droppedSourceLabel: String?
    var droppedSourceItemCount: Int
    var workerCount: Int
    var verifyCopies: Bool
    var isRunInProgress: Bool
}

struct SetupScreenModel {
    let context: SetupScreenContext

    init(
        setupStore: SetupStore,
        preferencesStore: PreferencesStore,
        isRunInProgress: Bool
    ) {
        self.init(
            context: SetupScreenContext(
                sourcePath: setupStore.sourcePath,
                destinationPath: setupStore.destinationPath,
                selectedProfileName: setupStore.selectedProfileName,
                activeProfile: setupStore.activeProfile,
                usingDroppedSource: setupStore.usingDroppedSource,
                droppedSourceLabel: setupStore.droppedSourceLabel,
                droppedSourceItemCount: setupStore.droppedSourceItemCount,
                workerCount: preferencesStore.workerCount,
                verifyCopies: preferencesStore.verifyCopies,
                isRunInProgress: isRunInProgress
            )
        )
    }

    init(context: SetupScreenContext) {
        self.context = context
    }

    var canStartRun: Bool {
        !context.selectedProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!context.sourcePath.isEmpty && !context.destinationPath.isEmpty)
    }

    var displayedSourcePath: String {
        if context.usingDroppedSource {
            return context.droppedSourceLabel ?? context.sourcePath
        }
        return context.sourcePath
    }

    var sourceStepState: SetupStepState {
        if context.usingDroppedSource || !context.sourcePath.isEmpty {
            return .ready(
                context.usingDroppedSource ? "Dropped Source Ready" : "Source Ready",
                .success
            )
        }
        return .needed("Source Needed", .warning)
    }

    var destinationStepState: SetupStepState {
        if !context.destinationPath.isEmpty {
            return .ready("Destination Ready", .success)
        }
        return .needed("Destination Needed", .warning)
    }

    var heroTone: SetupScreenTone {
        if canStartRun {
            return .ready
        }
        if context.usingDroppedSource || !context.sourcePath.isEmpty || !context.destinationPath.isEmpty {
            return .warning
        }
        return .idle
    }

    var heroBadgeTitle: String {
        if context.activeProfile != nil {
            return "Profile Ready"
        }
        if canStartRun {
            return "Ready to Preview"
        }
        if context.usingDroppedSource || !context.sourcePath.isEmpty || !context.destinationPath.isEmpty {
            return "Continue Setup"
        }
        return "Start Here"
    }

    var heroBadgeSymbol: String {
        if canStartRun {
            return "checkmark.circle.fill"
        }
        if context.usingDroppedSource {
            return "square.and.arrow.down.on.square.fill"
        }
        return "circle.dashed"
    }

    var sourceSummaryValue: String {
        if context.usingDroppedSource {
            if context.droppedSourceItemCount > 0 {
                return "\(context.droppedSourceItemCount) dragged item\(context.droppedSourceItemCount == 1 ? "" : "s")"
            }
            return "Dragged items ready"
        }
        if let profile = context.activeProfile {
            return profile.sourcePath
        }
        return context.sourcePath.isEmpty ? "Needed" : "Ready"
    }

    var destinationSummaryValue: String {
        if let profile = context.activeProfile {
            return profile.destinationPath
        }
        return context.destinationPath.isEmpty ? "Needed" : "Ready"
    }

    var modeSummaryValue: String {
        if context.activeProfile != nil {
            return "Saved profile: \(context.selectedProfileName)"
        }
        if context.usingDroppedSource {
            return "One-off dragged source"
        }
        return "Manual source and destination"
    }

    var nextStepSummary: String {
        if context.sourcePath.isEmpty {
            return "Choose or drop a source"
        }
        if context.destinationPath.isEmpty {
            return "Choose a destination"
        }
        return "Preview the plan"
    }

    var configurationSummary: String {
        if context.activeProfile != nil {
            return "Using the saved profile \(context.selectedProfileName)"
        }
        return context.usingDroppedSource ? "Manual destination with dragged source" : "Manual source and destination"
    }

    var performanceSummary: String {
        "\(context.workerCount) workers"
    }

    var safetySummary: String {
        context.verifyCopies
            ? "Verification is enabled after copy"
            : "Verification is disabled for faster throughput"
    }

    var readinessBadgeTitle: String {
        canStartRun ? "Ready to Preview" : "Needs Setup"
    }

    var readinessBadgeSymbol: String {
        canStartRun ? "eye.fill" : "exclamationmark.circle"
    }

    var readinessTone: SetupScreenTone {
        canStartRun ? .ready : .warning
    }

    var readinessMessage: String {
        canStartRun
            ? "Preview is non-destructive. Transfer still requires an explicit confirmation before the backend begins copying."
            : "Complete the source and destination, or pick a saved profile, and Chronoframe will guide you into a safe preview."
    }

    var savedSetupBadgeTitle: String {
        context.activeProfile != nil ? "Active" : "Optional"
    }

    var savedSetupBadgeSymbol: String {
        context.activeProfile != nil ? "checkmark.circle.fill" : "bookmark"
    }

    var savedSetupTone: SetupScreenTone {
        context.activeProfile != nil ? .success : .idle
    }

    var sourcePathHelper: String {
        context.usingDroppedSource
            ? "Dragged items are staged safely as links. Choose a folder here if you want to switch back to a normal source."
            : "Chronoframe reads from this library and never mutates the originals."
    }

    var destinationPathHelper: String {
        "Chronoframe writes organized files and supporting artifacts here."
    }

    var primaryAction: SetupPrimaryAction {
        if context.sourcePath.isEmpty {
            return .chooseSource
        }
        if context.destinationPath.isEmpty {
            return .chooseDestination
        }
        return .preview
    }

    var primaryActionDisabled: Bool {
        context.isRunInProgress
    }
}
