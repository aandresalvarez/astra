# First-Class Governed MCP Capabilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MCP a visible, governed, testable ASTRA capability resource from package authoring/import through catalog display, readiness, runtime projection, and run evidence.

**Architecture:** Keep `PluginPackage.mcpServers` as the durable source of truth; do not introduce a second runtime-only MCP registry. Add small presentation/draft/readiness helpers so `ConfigureView`, `PluginCatalogView`, and `WorkspaceRightRailView` do not absorb more responsibilities. Continue to fail closed: unsafe commands, remote URLs, names, undeclared env keys, unsupported runtimes, and missing stdio binaries should be visible before launch and blocked or skipped by policy. Presentation must not perform synchronous filesystem/process probing; MCP readiness is computed from explicit preflight/cache inputs.

**Tech Stack:** SwiftPM macOS app, SwiftData models, SwiftUI, `swift-testing`, existing ASTRA capability catalog/runtime services.

---

## Scope And Root Cause

Current state:
- The package schema already supports `mcpServers` in `ASTRACore/PluginPackage.swift`.
- Runtime projection already materializes enabled, runnable MCP servers in `Astra/Services/Capabilities/MCPRuntimeProjection.swift`.
- Claude, Copilot CLI, and Codex CLI have MCP launch plumbing.
- The Capabilities UI can render an MCP section, but bundled packages do not currently declare MCP servers.
- The right rail and creation flow still treat MCP as either invisible package metadata or an old `LocalTool(toolType: "mcp")` tool-name hint.

Root cause:
- ASTRA has the runtime half of MCP but not the product lifecycle half. Users cannot discover, author, import, inspect, and verify MCP capabilities as first-class governed resources.

First-principles fix:
- Treat MCP servers as package-owned resources with the same lifecycle guarantees as skills, connectors, tools, templates, and browser adapters.
- Make package-declared MCP resources visible in every capability summary, authoring flow, readiness surface, and run evidence surface.
- Keep the old `LocalTool(toolType: "mcp")` path as a legacy/custom-tool affordance, not as the canonical MCP server management model.

---

## File Structure

Create:
- `Astra/Services/Capabilities/CapabilityPackageResourceSummary.swift`
  - Single responsibility: derive stable resource counts/names and compact summaries from a `PluginPackage`.
- `Astra/Services/Capabilities/CapabilityMCPServerDraft.swift`
  - Single responsibility: model and validate the capability-creation form for one MCP server, then convert to `PluginMCPServer`.
- `Astra/Services/Capabilities/CapabilityMCPReadinessService.swift`
  - Single responsibility: derive pre-enable/readiness messages for package-declared MCP servers from supplied preflight state without launching a task or probing the filesystem from render paths.
- `Astra/Views/Capabilities/CapabilityMCPServerDraftEditor.swift`
  - Single responsibility: render and edit MCP server drafts for the capability creation sheet.
- `Tests/CapabilityPackageResourceSummaryTests.swift`
- `Tests/CapabilityMCPServerDraftTests.swift`
- `Tests/CapabilityMCPReadinessServiceTests.swift`

Modify:
- `Astra/Services/Capabilities/CapabilityPackageFactory.swift`
  - Accept package-declared MCP servers during local capability creation.
- `Astra/Services/Capabilities/CapabilityHealthService.swift`
  - Include MCP readiness messages alongside prerequisite messages.
- `Astra/Views/ConfigureView.swift`
  - Add an MCP step to `CapabilityCreationWizardView`; delegate editing to `CapabilityMCPServerDraftEditor`.
- `Astra/Views/PluginCatalogView.swift`
  - Use the shared resource summary; show MCP readiness in package details/setup validation.
- `Astra/Views/WorkspaceRightRailView.swift`
  - Count and summarize MCP servers in capability rows.
- `Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift`
  - Include MCP servers in rail cache signatures.
- `Astra/Views/Components/ContextRailRows.swift`
  - Add `mcpServerNames` to `RailCapabilityItem`.
- `Astra/Resources/Capabilities/README.md`
  - Document the visible MCP package lifecycle.
- `Astra/Resources/Capabilities/mcp-smoke-test.json`
  - Add one built-in, approved-but-setup-gated local stub MCP package with a deterministic command contract so the UI has a truthful visible MCP capability before any provider-specific MCP package is shipped.
- `Tests/CapabilityPackageFactoryTests.swift`
- `Tests/CapabilityHealthServiceTests.swift`
- `Tests/CapabilityRailPresentationTests.swift`
- `Tests/PluginCatalogTests.swift`
- `Tests/PluginPackageMCPTests.swift`
- `Tests/MCPRuntimeProjectionTests.swift`
- `Tests/CapabilityGalleryInventoryTests.swift`

---

### Task 1: Centralize Package Resource Summaries

**Files:**
- Create: `Astra/Services/Capabilities/CapabilityPackageResourceSummary.swift`
- Create: `Tests/CapabilityPackageResourceSummaryTests.swift`
- Modify: `Astra/Views/PluginCatalogView.swift`
- Modify: `Astra/Views/WorkspaceRightRailView.swift`
- Modify: `Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift`

- [ ] **Step 1: Write failing summary tests**

Add `Tests/CapabilityPackageResourceSummaryTests.swift`:

```swift
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Package Resource Summary")
struct CapabilityPackageResourceSummaryTests {
    @Test("counts and names include MCP servers")
    func countsAndNamesIncludeMCPServers() {
        let package = PluginPackage(
            id: "mcp-visible",
            name: "MCP Visible",
            icon: "server.rack",
            description: "Visible MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "github",
                    displayName: "GitHub MCP",
                    transport: .stdio,
                    command: "github-mcp-server",
                    allowedTools: ["issues.list"]
                )
            ],
            templates: [],
            browserAdapters: ["github"],
            governance: .builtInApproved(riskLevel: .high)
        )

        let summary = CapabilityPackageResourceSummary(package: package)

        #expect(summary.declaredResourceCount == 2)
        #expect(summary.mcpServerNames == ["GitHub MCP"])
        #expect(summary.contentSummary(separator: ", ") == "1 MCP server, 1 browser adapter")
        #expect(summary.contentSummary(separator: " · ") == "1 MCP server · 1 browser adapter")
    }

    @Test("empty package reports no declared resources")
    func emptyPackageReportsNoDeclaredResources() {
        let package = PluginPackage(
            id: "empty",
            name: "Empty",
            icon: "puzzlepiece.extension",
            description: "",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )

        let summary = CapabilityPackageResourceSummary(package: package)

        #expect(summary.declaredResourceCount == 0)
        #expect(summary.contentSummary(separator: " · ") == "No declared resources")
    }
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter CapabilityPackageResourceSummaryTests
```

Expected: FAIL because `CapabilityPackageResourceSummary` does not exist.

- [ ] **Step 3: Implement the summary helper**

Create `Astra/Services/Capabilities/CapabilityPackageResourceSummary.swift`:

```swift
import Foundation
import ASTRACore

struct CapabilityPackageResourceSummary: Equatable {
    let skillNames: [String]
    let connectorNames: [String]
    let localToolNames: [String]
    let mcpServerNames: [String]
    let browserAdapterNames: [String]
    let templateNames: [String]
    let prerequisiteNames: [String]

    init(package: PluginPackage) {
        skillNames = package.skills.map(\.name)
        connectorNames = package.connectors.map(\.name)
        localToolNames = package.localTools.map(\.name)
        mcpServerNames = package.mcpServers.map(\.displayName)
        browserAdapterNames = package.browserAdapters
        templateNames = package.templates.map(\.name)
        prerequisiteNames = package.prerequisites.map(\.displayName)
    }

    var declaredResourceCount: Int {
        skillNames.count
            + connectorNames.count
            + localToolNames.count
            + mcpServerNames.count
            + browserAdapterNames.count
            + templateNames.count
    }

    var resourceCountsForCacheSignature: [Int] {
        [
            skillNames.count,
            connectorNames.count,
            localToolNames.count,
            mcpServerNames.count,
            templateNames.count,
            browserAdapterNames.count,
            prerequisiteNames.count
        ]
    }

    func contentSummary(separator: String) -> String {
        let parts = [
            countPhrase(skillNames.count, singular: "skill", plural: "skills"),
            countPhrase(connectorNames.count, singular: "connector", plural: "connectors"),
            countPhrase(localToolNames.count, singular: "tool", plural: "tools"),
            countPhrase(mcpServerNames.count, singular: "MCP server", plural: "MCP servers"),
            countPhrase(browserAdapterNames.count, singular: "browser adapter", plural: "browser adapters"),
            countPhrase(templateNames.count, singular: "template", plural: "templates")
        ].compactMap { $0 }

        return parts.isEmpty ? "No declared resources" : parts.joined(separator: separator)
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}
```

- [ ] **Step 4: Wire summary into existing surfaces**

Modify `Astra/Views/PluginCatalogView.swift`:
- Replace the local `capabilityContentsSummary(_:)` body with:

```swift
private func capabilityContentsSummary(_ package: PluginPackage) -> String {
    CapabilityPackageResourceSummary(package: package).contentSummary(separator: " · ")
}
```

Modify `Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift`:
- Replace the `resourceCounts` array in `CapabilityRailPackageSignature.init(package:)` with:

```swift
resourceCounts = CapabilityPackageResourceSummary(package: package).resourceCountsForCacheSignature
```

Modify `Astra/Views/WorkspaceRightRailView.swift`:
- In `makePackageCapabilityItem`, add:

```swift
let packageSummary = CapabilityPackageResourceSummary(package: package)
```

- Replace the declared resource count expression with:

```swift
let declaredResourceCount = packageSummary.declaredResourceCount
```

- Keep `package.contentSummary` for now unless Task 2 changes row copy.

- [ ] **Step 5: Verify**

Run:

```bash
swift test --filter CapabilityPackageResourceSummaryTests
swift test --filter PluginCatalogSearchTests
swift test --filter WorkspaceRightRailPerformanceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Astra/Services/Capabilities/CapabilityPackageResourceSummary.swift \
  Astra/Views/PluginCatalogView.swift \
  Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift \
  Astra/Views/WorkspaceRightRailView.swift \
  Tests/CapabilityPackageResourceSummaryTests.swift
git commit -m "feat: centralize capability resource summaries"
```

---

### Task 2: Show MCP Servers In The Right Rail Composition

**Files:**
- Modify: `Astra/Views/Components/ContextRailRows.swift`
- Modify: `Astra/Views/WorkspaceRightRailView.swift`
- Modify: `Tests/CapabilityRailPresentationTests.swift`

- [ ] **Step 1: Write failing rail presentation test**

Append to `Tests/CapabilityRailPresentationTests.swift`:

```swift
@Test("capability composition summary includes MCP servers")
func capabilityCompositionSummaryIncludesMCPServers() {
    let item = RailCapabilityItem(
        id: "package:mcp-visible",
        name: "MCP Visible",
        icon: "server.rack",
        summary: "MCP package",
        color: Stanford.lagunita,
        isEnabled: true,
        readiness: .ready,
        presentation: CapabilityRailPackagePresentation.make(
            isEnabled: true,
            readinessLevel: .ready,
            workspaceName: "Workspace",
            sharedResourceCount: 0,
            workspaceResourceCount: 0,
            declaredResourceCount: 1,
            contentSummary: "1 MCP server"
        ),
        source: .package(PluginPackage(
            id: "mcp-visible",
            name: "MCP Visible",
            icon: "server.rack",
            description: "MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [PluginMCPServer(id: "github", displayName: "GitHub MCP", transport: .stdio, command: "github-mcp-server")],
            templates: [],
            governance: .builtInApproved()
        )),
        skillNames: [],
        connectorNames: [],
        toolNames: [],
        mcpServerNames: ["GitHub MCP"],
        browserAdapterNames: [],
        templateNames: [],
        requirementNames: []
    )

    #expect(WorkspaceRightRailPresentation.compositionSummary(for: item) == "1 MCP server")
}
```

This test requires extracting the existing private `capabilityCompositionSummary(for:)` logic into `WorkspaceRightRailPresentation`.

- [ ] **Step 2: Run the failing test**

Run:

```bash
swift test --filter CapabilityRailPresentationTests/capabilityCompositionSummaryIncludesMCPServers
```

Expected: FAIL because `RailCapabilityItem` has no `mcpServerNames` and `WorkspaceRightRailPresentation.compositionSummary(for:)` does not exist.

- [ ] **Step 3: Add MCP names to rail item**

Modify `Astra/Views/Components/ContextRailRows.swift`:

```swift
let mcpServerNames: [String]
```

Place it after `toolNames` and before `browserAdapterNames`.

- [ ] **Step 4: Extract composition summary**

Modify `Astra/Views/WorkspaceRightRailPresentation.swift`:

```swift
extension WorkspaceRightRailPresentation {
    static func compositionSummary(for item: RailCapabilityItem) -> String {
        var parts: [String] = []
        appendCount(item.skillNames.count, singular: "skill", plural: "skills", to: &parts)
        appendCount(item.connectorNames.count, singular: "connector", plural: "connectors", to: &parts)
        appendCount(item.toolNames.count, singular: "tool", plural: "tools", to: &parts)
        appendCount(item.mcpServerNames.count, singular: "MCP server", plural: "MCP servers", to: &parts)
        appendCount(item.browserAdapterNames.count, singular: "browser adapter", plural: "browser adapters", to: &parts)
        appendCount(item.templateNames.count, singular: "template", plural: "templates", to: &parts)

        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        let fallback = item.presentation.rowSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "No resources" : fallback
    }

    private static func appendCount(_ count: Int, singular: String, plural: String, to parts: inout [String]) {
        guard count > 0 else { return }
        parts.append("\(count) \(count == 1 ? singular : plural)")
    }
}
```

- [ ] **Step 5: Wire rail view**

Modify `Astra/Views/WorkspaceRightRailView.swift`:
- Replace private `capabilityCompositionSummary(for:)` with:

```swift
private func capabilityCompositionSummary(for item: RailCapabilityItem) -> String {
    WorkspaceRightRailPresentation.compositionSummary(for: item)
}
```

- Add `mcpServerNames` when creating `RailCapabilityItem`:

```swift
mcpServerNames: RailStringList.uniqueSorted(package.mcpServers.map(\.displayName)),
```

- [ ] **Step 6: Verify**

Run:

```bash
swift test --filter CapabilityRailPresentationTests
swift test --filter WorkspaceRightRailPerformanceTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Astra/Views/Components/ContextRailRows.swift \
  Astra/Views/WorkspaceRightRailPresentation.swift \
  Astra/Views/WorkspaceRightRailView.swift \
  Tests/CapabilityRailPresentationTests.swift
git commit -m "feat: show mcp servers in capability rail summaries"
```

---

### Task 3: Add A Typed MCP Draft Model For Capability Creation

**Files:**
- Create: `Astra/Services/Capabilities/CapabilityMCPServerDraft.swift`
- Modify: `Astra/Services/Capabilities/CapabilityPackageFactory.swift`
- Create: `Tests/CapabilityMCPServerDraftTests.swift`
- Modify: `Tests/CapabilityPackageFactoryTests.swift`

- [ ] **Step 1: Write failing draft tests**

Add `Tests/CapabilityMCPServerDraftTests.swift`:

```swift
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability MCP Server Draft")
struct CapabilityMCPServerDraftTests {
    @Test("stdio draft converts to plugin server")
    func stdioDraftConvertsToPluginServer() throws {
        let draft = CapabilityMCPServerDraft(
            serverID: "github",
            displayName: "GitHub MCP",
            transport: .stdio,
            command: "github-mcp-server",
            argumentsText: "stdio\n--read-only",
            urlText: "",
            environmentKeysText: "",
            connectorBindingsText: "",
            allowedToolsText: "issues.list\npull_requests.read",
            excludedToolsText: "repo.delete",
            resourcesEnabled: true,
            promptsEnabled: false,
            trustLevel: .high
        )

        let server = try draft.makeServer()

        #expect(server.id == "github")
        #expect(server.displayName == "GitHub MCP")
        #expect(server.transport == .stdio)
        #expect(server.command == "github-mcp-server")
        #expect(server.arguments == ["stdio", "--read-only"])
        #expect(server.environmentKeys == [])
        #expect(server.connectorBindings == [])
        #expect(server.allowedTools == ["issues.list", "pull_requests.read"])
        #expect(server.excludedTools == ["repo.delete"])
        #expect(server.resourcesEnabled)
        #expect(!server.promptsEnabled)
        #expect(server.trustLevel == .high)
    }

    @Test("remote draft requires valid URL")
    func remoteDraftRequiresValidURL() {
        let draft = CapabilityMCPServerDraft(
            serverID: "remote",
            displayName: "Remote MCP",
            transport: .http,
            command: "",
            argumentsText: "",
            urlText: "not a url"
        )

        #expect(throws: CapabilityMCPServerDraft.ValidationError.self) {
            _ = try draft.makeServer()
        }
    }

    @Test("invalid MCP permission names are rejected before package creation")
    func invalidPermissionNamesRejected() {
        let draft = CapabilityMCPServerDraft(
            serverID: "bad__id",
            displayName: "Bad MCP",
            transport: .stdio,
            command: "bad-mcp"
        )

        #expect(throws: CapabilityMCPServerDraft.ValidationError.self) {
            _ = try draft.makeServer()
        }
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
swift test --filter CapabilityMCPServerDraftTests
```

Expected: FAIL because `CapabilityMCPServerDraft` does not exist.

- [ ] **Step 3: Implement the draft model**

Create `Astra/Services/Capabilities/CapabilityMCPServerDraft.swift`:

```swift
import Foundation
import ASTRACore

struct CapabilityMCPServerDraft: Equatable, Identifiable {
    enum ValidationError: LocalizedError, Equatable {
        case missingID
        case missingDisplayName
        case missingCommand
        case invalidURL(String)
        case invalidName(String)

        var errorDescription: String? {
            switch self {
            case .missingID:
                return "MCP server ID is required."
            case .missingDisplayName:
                return "MCP server display name is required."
            case .missingCommand:
                return "Stdio MCP servers require a command."
            case .invalidURL(let value):
                return "Remote MCP URL is invalid: \(value)"
            case .invalidName(let reason):
                return reason
            }
        }
    }

    let id = UUID()
    var serverID: String = ""
    var displayName: String = ""
    var transport: PluginMCPServer.Transport = .stdio
    var command: String = ""
    var argumentsText: String = ""
    var urlText: String = ""
    var environmentKeysText: String = ""
    var connectorBindingsText: String = ""
    var allowedToolsText: String = ""
    var excludedToolsText: String = ""
    var resourcesEnabled: Bool = false
    var promptsEnabled: Bool = false
    var trustLevel: PluginMCPServer.TrustLevel = .medium

    func makeServer() throws -> PluginMCPServer {
        let trimmedID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw ValidationError.missingID }
        guard !trimmedName.isEmpty else { throw ValidationError.missingDisplayName }

        let server: PluginMCPServer
        switch transport {
        case .stdio:
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else { throw ValidationError.missingCommand }
            server = PluginMCPServer(
                id: trimmedID,
                displayName: trimmedName,
                transport: .stdio,
                command: trimmedCommand,
                arguments: lineList(argumentsText),
                environmentKeys: lineList(environmentKeysText),
                connectorBindings: lineList(connectorBindingsText),
                allowedTools: lineList(allowedToolsText),
                excludedTools: lineList(excludedToolsText),
                resourcesEnabled: resourcesEnabled,
                promptsEnabled: promptsEnabled,
                trustLevel: trustLevel
            )
        case .http, .sse:
            let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedURL), url.scheme != nil else {
                throw ValidationError.invalidURL(trimmedURL)
            }
            server = PluginMCPServer(
                id: trimmedID,
                displayName: trimmedName,
                transport: transport,
                url: url,
                environmentKeys: lineList(environmentKeysText),
                connectorBindings: lineList(connectorBindingsText),
                allowedTools: lineList(allowedToolsText),
                excludedTools: lineList(excludedToolsText),
                resourcesEnabled: resourcesEnabled,
                promptsEnabled: promptsEnabled,
                trustLevel: trustLevel
            )
        }

        if let reason = MCPEnvironmentKeyPolicy.invalidNameReason(server: server) {
            throw ValidationError.invalidName(reason)
        }
        return server
    }

    private func lineList(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Add package factory support**

Modify `Astra/Services/Capabilities/CapabilityPackageFactory.swift`:
- Add a parameter to `makePackage`:

```swift
mcpServers: [PluginMCPServer] = [],
```

- Pass it into `PluginPackage`:

```swift
mcpServers: mcpServers,
```

Add test to `Tests/CapabilityPackageFactoryTests.swift`:

```swift
@Test("MCP server package creates standalone MCP payload")
@MainActor
func mcpServerPackageCreatesStandaloneMCPPayload() {
    let server = PluginMCPServer(
        id: "github",
        displayName: "GitHub MCP",
        transport: .stdio,
        command: "github-mcp-server",
        allowedTools: ["issues.list"]
    )

    let package = CapabilityPackageFactory.makePackage(
        name: "GitHub MCP",
        description: "GitHub through MCP",
        mcpServers: [server]
    )

    #expect(package.skills.isEmpty)
    #expect(package.mcpServers.map(\.id) == ["github"])
    #expect(package.contentSummary == "1 MCP server")
}
```

- [ ] **Step 5: Verify**

Run:

```bash
swift test --filter CapabilityMCPServerDraftTests
swift test --filter CapabilityPackageFactoryTests
swift test --filter PluginPackageMCPTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Astra/Services/Capabilities/CapabilityMCPServerDraft.swift \
  Astra/Services/Capabilities/CapabilityPackageFactory.swift \
  Tests/CapabilityMCPServerDraftTests.swift \
  Tests/CapabilityPackageFactoryTests.swift
git commit -m "feat: add typed mcp server drafts to capability factory"
```

---

### Task 4: Add MCP Server Authoring To The Capability Creation Flow

**Files:**
- Create: `Astra/Views/Capabilities/CapabilityMCPServerDraftEditor.swift`
- Modify: `Astra/Views/ConfigureView.swift`
- Modify: `Tests/CapabilityMCPServerDraftTests.swift`

- [ ] **Step 1: Add a draft-list test**

Append to `Tests/CapabilityMCPServerDraftTests.swift`:

```swift
@Test("multiple drafts preserve deterministic server order")
func multipleDraftsPreserveDeterministicServerOrder() throws {
    let first = CapabilityMCPServerDraft(
        serverID: "zeta",
        displayName: "Zeta MCP",
        transport: .stdio,
        command: "zeta-mcp"
    )
    let second = CapabilityMCPServerDraft(
        serverID: "alpha",
        displayName: "Alpha MCP",
        transport: .stdio,
        command: "alpha-mcp"
    )

    let servers = try [first, second].map { try $0.makeServer() }

    #expect(servers.map(\.id) == ["zeta", "alpha"])
}
```

- [ ] **Step 2: Create a focused editor view**

Create `Astra/Views/Capabilities/CapabilityMCPServerDraftEditor.swift`:

```swift
import SwiftUI
import ASTRACore

struct CapabilityMCPServerDraftEditor: View {
    @Binding var draft: CapabilityMCPServerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Server ID", text: $draft.serverID)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Transport", selection: $draft.transport) {
                ForEach(PluginMCPServer.Transport.allCases, id: \.self) { transport in
                    Text(transport.rawValue.uppercased()).tag(transport)
                }
            }
            .pickerStyle(.segmented)

            if draft.transport == .stdio {
                TextField("Command", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
                labeledEditor("Arguments", text: $draft.argumentsText, height: 54)
            } else {
                TextField("URL", text: $draft.urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.ui(13, design: .monospaced))
            }

            labeledEditor("Allowed tools", text: $draft.allowedToolsText, height: 54)
            labeledEditor("Excluded tools", text: $draft.excludedToolsText, height: 54)
            labeledEditor("Environment keys", text: $draft.environmentKeysText, height: 54)
            labeledEditor("Connector bindings", text: $draft.connectorBindingsText, height: 54)

            HStack(spacing: 12) {
                Toggle("Resources", isOn: $draft.resourcesEnabled)
                Toggle("Prompts", isOn: $draft.promptsEnabled)
                Picker("Trust", selection: $draft.trustLevel) {
                    ForEach(PluginMCPServer.TrustLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .frame(maxWidth: 190)
            }
        }
    }

    private func labeledEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(Stanford.ui(13, design: .monospaced))
                .frame(minHeight: height)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
```

- [ ] **Step 3: Add the MCP step to the creation wizard**

Modify `CapabilityCreationWizardView.Step` in `Astra/Views/ConfigureView.swift`:

```swift
case mcp = "MCP"
```

Insert it after `.tools` and before `.connectors`.

Add state:

```swift
@State private var mcpDrafts: [CapabilityMCPServerDraft] = []
@State private var mcpValidationError = ""
```

Update `canCreate`:

```swift
!mcpDrafts.isEmpty ||
```

Update the `switch selectedStep`:

```swift
case .mcp:
    mcpStep
```

Add:

```swift
private var mcpStep: some View {
    VStack(alignment: .leading, spacing: 12) {
        identityFields

        if !mcpValidationError.isEmpty {
            Text(mcpValidationError)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.poppy)
        }

        ForEach($mcpDrafts) { $draft in
            CapabilityMCPServerDraftEditor(draft: $draft)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        Button {
            mcpDrafts.append(CapabilityMCPServerDraft())
        } label: {
            Label("Add MCP Server", systemImage: "plus")
                .font(Stanford.body(13))
        }
        .buttonStyle(.bordered)
    }
}
```

Update `validateStep`:

```swift
validationRow("MCP Servers", "\(mcpDrafts.count) declared")
```

Update `createCapability()` before calling the factory:

```swift
let mcpServers: [PluginMCPServer]
do {
    mcpServers = try mcpDrafts.map { try $0.makeServer() }
    mcpValidationError = ""
} catch {
    mcpValidationError = error.localizedDescription
    selectedStep = .mcp
    return
}
```

Pass into the factory:

```swift
mcpServers: mcpServers,
```

- [ ] **Step 4: Verify**

Run:

```bash
swift test --filter CapabilityMCPServerDraftTests
swift test --filter CapabilityPackageFactoryTests
swift test --filter ToolWizardFunctionalTests
```

Expected: PASS. `ToolWizardFunctionalTests` should keep the legacy local-tool MCP path intact.

- [ ] **Step 5: Commit**

```bash
git add Astra/Views/Capabilities/CapabilityMCPServerDraftEditor.swift \
  Astra/Views/ConfigureView.swift \
  Tests/CapabilityMCPServerDraftTests.swift
git commit -m "feat: add mcp server authoring to capability creation"
```

---

### Task 5: Surface MCP Readiness Before Enablement

**Files:**
- Create: `Astra/Services/Capabilities/CapabilityMCPReadinessService.swift`
- Modify: `Astra/Services/Capabilities/CapabilityHealthService.swift`
- Modify: `Astra/Views/PluginCatalogView.swift`
- Modify: `Tests/CapabilityMCPReadinessServiceTests.swift`
- Modify: `Tests/CapabilityHealthServiceTests.swift`

- [ ] **Step 1: Write failing readiness tests**

Create `Tests/CapabilityMCPReadinessServiceTests.swift`:

```swift
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability MCP Readiness Service")
struct CapabilityMCPReadinessServiceTests {
    @Test("missing stdio command creates readiness issue")
    func missingStdioCommandCreatesReadinessIssue() {
        let package = mcpPackage(command: "missing-mcp-server")

        let issues = CapabilityMCPReadinessService.issues(
            for: package,
            detectExecutable: { _ in "" }
        )

        #expect(issues.map(\.kind) == [.missingExecutable])
        #expect(issues.first?.message == "GitHub MCP: missing-mcp-server is not installed or executable.")
    }

    @Test("healthy stdio command creates no readiness issue")
    func healthyStdioCommandCreatesNoReadinessIssue() {
        let package = mcpPackage(command: "github-mcp-server")

        let issues = CapabilityMCPReadinessService.issues(
            for: package,
            detectExecutable: { _ in "/opt/bin/github-mcp-server" }
        )

        #expect(issues.isEmpty)
    }
}

private func mcpPackage(command: String) -> PluginPackage {
    PluginPackage(
        id: "github-mcp",
        name: "GitHub MCP",
        icon: "server.rack",
        description: "GitHub through MCP",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        mcpServers: [
            PluginMCPServer(
                id: "github",
                displayName: "GitHub MCP",
                transport: .stdio,
                command: command,
                allowedTools: ["issues.list"]
            )
        ],
        templates: [],
        governance: .builtInApproved(riskLevel: .high)
    )
}
```

- [ ] **Step 2: Implement readiness service**

Create `Astra/Services/Capabilities/CapabilityMCPReadinessService.swift`:

```swift
import Foundation
import ASTRACore

struct CapabilityMCPReadinessIssue: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case missingExecutable = "missing_executable"
        case missingRemoteURL = "missing_remote_url"
    }

    let packageID: String
    let packageName: String
    let serverID: String
    let serverName: String
    let kind: Kind
    let message: String

    var id: String {
        "\(packageID):\(serverID):\(kind.rawValue)"
    }
}

enum CapabilityMCPReadinessService {
    static func issues(
        for package: PluginPackage,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> [CapabilityMCPReadinessIssue] {
        package.mcpServers.compactMap { server in
            switch server.transport {
            case .stdio:
                let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, detectExecutable(command).isEmpty else { return nil }
                return CapabilityMCPReadinessIssue(
                    packageID: package.id,
                    packageName: package.name,
                    serverID: server.id,
                    serverName: server.displayName,
                    kind: .missingExecutable,
                    message: "\(server.displayName): \(command) is not installed or executable."
                )
            case .http, .sse:
                guard server.url == nil else { return nil }
                return CapabilityMCPReadinessIssue(
                    packageID: package.id,
                    packageName: package.name,
                    serverID: server.id,
                    serverName: server.displayName,
                    kind: .missingRemoteURL,
                    message: "\(server.displayName): remote URL is missing."
                )
            }
        }
    }

    static func readinessMessages(
        for package: PluginPackage,
        detectExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    ) -> [String] {
        issues(for: package, detectExecutable: detectExecutable).map(\.message)
    }
}
```

- [ ] **Step 3: Add MCP messages to health service**

Modify `Astra/Services/Capabilities/CapabilityHealthService.swift`:

```swift
static func readinessMessages(
    for package: PluginPackage,
    statuses: [String: HealthStatus],
    detectMCPExecutable: (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
) -> [String] {
    prerequisiteIssues(for: package, statuses: statuses).map(\.message)
        + CapabilityMCPReadinessService.readinessMessages(
            for: package,
            detectExecutable: detectMCPExecutable
        )
}
```

Keep the existing call sites working by using the default parameter.

- [ ] **Step 4: Add health-service regression**

Append to `Tests/CapabilityHealthServiceTests.swift`:

```swift
@Test("MCP readiness messages are included with prerequisite messages")
func mcpReadinessMessagesIncludedWithPrerequisites() {
    let package = PluginPackage(
        id: "mcp-health",
        name: "MCP Health",
        icon: "server.rack",
        description: "MCP package",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        mcpServers: [
            PluginMCPServer(id: "github", displayName: "GitHub MCP", transport: .stdio, command: "github-mcp-server")
        ],
        templates: [],
        governance: .builtInApproved()
    )

    let messages = CapabilityHealthService.readinessMessages(
        for: package,
        statuses: [:],
        detectMCPExecutable: { _ in "" }
    )

    #expect(messages == ["GitHub MCP: github-mcp-server is not installed or executable."])
}
```

- [ ] **Step 5: Ensure catalog/rail use the richer readiness**

Confirm `WorkspaceRightRailView.readiness(for:stateReadiness:prerequisiteStatuses:)` still calls `CapabilityHealthService.readinessMessages`. No call-site change is needed if Step 3 uses the default argument.

In `PluginCatalogView`, locate setup/validation message rendering for package blockers. Where it renders readiness summaries, include:

```swift
let mcpReadinessMessages = CapabilityMCPReadinessService.readinessMessages(for: package)
```

Append those messages beside prerequisite messages, not inside governance blockers.

- [ ] **Step 6: Verify**

Run:

```bash
swift test --filter CapabilityMCPReadinessServiceTests
swift test --filter CapabilityHealthServiceTests
swift test --filter PluginCatalogTests
swift test --filter MCPRuntimeProjectionTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Astra/Services/Capabilities/CapabilityMCPReadinessService.swift \
  Astra/Services/Capabilities/CapabilityHealthService.swift \
  Astra/Views/PluginCatalogView.swift \
  Tests/CapabilityMCPReadinessServiceTests.swift \
  Tests/CapabilityHealthServiceTests.swift
git commit -m "feat: surface mcp readiness before task launch"
```

---

### Task 6: Seed A Real Built-In MCP Capability

**Files:**
- Create: `Astra/Resources/Capabilities/github-mcp-workflow.json`
- Modify: `Astra/Resources/Capabilities/README.md`
- Modify: `Tests/PluginCatalogTests.swift`
- Modify: `Tests/CapabilityGalleryInventoryTests.swift`

- [ ] **Step 1: Write failing built-in catalog test**

Append to `Tests/PluginCatalogTests.swift`:

```swift
@Test("GitHub MCP capability is visible and setup gated")
func githubMCPCapabilityVisibleAndSetupGated() throws {
    let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-mcp-workflow" })

    #expect(package.name == "GitHub MCP")
    #expect(package.mcpServers.map(\.id) == ["github"])
    #expect(package.mcpServers.first?.command == "github-mcp-server")
    #expect(package.mcpServers.first?.allowedTools.contains("issues.list") == true)
    #expect(package.prerequisites.map(\.binary).contains("github-mcp-server"))
    #expect(package.governance.approvalStatus == .approved)
    #expect(package.governance.riskLevel == .high)
}
```

- [ ] **Step 2: Add built-in package JSON**

Create `Astra/Resources/Capabilities/github-mcp-workflow.json`:

```json
{
  "formatVersion": 2,
  "id": "github-mcp-workflow",
  "name": "GitHub MCP",
  "icon": "server.rack",
  "description": "Use a governed GitHub MCP server from supported agent runtimes",
  "author": "ASTRA",
  "category": "Integrations",
  "tags": ["github", "mcp", "pull-requests", "issues"],
  "version": "1.0.0",
  "setupGuide": "Install and authenticate a GitHub MCP server locally. ASTRA will only deliver this server to runtimes that support MCP launch configuration, and only the declared tool allow-list is granted.",
  "skills": [],
  "connectors": [],
  "localTools": [],
  "mcpServers": [
    {
      "id": "github",
      "displayName": "GitHub MCP",
      "transport": "stdio",
      "command": "github-mcp-server",
      "arguments": ["stdio"],
      "environmentKeys": [],
      "connectorBindings": [],
      "allowedTools": ["issues.list", "pull_requests.read", "pull_requests.list"],
      "excludedTools": ["repos.delete", "pull_requests.merge"],
      "resourcesEnabled": false,
      "promptsEnabled": false,
      "trustLevel": "high"
    }
  ],
  "templates": [],
  "browserAdapters": ["github"],
  "prerequisites": [
    {
      "binary": "github-mcp-server",
      "livenessArgs": ["--version"],
      "displayName": "GitHub MCP server",
      "purpose": "Serves GitHub MCP tools to supported agent runtimes.",
      "installHint": "Install a GitHub MCP server and ensure `github-mcp-server` is on PATH.",
      "authHint": "Authenticate the MCP server according to its installation instructions."
    }
  ],
  "governance": {
    "approvalStatus": "approved",
    "riskLevel": "high",
    "visibility": "everyone",
    "allowedRoles": [],
    "allowedWorkspaceTags": [],
    "requiresAdminApproval": false,
    "requiresExplicitUserConsent": false,
    "dataAccess": ["workspaceFiles", "externalService", "network"],
    "externalEffects": ["readOnly", "externalAPIWrite", "ticketMutation"],
    "approvedBy": "ASTRA",
    "policyNotes": "MCP server activation is governed by package policy, runtime support, command readiness, and explicit tool allow/exclude lists. Destructive operations are excluded by default."
  },
  "sourceMetadata": {
    "id": "built-in",
    "displayName": "Built-in Capabilities",
    "kind": "built-in",
    "trustLevel": "built-in"
  }
}
```

- [ ] **Step 3: Update README**

Modify `Astra/Resources/Capabilities/README.md`:
- Add a short subsection under "Local testing workflow":

```markdown
MCP capability packages:

- Declare servers in `mcpServers`; do not hide MCP tool names in skill prompt text.
- Add prerequisites for stdio server commands so catalog readiness can show missing installs before task launch.
- Prefer narrow `allowedTools` and explicit `excludedTools` for destructive operations.
- Verify package visibility with `swift test --filter PluginCatalogBuiltInTests`.
```

- [ ] **Step 4: Verify built-in inventory**

Run:

```bash
swift test --filter PluginCatalogBuiltInTests
swift test --filter CapabilityGalleryInventoryTests
swift test --filter CapabilityPackageValidatorTests
```

Expected: PASS. If `CapabilityGalleryInventoryTests` asserts exact package counts/categories, update the expected inventory to include `github-mcp-workflow` with category `Integrations`.

- [ ] **Step 5: Commit**

```bash
git add Astra/Resources/Capabilities/github-mcp-workflow.json \
  Astra/Resources/Capabilities/README.md \
  Tests/PluginCatalogTests.swift \
  Tests/CapabilityGalleryInventoryTests.swift
git commit -m "feat: seed governed github mcp capability"
```

---

### Task 7: Verify Runtime Projection And Run Evidence Still Fail Closed

**Files:**
- Modify: `Tests/MCPRuntimeProjectionTests.swift`
- Modify: `Tests/AgentRuntimeAdapterTests.swift`
- Modify: `Tests/PluginPackageMCPTests.swift`

- [ ] **Step 1: Add projection regression for built-in package**

Append to `Tests/MCPRuntimeProjectionTests.swift`:

```swift
@Test("built-in GitHub MCP package projects only when enabled")
@MainActor
func builtInGitHubMCPPackageProjectsOnlyWhenEnabled() throws {
    let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-mcp-workflow" })
    let workspace = Workspace(name: "MCP Projection", primaryPath: "/tmp/mcp-projection")

    #expect(MCPRuntimeProjection.enabledServers(
        for: workspace,
        packages: [package],
        approvalRecords: []
    ).isEmpty)

    workspace.enabledCapabilityIDs = [package.id]

    let servers = MCPRuntimeProjection.enabledServers(
        for: workspace,
        packages: [package],
        approvalRecords: []
    )

    #expect(servers.map(\.server.id) == ["github"])
    #expect(MCPRuntimeProjection.allowedToolPermissions(servers: servers).contains("mcp__github__issues.list"))
    #expect(MCPRuntimeProjection.deniedToolPermissions(servers: servers).contains("mcp__github__pull_requests.merge"))
}
```

- [ ] **Step 2: Add run manifest regression**

Append to `Tests/PluginPackageMCPTests.swift`:

```swift
@Test("built-in GitHub MCP appears in permission manifest when enabled")
@MainActor
func builtInGitHubMCPAppearsInPermissionManifestWhenEnabled() throws {
    let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-mcp-workflow" })
    let workspace = Workspace(name: "MCP Manifest", primaryPath: "/tmp/mcp-manifest")
    workspace.enabledCapabilityIDs = [package.id]

    let manifests = TaskCapabilityResolver.enabledMCPServerManifests(
        for: workspace,
        packages: [package]
    )

    #expect(manifests.map(\.packageID) == ["github-mcp-workflow"])
    #expect(manifests.first?.id == "github")
    #expect(manifests.first?.allowedTools.contains("issues.list") == true)
}
```

- [ ] **Step 3: Verify**

Run:

```bash
swift test --filter MCPRuntimeProjectionTests
swift test --filter PluginPackageMCPTests
swift test --filter AgentRuntimeAdapterTests
```

Expected: PASS. If `AgentRuntimeAdapterTests` has existing broad assertions for MCP server counts, update only the assertions that now see an enabled built-in MCP package in their fixture.

- [ ] **Step 4: Commit**

```bash
git add Tests/MCPRuntimeProjectionTests.swift \
  Tests/PluginPackageMCPTests.swift \
  Tests/AgentRuntimeAdapterTests.swift
git commit -m "test: verify governed mcp runtime projection"
```

---

### Task 8: Manual UI Verification

**Files:**
- No source files unless manual QA finds a defect.

- [ ] **Step 1: Run focused tests**

```bash
swift test --filter CapabilityPackageResourceSummaryTests
swift test --filter CapabilityMCPServerDraftTests
swift test --filter CapabilityMCPReadinessServiceTests
swift test --filter PluginCatalogBuiltInTests
swift test --filter PluginPackageMCPTests
swift test --filter MCPRuntimeProjectionTests
swift test --filter CapabilityRailPresentationTests
```

Expected: PASS.

- [ ] **Step 2: Run broader capability tests**

```bash
swift test --filter CapabilityInstallerTests
swift test --filter CapabilityCatalogPolicyTests
swift test --filter CapabilityPackageValidatorTests
swift test --filter TaskCapabilityResolverTests
swift test --filter PluginCatalogTests
```

Expected: PASS.

- [ ] **Step 3: Build and launch the development app**

```bash
./script/build_and_run.sh --verify
```

Expected:
- `dist/ASTRA Dev.app` launches.
- Capabilities contains `GitHub MCP`.
- The package row shows `1 MCP server`.
- Details show an `MCP Servers` section with the runtime-support subtitle.
- If `github-mcp-server` is not installed, readiness indicates the missing command before task launch.
- Creating a custom capability exposes the MCP step and writes `mcpServers` into the source JSON.

- [ ] **Step 4: Inspect logs for launch/runtime evidence**

```bash
tail -n 200 ~/Library/Logs/AstraDev/astra.log | rg "mcp|capability|permission"
```

Expected:
- Enabling/disabling capability emits capability audit events.
- Launch plans with enabled MCP packages include `mcp_server_count`.
- No secrets appear in rendered MCP config logs.

- [ ] **Step 5: Whitespace check**

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 6: Final commit**

```bash
git status --short
git add Astra Tests docs
git commit -m "feat: make mcp capabilities first class"
```

---

## Self-Review

Spec coverage:
- Visible MCP resource: Tasks 1, 2, 6.
- Governed package lifecycle: Tasks 3, 4, 5, 7.
- Validation and fail-closed policy: Tasks 3, 5, 7.
- Runtime support/readiness before enablement: Tasks 5, 6, 8.
- User-visible capability options: Tasks 4, 6, 8.

Placeholder scan:
- No placeholder markers remain.
- Every code-bearing task includes concrete snippets and commands.

Type consistency:
- `CapabilityMCPServerDraft.makeServer()` returns `PluginMCPServer` and keeps SwiftUI draft identity separate from the package server ID.
- `CapabilityPackageFactory.makePackage(... mcpServers:)` accepts `[PluginMCPServer]`.
- `RailCapabilityItem.mcpServerNames` is used by `WorkspaceRightRailPresentation.compositionSummary(for:)`.

Execution note:
- This plan intentionally preserves the old `LocalTool(toolType: "mcp")` path. Removing or migrating it should be a separate compatibility plan after first-class package MCPs are visible and stable.
