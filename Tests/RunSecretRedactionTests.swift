import Foundation
import SwiftData
import Testing
import ASTRACore
@testable import ASTRA
// `saveCredentialChecked(key:value:store:)` — the seam that lets these tests
// supply a fake Keychain — is internal to ASTRAModels.
@testable import ASTRAModels
@testable import ASTRAPersistence

/// The Atlassian token in the incident that prompted this work reached three
/// `TaskEvent` payloads. These are shaped like real credentials but are not
/// ones: `ATATT` is the Atlassian prefix, the tail is filler.
private let atlassianShaped = "ATATT3xFfGF0aaaabbbbccccddddeeeeffff0000111122223333444455556666"
private let redcapShaped = "0123456789ABCDEF0123456789ABCDEF"

@Suite("Run secret redaction", .serialized)
struct RunSecretRedactionTests {
    // MARK: - Classification

    @Test("A credential is recognized by its variable name, not its value")
    func secretKeysAreRecognizedByName() {
        for key in ["JIRA_API_TOKEN", "REDCAP_API_TOKEN", "atlassian_secret",
                    "DB_PASSWORD", "OPENAI_API_KEY", "SERVICE_CREDENTIAL", "MY_APIKEY"] {
            #expect(RunSecretRedaction.isSecretKey(key), "\(key) should be treated as a credential")
        }
        // Non-credentials share the same projection. Redacting a base URL or a
        // project ID would shred transcripts while protecting nothing.
        for key in ["JIRA_BASE_URL", "REDCAP_URL", "ASTRA_CONNECTORS", "PROJECT_ID", "USER_EMAIL"] {
            #expect(!RunSecretRedaction.isSecretKey(key), "\(key) should not be treated as a credential")
        }
    }

    @Test("Only credential-named values of usable length are collected from an environment")
    func secretValuesFilterTheEnvironment() {
        let values = Set(RunSecretRedaction.secretValues(in: [
            "JIRA_API_TOKEN": atlassianShaped,
            "JIRA_BASE_URL": "https://coral.atlassian.net",
            "REDCAP_API_TOKEN": "  \(redcapShaped)  ",
            "SHORT_TOKEN": "ab"
        ]))
        #expect(values == [atlassianShaped, redcapShaped])
    }

    // MARK: - The pure pass

    @Test("Redaction removes the value and leaves the surrounding text intact")
    func redactionRemovesTheValue() {
        let text = "curl -H \"Authorization: Bearer \(atlassianShaped)\" https://coral.atlassian.net"
        let redacted = RunSecretRedaction.redact(text, secrets: [atlassianShaped])
        #expect(!redacted.contains(atlassianShaped))
        #expect(redacted.contains("https://coral.atlassian.net"))
        #expect(redacted.contains(RunSecretRedaction.marker))
    }

    @Test("A secret containing another is replaced whole")
    func longestSecretWinsSoNoSuffixSurvives() {
        let short = "abcd1234efgh"
        let long = short + "ijkl5678mnop"
        let redacted = RunSecretRedaction.redact("value=\(long)", secrets: [short, long])
        // Replacing the short one first would leave "ijkl5678mnop" — half a
        // live credential — sitting in the transcript.
        #expect(!redacted.contains("ijkl5678mnop"))
        #expect(redacted == "value=\(RunSecretRedaction.marker)")
    }

    @Test("A truncated secret is redacted down to its surviving prefix")
    func truncatedSecretPrefixIsRedacted() {
        // Tool results are capped at 10,000 characters, which cuts a secret in
        // half rather than removing it. Exact replacement cannot see the
        // remainder; the fragment scan can.
        let truncated = String(atlassianShaped.prefix(24))
        let redacted = RunSecretRedaction.redact("token starts: \(truncated)", secrets: [atlassianShaped])
        #expect(!redacted.contains(truncated))
        #expect(redacted.hasPrefix("token starts: "))
    }

    @Test("Text shorter than the fragment floor is left alone")
    func shortIncidentalMatchesSurvive() {
        // "0123456" is the head of the REDCap-shaped value but is also just a
        // number someone might legitimately write.
        let redacted = RunSecretRedaction.redact("record 0123456 ok", secrets: [redcapShaped])
        #expect(redacted == "record 0123456 ok")
    }

    @Test("Redaction with no secrets returns the text unchanged")
    func redactionWithoutSecretsIsANoOp() {
        #expect(RunSecretRedaction.redact("plain text", secrets: []) == "plain text")
    }

    // MARK: - The registry

    @Test("An unregistered task redacts nothing")
    func unregisteredTaskIsUntouched() {
        let taskID = UUID()
        #expect(RunSecretRedactionScope.redact(atlassianShaped, taskID: taskID) == atlassianShaped)
        #expect(RunSecretRedactionScope.redact(atlassianShaped, taskID: nil) == atlassianShaped)
    }

    @Test("Registering an environment redacts its credentials but not its URLs")
    func registrationDerivesFromTheEnvironment() {
        let taskID = UUID()
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        RunSecretRedactionScope.register(taskID: taskID, environment: [
            "JIRA_API_TOKEN": atlassianShaped,
            "JIRA_BASE_URL": "https://coral.atlassian.net"
        ])

        let redacted = RunSecretRedactionScope.redact(
            "\(atlassianShaped) at https://coral.atlassian.net", taskID: taskID)
        #expect(!redacted.contains(atlassianShaped))
        #expect(redacted.contains("https://coral.atlassian.net"))
    }

    @Test("A later, narrower resolution cannot unregister an earlier secret")
    func registrationAccumulates() {
        // The environment is resolved several times per launch — preflight, the
        // launch itself, the permission summary — and they do not all see the
        // same connectors. If a narrower one replaced the set, a value the
        // agent already holds would start reaching the store in the clear.
        let taskID = UUID()
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        RunSecretRedactionScope.register(taskID: taskID, environment: ["JIRA_API_TOKEN": atlassianShaped])
        RunSecretRedactionScope.register(taskID: taskID, environment: ["REDCAP_API_TOKEN": redcapShaped])

        let redacted = RunSecretRedactionScope.redact("\(atlassianShaped) \(redcapShaped)", taskID: taskID)
        #expect(!redacted.contains(atlassianShaped))
        #expect(!redacted.contains(redcapShaped))
    }

    @Test("Registrations are bounded so a long-lived process does not hoard secrets")
    func registrationsAreEvictedLeastRecentlyRegisteredFirst() {
        let overflow = RunSecretRedactionScope.retainedTaskLimit + 1
        let taskIDs = (0..<overflow).map { _ in UUID() }
        defer { taskIDs.forEach { RunSecretRedactionScope.forget(taskID: $0) } }
        for (index, taskID) in taskIDs.enumerated() {
            RunSecretRedactionScope.register(taskID: taskID, secrets: ["secret-value-\(index)-padding"])
        }

        #expect(RunSecretRedactionScope.secrets(for: taskIDs[0]).isEmpty)
        #expect(!RunSecretRedactionScope.secrets(for: taskIDs[overflow - 1]).isEmpty)
    }

    @Test("A task that is still redacting outlives newer registrations")
    func evictionTracksUseNotRegistration() {
        // The shape that broke: a long task registers once at launch and then
        // redacts for hours. Ordering by registration alone meant sixteen short
        // tasks started after it evicted the live one, and every credential it
        // echoed from then on was persisted in the clear.
        let limit = RunSecretRedactionScope.retainedTaskLimit
        let longLived = UUID()
        let newcomers = (0..<limit).map { _ in UUID() }
        defer { ([longLived] + newcomers).forEach { RunSecretRedactionScope.forget(taskID: $0) } }

        RunSecretRedactionScope.register(taskID: longLived, secrets: [atlassianShaped])
        for (index, taskID) in newcomers.dropLast().enumerated() {
            RunSecretRedactionScope.register(taskID: taskID, secrets: ["secret-value-\(index)-padding"])
        }

        // Its only sign of life is that it is still producing output.
        #expect(!RunSecretRedactionScope.redact("bearer \(atlassianShaped)", taskID: longLived)
            .contains(atlassianShaped))

        RunSecretRedactionScope.register(taskID: newcomers[limit - 1], secrets: [redcapShaped])

        #expect(!RunSecretRedactionScope.secrets(for: longLived).isEmpty)
        #expect(RunSecretRedactionScope.secrets(for: newcomers[0]).isEmpty)
    }

    // MARK: - The seam between chunks

    @Test("A secret split across two streamed chunks is still caught")
    func secretStraddlingAChunkBoundaryIsRedacted() {
        let taskID = UUID()
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        RunSecretRedactionScope.register(taskID: taskID, secrets: [atlassianShaped])

        let head = String(atlassianShaped.prefix(20))
        let tail = String(atlassianShaped.dropFirst(20))
        var payload = RunSecretRedactionScope.redact("token: \(head)", taskID: taskID)
        let append = RunSecretRedactionScope.redactedAppend(
            existing: payload, addition: "\(tail) done", taskID: taskID)
        if append.dropFromExisting > 0 { payload.removeLast(append.dropFromExisting) }
        payload += append.append

        #expect(!payload.contains(atlassianShaped))
        #expect(payload.hasPrefix("token: "))
        #expect(payload.hasSuffix(" done"))
    }

    @Test("An append that touches no secret leaves the existing text byte-identical")
    func cleanAppendDoesNotRewriteHistory() {
        let taskID = UUID()
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        RunSecretRedactionScope.register(taskID: taskID, secrets: [atlassianShaped])

        let append = RunSecretRedactionScope.redactedAppend(
            existing: "the agent said ", addition: "hello", taskID: taskID)
        #expect(append.dropFromExisting == 0)
        #expect(append.append == "hello")
    }

    // MARK: - The persistence funnel

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        Fixture(container: try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    @MainActor
    @Test("Every TaskEvent construction path redacts, including the structured ones")
    func taskEventInitializersRedact() throws {
        let fixture = try Self.makeFixture()
        let task = AgentTask(title: "Attestation", goal: "Collect REDCap evidence")
        fixture.context.insert(task)
        defer { RunSecretRedactionScope.forget(taskID: task.id) }
        RunSecretRedactionScope.register(taskID: task.id, secrets: [atlassianShaped])

        let leak = "env dump: JIRA_API_TOKEN=\(atlassianShaped)"
        let designated = TaskEvent(task: task, type: "tool.result", payload: leak)
        let convenience = TaskEvent(task: task, eventType: TaskEventTypes.Tool.result, payload: leak)
        let structured = TaskEvent.structuredPayloadEvent(
            task: task, eventType: TaskEventTypes.Tool.result, payload: ["body": leak])

        for event in [designated, convenience, structured] {
            #expect(!event.payload.contains(atlassianShaped))
            #expect(event.payload.contains(RunSecretRedaction.marker))
        }
        // Redaction must not swallow the event: the user still needs to see
        // that the agent dumped its environment.
        #expect(designated.payload.hasPrefix("env dump: JIRA_API_TOKEN="))
    }

    @MainActor
    @Test("Run output is redacted on replacement and across appends")
    func taskRunOutputIsRedacted() throws {
        let fixture = try Self.makeFixture()
        let task = AgentTask(title: "Attestation", goal: "Collect REDCap evidence")
        fixture.context.insert(task)
        let run = TaskRun(task: task)
        fixture.context.insert(run)
        defer { RunSecretRedactionScope.forget(taskID: task.id) }
        RunSecretRedactionScope.register(taskID: task.id, secrets: [atlassianShaped])

        run.setOutput("bearer \(atlassianShaped)")
        #expect(!run.output.contains(atlassianShaped))

        run.setOutput("")
        run.appendOutput("bearer \(atlassianShaped.prefix(30))")
        run.appendOutput("\(atlassianShaped.dropFirst(30)) end")
        #expect(!run.output.contains(atlassianShaped))
        #expect(run.output.hasSuffix(" end"))
    }

    @MainActor
    @Test("Redaction does not disturb the protocol-marker flag")
    func protocolMarkerFlagSurvivesRedaction() throws {
        let fixture = try Self.makeFixture()
        let task = AgentTask(title: "Attestation", goal: "Collect REDCap evidence")
        fixture.context.insert(task)
        let run = TaskRun(task: task)
        fixture.context.insert(run)
        defer { RunSecretRedactionScope.forget(taskID: task.id) }
        RunSecretRedactionScope.register(taskID: task.id, secrets: [atlassianShaped])

        run.setOutput("\(AstraRunProtocolParser.markerToken) status \(atlassianShaped)")
        #expect(run.hasProtocolEvents == true)
        #expect(!run.output.contains(atlassianShaped))
    }

    @MainActor
    @Test("A task with no registered secrets keeps its payload verbatim")
    func unregisteredTaskEventIsVerbatim() throws {
        let fixture = try Self.makeFixture()
        let task = AgentTask(title: "Plain", goal: "No connectors")
        fixture.context.insert(task)

        let event = TaskEvent(task: task, type: "agent.response", payload: "nothing secret here")
        #expect(event.payload == "nothing secret here")
    }
}

@Suite("Persisted credential purge", .serialized)
struct PersistedCredentialPurgeServiceTests {
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        Fixture(container: try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    /// Reproduces the incident's store shape: a Jira connector holding a live
    /// token, and transcript rows that already contain it.
    @MainActor
    private static func seedLeakedStore(
        _ fixture: Fixture,
        store: MockSecretStore
    ) throws -> (task: AgentTask, run: TaskRun, events: [TaskEvent]) {
        let context = fixture.context
        let connector = Connector(
            name: "Jira", serviceType: "jira", icon: "ticket",
            baseURL: "https://coral.atlassian.net", authMethod: "api_key")
        context.insert(connector)
        #expect(connector.saveCredentialChecked(
            key: "JIRA_API_TOKEN", value: atlassianShaped, store: store) == .saved)

        let task = AgentTask(title: "Data privacy attestation", goal: "Collect evidence")
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)

        // Built before the funnel existed, so written in the clear. Assigning
        // the fields directly is what a pre-redaction build effectively did.
        let events = (0..<3).map { index -> TaskEvent in
            let event = TaskEvent(task: task, type: "tool.result", payload: "placeholder \(index)", run: run)
            event.payload = "step \(index): JIRA_API_TOKEN=\(atlassianShaped)"
            context.insert(event)
            return event
        }
        run.setOutput("launched with JIRA_API_TOKEN=\(atlassianShaped)")
        try context.save()
        return (task, run, events)
    }

    @MainActor
    @Test("The purge clears a leaked token from transcripts and then finds nothing")
    func purgeClearsLeakedTokenFromTranscripts() async throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        let seeded = try Self.seedLeakedStore(fixture, store: store)

        let first = await PersistedCredentialPurgeService.purge(
            modelContext: fixture.context, store: store)
        #expect(first.completed)
        #expect(first.eventsRewritten == 3)
        #expect(first.runsRewritten == 1)

        for event in seeded.events {
            #expect(!event.payload.contains(atlassianShaped))
            #expect(event.payload.contains(RunSecretRedaction.marker))
            // Rewritten, never deleted: the transcript still says what happened.
            #expect(event.payload.hasPrefix("step "))
        }
        #expect(!seeded.run.output.contains(atlassianShaped))

        // A second pass stops at the count probe. Not merely idempotent — it
        // must not keep paying for a sweep on every launch.
        let second = await PersistedCredentialPurgeService.purge(
            modelContext: fixture.context, store: store)
        #expect(second == .init(secretsConsidered: 1, completed: true))
    }

    @MainActor
    @Test("A store with no stored credentials never queries the transcript tables")
    func purgeSkipsWhenNoCredentialsExist() async throws {
        let fixture = try Self.makeFixture()
        let task = AgentTask(title: "Plain", goal: "No connectors")
        fixture.context.insert(task)
        fixture.context.insert(TaskEvent(task: task, type: "agent.response", payload: "hello"))
        try fixture.context.save()

        let outcome = await PersistedCredentialPurgeService.purge(
            modelContext: fixture.context, store: MockSecretStore())
        #expect(outcome == .init(completed: true, skippedNoSecrets: true))
    }

    /// The build gate exists to stop the sweep repeating, not to retire it. A
    /// Keychain the process could not read is indistinguishable from a store
    /// with no credentials, so recording the build on that outcome would mean
    /// one unreadable launch permanently cancels the containment sweep for
    /// this build — including for the store that still holds the leak.
    @MainActor
    @Test("A sweep that found no credential to search for does not spend the build gate")
    func purgeIfNeededKeepsGateOpenWhenNoSecretsAreReadable() async throws {
        let fixture = try Self.makeFixture()
        let defaults = try #require(UserDefaults(suiteName: "purge-gate-no-secrets"))
        defaults.removePersistentDomain(forName: "purge-gate-no-secrets")

        let recorded = await PersistedCredentialPurgeService.purgeIfNeeded(
            modelContext: fixture.context,
            currentBuild: "10029",
            defaults: defaults,
            store: MockSecretStore()
        )

        #expect(recorded == false)
        #expect(defaults.string(forKey: AppStorageKeys.completedPersistedCredentialPurgeBuild) == nil)
    }

    @MainActor
    @Test("A sweep that ran against real credentials spends the build gate once")
    func purgeIfNeededRecordsBuildAfterRealSweep() async throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        _ = try Self.seedLeakedStore(fixture, store: store)
        let defaults = try #require(UserDefaults(suiteName: "purge-gate-real-sweep"))
        defaults.removePersistentDomain(forName: "purge-gate-real-sweep")

        let first = await PersistedCredentialPurgeService.purgeIfNeeded(
            modelContext: fixture.context,
            currentBuild: "10029",
            defaults: defaults,
            store: store
        )
        #expect(first)
        #expect(defaults.string(forKey: AppStorageKeys.completedPersistedCredentialPurgeBuild) == "10029")

        // Same build, so the sweep does not run again.
        let second = await PersistedCredentialPurgeService.purgeIfNeeded(
            modelContext: fixture.context,
            currentBuild: "10029",
            defaults: defaults,
            store: store
        )
        #expect(second == false)
    }

    /// A skill holds Keychain-backed environment values of its own, and they
    /// reach a run's environment exactly the way a connector's do. Sweeping
    /// only connectors left a leaked skill token in the transcripts it had
    /// already reached.
    @MainActor
    @Test("A skill's Keychain-held token is swept out of the transcripts too")
    func purgeSweepsSkillSecrets() async throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        let skill = Skill(name: "REDCap export")
        fixture.context.insert(skill)
        // Assigned rather than written through `setEnvironmentValue`, which
        // saves to the real Keychain: the seam it uses takes no store.
        skill.environmentKeys = ["REDCAP_API_TOKEN", "PROJECT_KEY"]
        skill.environmentValues = ["", ""]
        let entityID = KeychainSecretStore.skillEntityID(for: skill.id)
        #expect(store.save(key: "REDCAP_API_TOKEN", value: redcapShaped, entityID: entityID, label: nil))
        #expect(store.save(key: "PROJECT_KEY", value: "STAR-PROJECT-2026", entityID: entityID, label: nil))

        let task = AgentTask(title: "Export", goal: "Export the cohort")
        fixture.context.insert(task)
        let event = TaskEvent(task: task, type: "tool.result", payload: "placeholder")
        event.payload = "curl -H 'token: \(redcapShaped)' for STAR-PROJECT-2026"
        fixture.context.insert(event)
        try fixture.context.save()

        // Two predicates, deliberately. `Skill.isSecretEnvironmentKey` decides
        // what is *stored* in the Keychain and is the wider of the two, so
        // `PROJECT_KEY` is held there; `RunSecretRedaction.isSecretKey` decides
        // what a run redacts, and it does not treat a project key as a
        // credential. Sweeping the wider set would make old transcripts hide
        // identifiers that today's transcripts show.
        let values = PersistedCredentialPurgeService.liveCredentialValues(
            modelContext: fixture.context, store: store)
        #expect(values == [redcapShaped])

        let outcome = await PersistedCredentialPurgeService.purge(
            modelContext: fixture.context, store: store)
        #expect(outcome.eventsRewritten == 1)
        #expect(!event.payload.contains(redcapShaped))
        #expect(event.payload.contains("STAR-PROJECT-2026"))
    }

    @MainActor
    @Test("Non-credential connector values are never treated as secrets")
    func purgeIgnoresNonCredentialValues() throws {
        let fixture = try Self.makeFixture()
        let store = MockSecretStore()
        let connector = Connector(
            name: "Jira", serviceType: "jira", icon: "ticket",
            baseURL: "https://coral.atlassian.net", authMethod: "api_key")
        fixture.context.insert(connector)
        #expect(connector.saveCredentialChecked(
            key: "JIRA_API_TOKEN", value: atlassianShaped, store: store) == .saved)
        #expect(connector.saveCredentialChecked(
            key: "JIRA_EMAIL", value: "person@stanford.edu", store: store) == .saved)

        let values = PersistedCredentialPurgeService.liveCredentialValues(
            modelContext: fixture.context, store: store)
        // An address is an identifier, not a credential. Redacting it out of
        // transcripts would destroy the audit trail the attestation depends on.
        #expect(values == [atlassianShaped])
    }
}
