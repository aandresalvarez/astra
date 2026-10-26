import Foundation
import Testing
@testable import ASTRA

/// Pins the rules of the Workspace Context rail v2 model
/// (`docs/specs/2026-10-26-workspace-context-rail-v2.md`, rev 2): presence
/// makes a row, no box without content, only two things get colour, one line
/// per fact, fixed order, and the density tokens.
@Suite("Workspace Rail Section Presentation")
struct WorkspaceRailSectionPresentationTests {
    private typealias Rail = WorkspaceRailSectionPresentation

    /// The owner's workspace as in the 2026-10-26 screenshot: a pinned
    /// repository on `clew`, a clean checkout, instructions set, memory empty.
    private func ownerEnvironment() -> Rail.EnvironmentFacts {
        Rail.EnvironmentFacts(
            primaryPath: "/Users/owner/Documents/Astra/Workspaces/data-services/",
            additionalPaths: ["/Users/owner/Documents/Coral/Code/clew"],
            repositoryName: "clew",
            repositoryPath: "/Users/owner/Documents/Coral/Code/clew",
            branch: "main"
        )
    }

    private func ownerContext() -> Rail.ContextFacts {
        Rail.ContextFacts(instructions: "Investigate data-services incidents.\nNever query production directly.")
    }

    private func ownerCapabilities() -> [Rail.CapabilityFacts] {
        [
            Rail.CapabilityFacts(id: "google-cloud", name: "Google Cloud"),
            Rail.CapabilityFacts(id: "bigquery-analyst", name: "BigQuery Analyst"),
            Rail.CapabilityFacts(id: "granola-mcp", name: "mcp.granola.ai MCP")
        ]
    }

    private func rows(_ kind: Rail.RowKind, in box: Rail.Box) -> [Rail.Row] {
        box.rows.filter { $0.kind == kind }
    }

    // MARK: Rule 1 — presence makes a row

    @Test("an empty memory makes no row and raises no attention")
    func emptyMemoryMakesNoRowAndNoAttention() {
        let box = Rail.contextBox(ownerContext())
        #expect(rows(.memory, in: box).isEmpty)
        #expect(box.rows.allSatisfy { $0.tone == .neutral })
        #expect(box.forcesExpansion == false)

        let withMemory = Rail.contextBox(Rail.ContextFacts(instructions: "x", memoryCount: 3))
        let memory = rows(.memory, in: withMemory)
        #expect(memory.count == 1)
        #expect(memory.first?.value == "3 details")
        #expect(memory.first?.isExpandable == true)
        #expect(Rail.contextBox(Rail.ContextFacts(memoryCount: 1)).rows.last?.value == "1 detail")
    }

    @Test("an empty remote server list makes no row")
    func emptyRemoteListMakesNoRow() {
        let clean = Rail.environmentBox(ownerEnvironment())
        #expect(rows(.remote, in: clean).isEmpty)

        var facts = ownerEnvironment()
        facts.remoteServerNames = ["dsi-bastion"]
        let remote = rows(.remote, in: Rail.environmentBox(facts))
        #expect(remote.count == 1)
        #expect(remote.first?.value == "1 server · dsi-bastion")

        facts.remoteServerNames = ["dsi-bastion", "hpc-login", "  "]
        #expect(rows(.remote, in: Rail.environmentBox(facts)).first?.value == "2 servers")
    }

    @Test("routines appear only once one is scheduled")
    func routinesAppearOnlyOnceScheduled() {
        #expect(rows(.routines, in: Rail.contextBox(ownerContext())).isEmpty)
        let one = Rail.contextBox(Rail.ContextFacts(routineTitles: ["Nightly digest · 02:00"]))
        #expect(rows(.routines, in: one).first?.value == "Nightly digest · 02:00")
        let two = Rail.contextBox(Rail.ContextFacts(routineTitles: ["A", "B"]))
        #expect(rows(.routines, in: two).first?.value == "2 scheduled")
    }

    @Test("empty instructions still show a row, with Write and no warning")
    func emptyInstructionsShowWriteWithNoWarning() throws {
        let box = Rail.contextBox(Rail.ContextFacts())
        let row = try #require(rows(.instructions, in: box).first)
        #expect(row.title == "Instructions")
        #expect(row.value == nil)
        #expect(row.action == .verb("Write"))
        #expect(row.tone == .neutral)
        #expect(row.isExpandable)
        // The box exists because Instructions is the one always-present row.
        #expect(box.rows.count == 1)
        #expect(box.collapsedSummary == "No instructions yet")
    }

    @Test("set instructions show their first line and Edit")
    func setInstructionsShowFirstLineAndEdit() throws {
        let box = Rail.contextBox(ownerContext())
        let row = try #require(rows(.instructions, in: box).first)
        #expect(row.value == "Investigate data-services incidents.")
        #expect(row.action == .verb("Edit"))
        #expect(Rail.instructionsFirstLine("\n\n  second line first  \nmore") == "second line first")
        #expect(Rail.instructionsFirstLine("   \n ") == nil)
    }

    @Test("folders follow presence: the root, each added folder, no duplicates")
    func foldersFollowPresence() {
        var facts = ownerEnvironment()
        facts.additionalPaths = [
            "/Users/owner/Documents/Coral/Code/clew/",
            "/Users/owner/Documents/Astra/Workspaces/data-services",
            "/Users/owner/Documents/Coral/Code/clew"
        ]
        let folders = rows(.folder, in: Rail.environmentBox(facts))
        #expect(folders.map(\.value) == ["…/Workspaces/data-services", "…/Code/clew"])

        let missingRoot = Rail.environmentBox(Rail.EnvironmentFacts(primaryPath: "  "))
        let root = missingRoot.rows.first
        #expect(root?.kind == .folder)
        #expect(root?.action == .verb("Choose…"))
        #expect(root?.tone == .neutral)
    }

    @Test("the repository row names its folder only when it is not the root")
    func repositoryRowNamesItsFolderOnlyWhenNotRoot() {
        let pinned = rows(.repository, in: Rail.environmentBox(ownerEnvironment()))
        #expect(pinned.first?.value == "clew · …/Code/clew")
        #expect(pinned.first?.isExpandable == false)

        var atRoot = ownerEnvironment()
        atRoot.repositoryPath = atRoot.primaryPath
        atRoot.hasMultipleRepositories = true
        let row = rows(.repository, in: Rail.environmentBox(atRoot)).first
        #expect(row?.value == "clew")
        #expect(row?.isExpandable == true)

        var none = ownerEnvironment()
        none.repositoryName = nil
        none.branch = nil
        #expect(rows(.repository, in: Rail.environmentBox(none)).isEmpty)
        #expect(rows(.branch, in: Rail.environmentBox(none)).isEmpty)
    }

    @Test("runs-in names the container or Local")
    func runsInNamesContainerOrLocal() {
        #expect(rows(.runsIn, in: Rail.environmentBox(ownerEnvironment())).first?.value == "Local")
        var docker = ownerEnvironment()
        docker.executionEnvironment = .container(name: "astra-dev")
        #expect(rows(.runsIn, in: Rail.environmentBox(docker)).first?.value == "Docker · astra-dev")
        docker.executionEnvironment = .container(name: " ")
        #expect(rows(.runsIn, in: Rail.environmentBox(docker)).first?.value == "Docker")
    }

    // MARK: Rule 2 — no box without content

    @Test("a workspace with no capabilities has no Capabilities box")
    func noCapabilitiesMeansNoCapabilitiesBox() {
        let boxes = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: [])
        #expect(boxes.map(\.section) == [.environment, .context])
        #expect(Rail.capabilitiesBox([]) == nil)
    }

    @Test("no box ever renders with zero rows")
    func noBoxRendersWithZeroRows() {
        let fixtures: [(Rail.EnvironmentFacts, Rail.ContextFacts, [Rail.CapabilityFacts])] = [
            (Rail.EnvironmentFacts(primaryPath: ""), Rail.ContextFacts(), []),
            (ownerEnvironment(), ownerContext(), ownerCapabilities()),
            (ownerEnvironment(), Rail.ContextFacts(), [Rail.CapabilityFacts(id: "d", name: "", isDraft: true)])
        ]
        for (environment, context, capabilities) in fixtures {
            let boxes = Rail.boxes(environment: environment, context: context, capabilities: capabilities)
            #expect(!boxes.isEmpty)
            #expect(boxes.allSatisfy { !$0.rows.isEmpty })
        }
    }

    @Test("the rail-level Add lists absent boxes first, then present boxes' adds")
    func railAddListsAbsentBoxesFirst() {
        let without = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: [])
        #expect(Rail.railAddActions(for: without) == [
            .addCapability,
            .addFolder, .connectServer, .runInContainer,
            .addMemory, .newRoutine
        ])

        let with = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: ownerCapabilities())
        #expect(Rail.railAddActions(for: with) == [
            .addFolder, .connectServer, .runInContainer,
            .addMemory, .newRoutine,
            .addCapability
        ])
        #expect(Rail.railAddTitle == "Add…")
    }

    @Test("each box's plus offers only its own adds")
    func eachBoxPlusOffersOnlyItsOwnAdds() {
        let boxes = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: ownerCapabilities())
        #expect(boxes[0].addActions == [.addFolder, .connectServer, .runInContainer])
        #expect(boxes[1].addActions == [.addMemory, .newRoutine])
        #expect(boxes[2].addActions == [.addCapability])
        #expect(Rail.AddAction.addMemory.title == "Add memory")
        #expect(Rail.AddAction.connectServer.title == "Connect a server…")
        #expect(Rail.AddAction.addCapability.title == "Add capability…")
    }

    // MARK: Rule 3 — only two things get colour

    @Test("a blocked capability sorts first and carries exactly one verb")
    func blockedCapabilitySortsFirstWithExactlyOneVerb() throws {
        let box = try #require(Rail.capabilitiesBox(ownerCapabilities() + [
            Rail.CapabilityFacts(id: "jira", name: "Jira", isBlocked: true, blockedVerb: "Sign in"),
            Rail.CapabilityFacts(id: "draft", name: "New Skill", isDraft: true),
            Rail.CapabilityFacts(id: "docker", name: "Docker", isBlocked: true, blockedVerb: " ")
        ]))
        #expect(box.rows.map(\.title) == [
            "Docker", "Jira", "BigQuery Analyst", "Google Cloud", "mcp.granola.ai MCP", "New Skill"
        ])
        #expect(box.rows[0].action == .repair("Set up"))
        #expect(box.rows[1].action == .repair("Sign in"))
        #expect(box.rows[2...4].allSatisfy { $0.action == nil })
        #expect(box.rows[5].action == .label("Draft"))
        #expect(box.rows.allSatisfy { $0.tone == .neutral && $0.detail == nil && $0.value == nil })
        #expect(box.forcesExpansion)

        let calm = try #require(Rail.capabilitiesBox(ownerCapabilities()))
        #expect(calm.forcesExpansion == false)
        #expect(calm.rows.allSatisfy { $0.action == nil })
    }

    @Test("a blocked draft is a draft, not a blocker")
    func blockedDraftIsADraft() throws {
        let box = try #require(Rail.capabilitiesBox([
            Rail.CapabilityFacts(id: "d", name: "", isBlocked: true, blockedVerb: "Sign in", isDraft: true)
        ]))
        #expect(box.rows.first?.title == "Untitled capability")
        #expect(box.rows.first?.action == .label("Draft"))
        #expect(box.forcesExpansion == false)
    }

    @Test("working-tree state is neutral text unless a sync blocks")
    func workingTreeStateIsNeutralUnlessSyncBlocks() throws {
        var facts = ownerEnvironment()
        facts.changedFileCount = 3
        let changed = try #require(rows(.branch, in: Rail.environmentBox(facts)).first)
        #expect(changed.detail == "3 changed")
        #expect(changed.tone == .neutral)

        facts.changedFileCount = 0
        facts.aheadCount = 2
        facts.behindCount = 1
        let diverged = try #require(rows(.branch, in: Rail.environmentBox(facts)).first)
        #expect(diverged.detail == "2 ahead · 1 behind")
        #expect(diverged.tone == .info)

        let clean = try #require(rows(.branch, in: Rail.environmentBox(ownerEnvironment())).first)
        #expect(clean.detail == nil)
        #expect(clean.tone == .neutral)
    }

    @Test("the verbs footer appears only when something is actionable")
    func footerAppearsOnlyWhenActionable() {
        #expect(Rail.footerActions(ownerEnvironment()) == [])

        var changed = ownerEnvironment()
        changed.changedFileCount = 3
        #expect(Rail.footerActions(changed) == ["Commit & push", "Create PR"])

        var ahead = ownerEnvironment()
        ahead.aheadCount = 2
        #expect(Rail.footerActions(ahead) == ["Push", "Create PR"])

        ahead.openPullRequestLabel = "#552 · draft"
        #expect(Rail.footerActions(ahead) == ["Push"])

        var openOnly = ownerEnvironment()
        openOnly.openPullRequestLabel = "#552 · draft"
        let box = Rail.environmentBox(openOnly)
        #expect(box.footerActions == [])
        #expect(rows(.pullRequest, in: box).first?.tone == .link)

        var noRepository = ownerEnvironment()
        noRepository.branch = nil
        noRepository.changedFileCount = 5
        #expect(Rail.footerActions(noRepository) == [])
    }

    @Test("retired checklist vocabulary never appears in the rail")
    func retiredVocabularyNeverAppears() {
        var blocked = ownerEnvironment()
        blocked.behindCount = 1
        blocked.openPullRequestLabel = "#552 · draft"
        blocked.remoteServerNames = ["dsi-bastion"]
        let boxes = Rail.boxes(
            environment: blocked,
            context: Rail.ContextFacts(memoryCount: 2, routineTitles: ["A", "B"]),
            capabilities: ownerCapabilities() + [
                Rail.CapabilityFacts(id: "jira", name: "Jira", isBlocked: true, blockedVerb: "Sign in"),
                Rail.CapabilityFacts(id: "draft", name: "", isDraft: true)
            ]
        )

        var strings: [String] = boxes.flatMap { box -> [String] in
            [box.title, box.collapsedSummary] + box.footerActions + box.addActions.map(\.title)
        }
        for row in boxes.flatMap(\.rows) {
            strings += [row.title, row.value ?? "", row.detail ?? ""]
            switch row.action {
            case .verb(let text)?, .repair(let text)?, .label(let text)?: strings.append(text)
            case nil: break
            }
        }
        strings += Rail.railAddActions(for: boxes).map(\.title) + [Rail.railAddTitle]

        let retired = ["configured", "missing", "needs setup", "ready", "show all", "hide", "reference", "setup"]
        for string in strings {
            let lowered = string.lowercased()
            #expect(!retired.contains { lowered.contains($0) }, "\(string) reuses retired vocabulary")
        }
    }

    // MARK: Rule 4 — one line per fact, fixed order, summaries

    @Test("the box order is fixed and never reacts to what is empty")
    func boxOrderIsFixed() {
        #expect(Rail.sectionOrder == [.environment, .context, .capabilities, .outputs])
        #expect(Rail.Section.allCases == Rail.sectionOrder)

        let full = Rail.boxes(
            environment: ownerEnvironment(),
            context: ownerContext(),
            capabilities: ownerCapabilities(),
            outputs: Rail.OutputFacts(files: [Rail.OutputFile(path: "/tmp/task/PLAN.md")])
        )
        #expect(full.map(\.section) == Rail.sectionOrder)

        // No outputs yet: the task-scoped box is simply absent, nothing moves.
        let onboarding = Rail.boxes(
            environment: Rail.EnvironmentFacts(primaryPath: "/tmp/w"),
            context: Rail.ContextFacts(),
            capabilities: ownerCapabilities()
        )
        #expect(onboarding.map(\.section) == [.environment, .context, .capabilities])
    }

    @Test("collapsed boxes say what is inside")
    func collapsedBoxesSayWhatIsInside() {
        let clean = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: ownerCapabilities())
        #expect(clean.map(\.collapsedSummary) == [
            "clew · main · clean",
            "Instructions",
            "BigQuery Analyst · Google Cloud · mcp.granola.ai MCP"
        ])

        var busy = ownerEnvironment()
        busy.changedFileCount = 3
        busy.repositoryName = nil
        let context = Rail.ContextFacts(instructions: "x", memoryCount: 3, routineTitles: ["Nightly"])
        let boxes = Rail.boxes(environment: busy, context: context, capabilities: [])
        #expect(boxes.map(\.collapsedSummary) == ["data-services · main · 3 changed", "Instructions · 3 details · 1 routine"])

        var noRepository = Rail.EnvironmentFacts(primaryPath: "/Users/owner/grant-reporting")
        noRepository.executionEnvironment = .container(name: "astra-dev")
        #expect(Rail.environmentBox(noRepository).collapsedSummary == "grant-reporting · Docker · astra-dev")
    }

    @Test("rows are key and value on one line")
    func rowsAreKeyAndValueOnOneLine() {
        let boxes = Rail.boxes(environment: ownerEnvironment(), context: ownerContext(), capabilities: ownerCapabilities())
        for row in boxes.flatMap(\.rows) {
            #expect(!row.title.contains("\n"))
            #expect(!(row.value ?? "").contains("\n"))
            #expect(!row.title.isEmpty)
        }
        // Inventory (skills, connectors, tools) is not a row value.
        let capabilities = boxes[2].rows
        #expect(capabilities.allSatisfy { $0.value == nil && $0.detail == nil })
    }

    @Test("the rail uses the sidebar's density inside today's boxes")
    func railUsesSidebarDensity() {
        #expect(Rail.Layout.boxTitleFontSize == 13)
        #expect(Rail.Layout.rowTitleFontSize == 13)
        #expect(Rail.Layout.rowValueFontSize == 12)
        #expect(Rail.Layout.rowHeight == 30)
        #expect(Rail.Layout.leadingIconFontSize == 13)
        #expect(Rail.Layout.leadingIconFrame == 20)
        #expect(Rail.Layout.boxPaddingTop == 4)
        #expect(Rail.Layout.boxPaddingHorizontal == 6)
        #expect(Rail.Layout.boxPaddingBottom == 8)
        #expect(Rail.Layout.boxSpacing == 10)
        #expect(Rail.Layout.columnWidth == 340)
        #expect(Rail.Layout.minimumColumnWidth == 300)
        #expect(Rail.Layout.automaticMaximumColumnWidth == 380)
        #expect(Rail.Layout.maximumColumnWidth == 420)

        // Lighter than the v1 rail it replaces, and subordinate to the chat body.
        #expect(Rail.Layout.rowHeight < CapabilityRailLayout.regularRowMinHeight)
        #expect(Rail.Layout.rowHeight < CapabilityRailLayout.setupRowMinHeight)
        #expect(Rail.Layout.leadingIconFrame < CapabilityRailLayout.leadingIconFrame)
        // The Repository and Container cards share the box title size until the
        // Environment box absorbs them.
        #expect(Rail.Layout.boxTitleFontSize == CapabilityRailLayout.sectionTitleFontSize)
        #expect(Rail.Layout.rowTitleFontSize < CapabilityRailLayout.rowTitleFontSize)
        #expect(Rail.Layout.rowTitleFontSize < Stanford.chatBodyPointSize)
        #expect(Rail.Layout.boxTitleFontSize < Stanford.chatBodyPointSize)
    }
}

// MARK: - Outputs

extension WorkspaceRailSectionPresentationTests {
    private typealias Outputs = WorkspaceRailSectionPresentation

    private func outputs(_ count: Int, prefix: String = "/tmp/task/out") -> Outputs.OutputFacts {
        Outputs.OutputFacts(files: (1...count).map {
            Outputs.OutputFile(path: "\(prefix)/report-\($0).md")
        })
    }

    @Test("a task that produced nothing has no Outputs box")
    func noOutputsMeansNoOutputsBox() {
        #expect(Outputs.outputsBox(Outputs.OutputFacts()) == nil)
        let boxes = Outputs.boxes(
            environment: Outputs.EnvironmentFacts(primaryPath: "/tmp/w"),
            context: Outputs.ContextFacts(),
            capabilities: []
        )
        #expect(!boxes.contains { $0.section == .outputs })
        #expect(Outputs.sectionOrder.last == .outputs)
        #expect(Outputs.Section.outputs.title == "Outputs")
    }

    @Test("outputs list one line per file, newest first, with the shelf's icon")
    func outputsListOneLinePerFile() throws {
        let facts = Outputs.OutputFacts(files: [
            Outputs.OutputFile(path: "/tmp/task/PLAN.md"),
            Outputs.OutputFile(path: "/tmp/task/site/index.html", destination: .browser),
            Outputs.OutputFile(path: "/tmp/task/data/results.csv", destination: .query),
            Outputs.OutputFile(path: "/tmp/task/PLAN.md")
        ])
        let box = try #require(Outputs.outputsBox(facts))
        #expect(box.rows.map(\.title) == ["PLAN.md", "index.html", "results.csv"])
        #expect(box.rows.map(\.systemImage) == ["doc.text", "globe", "tablecells"])
        #expect(box.rows.allSatisfy { $0.action == nil && $0.value == nil && !$0.isExpandable })
        #expect(box.rows.first?.kind == .output(path: "/tmp/task/PLAN.md"))
        #expect(box.addActions.isEmpty)
        #expect(box.forcesExpansion == false)
        #expect(box.collapsedSummary == "3 files · PLAN.md, index.html, results.csv")
    }

    @Test("outputs past the row limit fold into one link row into Files")
    func outputsPastTheLimitFoldIntoOneRow() throws {
        let box = try #require(Outputs.outputsBox(outputs(11)))
        #expect(box.rows.count == Outputs.outputRowLimit + 1)
        #expect(Outputs.outputRowLimit == 8)
        let overflow = try #require(box.rows.last)
        #expect(overflow.kind == .outputsOverflow(hiddenCount: 3, firstHiddenPath: "/tmp/task/out/report-9.md"))
        #expect(overflow.title == "3 more in Files")
        #expect(overflow.tone == .link)
        #expect(box.collapsedSummary == "11 files · report-1.md, report-2.md, report-3.md +8")

        let exact = try #require(Outputs.outputsBox(outputs(8)))
        #expect(exact.rows.count == 8)
        #expect(exact.rows.allSatisfy { if case .output = $0.kind { return true } else { return false } })
    }

    @Test("duplicate output names lead with their folder")
    func duplicateOutputNamesLeadWithTheirFolder() throws {
        let box = try #require(Outputs.outputsBox(Outputs.OutputFacts(files: [
            Outputs.OutputFile(path: "/tmp/task/a/README.md"),
            Outputs.OutputFile(path: "/tmp/task/b/readme.md"),
            Outputs.OutputFile(path: "/tmp/task/notes.md")
        ])))
        #expect(box.rows.map(\.title) == ["a/README.md", "b/readme.md", "notes.md"])
    }

    @Test("the Outputs box has no adds and never changes the rail-level Add")
    func outputsHaveNoAdds() {
        #expect(Outputs.AddAction.actions(for: .outputs).isEmpty)
        let with = Outputs.boxes(
            environment: Outputs.EnvironmentFacts(primaryPath: "/tmp/w"),
            context: Outputs.ContextFacts(),
            capabilities: [],
            outputs: outputs(2)
        )
        let without = Outputs.boxes(
            environment: Outputs.EnvironmentFacts(primaryPath: "/tmp/w"),
            context: Outputs.ContextFacts(),
            capabilities: []
        )
        #expect(with.map(\.section) == [.environment, .context, .outputs])
        #expect(Outputs.railAddActions(for: with) == Outputs.railAddActions(for: without))
    }
}
