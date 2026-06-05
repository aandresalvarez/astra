import Testing
import CoreGraphics
@testable import ASTRA

/// Regression tests for the panel layout math that drives the
/// detail/shelf/inspector column sizing in ContentDetailAreaView.
///
/// These cover the bugs identified in the UI bug hunt after the rail-column
/// removal and the `.inspector()` → custom HStack migration:
///   - Detail area must never collapse to ≤ 0 once a shelf is clamped.
///   - When a shelf + inspector + detail can't all fit at their minimums, the
///     compact threshold must recognize that so callers can react (auto-hide,
///     squish the inspector, etc.).
///   - Compact-layout threshold must match the production constant.
@Suite("PanelLayoutGeometry")
struct PanelLayoutGeometryTests {

    // MARK: - Constants

    @Test("Compact threshold matches the production constant")
    func compactThresholdConstant() {
        // If this drifts, the auto-hide-sidebar logic in reconcileCompactPanelLayout
        // will fire at the wrong width. The number is intentional — change requires
        // a UI review pass — so we pin it.
        #expect(PanelLayoutGeometry.compactPanelMutualExclusionWidth == 1_280)
    }

    @Test("Inspector column width matches the production constant")
    func inspectorColumnWidthConstant() {
        #expect(PanelLayoutGeometry.inspectorMinColumnWidth == 340)
        #expect(PanelLayoutGeometry.inspectorColumnWidth == 392)
        #expect(PanelLayoutGeometry.inspectorDefaultMaxColumnWidth == 420)
        #expect(PanelLayoutGeometry.inspectorMaxColumnWidth == 460)
    }

    @Test("Main window opens wide enough for sidebar and right panel")
    func mainWindowDefaultSizeSupportsSidePanels() {
        #expect(AppWindowLayout.mainMinimumWidth == 900)
        #expect(AppWindowLayout.mainMinimumHeight == 600)
        #expect(AppWindowLayout.mainDefaultWidth == PanelLayoutGeometry.compactPanelMutualExclusionWidth + 80)
        #expect(AppWindowLayout.mainDefaultHeight == 750)
        #expect(AppWindowLayout.mainDefaultWidth > PanelLayoutGeometry.compactPanelMutualExclusionWidth)
    }

    @Test("Workspace shelf visibility uses stable persisted item values")
    func workspaceShelfVisibilityUsesStablePersistedValues() {
        #expect(AppStorageKeys.activeWorkspaceCanvasItemsByConversation == "astra.workspaceCanvas.activeItemsByConversation.v1")
        #expect(WorkspaceCanvasItem.plan.rawValue == "plan")
        #expect(WorkspaceCanvasItem.markdown.rawValue == "markdown")
        #expect(WorkspaceCanvasItem.browser.rawValue == "browser")
        #expect(WorkspaceCanvasItem.query.rawValue == "query")
        #expect(WorkspaceCanvasItemPreference.item(for: "") == nil)
        #expect(WorkspaceCanvasItemPreference.rawValue(for: nil) == "")
        #expect(WorkspaceCanvasItemPreference.rawValue(for: .browser) == "browser")
        #expect(WorkspaceCanvasItemPreference.emptyStorageRawValue == "{}")
    }

    @Test("Workspace shelf preference changes only for explicit user choices in the current conversation")
    func workspaceShelfPreferenceChangesOnlyForExplicitUserChoicesInCurrentConversation() {
        let conversationA = "conversation-a"
        let conversationB = "conversation-b"

        let withBrowser = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: WorkspaceCanvasItemPreference.emptyStorageRawValue,
            conversationID: conversationA,
            item: .browser,
            remember: true
        )

        #expect(WorkspaceCanvasItemPreference.item(in: withBrowser, for: conversationA) == .browser)
        #expect(WorkspaceCanvasItemPreference.item(in: withBrowser, for: conversationB) == nil)

        #expect(WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: withBrowser,
            conversationID: conversationA,
            item: nil,
            remember: false
        ) == withBrowser)

        let withConversationAClosed = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: withBrowser,
            conversationID: conversationA,
            item: nil,
            remember: true
        )
        #expect(WorkspaceCanvasItemPreference.item(in: withConversationAClosed, for: conversationA) == nil)

        let withConversationBMarkdown = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: withConversationAClosed,
            conversationID: conversationB,
            item: .markdown,
            remember: true
        )
        #expect(WorkspaceCanvasItemPreference.item(in: withConversationBMarkdown, for: conversationA) == nil)
        #expect(WorkspaceCanvasItemPreference.item(in: withConversationBMarkdown, for: conversationB) == .markdown)
        #expect(WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: withConversationBMarkdown,
            conversationID: nil,
            item: nil,
            remember: true
        ) == withConversationBMarkdown)
    }

    // MARK: - isCompactPanelLayout

    @Test("isCompactPanelLayout is false for zero or negative widths (layout not measured yet)")
    func compactLayoutGuardsZero() {
        #expect(PanelLayoutGeometry.isCompactPanelLayout(width: 0) == false)
        #expect(PanelLayoutGeometry.isCompactPanelLayout(width: -100) == false)
    }

    @Test("isCompactPanelLayout flips at the threshold")
    func compactLayoutFlipsAtThreshold() {
        #expect(PanelLayoutGeometry.isCompactPanelLayout(width: 1_279) == true)
        #expect(PanelLayoutGeometry.isCompactPanelLayout(width: 1_280) == false)
        #expect(PanelLayoutGeometry.isCompactPanelLayout(width: 1_500) == false)
    }

    // MARK: - Inspector sizing

    @Test("Inspector docked width uses viewport-relative clamp")
    func inspectorDockedWidthClamp() {
        #expect(PanelLayoutGeometry.inspectorDockedColumnWidth(for: 1_000) == 340)
        #expect(PanelLayoutGeometry.inspectorDockedColumnWidth(for: 1_600) == 384)
        #expect(PanelLayoutGeometry.inspectorDockedColumnWidth(for: 2_000) == 420)
    }

    @Test("Resizable inspector width preserves detail minimum and user max")
    func inspectorResizableWidthClamp() {
        #expect(PanelLayoutGeometry.inspectorResizableColumnWidth(
            500,
            detailAreaWidth: 1_000,
            minimumDetailWidth: 480
        ) == 460)
        #expect(PanelLayoutGeometry.inspectorResizableColumnWidth(
            500,
            detailAreaWidth: 850,
            minimumDetailWidth: 480
        ) == 370)
        #expect(PanelLayoutGeometry.inspectorResizableColumnWidth(
            200,
            detailAreaWidth: 1_200,
            minimumDetailWidth: 480
        ) == 340)
    }

    @Test("Inspector becomes overlay when docked layout would squeeze detail")
    func inspectorOverlayBreakpoint() {
        #expect(PanelLayoutGeometry.shouldOverlayInspector(
            detailAreaWidth: 819,
            minimumDetailWidth: 480
        ) == true)
        #expect(PanelLayoutGeometry.shouldOverlayInspector(
            detailAreaWidth: 820,
            minimumDetailWidth: 480
        ) == false)
    }

    @Test("Overlay inspector width stays readable but fits tiny windows")
    func inspectorOverlayWidthClamp() {
        #expect(PanelLayoutGeometry.inspectorOverlayWidth(for: 300) == 280)
        #expect(abs(PanelLayoutGeometry.inspectorOverlayWidth(for: 380) - 349.6) < 0.01)
        #expect(PanelLayoutGeometry.inspectorOverlayWidth(for: 900) == 420)
    }

    // MARK: - clampedShelfWidth (bug regression: detail must not collapse to 0)

    @Test("Browser shelf clamps to min width when squeezed; detail stays ≥ minimumDetailWidth")
    func browserShelfRespectsMinimumDetailWidth() {
        // Browser: min 360, max 1120, minimumDetailWidth 520.
        let available: CGFloat = 1_000
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            800, // user stored a wide shelf
            shelfMinWidth: 360,
            shelfMaxWidth: 1_120,
            minimumDetailWidth: 520,
            availableWidth: available
        )
        // Should be limited to availableWidth - minimumDetailWidth = 480, not 800.
        #expect(clamped == 480)
        let detail = PanelLayoutGeometry.detailWidthAfterShelf(
            availableWidth: available,
            clampedShelfWidth: clamped
        )
        #expect(detail == 520)
    }

    @Test("When the available width can't satisfy both minimums, shelf falls back to its min")
    func shelfFallsBackToMinWhenSpaceImpossible() {
        // 480pt available, browser needs 520 for detail — impossible.
        // Behavior: shelf clamps to its min (360), detail gets whatever's left
        // (which is positive but smaller than the minimumDetailWidth).
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            800,
            shelfMinWidth: 360,
            shelfMaxWidth: 1_120,
            minimumDetailWidth: 520,
            availableWidth: 480
        )
        #expect(clamped == 360)
        let detail = PanelLayoutGeometry.detailWidthAfterShelf(
            availableWidth: 480,
            clampedShelfWidth: clamped
        )
        #expect(detail == 120)
    }

    @Test("Detail width never goes negative even at pathological widths")
    func detailWidthNeverNegative() {
        // 200pt available, browser min 360. Detail mathematically = -160.
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            400,
            shelfMinWidth: 360,
            shelfMaxWidth: 1_120,
            minimumDetailWidth: 520,
            availableWidth: 200
        )
        #expect(clamped == 360)
        let detail = PanelLayoutGeometry.detailWidthAfterShelf(
            availableWidth: 200,
            clampedShelfWidth: clamped
        )
        // Without the floor, detail would be -160; the helper must clamp to 0.
        #expect(detail == 0)
    }

    @Test("User-requested shelf width below the min snaps up to the min")
    func belowMinSnapsToMin() {
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            200,
            shelfMinWidth: 360,
            shelfMaxWidth: 1_120,
            minimumDetailWidth: 520,
            availableWidth: 2_000
        )
        #expect(clamped == 360)
    }

    @Test("User-requested shelf width above the max snaps down to the max")
    func aboveMaxSnapsToMax() {
        let clamped = PanelLayoutGeometry.clampedShelfWidth(
            5_000,
            shelfMinWidth: 360,
            shelfMaxWidth: 1_120,
            minimumDetailWidth: 520,
            availableWidth: 10_000
        )
        #expect(clamped == 1_120)
    }

    @Test("Files shelf minimum preserves navigator and preview")
    func filesShelfMinimumPreservesNavigatorAndPreview() {
        #expect(PanelLayoutGeometry.filesShelfMinReadableWidth == 550)
        #expect(PanelLayoutGeometry.filesShelfPreviewWidth(shelfWidth: 360) < PanelLayoutGeometry.filesShelfMinimumPreviewWidth)
        #expect(PanelLayoutGeometry.filesShelfPreviewWidth(
            shelfWidth: PanelLayoutGeometry.filesShelfMinReadableWidth
        ) == PanelLayoutGeometry.filesShelfMinimumPreviewWidth)
    }

    @Test("Files shelf drag below minimum dismisses instead of saving a smashed width")
    func shelfResizeDismissesBelowMinimum() {
        let minimum = PanelLayoutGeometry.filesShelfMinReadableWidth
        #expect(PanelLayoutGeometry.shouldDismissShelfResize(
            proposedWidth: minimum - 0.5,
            shelfMinWidth: minimum
        ) == true)
        #expect(PanelLayoutGeometry.shouldDismissShelfResize(
            proposedWidth: minimum,
            shelfMinWidth: minimum
        ) == false)
        #expect(PanelLayoutGeometry.shouldDismissShelfResize(
            proposedWidth: minimum + 40,
            shelfMinWidth: minimum
        ) == false)
    }

    // MARK: - cannotFitShelfAndInspector (bug regression: don't pretend three columns fit when they don't)

    @Test("Three columns fit comfortably at wide widths")
    func threeColumnsFitWide() {
        // Wide window: 1700pt detail area, browser (min 360), min detail 520.
        // 1700 ≥ 360 + 520 + 340 = 1220 → fits.
        let cannotFit = PanelLayoutGeometry.cannotFitShelfAndInspector(
            detailAreaWidth: 1_700,
            shelfMinWidth: 360,
            minimumDetailWidth: 520
        )
        #expect(cannotFit == false)
    }

    @Test("Three columns can't fit at narrow widths — caller must auto-close one")
    func threeColumnsCannotFitNarrow() {
        // 1100pt detail area: 360 + 520 + 340 = 1220. 1100 < 1220 → can't fit.
        let cannotFit = PanelLayoutGeometry.cannotFitShelfAndInspector(
            detailAreaWidth: 1_100,
            shelfMinWidth: 360,
            minimumDetailWidth: 520
        )
        #expect(cannotFit == true)
    }

    @Test("Boundary: exactly the minimum sum fits")
    func threeColumnsFitExactlyAtBoundary() {
        // 1220pt = sum of minimums exactly. Should fit (no slack, but valid).
        let cannotFit = PanelLayoutGeometry.cannotFitShelfAndInspector(
            detailAreaWidth: 1_220,
            shelfMinWidth: 360,
            minimumDetailWidth: 520
        )
        #expect(cannotFit == false)
    }

    @Test("Zero or negative detail-area width is treated as 'cannot fit'")
    func zeroDetailAreaCannotFit() {
        #expect(PanelLayoutGeometry.cannotFitShelfAndInspector(
            detailAreaWidth: 0,
            shelfMinWidth: 360,
            minimumDetailWidth: 520
        ) == true)
        #expect(PanelLayoutGeometry.cannotFitShelfAndInspector(
            detailAreaWidth: -50,
            shelfMinWidth: 360,
            minimumDetailWidth: 520
        ) == true)
    }
}
