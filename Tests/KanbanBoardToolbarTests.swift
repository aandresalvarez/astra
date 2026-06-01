import Testing
import Foundation
@testable import ASTRA

/// Lightweight contract tests for the Kanban board toolbar reorg. The
/// view itself is mostly SwiftUI glue that's easier to verify by
/// running the app, but a couple of pure pieces are worth pinning so a
/// future refactor can't silently break the contract.
@Suite("KanbanBoardToolbar")
struct KanbanBoardToolbarTests {

    @Test("KanbanBoardDensity has the three documented variants")
    func densityVariants() {
        let variants = KanbanBoardDensity.allCases
        #expect(variants == [.compact, .comfortable, .spacious],
                "Density picker order is locked because users learn it positionally")
    }

    @Test("Each density variant has a non-empty title and icon")
    func densityMetadata() {
        for density in KanbanBoardDensity.allCases {
            #expect(!density.title.isEmpty, "\(density) is missing a title")
            #expect(!density.icon.isEmpty, "\(density) is missing an icon")
        }
    }

    @Test("KanbanCategory keyboard shortcuts are 1–5 in lifecycle order")
    func keyboardShortcutsAreLifecycleOrder() {
        // The per-card context-menu shortcuts rely on this ordering. If
        // anyone reshuffles, users' muscle memory breaks. Compared via
        // the underlying character because KeyEquivalent is opaque.
        let expected: [(KanbanCategory, Character)] = [
            (KanbanCategory.drafts,  "1"),
            (KanbanCategory.queued,  "2"),
            (KanbanCategory.running, "3"),
            (KanbanCategory.review,  "4"),
            (KanbanCategory.done,    "5")
        ]
        for (category, char) in expected {
            #expect(category.keyboardMoveShortcut.character == char,
                    "\(category) shortcut drifted from \(char)")
        }
    }

    @Test("Each category has a non-empty accessibility description")
    func accessibilityDescriptionsPresent() {
        for category in KanbanCategory.allCases {
            #expect(!category.accessibilityDescription.isEmpty,
                    "\(category) is missing an AX description")
        }
    }

    @Test("Kanban board keeps the lean workspace-page presentation contract")
    func leanWorkspacePresentationContract() {
        #expect(KanbanBoardPresentation.toolbarUsesSingleRow == true)
        #expect(KanbanBoardPresentation.columnsUseQuietLaneChrome == true)
        #expect(KanbanBoardPresentation.columnHeaderUsesDotTitleCount == true)
        #expect(KanbanBoardPresentation.taskCardsUseSingleMetadataLine == true)
        #expect(KanbanBoardPresentation.taskCardsReserveTopMetadataRow == false)
        #expect(KanbanBoardPresentation.visibleTrashIsQuietUntilDrag == true)
        #expect(KanbanBoardPresentation.reviewCardsUseLeadingAccentOnly == true)
        #expect(KanbanBoardPresentation.taskCardsDeduplicateRepeatedTitles == true)
        #expect(KanbanBoardPresentation.taskCardsExposeOutcomeMetadata == true)
    }

    @Test("Kanban content width is shared with workspace page alignment")
    func kanbanContentWidthIsSharedWithWorkspacePageAlignment() {
        let categories: [KanbanCategory] = [.drafts, .review, .done]
        let expected = KanbanBoardDensity.spacious.columnWidth(for: .drafts)
            + KanbanBoardDensity.spacious.columnWidth(for: .review)
            + KanbanBoardDensity.spacious.columnWidth(for: .done)
            + (KanbanBoardLayout.columnSpacing * 2)

        #expect(KanbanBoardLayout.outerPadding == 12)
        #expect(KanbanBoardLayout.contentWidth(for: categories, density: .spacious) == expected)
    }

    @Test("Kanban task cards collapse adjacent duplicate titles")
    func taskCardsCollapseAdjacentDuplicateTitles() {
        let repeated = "Create 3D 2x2 Rubik's Cube websiteCreate 3D 2x2 Rubik's Cube website"

        #expect(KanbanTaskCardView.displayTitle(for: repeated) == "Create 3D 2x2 Rubik's Cube website")
        #expect(KanbanTaskCardView.displayTitle(for: "Create 2030 agent landscape slide deck") == "Create 2030 agent landscape slide deck")
    }

    @Test("Review task cards include outcome in metadata")
    func reviewTaskCardsIncludeOutcomeInMetadata() {
        #expect(KanbanTaskCardView.metadataParts(
            titleBadge: nil,
            showDetails: false,
            category: .review,
            status: .completed,
            threadMessageLabel: "13 messages",
            relativeUpdatedAt: "2h"
        ) == ["Run finished", "2h"])

        #expect(KanbanTaskCardView.metadataParts(
            titleBadge: nil,
            showDetails: true,
            category: .review,
            status: .failed,
            threadMessageLabel: "6 messages",
            relativeUpdatedAt: "5d"
        ) == ["Run failed", "6 messages", "5d"])
    }
}
