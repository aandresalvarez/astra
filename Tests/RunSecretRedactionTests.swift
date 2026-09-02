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

    /// The invariant the two predicates exist to keep: a name that puts a value
    /// in the Keychain must also be a name a transcript redacts. It was broken
    /// for every credential matching bare `KEY` or `AUTH` — an `SSH_PRIVATE_KEY`
    /// or a `CLIENT_AUTH` was loaded from the Keychain, projected into the
    /// agent's environment, and then written to the transcript in the clear,
    /// because the redaction predicate had been narrowed by hand and the two
    /// lists silently drifted apart.
    @Test("Anything the Keychain will hold is something a transcript will redact")
    func everyStorableKeyIsRedactable() {
        for key in ["SSH_PRIVATE_KEY", "CLIENT_AUTH", "GITHUB_KEY", "AUTHORIZATION",
                    "JIRA_API_TOKEN", "DB_PASSWORD", "SERVICE_CREDENTIAL"] {
            #expect(
                Skill.isSecretEnvironmentKey(key),
                "\(key) should be Keychain-backed; this test is otherwise vacuous"
            )
            #expect(
                RunSecretRedaction.isSecretKey(key),
                "\(key) is Keychain-backed, so its value must never survive in a transcript"
            )
        }

        // The one permitted divergence, and it is enumerated rather than
        // inferred: these are stored, because a value already in the Keychain
        // has to stay readable, and deliberately not redacted, because they
        // name things rather than unlock them.
        for key in ["PROJECT_KEY", "JIRA_PROJECT_KEY", "SIGNING_KEY_ID"] {
            #expect(Skill.isSecretEnvironmentKey(key))
            #expect(
                !RunSecretRedaction.isSecretKey(key),
                "\(key) identifies rather than authenticates; redacting it shreds the transcript"
            )
        }
    }

    /// An `SSH_PRIVATE_KEY` value reaching a payload is the shape of the leak
    /// the narrowed predicate allowed, so it is pinned end to end rather than
    /// at the predicate alone.
    @Test("A Keychain-backed SSH key and client auth are stripped from a payload")
    func widerCredentialNamesAreRedactedFromText() {
        let sshShaped = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
        let clientAuthShaped = "Basic YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo="
        let secrets = RunSecretRedaction.secretValues(in: [
            "SSH_PRIVATE_KEY": sshShaped,
            "CLIENT_AUTH": clientAuthShaped,
            "JIRA_PROJECT_KEY": "STAR"
        ])
        let redacted = RunSecretRedaction.redact(
            "ssh key was \(sshShaped) and header \(clientAuthShaped) for STAR",
            secrets: secrets
        )
        #expect(!redacted.contains(sshShaped))
        #expect(!redacted.contains(clientAuthShaped))
        #expect(redacted.contains("for STAR"), "The project key names a board; it is not a credential")
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

    /// "Used" is not "running". A scope is only touched when its task writes
    /// output, and a task that is thinking, waiting on a tool, or blocked on the
    /// user writes nothing for minutes at a time. Sixteen short tasks in that
    /// window evicted a live one, and `use` returns before `touch` when the
    /// scope is missing, so reading could not bring it back either.
    @Test("A task with a live process is never evicted, however quiet it is")
    func activeRunsAreNotEvicted() {
        let limit = RunSecretRedactionScope.retainedTaskLimit
        let running = UUID()
        let newcomers = (0..<(limit + 4)).map { _ in UUID() }
        defer {
            RunSecretRedactionScope.endRun(taskID: running)
            ([running] + newcomers).forEach { RunSecretRedactionScope.forget(taskID: $0) }
        }

        RunSecretRedactionScope.beginRun(taskID: running)
        RunSecretRedactionScope.register(taskID: running, secrets: [atlassianShaped])
        #expect(RunSecretRedactionScope.isRunActive(taskID: running))

        // It says nothing at all from here on, which is the point.
        for (index, taskID) in newcomers.enumerated() {
            RunSecretRedactionScope.register(taskID: taskID, secrets: ["secret-value-\(index)-padding"])
        }

        #expect(!RunSecretRedactionScope.secrets(for: running).isEmpty)
        #expect(!RunSecretRedactionScope.redact("bearer \(atlassianShaped)", taskID: running)
            .contains(atlassianShaped))
        // Bounded still: the overflow came out of the finished tasks.
        #expect(RunSecretRedactionScope.secrets(for: newcomers[0]).isEmpty)
    }

    /// The pin has to come off, or the ceiling is not a ceiling.
    @Test("A finished run stops being pinned and rejoins the eviction order")
    func endingARunReleasesThePin() {
        let limit = RunSecretRedactionScope.retainedTaskLimit
        let finished = UUID()
        let newcomers = (0..<limit).map { _ in UUID() }
        defer { ([finished] + newcomers).forEach { RunSecretRedactionScope.forget(taskID: $0) } }

        // Nested launches on one task: the pin is a count, so the inner one
        // ending must not unpin the outer.
        RunSecretRedactionScope.beginRun(taskID: finished)
        RunSecretRedactionScope.beginRun(taskID: finished)
        RunSecretRedactionScope.register(taskID: finished, secrets: [atlassianShaped])
        RunSecretRedactionScope.endRun(taskID: finished)
        #expect(RunSecretRedactionScope.isRunActive(taskID: finished))
        RunSecretRedactionScope.endRun(taskID: finished)
        #expect(!RunSecretRedactionScope.isRunActive(taskID: finished))

        for (index, taskID) in newcomers.enumerated() {
            RunSecretRedactionScope.register(taskID: taskID, secrets: ["secret-value-\(index)-padding"])
        }

        #expect(RunSecretRedactionScope.secrets(for: finished).isEmpty)
    }

    // MARK: - Key classification

    /// A bare substring match let an exception swallow a credential whose name
    /// merely started with it. `Skill.isSecretEnvironmentKey` has no exception
    /// list, so `PROJECT_KEY_TOKEN` was stored in the Keychain, projected into
    /// the agent environment, and then classified as not-a-secret by everything
    /// that redacts or purges.
    @Test("An exception has to own the end of the name")
    func exceptionsDoNotSwallowSuffixedCredentials() {
        #expect(!RunSecretRedaction.isSecretKey("PROJECT_KEY"))
        #expect(!RunSecretRedaction.isSecretKey("JIRA_PROJECT_KEY"))
        #expect(!RunSecretRedaction.isSecretKey("KEY_ID"))
        #expect(!RunSecretRedaction.isSecretKey("SSH_AUTH_SOCK"))

        #expect(RunSecretRedaction.isSecretKey("PROJECT_KEY_TOKEN"))
        #expect(RunSecretRedaction.isSecretKey("JIRA_PROJECT_KEY_SECRET"))
        #expect(RunSecretRedaction.isSecretKey("KEY_ID_PASSWORD"))
        #expect(RunSecretRedaction.isSecretKey("PROJECT_KEY_ID_TOKEN"))
    }

    /// And the classification has to reach the redactor, not just the predicate.
    @Test("A suffixed credential's value is redacted from run output")
    func suffixedCredentialValueIsRedacted() {
        let taskID = UUID()
        defer { RunSecretRedactionScope.forget(taskID: taskID) }
        RunSecretRedactionScope.register(taskID: taskID, environment: [
            "PROJECT_KEY": "STAR",
            "PROJECT_KEY_TOKEN": atlassianShaped
        ])

        let redacted = RunSecretRedactionScope.redact(
            "PROJECT_KEY=STAR PROJECT_KEY_TOKEN=\(atlassianShaped)",
            taskID: taskID
        )
        #expect(!redacted.contains(atlassianShaped))
        // The project name is not a credential and stays readable.
        #expect(redacted.contains("PROJECT_KEY=STAR"))
    }

    // MARK: - The launch environment

    /// Registration used to see only the capability overlay, but the subprocess
    /// receives far more than that. `RuntimeProcessEnvironment.enriched` starts
    /// from `ProcessInfo.processInfo.environment`, so every variable ASTRA was
    /// itself launched with is inherited by the agent — and a developer build
    /// started from a shell that exports `ANTHROPIC_API_KEY` or
    /// `OPENAI_API_KEY` was handing the agent a live provider credential that
    /// nothing would redact. Echoing it wrote it into the transcript verbatim.
    @MainActor
    @Test("A credential inherited from ASTRA's own launch is registered for redaction")
    func inheritedLaunchCredentialsAreRegistered() {
        // A name no ASTRA code reads, so setting it cannot change how a suite
        // running alongside this one behaves. What is under test is inheritance
        // from the process environment, not any particular provider.
        let inherited = "ASTRA_TEST_INHERITED_API_TOKEN"
        setenv(inherited, atlassianShaped, 1)
        defer { unsetenv(inherited) }

        let task = AgentTask(title: "Echo", goal: "Print the environment")
        defer { RunSecretRedactionScope.forget(taskID: task.id) }
        let env = AgentRuntimeProcessRunner.environment(
            phase: .run, task: task, taskEnv: [:], includeClaudeTeamFlag: false)
        #expect(env[inherited] == atlassianShaped, "The agent really does inherit it")

        let redacted = RunSecretRedactionScope.redact(
            "the agent echoed \(atlassianShaped)", taskID: task.id)
        #expect(!redacted.contains(atlassianShaped))
    }

    /// The other half of registering a whole launch environment: it is full of
    /// variables that are not credentials, and redacting one of those shreds
    /// the transcript. `SSH_AUTH_SOCK` is the collision that matters, because
    /// macOS sets it on every login session and its value is a path — and the
    /// fragment scan matches on eight bytes, so registering it would replace
    /// `/private` wherever it appeared.
    @MainActor
    @Test("Ordinary launch variables are not mistaken for credentials")
    func inheritedNonCredentialsAreLeftAlone() {
        #expect(!RunSecretRedaction.isSecretKey("SSH_AUTH_SOCK"))
        let socket = "/private/tmp/com.apple.launchd.AbCdEf1234/Listeners"
        #expect(RunSecretRedaction.secretValues(in: ["SSH_AUTH_SOCK": socket]).isEmpty)

        let task = AgentTask(title: "Echo", goal: "Print the environment")
        defer { RunSecretRedactionScope.forget(taskID: task.id) }
        // Restored rather than unset: this one is real on any login session,
        // and the ssh shim reads it.
        let previousSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", socket, 1)
        defer {
            if let previousSocket {
                setenv("SSH_AUTH_SOCK", previousSocket, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        let env = AgentRuntimeProcessRunner.environment(
            phase: .run, task: task, taskEnv: [:], includeClaudeTeamFlag: false)

        let sample = "wrote \(socket) using PATH=\(env["PATH"] ?? "")"
        #expect(RunSecretRedactionScope.redact(sample, taskID: task.id) == sample)
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

        // Both predicates now read the same pattern list, so anything the
        // Keychain holds is swept. `PROJECT_KEY` still survives, but by being
        // named in `RunSecretRedaction.nonCredentialKeyNames` rather than by
        // falling through a narrower rule — the difference matters, because the
        // narrower rule also silently spared `SSH_PRIVATE_KEY` and
        // `CLIENT_AUTH`.
        let values = try PersistedCredentialPurgeService.liveCredentialValues(
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

        let values = try PersistedCredentialPurgeService.liveCredentialValues(
            modelContext: fixture.context, store: store)
        // An address is an identifier, not a credential. Redacting it out of
        // transcripts would destroy the audit trail the attestation depends on.
        #expect(values == [atlassianShaped])
    }
}
