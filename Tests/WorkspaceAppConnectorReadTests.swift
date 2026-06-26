import Foundation
import Testing
@testable import ASTRA

/// Connector-read bridge: lets a sandboxed HTML app read LIVE connector data (the user's real GitHub
/// PRs) through the vetted `astra.read` verb. The security-critical surfaces pinned here:
/// - the bridge read allowlist (`resolveRead`): only a declared source named by a `capability.read`
///   action's exact `sourceRef`, never a page-fabricated source, and `capability.write` never bridged;
/// - the validator's HTML connector-read invariants (read-only sources, sourceRef well-formed);
/// - the GitHub read client (operation/state validation, repo taken from the MANIFEST not the page);
/// - the contract registry auto-mapping `pullRequest.read` → `github-pr-read-native`;
/// - the deterministic GitHub-PR app builder + intent detection + scope notice.
@Suite("Workspace App — connector read bridge")
struct WorkspaceAppConnectorReadTests {

    // MARK: - Fixtures

    /// A valid HTML app that reads one GitHub PR source through `astra.read`.
    private func prManifest(
        sourceRef: String = "myPRs",
        sourceID: String = "myPRs",
        sourceMode: String = "read",
        actionType: String = "capability.read",
        requirementRef: String? = "github",
        sourceOperation: String = "listMyPullRequests",
        requirementOps: [String] = ["listMyPullRequests"]
    ) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "prs", name: "My PRs"),
            requirements: [
                WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                        operations: requirementOps, providerHint: "github")
            ],
            sources: [
                WorkspaceAppSource(id: sourceID, requirementRef: requirementRef,
                                   operation: sourceOperation, mode: sourceMode)
            ],
            actions: [
                WorkspaceAppActionSpec(id: "read_prs", type: actionType, sourceRef: sourceRef)
            ],
            permissions: WorkspaceAppPermissions(reads: ["pullRequest.read"], defaultMode: .draftOnly),
            html: "<main></main><script>astra.read('myPRs');</script>"
        )
    }

    // MARK: - Bridge: resolveRead (the read allowlist)

    @Test("resolveRead admits a declared source named by a matching capability.read action")
    func resolveReadAdmitsDeclaredSource() {
        let manifest = prManifest()
        let resolved = WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:]), in: manifest)
        #expect(resolved?.action.type == "capability.read")
        #expect(resolved?.input.table == "myPRs")
    }

    @Test("resolveRead rejects an undeclared source, a mismatched sourceRef, and an empty sourceRef")
    func resolveReadRejectsUndeclaredOrMismatched() {
        // Undeclared source id (not in manifest.sources).
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "other", record: [:]), in: prManifest()) == nil)
        // Source exists but no capability.read action names it via sourceRef.
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:]),
                                                   in: prManifest(sourceRef: "different")) == nil)
        // capability.read action with an empty sourceRef cannot be reached.
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:]),
                                                   in: prManifest(sourceRef: "")) == nil)
    }

    @Test("parseRead validates op + sourceId and rejects non-scalar records")
    func parseReadValidates() {
        #expect(WorkspaceAppDataBridge.parseRead(["op": "read", "sourceId": "myPRs"]) != nil)
        #expect(WorkspaceAppDataBridge.parseRead(["op": "read", "sourceId": "myPRs",
                                                  "record": ["state": "open"]])?.record["state"] == .text("open"))
        // Missing/empty sourceId, wrong op, and a nested-object record all reject.
        #expect(WorkspaceAppDataBridge.parseRead(["op": "read", "sourceId": ""]) == nil)
        #expect(WorkspaceAppDataBridge.parseRead(["op": "query", "sourceId": "myPRs"]) == nil)
        #expect(WorkspaceAppDataBridge.parseRead(["op": "read", "sourceId": "myPRs",
                                                  "record": ["nested": ["x": 1]]]) == nil)
    }

    @Test("injected astra API exposes read; handlers expose a read closure only with the async executor")
    @MainActor
    func handlersExposeReadOnlyWhenWired() {
        #expect(WorkspaceAppDataBridge.injectedScript.contains("read: function"))
        let manifest = prManifest()
        let result: (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput)
            -> WorkspaceAppActionExecutionResult = { _, _, _ in
                WorkspaceAppActionExecutionResult(
                    run: WorkspaceAppRun(workspaceID: UUID(), appID: UUID(), appLogicalID: "x",
                                         actionID: "x", trigger: .user, inputSummary: ""),
                    rows: [], outputSummary: ""
                )
            }
        // No async executor supplied → no read surface (e.g. the preview surface).
        let noRead = WorkspaceAppDataBridge.handlers(manifest: manifest, runs: [], onRunAction: result)
        #expect(noRead?.read == nil)
        // Async executor supplied → read closure present.
        let withRead = WorkspaceAppDataBridge.handlers(
            manifest: manifest, runs: [], onRunAction: result,
            onCapabilityRead: { action, m, input in result(action, m, input) }
        )
        #expect(withRead?.read != nil)
    }

    // MARK: - Validator: HTML connector-read invariants

    @Test("validator accepts an HTML app that declares a read-only GitHub PR source")
    func validatorAcceptsReadOnlyConnectorApp() {
        #expect(WorkspaceAppManifestValidator.validate(prManifest()).isValid)
    }

    @Test("validator blocks capability.write, a write-mode source, and a sourceRef-less read in an HTML app")
    func validatorBlocksWritesAndMalformedReads() {
        // A connector WRITE is never allowed from an HTML app.
        #expect(!WorkspaceAppManifestValidator.validate(prManifest(actionType: "capability.write")).isValid)
        // A write-mode source has no place in a read-only HTML app.
        #expect(!WorkspaceAppManifestValidator.validate(prManifest(sourceMode: "write")).isValid)
        // A capability.read action must name a declared source via sourceRef.
        #expect(!WorkspaceAppManifestValidator.validate(prManifest(sourceRef: "")).isValid)
    }

    // MARK: - GitHub read client

    @Test("decodeRows flattens gh JSON into scalar rows")
    func decodeRowsFlattensJSON() {
        let json = """
        [{"number":42,"title":"Fix bug","url":"https://x/pull/42","state":"OPEN","isDraft":false,
          "updatedAt":"2026-06-20T00:00:00Z","author":{"login":"alvaro"},
          "repository":{"name":"astra","nameWithOwner":"o/astra"}}]
        """
        let rows = WorkspaceAppGitHubCLIPRReader.decodeRows(from: json)
        #expect(rows.count == 1)
        #expect(rows[0]["number"] == .integer(42))
        #expect(rows[0]["title"] == .text("Fix bug"))
        #expect(rows[0]["state"] == .text("OPEN"))
        #expect(rows[0]["isDraft"] == .bool(false))
        #expect(rows[0]["author"] == .text("alvaro"))
        #expect(rows[0]["repository"] == .text("o/astra"))
        // Garbage in → empty (never a crash or a fabricated row).
        #expect(WorkspaceAppGitHubCLIPRReader.decodeRows(from: "not json").isEmpty)
    }

    @Test("read client validates operation + state and takes the repo from the manifest, not the page")
    func readClientValidatesAndUsesManifestRepo() async throws {
        // Requirement declares BOTH ops so this fixture exercises each without tripping the
        // op-broadening guard (covered separately in clientRefusesOpBroadening).
        let requirement = WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                                  operations: ["listMyPullRequests", "listRepoPullRequests"],
                                                  providerHint: "github")
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: UUID(), appID: UUID(), appLogicalID: "prs",
            requirementID: "github", contract: "pullRequest.read",
            operations: ["listMyPullRequests", "listRepoPullRequests"], optional: false, status: .mapped,
            implementationID: "github-pr-read-native", provider: "github", transport: .native
        )

        // listMyPullRequests: no repo, page-supplied state passes through (validated).
        let mine = PRRequestRecorder()
        let mineSource = WorkspaceAppSource(id: "myPRs", requirementRef: "github",
                                            operation: "listMyPullRequests", mode: "read")
        _ = try await WorkspaceAppGitHubPRReadClient(reader: mine).read(
            source: mineSource, requirement: requirement, binding: binding,
            input: WorkspaceAppSourceResolutionInput(parameters: ["state": .text("closed")]))
        #expect(await mine.last?.operation == "listMyPullRequests")
        #expect(await mine.last?.repo == nil)
        #expect(await mine.last?.state == "closed")

        // A bogus page state falls back to "open".
        let bogus = PRRequestRecorder()
        _ = try await WorkspaceAppGitHubPRReadClient(reader: bogus).read(
            source: mineSource, requirement: requirement, binding: binding,
            input: WorkspaceAppSourceResolutionInput(parameters: ["state": .text("../../etc")]))
        #expect(await bogus.last?.state == "open")

        // listRepoPullRequests: repo comes from the source projectRef (manifest), not a page param.
        let repoReader = PRRequestRecorder()
        let repoSource = WorkspaceAppSource(id: "repoPRs", requirementRef: "github",
                                            operation: "listRepoPullRequests", mode: "read",
                                            projectRef: "owner/astra")
        _ = try await WorkspaceAppGitHubPRReadClient(reader: repoReader).read(
            source: repoSource, requirement: requirement, binding: binding,
            input: WorkspaceAppSourceResolutionInput(parameters: ["repo": .text("attacker/evil")]))
        #expect(await repoReader.last?.repo == "owner/astra")

        // listRepoPullRequests without a valid declared repo → refuses (never silently lists my PRs).
        let missingRepo = WorkspaceAppSource(id: "repoPRs", requirementRef: "github",
                                             operation: "listRepoPullRequests", mode: "read")
        await #expect(throws: (any Error).self) {
            _ = try await WorkspaceAppGitHubPRReadClient(reader: PRRequestRecorder()).read(
                source: missingRepo, requirement: requirement, binding: binding,
                input: WorkspaceAppSourceResolutionInput())
        }
    }

    @Test("repo slug validator rejects flag-like and malformed slugs")
    func repoSlugValidator() {
        #expect(GitService.isValidRepoSlug("owner/name"))
        #expect(GitService.isValidRepoSlug("o-w.n/repo_1"))
        #expect(!GitService.isValidRepoSlug("-flag/name"))   // leading dash → could read as a gh flag
        #expect(!GitService.isValidRepoSlug("owner"))         // no slash
        #expect(!GitService.isValidRepoSlug("a/b/c"))         // too many segments
        #expect(!GitService.isValidRepoSlug("owner/na me"))   // whitespace
    }

    // MARK: - Contract registry auto-mapping

    @Test("registry resolves pullRequest.read to the native github implementation (auto-mapped on publish)")
    func registryResolvesGitHubPRRead() {
        let registry = WorkspaceAppContractRegistry()
        let requirement = WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                                  operations: ["listMyPullRequests"], providerHint: "github")
        let resolution = registry.resolve(requirement)
        #expect(resolution.selectedImplementation?.id == "github-pr-read-native")
        #expect(resolution.selectedImplementation?.provider == "github")
    }

    // MARK: - Deterministic builder + intent detection + scope

    @Test("the deterministic GitHub PR app builder produces a valid connector-read app")
    func deterministicBuilderIsValid() {
        let manifest = WorkspaceAppStudioBuilder.githubPullRequestsHTMLManifest(intent: "show my open PRs")
        #expect(manifest.html != nil)
        #expect(manifest.actions.contains { $0.type == "capability.read" })
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("GitHub PR intent detection is tight")
    func intentDetection() {
        #expect(WorkspaceAppStudioBuilder.isGitHubPullRequestIntent("show my open pull requests"))
        #expect(WorkspaceAppStudioBuilder.isGitHubPullRequestIntent("a dashboard of my github PRs"))
        #expect(!WorkspaceAppStudioBuilder.isGitHubPullRequestIntent("track groceries"))
    }

    @Test("scope notice is positive for GitHub PRs and a sample-data caveat for unsupported connectors")
    func scopeNotice() {
        let pr = WorkspaceAppStudioScope.needsConnectorNotice(for: "show my github pull requests")
        #expect(pr?.contains("REAL GitHub pull requests") == true)
        let jira = WorkspaceAppStudioScope.needsConnectorNotice(for: "sync with jira")
        #expect(jira?.contains("sample data") == true)
    }

    // MARK: - CB6 security hardening (codex findings)

    @Test("isBridgeEligible includes capability.read so a read app and a pure-UI app differ (WebView identity)")
    func bridgeEligibilityIncludesReads() {
        // A read-only connector app IS bridge-eligible (the BLOCKER fix).
        #expect(WorkspaceAppDataBridge.isBridgeEligible(prManifest()))
        // A pure-UI HTML app is NOT — so it gets a distinct WebView identity and never reuses a read
        // app's WebView (which would keep the stale astra.read handler alive).
        var pure = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "pure", name: "Pure"),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: "<main>hi</main>"
        )
        #expect(!WorkspaceAppDataBridge.isBridgeEligible(pure))
        // Storage makes it eligible again.
        pure.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "t", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        #expect(WorkspaceAppDataBridge.isBridgeEligible(pure))
    }

    @Test("resolveRead rejects a storage-shadow source (no requirementRef) and clamps the caller limit")
    func resolveReadStorageShadowAndLimit() {
        // A source with NO requirementRef (could shadow an app-storage table) is not connector-readable.
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:]),
                                                   in: prManifest(requirementRef: nil)) == nil)
        // The caller limit is clamped to the connector-read cap; an unset limit gets the small default.
        let big = WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:], limit: 100_000),
                                                     in: prManifest())
        #expect(big?.input.limit == WorkspaceAppDataBridge.maxConnectorReadLimit)
        let none = WorkspaceAppDataBridge.resolveRead(.init(sourceId: "myPRs", record: [:], limit: nil),
                                                      in: prManifest())
        #expect(none?.input.limit == WorkspaceAppDataBridge.defaultConnectorReadLimit)
    }

    @Test("validator rejects a connector-read source without a requirementRef or with an undeclared operation")
    func validatorRejectsMalformedConnectorRead() {
        // No requirementRef → not a connector source (astra.read is connectors-only).
        #expect(!WorkspaceAppManifestValidator.validate(prManifest(requirementRef: nil)).isValid)
        // Source op the requirement does not declare → op-broadening, rejected.
        #expect(!WorkspaceAppManifestValidator.validate(
            prManifest(sourceOperation: "listMyPullRequests", requirementOps: ["listRepoPullRequests"])
        ).isValid)
    }

    @Test("validator rejects a capability.read source that shadows a storage table (pipeline-step leak)")
    func validatorRejectsStorageShadowSource() {
        // The connector source id "myPRs" also names a storage table → it would shadow app storage when
        // run as a capability.read pipeline/loop step via astra.runAction. Must be rejected.
        var manifest = prManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "myPRs", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("shadow app storage") })
    }

    @Test("the GitHub client refuses an operation the requirement did not declare (no op-broadening)")
    func clientRefusesOpBroadening() async {
        let requirement = WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                                  operations: ["listRepoPullRequests"], providerHint: "github")
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: UUID(), appID: UUID(), appLogicalID: "prs",
            requirementID: "github", contract: "pullRequest.read",
            operations: ["listRepoPullRequests"], optional: false, status: .mapped,
            implementationID: "github-pr-read-native", provider: "github", transport: .native
        )
        // Source declares the BROAD op, but the requirement only declared the narrow one.
        let source = WorkspaceAppSource(id: "myPRs", requirementRef: "github",
                                        operation: "listMyPullRequests", mode: "read")
        await #expect(throws: (any Error).self) {
            _ = try await WorkspaceAppGitHubPRReadClient(reader: PRRequestRecorder()).read(
                source: source, requirement: requirement, binding: binding,
                input: WorkspaceAppSourceResolutionInput())
        }
    }

    @Test("the injected astra.read forwards the caller limit so the native clamp can apply it")
    func injectedReadForwardsLimit() {
        #expect(WorkspaceAppDataBridge.injectedScript.contains("limit: (opts && opts.limit)"))
    }

    @Test("denyAll handlers refuse every verb (fail-closed reuse defense)")
    @MainActor
    func denyAllRefuses() {
        let handlers = WorkspaceAppDataBridge.denyAll
        #expect(handlers.read == nil)
        #expect(handlers.runAction == nil)
        if case .error = handlers.storage(.init(op: "query", table: "t", record: [:], limit: nil)) {
            // expected
        } else {
            Issue.record("denyAll storage must refuse")
        }
    }
}

/// Captures the last request handed to the GitHub PR transport so tests can assert the client mapped
/// operation/state/repo correctly — without ever shelling out to `gh`.
private actor PRRequestRecorder: WorkspaceAppGitHubPRReading {
    private(set) var last: WorkspaceAppGitHubPRRequest?
    let rows: [[String: WorkspaceAppStorageValue]]
    init(rows: [[String: WorkspaceAppStorageValue]] = []) { self.rows = rows }
    func read(_ request: WorkspaceAppGitHubPRRequest) async throws -> [[String: WorkspaceAppStorageValue]] {
        last = request
        return rows
    }
}
