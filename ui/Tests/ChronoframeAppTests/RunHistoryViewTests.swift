import ChronoframeAppCore
import Foundation
import SwiftUI
import XCTest
@testable import ChronoframeApp

@MainActor
final class RunHistoryViewTests: XCTestCase {
    /// Regression for review rec #4: the revert confirmation dialog
    /// previously hardcoded transfer-revert language ("remove the
    /// files this receipt copied, but only if their contents still
    /// match…") for every receipt kind. Dedupe revert RESTORES files
    /// from the Trash; the wording must reflect that.
    func testConfirmationCopyBranchesByEntryKindForDedupeReceipts() {
        let dedupeEntry = makeEntry(kind: .dedupeAuditReceipt)

        XCTAssertEqual(
            RunHistoryView.confirmationTitle(for: dedupeEntry),
            "Restore deduplicated files?"
        )
        XCTAssertEqual(
            RunHistoryView.confirmationActionLabel(for: dedupeEntry),
            "Restore"
        )
        let message = RunHistoryView.confirmationMessage(for: dedupeEntry)
        XCTAssertTrue(
            message.contains("Trash"),
            "Dedupe revert message must mention the Trash"
        )
        XCTAssertFalse(
            message.contains("remove the files this receipt copied"),
            "Dedupe revert message must not reuse transfer-copy language"
        )
    }

    /// Negative case: the legacy organize transfer audit receipt must
    /// still get the original confirmation copy.
    func testConfirmationCopyKeepsTransferLanguageForAuditReceipts() {
        let transferEntry = makeEntry(kind: .auditReceipt)

        XCTAssertEqual(
            RunHistoryView.confirmationTitle(for: transferEntry),
            "Revert this transfer?"
        )
        XCTAssertEqual(
            RunHistoryView.confirmationActionLabel(for: transferEntry),
            "Revert"
        )
        let message = RunHistoryView.confirmationMessage(for: transferEntry)
        XCTAssertTrue(message.contains("remove the files this receipt copied"))
        XCTAssertTrue(message.contains("contents still match"))
    }

    /// Dedupe restore is affirmative — the primary button must NOT be
    /// red. Transfer revert remains destructive. Pure helper test; no
    /// SwiftUI rendering required.
    func testConfirmationRoleDropsDestructiveForDedupeRestore() {
        let dedupeEntry = makeEntry(kind: .dedupeAuditReceipt)
        let transferEntry = makeEntry(kind: .auditReceipt)

        XCTAssertNil(RunHistoryView.confirmationActionRole(for: dedupeEntry))
        XCTAssertEqual(RunHistoryView.confirmationActionRole(for: transferEntry), .destructive)
    }

    /// `confirmationTitle(for:)` is also called when no entry is
    /// pending (the `.confirmationDialog` modifier evaluates the title
    /// at body construction time). It must default to the transfer
    /// title so the dialog has a stable label even before a receipt
    /// is selected.
    func testConfirmationTitleFallsBackToTransferWhenNoEntryPending() {
        XCTAssertEqual(
            RunHistoryView.confirmationTitle(for: nil),
            "Revert this transfer?"
        )
    }

    // MARK: - Source folder label (design-critique fix #6)

    func testSourceFolderLabelUsesLastPathComponentNotFullVolumePath() {
        // Primary row label must be the folder name, not the entire volume path.
        // /Volumes/Photos_4_27_26/2013 → "2013"
        XCTAssertEqual(
            RunHistoryView.sourceFolderLabel(for: "/Volumes/Photos_4_27_26/2013"),
            "2013"
        )
        // Backup volumes with opaque names → still readable as the leaf name
        XCTAssertEqual(
            RunHistoryView.sourceFolderLabel(for: "/Volumes/Backup_21_12"),
            "Backup_21_12"
        )
        // Deep hierarchy: only the last component
        XCTAssertEqual(
            RunHistoryView.sourceFolderLabel(for: "/Users/alice/Pictures/RAW/2024/January"),
            "January"
        )
    }

    private func makeEntry(kind: RunHistoryEntryKind) -> RunHistoryEntry {
        RunHistoryEntry(
            kind: kind,
            title: "Receipt",
            path: "/Volumes/Dest/.organize_logs/receipt.json",
            relativePath: ".organize_logs/receipt.json",
            fileSizeBytes: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
