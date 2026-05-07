import ChronoframeAppCore
import SwiftUI
import XCTest
@testable import ChronoframeApp

@MainActor
final class DeduplicateStatusViewTests: XCTestCase {
    /// `Style` controls the icon glyph + tint. The mapping is the
    /// invariant the consolidation relies on — if it drifts, the eight
    /// migrated states drift with it. Pure enum mapping; no rendering.
    func testStyleIconAndTintMappings() {
        XCTAssertNil(DeduplicateStatusView<EmptyView, EmptyView>.Style.progress.systemImage)
        XCTAssertEqual(
            DeduplicateStatusView<EmptyView, EmptyView>.Style.success.systemImage,
            "checkmark.circle.fill"
        )
        XCTAssertEqual(
            DeduplicateStatusView<EmptyView, EmptyView>.Style.restored.systemImage,
            "arrow.uturn.backward.circle.fill"
        )
        XCTAssertEqual(
            DeduplicateStatusView<EmptyView, EmptyView>.Style.warning.systemImage,
            "exclamationmark.triangle.fill"
        )

        // success and restored share the success tint; warning uses
        // the danger tint. Progress uses the action accent.
        XCTAssertEqual(
            DeduplicateStatusView<EmptyView, EmptyView>.Style.success.tint,
            DeduplicateStatusView<EmptyView, EmptyView>.Style.restored.tint
        )
        XCTAssertNotEqual(
            DeduplicateStatusView<EmptyView, EmptyView>.Style.success.tint,
            DeduplicateStatusView<EmptyView, EmptyView>.Style.warning.tint
        )
    }

    /// Smoke-test: each style renders without crashing for a minimal
    /// configuration. Catches missing required init params or layout
    /// assertions in the shared status surface.
    func testEachStyleRendersWithoutCrashing() {
        let styles: [DeduplicateStatusView<EmptyView, EmptyView>.Style] = [.progress, .success, .restored, .warning]
        for style in styles {
            let view = DeduplicateStatusView<EmptyView, EmptyView>(
                style: style,
                title: "Title",
                message: "Body",
                detail: "12 of 84"
            )
            _ = view.body
        }
    }

    func testStatusViewRendersPrimaryAndSecondaryActions() {
        let view = DeduplicateStatusView(
            style: .success,
            title: "Nothing to deduplicate",
            primary: {
                Button("Scan Again") {}
            },
            secondary: {
                Button("Change Folder") {}
            }
        )

        _ = view.body
    }

    func testCommitFooterCopyDistinguishesTrashFromHardDelete() {
        XCTAssertEqual(
            DeduplicateView.commitFooterTitle(fileCount: 2, hardDelete: false),
            "2 files will be moved to Trash"
        )
        XCTAssertEqual(
            DeduplicateView.commitFooterTitle(fileCount: 1, hardDelete: true),
            "1 file will be permanently deleted"
        )

        let trashDetail = DeduplicateView.commitFooterDetail(byteCount: 1_048_576, hardDelete: false)
        XCTAssertTrue(trashDetail.contains("recoverable"))
        XCTAssertFalse(trashDetail.contains("permanently"))

        let hardDeleteDetail = DeduplicateView.commitFooterDetail(byteCount: 1_048_576, hardDelete: true)
        XCTAssertTrue(hardDeleteDetail.contains("permanently removed"))
        XCTAssertFalse(hardDeleteDetail.contains("recoverable"))
    }

    func testDeduplicateReviewLayoutSwitchesAtConfiguredBreakpoint() {
        XCTAssertEqual(
            DeduplicateReviewLayout.mode(forWidth: DesignTokens.DeduplicateLayout.reviewWideBreakpoint - 1),
            .compact
        )
        XCTAssertEqual(
            DeduplicateReviewLayout.mode(forWidth: DesignTokens.DeduplicateLayout.reviewWideBreakpoint),
            .wide
        )
        XCTAssertEqual(
            DeduplicateReviewLayout.mode(forWidth: DesignTokens.DeduplicateLayout.reviewWideBreakpoint + 1),
            .wide
        )
    }

    func testCompactClusterListHeightClampsWithinConfiguredRange() {
        XCTAssertEqual(
            DeduplicateReviewLayout.compactClusterListHeight(forAvailableHeight: 300),
            DesignTokens.DeduplicateLayout.compactClusterListMinHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(
            DeduplicateReviewLayout.compactClusterListHeight(forAvailableHeight: 2_000),
            DesignTokens.DeduplicateLayout.compactClusterListMaxHeight,
            accuracy: 0.5
        )
        let middle = DeduplicateReviewLayout.compactClusterListHeight(forAvailableHeight: 700)
        XCTAssertGreaterThan(middle, DesignTokens.DeduplicateLayout.compactClusterListMinHeight)
        XCTAssertLessThan(middle, DesignTokens.DeduplicateLayout.compactClusterListMaxHeight)
    }

    func testDetailPreviewResizeBoundsPreservePreviewSpace() {
        let availableHeight: CGFloat = 900
        let bounds = DeduplicateDetailPreviewLayout.thumbnailStripHeightBounds(forAvailableHeight: availableHeight)

        XCTAssertEqual(bounds.lowerBound, DeduplicateDetailPreviewLayout.minimumThumbnailStripHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(bounds.upperBound, DeduplicateDetailPreviewLayout.maximumThumbnailStripHeight)
        let remainingPreviewHeight = availableHeight - DeduplicateDetailPreviewLayout.resizeHandleHeight - bounds.upperBound
        XCTAssertGreaterThanOrEqual(
            remainingPreviewHeight + 0.5,
            DeduplicateDetailPreviewLayout.minimumPreviewHeight
        )

        XCTAssertEqual(
            DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(10, availableHeight: availableHeight),
            bounds.lowerBound,
            accuracy: 0.5
        )
        XCTAssertEqual(
            DeduplicateDetailPreviewLayout.clampedThumbnailStripHeight(1_000, availableHeight: availableHeight),
            bounds.upperBound,
            accuracy: 0.5
        )
    }

    func testDetailPreviewThumbnailSizeGrowsWithStripHeight() {
        let compact = DeduplicateDetailPreviewLayout.thumbnailSize(forStripHeight: 126)
        let expanded = DeduplicateDetailPreviewLayout.thumbnailSize(forStripHeight: 260)

        XCTAssertGreaterThan(expanded, compact)
        XCTAssertGreaterThanOrEqual(compact, DeduplicateDetailPreviewLayout.minimumThumbnailSize)
        XCTAssertLessThanOrEqual(expanded, DeduplicateDetailPreviewLayout.maximumThumbnailSize)
    }

    func testCompletedStatusCopyKeepsPartialFailuresVisuallySeparate() {
        let copy = DeduplicateView.completedStatusCopy(for: DeduplicateCommitSummary(
            deletedCount: 3,
            failedCount: 1,
            bytesReclaimed: 1_048_576,
            receiptPath: "/tmp/receipt.json",
            hardDelete: false
        ))

        XCTAssertEqual(copy.message, "Removed 3 files · reclaimed 1 MB")
        XCTAssertEqual(copy.warning, "1 item failed — see Run History for details.")
    }

    func testRevertedStatusCopyKeepsPartialFailuresVisuallySeparate() {
        let copy = DeduplicateView.revertedStatusCopy(for: DeduplicateCommitSummary(
            deletedCount: 2,
            failedCount: 3,
            bytesReclaimed: 1_048_576,
            receiptPath: "/tmp/receipt.json",
            hardDelete: false
        ))

        XCTAssertEqual(copy.message, "Restored 2 files · 1 MB returned to the destination")
        XCTAssertEqual(copy.warning, "3 items could not be restored — see Run History for details.")
    }

    func testMatchReasonFormatterExplainsConfidenceReasonsWarningsAndKeepers() {
        let burst = MatchReason(
            timeDeltaSeconds: 12,
            averageVisionDistance: 0.08,
            minVisionDistance: 0.04,
            averageDhashDistance: 2,
            kind: .burst
        )
        let annotation = ClusterAnnotation(
            confidence: .high,
            matchReason: burst,
            keeperReason: KeeperReason(factors: [
                .betterOverallQuality(delta: 0.21),
                .eyesOpen,
                .largerFile(delta: 1_048_576),
            ]),
            warnings: [.differentFraming(cropDelta: 0.24)]
        )

        XCTAssertEqual(MatchReasonFormatter.summary(MatchReason(kind: .exactDuplicate)), "Identical file content")
        XCTAssertEqual(MatchReasonFormatter.summary(MatchReason(kind: .editedVariant)), "Edited version of the same photo")
        XCTAssertEqual(MatchReasonFormatter.summary(burst), "Taken 12s apart, 92% visually similar")
        XCTAssertEqual(MatchReasonFormatter.oneLiner(annotation), "92% similar, 12s apart")
        XCTAssertEqual(
            MatchReasonFormatter.keeperSummary(annotation.keeperReason!),
            "Kept: better quality (+0.21), eyes open, larger file (+1 MB)"
        )
        XCTAssertEqual(MatchReasonFormatter.warningSummary(annotation.warnings[0]), "Different framing (24% crop difference)")
        XCTAssertEqual(MatchReasonFormatter.warningSummary(.largeTimeGap(seconds: 90)), "Taken 1.5 min apart")
        XCTAssertEqual(MatchReasonFormatter.confidenceLabel(.high), "Auto")
        XCTAssertEqual(MatchReasonFormatter.confidenceLabel(.medium), "Review")
        XCTAssertEqual(MatchReasonFormatter.confidenceLabel(.low), "Careful")
    }
}
