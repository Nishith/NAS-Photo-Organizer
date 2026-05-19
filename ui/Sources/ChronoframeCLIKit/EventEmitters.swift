import ChronoframeCore
import Foundation

public enum JSONLineEmitter {
    /// Version of the wire format produced by `line(for:)`. Downstream
    /// consumers (CI scripts, log shippers) can branch on this when the
    /// schema evolves. Existing keys MUST keep their meaning across minor
    /// version bumps; only new optional keys may be added. Removing or
    /// renaming a key requires a major bump and is a breaking change.
    public static let eventVersion: Int = 1

    public static func line(for event: RunEvent) throws -> String {
        var payload = payload(for: event)
        payload["event_version"] = eventVersion
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Renders a CLI error as a JSON event so pipeline consumers in
    /// `--json` mode never have to parse free-form English on stdout.
    /// `kind` is one of "usage" (caller-side argument problem) or
    /// "operational" (engine-side failure).
    public static func errorLine(kind: String, message: String) -> String {
        let payload: [String: Any] = [
            "type": "error",
            "event_version": eventVersion,
            "kind": kind,
            "message": message,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{\"type\":\"error\",\"event_version\":1,\"kind\":\"\(kind)\",\"message\":\"\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func payload(for event: RunEvent) -> [String: Any] {
        switch event {
        case .startup:
            return ["type": "startup"]
        case let .phaseStarted(phase, total):
            return compact([
                "type": "task_start",
                "task": phase.rawValue,
                "total": total,
            ])
        case let .phaseProgress(phase, completed, total, bytesCopied, bytesTotal, _):
            return compact([
                "type": "task_progress",
                "task": phase.rawValue,
                "completed": completed,
                "total": total,
                "bytes_copied": bytesCopied,
                "bytes_total": bytesTotal,
            ])
        case let .phaseCompleted(phase, result):
            return compact([
                "type": "task_complete",
                "task": phase.rawValue,
                "found": result.found,
                "new": result.newCount,
                "already_in_destination": result.alreadyInDestinationCount,
                "duplicate": result.duplicateCount,
                "hash_errors": result.hashErrorCount,
                "copied": result.copiedCount,
                "failed": result.failedCount,
                "reverted": result.revertedCount,
                "skipped": result.skippedCount,
                "missing": result.missingCount,
                "moved": result.movedCount,
            ])
        case let .copyPlanReady(count):
            return ["type": "copy_plan_ready", "count": count]
        case let .dateHistogram(buckets):
            return [
                "type": "date_histogram",
                "buckets": buckets.map {
                    ["key": $0.key, "planned_count": $0.plannedCount]
                },
            ]
        case let .issue(issue):
            return [
                "type": issue.severity == .error ? "error" : "warning",
                "severity": issue.severity.rawValue,
                "message": issue.message,
            ]
        case let .prompt(message):
            return ["type": "prompt", "message": message]
        case let .complete(summary):
            return [
                "type": "complete",
                "status": backendStatus(for: summary.status),
                "title": summary.title,
                "metrics": metricsPayload(summary.metrics),
                "artifacts": compact([
                    "destination": summary.artifacts.destinationRoot,
                    "report": summary.artifacts.reportPath,
                    "preview_review": summary.artifacts.previewReviewPath,
                    "log": summary.artifacts.logFilePath,
                    "logs_directory": summary.artifacts.logsDirectoryPath,
                ]),
            ]
        }
    }

    private static func metricsPayload(_ metrics: RunMetrics) -> [String: Any] {
        compact([
            "discovered": metrics.discoveredCount,
            "planned": metrics.plannedCount,
            "already_in_destination": metrics.alreadyInDestinationCount,
            "duplicate": metrics.duplicateCount,
            "hash_errors": metrics.hashErrorCount,
            "copied": metrics.copiedCount,
            "failed": metrics.failedCount,
            "errors": metrics.errorCount,
            "bytes_copied": metrics.bytesCopied,
            "bytes_total": metrics.bytesTotal,
            "speed_mbps": metrics.speedMBps,
            "eta_seconds": metrics.etaSeconds,
            "reverted": metrics.revertedCount,
            "skipped": metrics.skippedCount,
            "missing": metrics.missingCount,
            "moved": metrics.movedCount,
            "date_histogram": metrics.dateHistogram.map {
                ["key": $0.key, "planned_count": $0.plannedCount]
            },
        ])
    }

    private static func compact(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, pair in
            if let value = pair.value {
                result[pair.key] = value
            }
        }
    }

    private static func backendStatus(for status: RunStatus) -> String {
        switch status {
        case .dryRunFinished:
            return "dry_run_finished"
        case .nothingToCopy:
            return "nothing_to_copy"
        case .revertEmpty:
            return "revert_empty"
        case .nothingToReorganize:
            return "nothing_to_reorganize"
        default:
            return status.rawValue
        }
    }
}

public enum HumanLineEmitter {
    public static func line(for event: RunEvent) -> String? {
        switch event {
        case .startup:
            return "Starting..."
        case let .phaseStarted(phase, total):
            if let total {
                return "\(phase.runningTitle) 0/\(total)"
            }
            return phase.runningTitle
        case let .phaseProgress(phase, completed, total, _, _, _):
            return "\(phase.title): \(completed)/\(total)"
        case let .phaseCompleted(phase, result):
            return completedLine(phase: phase, result: result)
        case let .copyPlanReady(count):
            return "\(count) files ready to copy."
        case let .issue(issue):
            return "\(issue.severity.prefix): \(issue.message)"
        case let .prompt(message):
            return message
        case let .complete(summary):
            return completeLine(summary)
        case .dateHistogram:
            return nil
        }
    }

    private static func completedLine(phase: RunPhase, result: RunPhaseResult) -> String {
        switch phase {
        case .discovery:
            return "Discovered \(result.found ?? 0) files."
        case .classification:
            return "Classified \(result.newCount ?? 0) new files, \(result.alreadyInDestinationCount ?? 0) already in destination."
        case .copy:
            return "Transfer complete: \(result.copiedCount ?? 0) copied, \(result.failedCount ?? 0) failed."
        case .revert:
            return "Revert complete: \(result.revertedCount ?? 0) reverted, \(result.skippedCount ?? 0) preserved, \(result.missingCount ?? 0) already missing."
        case .reorganize:
            return "Reorganize complete: \(result.movedCount ?? 0) moved, \(result.skippedCount ?? 0) skipped, \(result.failedCount ?? 0) failed."
        case .sourceHashing, .destinationIndexing:
            return "\(phase.title) complete."
        }
    }

    private static func completeLine(_ summary: RunSummary) -> String {
        switch summary.status {
        case .dryRunFinished:
            return "Preview complete. Report: \(summary.artifacts.reportPath ?? "not written")"
        case .finished:
            return "Done. Copied \(summary.metrics.copiedCount) files."
        case .nothingToCopy:
            return "Already up to date. Nothing to copy."
        case .reverted:
            return "Revert complete. Reverted \(summary.metrics.revertedCount) files."
        case .revertEmpty:
            return "Nothing to revert."
        case .reorganized:
            return "Reorganize complete. Moved \(summary.metrics.movedCount) files."
        case .nothingToReorganize:
            return "Layout already correct."
        case .failed:
            return "Run failed."
        case .cancelled:
            return "Cancelled."
        case .idle, .preflighting, .running:
            return summary.title
        }
    }
}
