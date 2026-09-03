import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The rule that decides whether a workspace drawer says "this holds no work".
///
/// Reported in production: a workspace created while the app was already
/// running listed its first two completed tasks on the Kanban board, and its
/// drawer in the left rail went on offering "Add task" for seven hours. Every
/// layer beneath the drawer was correct at the time — the store's snapshot held
/// both tasks, and `SidebarTaskIndex` had the workspace in `anyTaskWorkspaceIDs`
/// within two seconds of the first one landing. The row simply never re-rendered
/// with them, because the index reaches a row through a closure capture and
/// SwiftUI cannot subscribe a row to a captured value.
///
/// So the fix gives the row a dependency it can be woken by: the workspace's own
/// `tasks` relationship, which is `@Observable`. These tests pin both halves —
/// the answer, and the read that earns the subscription. The second half has no
/// observable effect on the return value in the case that matters most, which is
/// precisely why it needs a test: it looks redundant, and deleting it as
/// redundant reintroduces the bug.
@Suite("Sidebar workspace drawer liveness")
@MainActor
struct SidebarWorkspaceDrawerLivenessTests {
    /// Records whether the drawer actually read `workspace.tasks`, which in the
    /// app is what registers the observation dependency.
    private final class RelationshipRead {
        private(set) var count = 0
        let holdsTasks: Bool

        init(holdsTasks: Bool) {
            self.holdsTasks = holdsTasks
        }

        func read() -> Bool {
            count += 1
            return holdsTasks
        }
    }

    @Test("An open drawer reads the relationship even when the index already says yes")
    func openDrawerAlwaysSubscribes() {
        let relationship = RelationshipRead(holdsTasks: true)
        let result = SidebarWorkspaceDrawer.holdsWork(
            isExpanded: true,
            indexHasAnyTask: true,
            workspaceHoldsTasks: relationship.read
        )

        #expect(result)
        #expect(
            relationship.count == 1,
            """
            The open drawer skipped the relationship because the index had \
            already answered. The read is not there for its value, it is there \
            so SwiftUI has something to invalidate the row with — skip it and \
            the drawer stops re-rendering when its tasks change.
            """
        )
    }

    @Test("A closed drawer the index vouches for does not fault the relationship")
    func closedDrawerStaysCheap() {
        let relationship = RelationshipRead(holdsTasks: true)
        let result = SidebarWorkspaceDrawer.holdsWork(
            isExpanded: false,
            indexHasAnyTask: true,
            workspaceHoldsTasks: relationship.read
        )

        #expect(result)
        #expect(
            relationship.count == 0,
            """
            Every closed row on the rail faulted its tasks relationship. The \
            index already answers for these; the whole point of consulting the \
            workspace only where the answer can change is that it costs nothing \
            on a rail of forty workspaces.
            """
        )
    }

    @Test("A drawer the index calls empty checks the workspace, open or closed")
    func anEmptyIndexAnswerIsAlwaysSecondGuessed() {
        for isExpanded in [true, false] {
            let relationship = RelationshipRead(holdsTasks: false)
            _ = SidebarWorkspaceDrawer.holdsWork(
                isExpanded: isExpanded,
                indexHasAnyTask: false,
                workspaceHoldsTasks: relationship.read
            )
            #expect(
                relationship.count == 1,
                "isExpanded=\(isExpanded): an index that says 'no work' is the answer that was wrong in production."
            )
        }
    }

    @Test("A stale index does not get to claim the drawer is empty")
    func staleIndexLosesToTheRelationship() {
        let holdsWork = SidebarWorkspaceDrawer.holdsWork(
            isExpanded: true,
            indexHasAnyTask: false,
            workspaceHoldsTasks: { true }
        )
        #expect(holdsWork)
        #expect(
            !SidebarWorkspaceDrawer.showsEmptyState(
                hasDrawerTasks: false,
                holdsWork: holdsWork,
                hasApps: false
            ),
            """
            This is the reported bug exactly: the row's index says the workspace \
            has nothing, the workspace itself holds a completed task, and the \
            drawer offered "Add task" anyway.
            """
        )
    }

    @Test("A drawer with nothing anywhere still offers Add task")
    func genuinelyEmptyDrawerKeepsItsEmptyState() {
        #expect(
            SidebarWorkspaceDrawer.showsEmptyState(
                hasDrawerTasks: false,
                holdsWork: SidebarWorkspaceDrawer.holdsWork(
                    isExpanded: true,
                    indexHasAnyTask: false,
                    workspaceHoldsTasks: { false }
                ),
                hasApps: false
            ),
            "A brand-new workspace has to keep its call to action; suppressing it leaves a blank drawer."
        )
    }

    @Test("Work the drawer cannot list still suppresses the empty state")
    func workOutsideTheDrawerSuppressesTheEmptyState() {
        // Tasks the drawer filters out — done, not under review — are still work.
        // Claiming "nothing here" over them is what makes the empty state a lie.
        #expect(
            !SidebarWorkspaceDrawer.showsEmptyState(hasDrawerTasks: false, holdsWork: true, hasApps: false)
        )
        #expect(
            !SidebarWorkspaceDrawer.showsEmptyState(hasDrawerTasks: false, holdsWork: false, hasApps: true)
        )
    }

    /// The same decision against real models, so the two witnesses cannot drift
    /// apart in the one direction that matters: a snapshot taken before the task
    /// landed, and a workspace that already holds it.
    @Test("A workspace holding a task beats an index built before it arrived")
    func realModelsReproduceTheProductionShape() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "PCORnet Old Queries", primaryPath: "/tmp/pcornet")
        context.insert(workspace)
        try context.save()

        // The snapshot the sidebar was holding when the workspace was created.
        let staleIndex = SidebarTaskIndex(tasks: [], searchText: "")

        let arrival = AgentTask(title: "hy what can you do ?", goal: "first task")
        arrival.status = .completed
        arrival.workspace = workspace
        context.insert(arrival)
        try context.save()

        #expect(!staleIndex.hasAnyTask(in: workspace), "Precondition: the stale index cannot know about the task.")
        #expect(
            SidebarWorkspaceDrawer.holdsWork(
                isExpanded: true,
                indexHasAnyTask: staleIndex.hasAnyTask(in: workspace),
                workspaceHoldsTasks: { !workspace.tasks.isEmpty }
            ),
            "The workspace holds a completed task; no drawer of it may call itself empty."
        )

        // And once the snapshot catches up, both witnesses agree.
        let freshIndex = SidebarTaskIndex(tasks: [arrival], searchText: "")
        #expect(freshIndex.hasAnyTask(in: workspace))
    }
}
