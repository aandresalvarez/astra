import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Local MLX Runtime", .serialized)
struct LocalModelRuntimeTests {
    @Test("Protocol parser maps local helper JSON to agent events")
    func protocolParserMapsLocalHelperJSONToAgentEvents() throws {
        let encoder = JSONEncoder()
        let started = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "started",
            sessionID: "session-1",
            model: LocalMLXRuntime.defaultModel
        )), encoding: .utf8)
        let text = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "text",
            text: "hello"
        )), encoding: .utf8)
        let stats = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "stats",
            inputTokens: 12,
            outputTokens: 7,
            durationMs: 42,
            turns: 1
        )), encoding: .utf8)
        let memory = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "memory",
            phase: "after_load",
            activeMemoryBytes: 2_048,
            peakMemoryBytes: 4_096,
            cacheMemoryBytes: 1_024,
            memoryLimitBytes: 8_192,
            cacheLimitBytes: 512,
            memoryBudgetBytes: 8_192
        )), encoding: .utf8)
        let memoryPressure = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "memory",
            message: "memory pressure: memory limit exceeded",
            phase: "generate"
        )), encoding: .utf8)
        let phase = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "phase",
            message: "Loading local MLX model.",
            phase: "load_model"
        )), encoding: .utf8)
        let cancelled = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "cancelled",
            message: "cancelled_by_user"
        )), encoding: .utf8)
        let completed = try String(data: encoder.encode(LocalModelProtocolEnvelope(
            type: "completed",
            summary: "<think>hidden chain of thought</think>\n\nVisible answer"
        )), encoding: .utf8)

        #expect(LocalModelProtocolParser.agentEvents(from: try #require(started)) == [
            .started(sessionID: "session-1", model: LocalMLXRuntime.defaultModel)
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(text)) == [
            .text(text: "hello")
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(stats)) == [
            .stats(inputTokens: 12, outputTokens: 7, costUSD: nil, durationMs: 42, turns: 1)
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(memory)) == [
            .diagnostic(kind: "local_model.memory", message: "Local MLX memory: phase: after_load | active: 2.0 KB | peak: 4.0 KB | cache: 1.0 KB | memory limit: 8.0 KB | cache limit: 512 B | budget: 8.0 KB")
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(memoryPressure)) == [
            .diagnostic(kind: "local_model.memory", message: "Local MLX memory: phase: generate | message: memory pressure: memory limit exceeded")
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(phase)) == [
            .thinking(text: "Loading local MLX model.")
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(cancelled)) == [
            .diagnostic(kind: "local_model.cancelled", message: "cancelled_by_user")
        ])
        #expect(LocalModelProtocolParser.agentEvents(from: try #require(completed)) == [
            .completed(summary: "Visible answer")
        ])
    }

    @Test("Local action parser accepts final answers and nested tool calls")
    func localActionParserAcceptsFinalAnswersAndNestedToolCalls() throws {
        guard case .success(.final(_, let answer)) = LocalModelActionParser.parse("""
        {"type":"final","answer":"Done from local agent."}
        """) else {
            Issue.record("Expected final local action")
            return
        }
        #expect(answer == "Done from local agent.")

        guard case .success(.toolCall(let id, let tool, let arguments, _)) = LocalModelActionParser.parse("""
        ```json
        {"type":"tool_call","id":"read-1","tool":"workspace.read_file","arguments":{"path":"notes.txt","max_bytes":2048}}
        ```
        """) else {
            Issue.record("Expected tool-call local action")
            return
        }

        #expect(id == "read-1")
        #expect(tool == "workspace.read_file")
        #expect(arguments["path"]?.stringValue == "notes.txt")
        #expect(arguments["max_bytes"]?.intValue == 2_048)
    }

    @Test("Local action parser normalizes tool names used as action type")
    func localActionParserNormalizesToolNamesUsedAsActionType() throws {
        guard case .success(.toolCall(let id, let tool, let arguments, _)) = LocalModelActionParser.parse("""
        {"type":"shell.exec","id":"list-1","command":"/bin/ls -1","cwd":".","timeout_seconds":10,"max_output_bytes":1000}
        """) else {
            Issue.record("Expected shell.exec type alias to parse as a tool call")
            return
        }

        #expect(id == "list-1")
        #expect(tool == "shell.exec")
        #expect(arguments["command"]?.stringValue == "/bin/ls -1")
        #expect(arguments["cwd"]?.stringValue == ".")
        #expect(arguments["timeout_seconds"]?.intValue == 10)
        #expect(arguments["max_output_bytes"]?.intValue == 1_000)

        guard case .success(.toolCall(_, let nestedTool, let nestedArguments, _)) = LocalModelActionParser.parse("""
        {"type":"network.fetch","args":{"url":"https://example.com/data.json","method":"GET"}}
        """) else {
            Issue.record("Expected args alias to parse as tool-call arguments")
            return
        }

        #expect(nestedTool == "network.fetch")
        #expect(nestedArguments["url"]?.stringValue == "https://example.com/data.json")
        #expect(nestedArguments["method"]?.stringValue == "GET")

        guard case .success(.toolCall(_, let aliasTool, let aliasArguments, _)) = LocalModelActionParser.parse("""
        {"type":"tool_call","tool":"shell","arguments":{"command":"/bin/ls -1","cwd":"."}}
        """) else {
            Issue.record("Expected shell tool alias to normalize to shell.exec")
            return
        }

        #expect(aliasTool == "shell.exec")
        #expect(aliasArguments["command"]?.stringValue == "/bin/ls -1")
    }

    @Test("Local JSON integer conversion rejects unsafe finite numbers")
    func localJSONIntegerConversionRejectsUnsafeFiniteNumbers() {
        #expect(LocalModelJSONValue.number(42).intValue == 42)
        #expect(LocalModelJSONValue.number(42.9).intValue == 42)
        #expect(LocalModelJSONValue.string(" 2048 ").intValue == 2_048)
        #expect(LocalModelJSONValue.number(Double.greatestFiniteMagnitude).intValue == nil)
        #expect(LocalModelJSONValue.number(Double.infinity).intValue == nil)
        #expect(LocalModelJSONValue.number(-Double.greatestFiniteMagnitude).intValue == nil)
    }

    @Test("Local action parser accepts blocked and cancelled lifecycle actions")
    func localActionParserAcceptsBlockedAndCancelledLifecycleActions() throws {
        guard case .success(.blocked(let blockedID, let reason)) = LocalModelActionParser.parse("""
        {"type":"blocked","id":"block-1","reason":"Needs a connected Jira account."}
        """) else {
            Issue.record("Expected blocked local action")
            return
        }
        #expect(blockedID == "block-1")
        #expect(reason == "Needs a connected Jira account.")

        guard case .success(.cancelled(let cancelledID, let cancelReason)) = LocalModelActionParser.parse("""
        {"type":"cancelled","id":"cancel-1","reason":"User cancelled the run."}
        """) else {
            Issue.record("Expected cancelled local action")
            return
        }
        #expect(cancelledID == "cancel-1")
        #expect(cancelReason == "User cancelled the run.")
    }

    @Test("Local action parser reports malformed action output")
    func localActionParserReportsMalformedActionOutput() throws {
        guard case .failure(.noJSONObject) = LocalModelActionParser.parse("I will now read the workspace.") else {
            Issue.record("Expected missing JSON action failure")
            return
        }

        guard case .failure(.missingField("answer")) = LocalModelActionParser.parse("""
        {"type":"final","answer":"   "}
        """) else {
            Issue.record("Expected missing final-answer field failure")
            return
        }

        guard case .failure(.unsupportedType("shell")) = LocalModelActionParser.parse("""
        {"type":"shell","command":"rm -rf /"}
        """) else {
            Issue.record("Expected unsupported action type failure")
            return
        }
    }

    @Test("Local agent Qwen prompt adapter uses validated metadata and disables thinking")
    func localAgentQwenPromptAdapterUsesValidatedMetadataAndDisablesThinking() throws {
        let directory = try completeModelDirectory(modelType: "qwen3")
        let messages = LocalAgentPromptAdapter.initialMessages(
            systemPrompt: "Base system.",
            userPrompt: "Do the task.",
            model: "custom-local-model",
            modelDirectory: directory.path
        )

        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("Local Agent model adapter: Qwen."))
        #expect(messages[0].content.contains("Validated model_type: qwen3."))
        #expect(messages[1].role == "user")
        #expect(messages[1].content.hasSuffix("/no_think"))
    }

    @Test("Local agent Llama prompt adapter is explicit and does not add Qwen controls")
    func localAgentLlamaPromptAdapterIsExplicitAndDoesNotAddQwenControls() {
        let adapter = LocalAgentPromptAdapter.adapter(
            model: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelDirectory: ""
        )
        let messages = LocalAgentPromptAdapter.initialMessages(
            systemPrompt: "Base system.",
            userPrompt: "Do the task.",
            model: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelDirectory: ""
        )

        #expect(adapter.family == .llama)
        #expect(adapter.requiresValidatedModelFolder)
        #expect(messages[0].content.contains("Local Agent model adapter: Llama."))
        #expect(messages[0].content.contains("Model family inferred from configured model ID"))
        #expect(!messages[1].content.contains("/no_think"))
    }

    @Test("Local agent treats non-curated model ids as generic")
    func localAgentTreatsNonCuratedModelIdsAsGeneric() {
        let adapter = LocalAgentPromptAdapter.adapter(
            model: "local/custom-mlx-model",
            modelDirectory: ""
        )
        let messages = LocalAgentPromptAdapter.initialMessages(
            systemPrompt: "Base system.",
            userPrompt: "Do the task.",
            model: "local/custom-mlx-model",
            modelDirectory: ""
        )

        #expect(adapter.family == .generic)
        #expect(!adapter.requiresValidatedModelFolder)
        #expect(messages[0].content.contains("Local Agent model adapter: Generic MLX text model."))
        #expect(!messages[1].content.contains("/no_think"))
    }

    @Test("Local Agent branch preflight reports selected workspace is not a git repo")
    func localAgentBranchPreflightReportsSelectedWorkspaceIsNotAGitRepo() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let decision = LocalAgentGitBranchPreflight.decision(
            requestText: "can you see the abailable bracnhes in the repo ?",
            workspacePath: directory.path,
            shellExecutionEnabled: true
        )

        guard case .notGitRepository(let answer) = decision else {
            Issue.record("Expected non-repo branch request to produce a clear local answer.")
            return
        }
        #expect(answer.contains("not a Git repository"))
        #expect(answer.contains(directory.standardizedFileURL.path))
    }

    @Test("Local Agent branch preflight requires explicit git context")
    func localAgentBranchPreflightRequiresExplicitGitContext() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(LocalAgentGitBranchPreflight.decision(
            requestText: "Can you list the available bank branches nearby?",
            workspacePath: directory.path,
            shellExecutionEnabled: true
        ) == nil)

        #expect(LocalAgentGitBranchPreflight.decision(
            requestText: "Can you list the available git branches?",
            workspacePath: directory.path,
            shellExecutionEnabled: true
        ) != nil)
    }

    @Test("Local Agent task output policy treats ASTRA state files as internal")
    func localAgentTaskOutputPolicyTreatsAstraStateFilesAsInternal() {
        #expect(!TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: "current_state.json"))
        #expect(!TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: "session_history.md"))
        #expect(!TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: "turns/turn_001.md"))
        #expect(!TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: ".runtime-bin/astra-local-model"))
        #expect(TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: "beta-soak/report.md"))
    }

    @Test("Local Agent branch preflight requests git branch shell approval in git repo")
    func localAgentBranchPreflightRequestsGitBranchShellApprovalInGitRepo() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let decision = LocalAgentGitBranchPreflight.decision(
            requestText: "Can you list the available branches in this repository?",
            workspacePath: directory.path,
            shellExecutionEnabled: true
        )

        guard case .requestShellApproval(let command, let cwd) = decision else {
            Issue.record("Expected git branch request in a repo to request shell approval.")
            return
        }
        #expect(command == "git branch --all --no-color")
        #expect(cwd == ".")
    }

    @Test("Local Agent branch preflight reports disabled shell commands")
    func localAgentBranchPreflightReportsDisabledShellCommands() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let decision = LocalAgentGitBranchPreflight.decision(
            requestText: "show git branches",
            workspacePath: directory.path,
            shellExecutionEnabled: false
        )

        guard case .shellUnavailable(let answer) = decision else {
            Issue.record("Expected branch request with disabled shell to explain the setting.")
            return
        }
        #expect(answer.contains("shell commands are disabled"))
        #expect(answer.contains("git branch --all --no-color"))
    }

    @MainActor
    @Test("Local Jira search uses configured connector without exposing credentials")
    func localJiraSearchUsesConfiguredConnectorWithoutExposingCredentials() async throws {
        let connector = Connector(
            name: "Team Jira",
            serviceType: "jira",
            baseURL: "https://jira.example.test",
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["STAR"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "secret-token", entityID: entityID, label: nil)

        let transport = LocalJiraSearchMockTransport(body: """
        {
          "issues": [
            {
              "key": "STAR-12246",
              "fields": {
                "summary": "Prepare PAQS response",
                "status": {"name": "In Progress"},
                "assignee": {"displayName": "A. User"},
                "issuetype": {"name": "Story"},
                "updated": "2026-05-28T08:00:00.000-0700"
              }
            }
          ]
        }
        """)
        let service = JiraConnectorSearchService(
            connectors: [connector],
            contextText: "Review STAR work in Jira",
            store: store,
            transport: transport
        )

        let result = await service.search(arguments: [
            "jql": .string("project = STAR ORDER BY updated DESC"),
            "max_results": .number(5)
        ])

        guard case .success(let issues) = result else {
            Issue.record("Expected Jira search success")
            return
        }
        #expect(issues == [
            JiraSearchResult(
                key: "STAR-12246",
                summary: "Prepare PAQS response",
                status: "In Progress",
                assignee: "A. User",
                issueType: "Story",
                updated: "2026-05-28T08:00:00.000-0700"
            )
        ])

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/rest/api/3/search/jql")
        #expect(request.url?.query?.contains("jql=") == true)
        #expect(request.url?.query?.contains("maxResults=5") == true)
        #expect(request.timeoutInterval == JiraConnectorSearchService.requestTimeout)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("secret-token") == false)

        let projectResult = await service.search(arguments: [
            "project": .string(#"STAR" OR updated >= -30d"#),
            "max_results": .number(1)
        ])
        guard case .success = projectResult else {
            Issue.record("Expected quoted Jira project search success")
            return
        }
        let projectRequest = try #require(transport.requests.dropFirst().first)
        let projectItems = URLComponents(url: try #require(projectRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(projectItems.first { $0.name == "jql" }?.value == #"project = "STAR\" OR UPDATED >= -30D" ORDER BY updated DESC"#)

        let observation = JiraConnectorSearchService.observation(from: result)
        #expect(observation.status == "ok")
        #expect(observation.content.contains("STAR-12246"))
        #expect(!observation.content.contains("secret-token"))
    }

    @MainActor
    @Test("Local GitHub search uses configured connector without exposing credentials")
    func localGitHubSearchUsesConfiguredConnectorWithoutExposingCredentials() async throws {
        let connector = Connector(
            name: "Team GitHub",
            serviceType: "github",
            baseURL: "https://api.github.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GITHUB_TOKEN"]
        connector.configKeys = ["GITHUB_REPOS"]
        connector.configValues = ["susom/astra"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GITHUB_TOKEN", value: "secret-github-token", entityID: entityID, label: nil)

        let transport = LocalConnectorSearchMockTransport(body: """
        {
          "items": [
            {
              "number": 92,
              "title": "Add Local MLX provider",
              "state": "open",
              "html_url": "https://github.com/susom/astra/pull/92",
              "repository_url": "https://api.github.com/repos/susom/astra",
              "pull_request": {"html_url": "https://github.com/susom/astra/pull/92"},
              "user": {"login": "alvaro1"},
              "updated_at": "2026-05-28T20:00:00Z"
            }
          ]
        }
        """)
        let service = GitHubConnectorSearchService(
            connectors: [connector],
            contextText: "Review GitHub PRs for ASTRA",
            store: store,
            transport: transport
        )

        let result = await service.search(arguments: [
            "query": .string("local mlx"),
            "type": .string("pr"),
            "state": .string("open"),
            "max_results": .number(5)
        ])

        guard case .success(let items) = result else {
            Issue.record("Expected GitHub search success")
            return
        }
        #expect(items == [
            GitHubSearchResult(
                repository: "susom/astra",
                number: 92,
                title: "Add Local MLX provider",
                state: "open",
                kind: "pull_request",
                author: "alvaro1",
                updated: "2026-05-28T20:00:00Z",
                url: "https://github.com/susom/astra/pull/92"
            )
        ])

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/search/issues")
        let queryItems = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.first { $0.name == "q" }?.value == "local mlx repo:susom/astra is:pr state:open")
        #expect(queryItems.first { $0.name == "per_page" }?.value == "5")
        #expect(request.timeoutInterval == GitHubConnectorSearchService.requestTimeout)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-github-token")

        let observation = GitHubConnectorSearchService.observation(from: result)
        #expect(observation.status == "ok")
        #expect(observation.content.contains("susom/astra#92"))
        #expect(observation.content.contains("Add Local MLX provider"))
        #expect(!observation.content.contains("secret-github-token"))
    }

    @MainActor
    @Test("Local Google Drive search and read use configured connector without exposing credentials")
    func localGoogleDriveSearchAndReadUseConfiguredConnectorWithoutExposingCredentials() async throws {
        let connector = Connector(
            name: "Team Drive",
            serviceType: "google_drive",
            baseURL: "https://www.googleapis.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GOOGLE_DRIVE_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GOOGLE_DRIVE_TOKEN", value: "secret-drive-token", entityID: entityID, label: nil)

        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/drive/v3/files/drive-file-1/export", body: "Launch notes summary\nPrivate details omitted."),
            .init(pathContains: "/drive/v3/files/drive-file-1", body: """
            {
              "id": "drive-file-1",
              "name": "Launch Notes",
              "mimeType": "application/vnd.google-apps.document",
              "webViewLink": "https://drive.google.com/document/d/drive-file-1",
              "modifiedTime": "2026-05-28T18:00:00Z",
              "size": "128"
            }
            """),
            .init(pathContains: "/drive/v3/files", body: """
            {
              "files": [
                {
                  "id": "drive-file-1",
                  "name": "Launch Notes",
                  "mimeType": "application/vnd.google-apps.document",
                  "webViewLink": "https://drive.google.com/document/d/drive-file-1",
                  "modifiedTime": "2026-05-28T18:00:00Z",
                  "owners": [{"displayName": "A. User"}],
                  "size": "128"
                }
              ]
            }
            """)
        ])
        let service = GoogleDriveConnectorSearchService(
            connectors: [connector],
            contextText: "Review launch notes in Google Drive",
            store: store,
            transport: transport
        )

        let searchResult = await service.search(arguments: [
            "query": .string("launch notes"),
            "max_results": .number(5)
        ])
        guard case .success(let files) = searchResult else {
            Issue.record("Expected Google Drive search success")
            return
        }
        #expect(files == [
            GoogleDriveFileSearchResult(
                id: "drive-file-1",
                name: "Launch Notes",
                mimeType: "application/vnd.google-apps.document",
                webViewLink: "https://drive.google.com/document/d/drive-file-1",
                modifiedTime: "2026-05-28T18:00:00Z",
                owner: "A. User",
                size: "128"
            )
        ])

        let readResult = await service.read(arguments: [
            "file_id": .string("drive-file-1"),
            "max_bytes": .number(100)
        ])
        guard case .success(let summary) = readResult else {
            Issue.record("Expected Google Drive read success")
            return
        }
        #expect(summary.text.contains("Launch notes summary"))
        #expect(!summary.truncated)

        let searchRequest = try #require(transport.requests.first)
        #expect(searchRequest.url?.path == "/drive/v3/files")
        let searchItems = URLComponents(url: try #require(searchRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(searchItems.first { $0.name == "q" }?.value == "(name contains 'launch notes' or fullText contains 'launch notes') and trashed = false")
        #expect(searchItems.first { $0.name == "pageSize" }?.value == "5")
        #expect(searchRequest.timeoutInterval == GoogleDriveConnectorSearchService.requestTimeout)
        #expect(searchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-drive-token")

        let exportRequest = try #require(transport.requests.first { $0.url?.path.contains("/export") == true })
        #expect(exportRequest.url?.query?.contains("mimeType=text/plain") == true)

        let searchObservation = GoogleDriveConnectorSearchService.searchObservation(from: searchResult)
        #expect(searchObservation.status == "ok")
        #expect(searchObservation.content.contains("Launch Notes"))
        #expect(searchObservation.content.contains("drive-file-1"))
        #expect(!searchObservation.content.contains("secret-drive-token"))

        let readObservation = GoogleDriveConnectorSearchService.readObservation(from: readResult)
        #expect(readObservation.status == "ok")
        #expect(readObservation.content.contains("Launch notes summary"))
        #expect(!readObservation.content.contains("secret-drive-token"))
    }

    @MainActor
    @Test("Local Google Drive read percent-escapes slash in file id path")
    func localGoogleDriveReadPercentEscapesSlashInFileIDPath() async throws {
        let connector = Connector(
            name: "Team Drive",
            serviceType: "google_drive",
            baseURL: "https://www.googleapis.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GOOGLE_DRIVE_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GOOGLE_DRIVE_TOKEN", value: "secret-drive-token", entityID: entityID, label: nil)

        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/drive/v3/files/drive%2Ffile-1/export", body: "Slash id content"),
            .init(pathContains: "/drive/v3/files/drive%2Ffile-1", body: """
            {
              "id": "drive/file-1",
              "name": "Slash ID Notes",
              "mimeType": "application/vnd.google-apps.document",
              "webViewLink": "https://drive.google.com/document/d/drive%2Ffile-1"
            }
            """)
        ])
        let service = GoogleDriveConnectorSearchService(
            connectors: [connector],
            contextText: "",
            store: store,
            transport: transport
        )

        let result = await service.read(arguments: [
            "file_id": .string("drive/file-1")
        ])

        guard case .success(let summary) = result else {
            Issue.record("Expected Google Drive read success")
            return
        }
        #expect(summary.text.contains("Slash id content"))
        #expect(transport.requests.allSatisfy { $0.url?.absoluteString.contains("drive%2Ffile-1") == true })
    }

    @MainActor
    @Test("Local Gmail search and read use configured connector without exposing credentials")
    func localGmailSearchAndReadUseConfiguredConnectorWithoutExposingCredentials() async throws {
        let connector = Connector(
            name: "Team Gmail",
            serviceType: "gmail",
            baseURL: "https://gmail.googleapis.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GMAIL_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GMAIL_TOKEN", value: "secret-gmail-token", entityID: entityID, label: nil)

        let messageBody = """
        {
          "id": "gmail-msg-1",
          "threadId": "gmail-thread-1",
          "snippet": "Please review the launch meeting summary.",
          "payload": {
            "mimeType": "multipart/alternative",
            "headers": [
              {"name": "Subject", "value": "Launch meeting notes"},
              {"name": "From", "value": "Ada <ada@example.com>"},
              {"name": "To", "value": "Team <team@example.com>"},
              {"name": "Date", "value": "Thu, 28 May 2026 10:00:00 -0700"}
            ],
            "parts": [
              {
                "mimeType": "text/plain",
                "body": {
                  "data": "TGF1bmNoIG1lZXRpbmcgbm90ZXMKUGxlYXNlIHJldmlldyB0aGUgc3VtbWFyeSBiZWZvcmUgRnJpZGF5Lg"
                }
              }
            ]
          }
        }
        """
        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/gmail/v1/users/me/messages/gmail-msg-1", body: messageBody),
            .init(pathContains: "/gmail/v1/users/me/messages", body: """
            {
              "messages": [
                {"id": "gmail-msg-1", "threadId": "gmail-thread-1"}
              ],
              "resultSizeEstimate": 1
            }
            """)
        ])
        let service = GmailConnectorSearchService(
            connectors: [connector],
            contextText: "Find launch meeting notes in Gmail",
            store: store,
            transport: transport
        )

        let searchResult = await service.search(arguments: [
            "query": .string("launch meeting"),
            "max_results": .number(3)
        ])
        guard case .success(let messages) = searchResult else {
            Issue.record("Expected Gmail search success")
            return
        }
        #expect(messages == [
            GmailMessageSearchResult(
                id: "gmail-msg-1",
                threadID: "gmail-thread-1",
                subject: "Launch meeting notes",
                from: "Ada <ada@example.com>",
                to: "Team <team@example.com>",
                date: "Thu, 28 May 2026 10:00:00 -0700",
                snippet: "Please review the launch meeting summary."
            )
        ])

        let readResult = await service.read(arguments: [
            "message_id": .string("gmail-msg-1"),
            "max_bytes": .number(200)
        ])
        guard case .success(let summary) = readResult else {
            Issue.record("Expected Gmail read success")
            return
        }
        #expect(summary.body.contains("Launch meeting notes"))
        #expect(summary.body.contains("Please review the summary before Friday."))
        #expect(!summary.truncated)

        let searchRequest = try #require(transport.requests.first)
        #expect(searchRequest.url?.path == "/gmail/v1/users/me/messages")
        let searchItems = URLComponents(url: try #require(searchRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(searchItems.first { $0.name == "q" }?.value == "launch meeting")
        #expect(searchItems.first { $0.name == "maxResults" }?.value == "3")
        #expect(searchRequest.timeoutInterval == GmailConnectorSearchService.requestTimeout)
        #expect(searchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-gmail-token")

        let metadataRequest = try #require(transport.requests.first { $0.url?.query?.contains("format=metadata") == true })
        #expect(metadataRequest.url?.path == "/gmail/v1/users/me/messages/gmail-msg-1")

        let searchObservation = GmailConnectorSearchService.searchObservation(from: searchResult)
        #expect(searchObservation.status == "ok")
        #expect(searchObservation.content.contains("Launch meeting notes"))
        #expect(searchObservation.content.contains("gmail-msg-1"))
        #expect(!searchObservation.content.contains("secret-gmail-token"))

        let readObservation = GmailConnectorSearchService.readObservation(from: readResult)
        #expect(readObservation.status == "ok")
        #expect(readObservation.content.contains("Please review the summary before Friday."))
        #expect(!readObservation.content.contains("secret-gmail-token"))
    }

    @MainActor
    @Test("Local Gmail search handles empty list payload without messages key")
    func localGmailSearchHandlesEmptyListPayloadWithoutMessagesKey() async throws {
        let connector = Connector(
            name: "Team Gmail",
            serviceType: "gmail",
            baseURL: "https://gmail.googleapis.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GMAIL_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GMAIL_TOKEN", value: "secret-gmail-token", entityID: entityID, label: nil)

        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/gmail/v1/users/me/messages", body: #"{"resultSizeEstimate":0}"#)
        ])
        let service = GmailConnectorSearchService(
            connectors: [connector],
            contextText: "",
            store: store,
            transport: transport
        )

        let result = await service.search(arguments: [
            "query": .string("no matches")
        ])

        guard case .success(let messages) = result else {
            Issue.record("Expected empty Gmail search success")
            return
        }
        #expect(messages.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @MainActor
    @Test("Local Gmail read percent-escapes slash in message id path")
    func localGmailReadPercentEscapesSlashInMessageIDPath() async throws {
        let connector = Connector(
            name: "Team Gmail",
            serviceType: "gmail",
            baseURL: "https://gmail.googleapis.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["GMAIL_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "GMAIL_TOKEN", value: "secret-gmail-token", entityID: entityID, label: nil)

        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/gmail/v1/users/me/messages/gmail%2Fmsg-1", body: """
            {
              "id": "gmail/msg-1",
              "threadId": "gmail-thread-1",
              "snippet": "Slash id message.",
              "payload": {
                "mimeType": "text/plain",
                "headers": [
                  {"name": "Subject", "value": "Slash id"}
                ],
                "body": {
                  "data": "U2xhc2ggaWQgbWVzc2FnZS4"
                }
              }
            }
            """)
        ])
        let service = GmailConnectorSearchService(
            connectors: [connector],
            contextText: "",
            store: store,
            transport: transport
        )

        let result = await service.read(arguments: [
            "message_id": .string("gmail/msg-1")
        ])

        guard case .success(let summary) = result else {
            Issue.record("Expected Gmail read success")
            return
        }
        #expect(summary.body.contains("Slash id message."))
        #expect(transport.requests.allSatisfy { $0.url?.absoluteString.contains("gmail%2Fmsg-1") == true })
    }

    @MainActor
    @Test("Local Slack search and thread use configured connector without exposing credentials")
    func localSlackSearchAndThreadUseConfiguredConnectorWithoutExposingCredentials() async throws {
        let connector = Connector(
            name: "Team Slack",
            serviceType: "slack",
            baseURL: "https://slack.com/api",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["SLACK_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "SLACK_TOKEN", value: "secret-slack-token", entityID: entityID, label: nil)

        let transport = LocalConnectorRouteMockTransport(routes: [
            .init(pathContains: "/conversations.replies", body: """
            {
              "ok": true,
              "messages": [
                {"user": "U123", "username": "ada", "text": "Release notes are ready.", "ts": "1716920000.000100"},
                {"user": "U456", "username": "lin", "text": "I will review before Friday.", "ts": "1716920005.000200"}
              ]
            }
            """),
            .init(pathContains: "/search.messages", body: """
            {
              "ok": true,
              "messages": {
                "matches": [
                  {
                    "iid": "slack-msg-1",
                    "channel": {"id": "C123", "name": "release"},
                    "user": "U123",
                    "username": "ada",
                    "text": "Release notes are ready.",
                    "ts": "1716920000.000100",
                    "permalink": "https://example.slack.com/archives/C123/p1716920000000100"
                  }
                ]
              }
            }
            """)
        ])
        let service = SlackConnectorSearchService(
            connectors: [connector],
            contextText: "Find release notes in Slack",
            store: store,
            transport: transport
        )

        let searchResult = await service.search(arguments: [
            "query": .string("release notes"),
            "max_results": .number(3)
        ])
        guard case .success(let messages) = searchResult else {
            Issue.record("Expected Slack search success")
            return
        }
        #expect(messages == [
            SlackMessageSearchResult(
                id: "slack-msg-1",
                channelID: "C123",
                channelName: "release",
                user: "U123",
                username: "ada",
                text: "Release notes are ready.",
                timestamp: "1716920000.000100",
                permalink: "https://example.slack.com/archives/C123/p1716920000000100"
            )
        ])

        let threadResult = await service.thread(arguments: [
            "channel_id": .string("C123"),
            "thread_ts": .string("1716920000.000100"),
            "max_results": .number(5)
        ])
        guard case .success(let thread) = threadResult else {
            Issue.record("Expected Slack thread success")
            return
        }
        #expect(thread.messages.count == 2)
        #expect(thread.messages.last?.text == "I will review before Friday.")
        #expect(!thread.truncated)

        let searchRequest = try #require(transport.requests.first)
        #expect(searchRequest.url?.path.hasSuffix("/search.messages") == true)
        let searchItems = URLComponents(url: try #require(searchRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(searchItems.first { $0.name == "query" }?.value == "release notes")
        #expect(searchItems.first { $0.name == "count" }?.value == "3")
        #expect(searchRequest.timeoutInterval == SlackConnectorSearchService.requestTimeout)
        #expect(searchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-slack-token")

        let threadRequest = try #require(transport.requests.first { $0.url?.path.hasSuffix("/conversations.replies") == true })
        let threadItems = URLComponents(url: try #require(threadRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(threadItems.first { $0.name == "channel" }?.value == "C123")
        #expect(threadItems.first { $0.name == "ts" }?.value == "1716920000.000100")
        #expect(threadItems.first { $0.name == "limit" }?.value == "5")

        let searchObservation = SlackConnectorSearchService.searchObservation(from: searchResult)
        #expect(searchObservation.status == "ok")
        #expect(searchObservation.content.contains("Release notes are ready."))
        #expect(searchObservation.content.contains("slack-msg-1"))
        #expect(!searchObservation.content.contains("secret-slack-token"))

        let threadObservation = SlackConnectorSearchService.threadObservation(from: threadResult)
        #expect(threadObservation.status == "ok")
        #expect(threadObservation.content.contains("I will review before Friday."))
        #expect(!threadObservation.content.contains("secret-slack-token"))
    }

    @MainActor
    @Test("Local Slack observations normalize and cap message text")
    func localSlackObservationsNormalizeAndCapMessageText() {
        let longText = "First line\nSecond line\t" + String(repeating: "word ", count: 200)
        let searchObservation = SlackConnectorSearchService.searchObservation(from: .success([
            SlackMessageSearchResult(
                id: "slack-msg-long",
                channelID: "C123",
                channelName: "release",
                user: "U123",
                username: "ada",
                text: longText,
                timestamp: "1716920000.000100",
                permalink: nil
            )
        ]))
        let threadObservation = SlackConnectorSearchService.threadObservation(from: .success(SlackThreadSummary(
            channelID: "C123",
            threadTimestamp: "1716920000.000100",
            messages: [
                SlackThreadMessage(
                    user: "U123",
                    username: "ada",
                    text: longText,
                    timestamp: "1716920000.000100"
                )
            ],
            truncated: false
        )))

        #expect(searchObservation.content.contains("First line Second line word"))
        #expect(threadObservation.content.contains("First line Second line word"))
        #expect(!searchObservation.content.contains("First line\nSecond line"))
        #expect(!threadObservation.content.contains("First line\nSecond line"))
        #expect(searchObservation.content.contains("... (truncated)"))
        #expect(threadObservation.content.contains("... (truncated)"))
        #expect(searchObservation.content.count < 700)
        #expect(threadObservation.content.count < 800)
    }

    @Test("Local async tool requests have bounded network timeouts")
    @MainActor
    func localAsyncToolRequestsHaveBoundedNetworkTimeouts() {
        #expect(JiraConnectorSearchService.requestTimeout == 15)
        #expect(GitHubConnectorSearchService.requestTimeout == 15)
        #expect(GoogleDriveConnectorSearchService.requestTimeout == 15)
        #expect(GmailConnectorSearchService.requestTimeout == 15)
        #expect(SlackConnectorSearchService.requestTimeout == 15)
        #expect(LocalAgentToolExecutor.browserRequestTimeout == 15)
    }

    @Test("Local tool observations are compacted before model replay")
    func localToolObservationsAreCompactedBeforeModelReplay() throws {
        let observation = LocalAgentToolObservation(
            status: "ok",
            content: String(repeating: "x", count: 13_000)
        )
        let data = try #require(observation.modelVisibleContent.data(using: .utf8))
        let payload = try JSONDecoder().decode([String: String].self, from: data)

        #expect(payload["status"] == "ok")
        #expect(payload["content"]?.count ?? 0 < 13_000)
        #expect(payload["content"]?.contains("truncated to 12000 characters") == true)
    }

    @Test("Local tool observations keep repository paths readable")
    func localToolObservationsKeepRepositoryPathsReadable() {
        let observation = LocalAgentToolObservation(
            status: "ok",
            content: "- susom/astra#92: Add Local MLX provider"
        )

        #expect(observation.modelVisibleContent.contains("susom/astra#92"))
        #expect(!observation.modelVisibleContent.contains("susom\\/astra#92"))
    }

    @Test("Local reasoning filter removes Qwen think blocks across stream chunks")
    func localReasoningFilterRemovesQwenThinkBlocksAcrossStreamChunks() {
        var filter = LocalModelReasoningFilter()
        var visible = ""
        visible += filter.process(text: "<thi")
        visible += filter.process(text: "nk>\ninternal reasoning")
        visible += filter.process(text: " with details</thi")
        visible += filter.process(text: "nk>\nFinal answer")
        visible += filter.flush()

        #expect(!visible.contains("internal reasoning"))
        #expect(visible == "Final answer")
    }

    @Test("Local reasoning filter removes echoed Local Chat system prompts")
    func localReasoningFilterRemovesEchoedLocalChatSystemPrompts() {
        var filter = LocalModelReasoningFilter()
        var visible = ""
        visible += filter.process(text: "Local Chat Mode:\nThis local model can answer only from text already included in this prompt. ")
        visible += filter.process(text: "It cannot execute shell commands, call connectors, use browser sessions, read or write workspace files, install packages, or create artifacts. ")
        visible += filter.process(text: "If the user asks for external data or an action, say Local Agent/tool execution is not enabled yet and ask them to switch to Claude Code, GitHub Copilot CLI, Google Antigravity CLI, or a future Local Agent mode. ")
        visible += filter.process(text: "Do not claim that you ran a connector, opened a page, read a file, wrote a file, or will proceed to do so.\n")
        visible += filter.process(text: "Unavailable in this Local Chat run: connectors: Jira.\n\nActual answer")
        visible += filter.flush()

        #expect(!visible.contains("Local Chat Mode"))
        #expect(!visible.contains("Unavailable in this Local Chat run"))
        #expect(visible == "Actual answer")
    }

    @Test("Local reasoning filter removes echoed utility system prompts")
    func localReasoningFilterRemovesEchoedUtilitySystemPrompts() {
        let visible = LocalModelReasoningFilter.visibleText(from: """
        You are ASTRA's Private Local Chat utility. Answer only from the prompt text. Do not claim you used files, shell commands, browser sessions, connectors, credentials, or ASTRA tools.

        Utility answer
        """)

        #expect(!visible.contains("Private Local Chat utility"))
        #expect(visible == "Utility answer")
    }

    @Test("Local stream pipeline strips split reasoning tags before recording")
    func localStreamPipelineStripsSplitReasoningTagsBeforeRecording() {
        var pipeline = AgentRuntimeEventPipeline(
            supportsAstraRunProtocol: true,
            stripsReasoningTags: true
        )
        let events = [
            "<thi",
            "nk>hidden local reasoning",
            "</thi",
            "nk>\nHeadless Local MLX response"
        ].flatMap { pipeline.process(AgentEvent.text(text: $0)) } + pipeline.flushAgentEvents()
        let visibleText = events.compactMap { event -> String? in
            if case .text(let text) = event {
                return text
            }
            return nil
        }.joined()

        #expect(!visibleText.contains("hidden local reasoning"))
        #expect(visibleText == "Headless Local MLX response")
    }

    @Test("Model catalog requires config tokenizer weights and supported model type")
    func modelCatalogRequiresConfigTokenizerWeightsAndSupportedModelType() throws {
        let directory = temporaryDirectory()

        #expect(LocalModelCatalog.validate(directory: directory.path).state == .blocked)

        try modelConfig(modelType: "qwen3").write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)
        #expect(report.state == .ready)
        #expect(report.metadata?.modelType == "qwen3")
        #expect(report.detail.contains("qwen3"))
    }

    @Test("Model catalog blocks unsupported architectures before load")
    func modelCatalogBlocksUnsupportedArchitecturesBeforeLoad() throws {
        let directory = temporaryDirectory()
        try modelConfig(modelType: "unknown_research_model").write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(report.state == .blocked)
        #expect(report.detail.contains("unknown_research_model"))
    }

    @Test("Model catalog gives specific guidance for GGUF-only folders")
    func modelCatalogGivesSpecificGuidanceForGGUFOnlyFolders() throws {
        let directory = temporaryDirectory()
        try Data([0]).write(to: directory.appendingPathComponent("gemma-4-E2B-it-Q8_0.gguf"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(report.state == .blocked)
        #expect(report.detail.contains("GGUF files"))
        #expect(report.detail.contains("not MLX model assets"))
        #expect(report.remediation?.contains(LocalMLXRuntime.recommendedModelRepository) == true)
        #expect(report.remediation?.contains(LocalMLXRuntime.recommendedModelsRoot) == true)
    }

    @Test("Model catalog allows supported Gemma 4 multimodal MLX folders before smoke")
    func modelCatalogAllowsSupportedGemma4MultimodalMLXFoldersBeforeSmoke() throws {
        let directory = temporaryDirectory()
        try multimodalGemmaConfig().write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(report.state == .ready)
        #expect(report.detail.contains("gemma4"))
        #expect(report.detail.contains("Multimodal image input is available"))
    }

    @Test("Model catalog supports Gemma 4 folders before smoke")
    func modelCatalogSupportsGemma4FoldersBeforeSmoke() throws {
        let directory = temporaryDirectory()
        try quantizedGemmaPLEConfig().write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(LocalModelArchitectureSupport.isSupported(modelType: "gemma4"))
        #expect(report.state == .ready)
        #expect(report.detail.contains("gemma4"))
    }

    @Test("Model catalog supports text-only Gemma 4 folders before smoke")
    func modelCatalogSupportsTextOnlyGemma4FoldersBeforeSmoke() throws {
        let directory = temporaryDirectory()
        try modelConfig(modelType: "gemma4_text").write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(LocalModelArchitectureSupport.isSupported(modelType: "gemma4_text"))
        #expect(report.state == .ready)
        #expect(report.detail.contains("gemma4_text"))
    }

    @Test("Model catalog blocks Gemma 4 unified folders before smoke")
    func modelCatalogBlocksGemma4UnifiedFoldersBeforeSmoke() throws {
        let directory = temporaryDirectory()
        try gemma4UnifiedConfig().write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(!LocalModelArchitectureSupport.isSupported(modelType: "gemma4_unified"))
        #expect(report.state == .blocked)
        #expect(report.detail.contains("Gemma4UnifiedForConditionalGeneration"))
        #expect(report.detail.contains("not supported"))
        #expect(report.remediation?.contains("Qwen") == true)
    }

    @Test("Model catalog blocks unsupported multimodal model types before smoke")
    func modelCatalogBlocksUnsupportedMultimodalModelTypesBeforeSmoke() throws {
        let directory = temporaryDirectory()
        try unsupportedMultimodalConfig().write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))

        let report = LocalModelCatalog.validate(directory: directory.path)

        #expect(report.state == .blocked)
        #expect(report.detail.contains("multimodal MLX conversion"))
        #expect(report.detail.contains("not supported"))
    }

    @Test("Model catalog scans candidates and imports selected metadata")
    func modelCatalogScansCandidatesAndImportsSelectedMetadata() throws {
        let parent = temporaryDirectory()
        let valid = parent.appendingPathComponent("Qwen 3 4B", isDirectory: true)
        let invalid = parent.appendingPathComponent("Unsupported", isDirectory: true)
        let noise = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try modelConfig(modelType: "qwen3").write(
            to: valid.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: valid.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: valid.appendingPathComponent("model.safetensors"))
        try modelConfig(modelType: "unknown_research_model").write(
            to: invalid.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        let entries = LocalModelCatalog.scan(roots: [parent.path])

        #expect(entries.map(\.displayName) == ["Qwen 3 4B", "Unsupported"])
        #expect(entries.first { $0.directory == valid.standardizedFileURL.path }?.report.state == .ready)
        #expect(entries.first { $0.directory == invalid.standardizedFileURL.path }?.report.state == .blocked)

        let defaultsName = "astra-local-model-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let report = LocalModelCatalog.importModel(directory: valid.path, defaults: defaults)

        #expect(report.state == .ready)
        #expect(LocalModelSettingsStore.modelDirectory(defaults: defaults) == valid.path)
        #expect(LocalModelSettingsStore.selectedModelMetadata(defaults: defaults)?.modelType == "qwen3")
        #expect(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) == 1)

        let blocked = LocalModelCatalog.importModel(
            directory: parent.appendingPathComponent("Moved").path,
            defaults: defaults
        )
        #expect(blocked.state == .blocked)
        #expect(LocalModelSettingsStore.modelDirectory(defaults: defaults) == valid.path)
    }

    @Test("Curated model set uses verified text models only")
    func curatedModelSetUsesVerifiedTextModelsOnly() {
        #expect(LocalMLXRuntime.defaultModels.first == "Qwen/Qwen3-4B-MLX-4bit")
        #expect(LocalMLXRuntime.defaultModels.contains("Qwen/Qwen3-4B-MLX-4bit"))
        #expect(LocalMLXRuntime.defaultModels.contains("Qwen/Qwen3-8B-MLX-4bit"))
        #expect(LocalMLXRuntime.defaultModels.contains("mlx-community/Llama-3.2-3B-Instruct-4bit"))
        #expect(!LocalMLXRuntime.defaultModels.contains("mlx-community/gemma-4-12B-it-4bit"))
        let installableModels = Set(LocalModelInstallCandidate.installCandidates.map(\.runtimeModel))
        for model in LocalMLXRuntime.defaultModels {
            #expect(installableModels.contains(model))
        }
        #expect(LocalMLXRuntime.recommendedDownloadCommand.contains(LocalMLXRuntime.recommendedModelRepository))
        #expect(LocalMLXRuntime.recommendedDownloadCommand.contains(LocalMLXRuntime.recommendedModelDirectory))
        #expect(LocalMLXRuntime.recommendedModelRepository == "Qwen/Qwen3-4B-MLX-4bit")
        #expect(!LocalModelInstallCandidate.installCandidates.contains { $0.repository.contains("lmstudio-community") })
        #expect(!LocalModelInstallCandidate.installCandidates.contains { $0.repository.contains("gemma-4-12B") })
        #expect(LocalModelInstallCandidate.recommended4Bit.reason.contains("Best starting point"))
        #expect(!LocalModelInstallCandidate.recommended4Bit.reason.contains(LocalMLXRuntime.recommendedModelRepository))
        #expect(LocalModelInstallCandidate.qwen8Bit.reason.contains("more memory"))
        #expect(LocalModelInstallCandidate.llamaSmall.reason.contains("lower-memory"))
        #expect(LocalModelInstallCandidate.recommended4Bit.downloadCommand.contains("Qwen/Qwen3-4B-MLX-4bit"))
    }

    @Test("Install recommendations are hardware aware while keeping Qwen as the normal default")
    func installRecommendationsAreHardwareAware() {
        let lowMemory = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 8 * LocalModelMemoryBudget.gib,
            cpuBrand: "Apple M2"
        )
        let minimum = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * LocalModelMemoryBudget.gib,
            cpuBrand: "Apple M2"
        )
        let recommended = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * LocalModelMemoryBudget.gib,
            cpuBrand: "Apple M2 Pro"
        )

        #expect(LocalModelInstallCandidate.recommendedCandidate(for: lowMemory).runtimeModel == LocalModelInstallCandidate.llamaSmall.runtimeModel)
        #expect(LocalModelInstallCandidate.installCandidates(for: lowMemory).map(\.runtimeModel) == [
            LocalModelInstallCandidate.llamaSmall.runtimeModel,
            LocalModelInstallCandidate.recommended4Bit.runtimeModel,
            LocalModelInstallCandidate.qwen8Bit.runtimeModel
        ])
        #expect(LocalModelInstallCandidate.recommendedCandidate(for: minimum).runtimeModel == LocalModelInstallCandidate.recommended4Bit.runtimeModel)
        #expect(LocalModelInstallCandidate.installCandidates(for: minimum).map(\.runtimeModel) == [
            LocalModelInstallCandidate.recommended4Bit.runtimeModel,
            LocalModelInstallCandidate.llamaSmall.runtimeModel,
            LocalModelInstallCandidate.qwen8Bit.runtimeModel
        ])
        #expect(LocalModelInstallCandidate.recommendedCandidate(for: recommended).runtimeModel == LocalModelInstallCandidate.recommended4Bit.runtimeModel)
        #expect(LocalModelInstallCandidate.installCandidates(for: recommended).map(\.runtimeModel) == [
            LocalModelInstallCandidate.recommended4Bit.runtimeModel,
            LocalModelInstallCandidate.qwen8Bit.runtimeModel,
            LocalModelInstallCandidate.llamaSmall.runtimeModel
        ])
        #expect(LocalModelInstallCandidate.recommendedCandidate(for: lowMemory).downloadCommand.contains("Llama-3.2-3B-Instruct-4bit"))
    }

    @Test("Local model choices only expose installed fallback models")
    func localModelChoicesOnlyExposeInstalledFallbackModels() throws {
        let installedDirectory = try completeModelDirectory()
        let missingDirectory = temporaryDirectory().appendingPathComponent("missing-fallback", isDirectory: true)
        let installed = LocalModelInstallCandidate(
            title: "Installed",
            repository: "example/installed",
            localDirectory: installedDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: "example/installed"
        )
        let missing = LocalModelInstallCandidate(
            title: "Missing",
            repository: "example/missing",
            localDirectory: missingDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: "example/missing"
        )

        let choices = LocalModelInstallChoices.selectableRuntimeModels(
            preferredModel: "manual/current",
            candidates: [installed, missing]
        )

        #expect(choices == ["example/installed", "manual/current"])
        #expect(!choices.contains("example/missing"))
    }

    @Test("Local model choices keep Gemma 4 preferred models")
    func localModelChoicesKeepGemma4PreferredModels() throws {
        let root = temporaryDirectory()
        let installedDirectory = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        try writeCompleteModelDirectory(at: installedDirectory)
        let installed = LocalModelInstallCandidate(
            title: "Installed",
            subtitle: "",
            reason: "",
            repository: "example/installed",
            localDirectory: installedDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: "Qwen/Qwen3-4B-MLX-4bit"
        )

        let choices = LocalModelInstallChoices.selectableRuntimeModels(
            preferredModel: "google/gemma-4-e2b-it",
            candidates: [installed]
        )

        #expect(choices == ["Qwen/Qwen3-4B-MLX-4bit", "google/gemma-4-e2b-it"])
        #expect(choices.contains("google/gemma-4-e2b-it"))
    }

    @Test("Selected local model summary distinguishes missing and invalid folders")
    func selectedLocalModelSummaryDistinguishesMissingAndInvalidFolders() throws {
        let root = temporaryDirectory()
        let missing = root.appendingPathComponent("missing-model", isDirectory: true)
        #expect(LocalModelSelectionSummary.summary(directory: "") == "No local model selected yet.")
        #expect(LocalModelSelectionSummary.summary(directory: missing.path).contains("Selected model folder is missing"))

        let invalid = root.appendingPathComponent("invalid-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try "{}".write(to: invalid.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(LocalModelSelectionSummary.summary(directory: invalid.path).contains("needs attention"))
        #expect(LocalModelSelectionSummary.summary(directory: invalid.path).contains("missing tokenizer.json or tokenizer.model"))

        let installed = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        try writeCompleteModelDirectory(at: installed)
        let candidate = LocalModelInstallCandidate(
            title: "Qwen 3 4B",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: installed.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        #expect(LocalModelSelectionSummary.summary(
            directory: installed.path,
            candidates: [candidate]
        ) == "Qwen 3 4B selected.")
    }

    @Test("Installer command downloads through Hugging Face into candidate folder")
    func installerCommandDownloadsThroughHuggingFaceIntoCandidateFolder() {
        let candidate = LocalModelInstallCandidate.recommended4Bit
        let arguments = LocalModelInstaller.installArguments(for: candidate)
        let stagingDirectory = LocalModelInstaller.stagingDirectory(for: candidate)

        #expect(arguments.first == "-c")
        #expect(arguments.contains(candidate.repository))
        #expect(arguments.contains(stagingDirectory))
        #expect(!arguments.contains(candidate.localDirectory))
        #expect(arguments[1].contains("huggingface_hub[hf_xet]"))
        #expect(arguments[1].contains("importlib.util.find_spec"))
        #expect(arguments[1].contains(#"find_spec("hf_xet")"#))
        #expect(arguments[1].contains("resume_download"))
        #expect(arguments[1].contains("--user"))
        #expect(arguments[1].contains("snapshot_download"))
        #expect(arguments[1].contains("allow_patterns"))
        #expect(arguments[1].contains("\"config.json\""))
        #expect(arguments[1].contains("\"tokenizer.json\""))
        #expect(arguments[1].contains("\"*.safetensors\""))
        #expect(arguments[1].contains("\"*.safetensors.index.json\""))
        #expect(arguments[1].contains("\"pytorch_model*.bin\""))
        #expect(candidate.consentMessage.contains("download Qwen 3 4B from Hugging Face"))
        #expect(candidate.consentMessage.contains("select it for Private Local Chat"))
        #expect(!candidate.consentMessage.contains("Python"))
        #expect(!candidate.consentMessage.contains("downloader"))
    }

    @Test("Local helper scanner reports installed models from model folders")
    func localHelperScannerReportsInstalledModelsFromModelFolders() throws {
        let root = temporaryDirectory()
        let qwen = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        try modelConfig(modelType: "qwen3").write(
            to: qwen.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: qwen.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: qwen.appendingPathComponent("model.safetensors"))

        let report = LocalModelListScanner.scan(
            modelsRoot: root.path,
            selectedModelDirectory: qwen.path,
            backend: "scaffold"
        )

        #expect(report.status == "ok")
        #expect(report.models == [
            LocalModelListEntry(
                model: "Qwen/Qwen3-4B-MLX-4bit",
                displayName: "Qwen 3 4B",
                directory: qwen.standardizedFileURL.path,
                selected: true
            )
        ])
    }

    @Test("Local helper scanner reports curated models in stable install order")
    func localHelperScannerReportsCuratedModelsInStableInstallOrder() throws {
        let root = temporaryDirectory()
        let unknown = root.appendingPathComponent("ZZZ-Custom-MLX", isDirectory: true)
        let llama = root.appendingPathComponent("Llama-3.2-3B-Instruct-4bit", isDirectory: true)
        let qwen8 = root.appendingPathComponent("Qwen3-8B-MLX-4bit", isDirectory: true)
        let qwen4 = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        for directory in [unknown, llama, qwen8, qwen4] {
            try writeCompleteModelDirectory(at: directory)
        }
        try modelConfig(modelType: "mistral", modelID: "local/custom-model").write(
            to: unknown.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        let report = LocalModelListScanner.scan(
            modelsRoot: root.path,
            selectedModelDirectory: llama.path,
            backend: "mlx"
        )

        #expect(report.models.map(\.model) == [
            "Qwen/Qwen3-4B-MLX-4bit",
            "Qwen/Qwen3-8B-MLX-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "local/custom-model"
        ])
        #expect(report.models.map(\.selected) == [false, false, true, false])
    }

    @Test("Local model catalog skips hidden install staging folders")
    func localModelCatalogSkipsHiddenInstallStagingFolders() throws {
        let root = temporaryDirectory()
        let installed = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        let staging = root
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("Qwen3-8B-MLX-4bit.partial", isDirectory: true)
        try writeCompleteModelDirectory(at: installed)
        try writeCompleteModelDirectory(at: staging)

        let entries = LocalModelCatalog.scan(roots: [root.path])

        #expect(entries.map(\.directory) == [installed.standardizedFileURL.path])
    }

    @Test("Local helper scanner includes supported Gemma folders and skips unified Gemma")
    func localHelperScannerIncludesSupportedGemmaFoldersAndSkipsUnifiedGemma() throws {
        let root = temporaryDirectory()
        let qwen = root.appendingPathComponent("Qwen3-4B-MLX-4bit", isDirectory: true)
        let quantizedPLE = root.appendingPathComponent("gemma-4-e2b-it-lm-4bit", isDirectory: true)
        let multimodal = root.appendingPathComponent("gemma-4-E2B-it-MLX-4bit", isDirectory: true)
        let textOnly = root.appendingPathComponent("gemma-4-text-mlx", isDirectory: true)
        let gemma12B = root.appendingPathComponent("gemma-4-12B-it-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: quantizedPLE, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: multimodal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textOnly, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gemma12B, withIntermediateDirectories: true)

        try modelConfig(modelType: "qwen3").write(
            to: qwen.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: qwen.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: qwen.appendingPathComponent("model.safetensors"))

        try quantizedGemmaPLEConfig().write(
            to: quantizedPLE.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: quantizedPLE.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: quantizedPLE.appendingPathComponent("model.safetensors"))

        try multimodalGemmaConfig().write(
            to: multimodal.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: multimodal.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: multimodal.appendingPathComponent("model.safetensors"))

        try modelConfig(modelType: "gemma4_text").write(
            to: textOnly.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: textOnly.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: textOnly.appendingPathComponent("model.safetensors"))

        try gemma4UnifiedConfig().write(
            to: gemma12B.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: gemma12B.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: gemma12B.appendingPathComponent("model.safetensors"))

        let report = LocalModelListScanner.scan(
            modelsRoot: root.path,
            selectedModelDirectory: multimodal.path,
            backend: "mlx"
        )

        #expect(report.models.contains(LocalModelListEntry(
            model: "Qwen/Qwen3-4B-MLX-4bit",
            displayName: "Qwen 3 4B",
            directory: qwen.standardizedFileURL.path,
            selected: false
        )))
        #expect(!report.models.contains { $0.model == "mlx-community/gemma-4-12B-it-4bit" })
        #expect(!report.models.contains { $0.directory == gemma12B.standardizedFileURL.path })
        #expect(report.models.contains { $0.directory == multimodal.standardizedFileURL.path && $0.selected })
        #expect(report.models.contains { $0.model == "gemma-4-text-mlx" })
    }

    @Test("Installer validates download and saves selected model folder")
    func installerValidatesDownloadAndSavesSelectedModelFolder() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("installed-model", isDirectory: true)
        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: directory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let runner = RecordingInstallRunner(
            result: RunResult(outcome: .exited(code: 0), stdout: "ok", stderr: ""),
            materializeModelType: "qwen3"
        )
        let installer = LocalModelInstaller(runner: runner)

        let result = try await installer.install(candidate: candidate)

        #expect(result.validationReport.state == .ready)
        #expect(LocalModelSettingsStore.modelDirectory() == directory.path)
        #expect(LocalModelSettingsStore.preferredModel() == LocalMLXRuntime.defaultModel)
        #expect(RuntimeProviderSettingsStore.homeDirectory(for: .localMLX) == directory.path)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
        #expect(!FileManager.default.fileExists(atPath: LocalModelInstaller.stagingDirectory(for: candidate)))
        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.path == LocalModelInstaller.pythonExecutable)
        #expect(calls.first?.args.contains(candidate.repository) == true)
        #expect(calls.first?.args.contains(LocalModelInstaller.stagingDirectory(for: candidate)) == true)
        #expect(calls.first?.args.contains(candidate.localDirectory) == false)
    }

    @Test("Installer reports approximate download progress from staging folder")
    func installerReportsApproximateDownloadProgressFromStagingFolder() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("installed-model", isDirectory: true)
        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: directory.path,
            estimatedSize: "about 1 MB",
            estimatedBytes: 1_000_000,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let runner = ProgressInstallRunner()
        let installer = LocalModelInstaller(runner: runner)
        let recorder = ProgressRecorder()

        let result = try await installer.install(candidate: candidate) { progress in
            await recorder.record(progress)
        }

        #expect(result.validationReport.state == .ready)
        let samples = await recorder.samples()
        #expect(samples.contains { $0.estimatedBytes == candidate.estimatedBytes })
        #expect(samples.contains { $0.downloadedBytes > 0 && ($0.fractionCompleted ?? 0) > 0 })
        #expect(samples.last?.fractionCompleted == 1)
    }

    @Test("Installer checks free disk space before starting large downloads")
    func installerChecksFreeDiskSpaceBeforeStartingLargeDownloads() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("installed-model", isDirectory: true)
        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: directory.path,
            estimatedSize: "about 2 GB",
            estimatedBytes: 2_000_000_000,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let runner = RecordingInstallRunner(
            result: RunResult(outcome: .exited(code: 0), stdout: "ok", stderr: ""),
            materializeModelType: "qwen3"
        )
        let diskSpaceProbe = RecordingDiskSpaceProbe(availableBytes: 1_000_000_000)
        let installer = LocalModelInstaller(
            runner: runner,
            availableDiskSpace: { diskSpaceProbe.availableDiskSpace(for: $0) }
        )

        do {
            _ = try await installer.install(candidate: candidate)
            Issue.record("Expected insufficient disk space")
        } catch let error as LocalModelInstallerError {
            #expect(error == .insufficientDiskSpace(
                requiredBytes: LocalModelInstaller.requiredFreeBytes(for: candidate),
                availableBytes: 1_000_000_000
            ))
            #expect(error.localizedDescription.contains("Not enough free disk space"))
        }

        #expect(await runner.recordedCalls().isEmpty)
        #expect(diskSpaceProbe.checkedPaths() == [
            LocalModelInstaller.diskSpaceCheckPath(for: candidate)
        ])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: LocalModelInstaller.stagingDirectory(for: candidate)))
    }

    @Test("Installer cleans failed partial downloads and preserves current model")
    func installerCleansFailedPartialDownloadsAndPreservesCurrentModel() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let finalDirectory = root.appendingPathComponent("installed-model", isDirectory: true)
        try writeCompleteModelDirectory(at: finalDirectory)
        let marker = finalDirectory.appendingPathComponent("keep.txt")
        try "existing".write(to: marker, atomically: true, encoding: .utf8)

        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: finalDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let staleStagingDirectory = LocalModelInstaller.stagingDirectory(for: candidate)
        try FileManager.default.createDirectory(atPath: staleStagingDirectory, withIntermediateDirectories: true)
        try "stale".write(
            toFile: (staleStagingDirectory as NSString).appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )

        let runner = RecordingInstallRunner(
            result: RunResult(outcome: .exited(code: 17), stdout: "", stderr: "network failed"),
            materializeModelType: "qwen3"
        )
        let installer = LocalModelInstaller(runner: runner)

        do {
            _ = try await installer.install(candidate: candidate)
            Issue.record("Expected failed install")
        } catch let error as LocalModelInstallerError {
            #expect(error == .downloadFailed(code: 17, evidence: "network failed"))
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: staleStagingDirectory))
        #expect(LocalModelSettingsStore.modelDirectory().isEmpty)
    }

    @Test("Installer rolls back previous model when replacement validation fails")
    func installerRollsBackPreviousModelWhenReplacementValidationFails() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let finalDirectory = root.appendingPathComponent("installed-model", isDirectory: true)
        try writeCompleteModelDirectory(at: finalDirectory)
        let marker = finalDirectory.appendingPathComponent("keep.txt")
        try "existing".write(to: marker, atomically: true, encoding: .utf8)

        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: finalDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let stagingDirectory = LocalModelInstaller.stagingDirectory(for: candidate)
        let runner = RecordingInstallRunner(
            result: RunResult(outcome: .exited(code: 0), stdout: "ok", stderr: ""),
            materializeModelType: "qwen3"
        )
        let installer = LocalModelInstaller(
            runner: runner,
            validateModelDirectory: { path, fileManager in
                if URL(fileURLWithPath: path).standardizedFileURL.path
                    == finalDirectory.standardizedFileURL.path {
                    return LocalModelValidationReport(
                        state: .blocked,
                        detail: "Post-move validation failed.",
                        remediation: "Keep the previous local model selected."
                    )
                }
                return LocalModelCatalog.validate(directory: path, fileManager: fileManager)
            }
        )

        do {
            _ = try await installer.install(candidate: candidate)
            Issue.record("Expected post-move validation failure")
        } catch let error as LocalModelInstallerError {
            #expect(error == .validationFailed(LocalModelValidationReport(
                state: .blocked,
                detail: "Post-move validation failed.",
                remediation: "Keep the previous local model selected."
            )))
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory))
        #expect(LocalModelSettingsStore.modelDirectory().isEmpty)
    }

    @Test("Installer cancellation cleans partial download and preserves current model")
    func installerCancellationCleansPartialDownloadAndPreservesCurrentModel() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        let previousHome = RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
        defer {
            restoreSettings()
            RuntimeProviderSettingsStore.setHomeDirectory(previousHome, for: .localMLX)
        }

        let root = temporaryDirectory()
        let finalDirectory = root.appendingPathComponent("installed-model", isDirectory: true)
        try writeCompleteModelDirectory(at: finalDirectory)
        let marker = finalDirectory.appendingPathComponent("keep.txt")
        try "existing".write(to: marker, atomically: true, encoding: .utf8)

        let candidate = LocalModelInstallCandidate(
            title: "Test 4-bit",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: finalDirectory.path,
            estimatedSize: "test",
            estimatedBytes: 100,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
        let stagingDirectory = LocalModelInstaller.stagingDirectory(for: candidate)
        let runner = CancellableInstallRunner()
        let installer = LocalModelInstaller(runner: runner)

        let task = Task {
            try await installer.install(candidate: candidate)
        }
        while await runner.recordedCalls().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled install")
        } catch let error as LocalModelInstallerError {
            #expect(error == .cancelled)
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory))
        #expect(LocalModelSettingsStore.modelDirectory().isEmpty)
    }


    @Test("Settings exposes local model setup guidance")
    func settingsExposesLocalModelSetupGuidance() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/LocalModelRuntime.swift"),
            encoding: .utf8
        )
        let orchestratorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/LocalAgentOrchestrator.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Install local model"))
        #expect(source.contains("localModelRecommendedInstallCandidate"))
        #expect(source.contains("localModelInstallCandidates"))
        #expect(source.contains("LocalModelInstallCandidate.installCandidates(for: localHardwareProfile)"))
        #expect(source.contains("Cancel Download"))
        #expect(source.contains("Retry Download"))
        #expect(source.contains("ProgressView(value: fraction, total: 1)"))
        #expect(source.contains("localModelInstallProgressSummary"))
        #expect(source.contains("localModelInstallProgressState = LocalModelInstallProgress(downloadedBytes: 0, estimatedBytes: candidate.estimatedBytes)"))
        #expect(source.contains(#"localModelInstallStatus.hasPrefix("Installed")"#))
        #expect(source.contains(#"localModelInstallStatus.hasPrefix("Selected")"#))
        #expect(source.contains("LocalModelSelectionSummary.summary(directory: selectedLocalModelDirectory)"))
        #expect(source.contains("lastLocalModelInstallCandidate"))
        #expect(source.contains("startLocalModelInstall"))
        #expect(source.contains("cancelLocalModelInstall"))
        #expect(source.contains("localModelInstallTask?.cancel()"))
        #expect(source.contains("Cancelling local model download and cleaning up partial files"))
        #expect(source.contains("LocalModelInstallerError.cancelled"))
        #expect(source.contains("Private Local Chat only"))
        #expect(source.contains("Enable Local Agent"))
        #expect(source.contains("Private Local Chat stays on this Mac"))
        #expect(source.contains("cannot use tools"))
        #expect(source.contains("Local Agent is experimental"))
        #expect(source.contains("read-only ASTRA-brokered tools by default"))
        #expect(source.contains("enabled below"))
        #expect(source.contains("Approved tool capabilities"))
        #expect(source.contains("Task output writes"))
        #expect(source.contains("Workspace file edits"))
        #expect(source.contains("Shell commands"))
        #expect(source.contains("Network fetches"))
        #expect(source.contains("Browser clicks"))
        #expect(source.contains("Browser typing"))
        #expect(source.contains("Local Agent advanced limits"))
        #expect(source.contains("localAgentWarnings"))
        #expect(source.contains("localAgentWarningMessages"))
        #expect(source.contains("High-risk Local Agent tools enabled"))
        #expect(source.contains("16 GB Macs can try small Local Agent tasks only"))
        #expect(source.contains("32 GB+ is the beta target"))
        #expect(source.contains("below the supported Local Agent tier"))
        #expect(source.contains("ASTRA still asks for scoped approval"))
        #expect(source.contains("Beta soak"))
        #expect(source.contains("LocalAgentBetaSoakStore.report"))
        #expect(source.contains("Copy Beta Evidence"))
        #expect(source.contains("Import Beta Evidence"))
        #expect(source.contains("LocalAgentBetaSoakStore.exportEvidence"))
        #expect(source.contains("LocalAgentBetaSoakStore.mergeEvidence"))
        #expect(orchestratorSource.contains("LocalAgentBetaSoakStore.recordRuntimeSample"))
        #expect(runtimeSource.contains("ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT"))
        #expect(source.contains("Release readiness"))
        #expect(source.contains("LocalModelReleaseGateAudit.checks"))
        #expect(source.contains("localModelReleaseReadinessSummaryView"))
        #expect(source.contains("LocalModelReleaseReadinessSummaryBuilder.summary"))
        #expect(source.contains("Needs evidence"))
        #expect(source.contains("GA ready"))
        #expect(runtimeSource.contains("Not ready for Local MLX general availability"))
        #expect(runtimeSource.contains("Ready for Local MLX general availability"))
        #expect(runtimeSource.contains("Local MLX Release Readiness"))
        #expect(source.contains("localModelReleaseGateRow"))
        #expect(source.contains("Copy Release Evidence"))
        #expect(source.contains("Import Release Evidence"))
        #expect(source.contains("Copy Readiness Summary"))
        #expect(source.contains("copyLocalModelReleaseReadinessSummary"))
        #expect(source.contains("LocalModelReleaseReadinessSummaryBuilder.textReport"))
        #expect(source.contains("Copied Local MLX release-readiness summary."))
        #expect(source.contains("Copy Validation Bundle"))
        #expect(source.contains("Import Validation Bundle"))
        #expect(source.contains("copyLocalModelCombinedReleaseEvidence"))
        #expect(source.contains("importLocalModelCombinedReleaseEvidence"))
        #expect(source.contains("LocalModelCombinedReleaseEvidenceStore.exportEvidence"))
        #expect(source.contains("LocalModelCombinedReleaseEvidenceStore.mergeEvidence"))
        #expect(source.contains("LocalModelReleaseCandidateValidationStore.exportEvidence"))
        #expect(source.contains("LocalModelReleaseCandidateValidationStore.mergeEvidence"))
        #expect(!source.contains("Copy Gemma Evidence"))
        #expect(!source.contains("Import Gemma Evidence"))
        #expect(!source.contains("LocalModelGemmaValidationStore"))
        #expect(!runtimeSource.contains("ASTRA_LOCAL_MLX_GEMMA_EVIDENCE_OUT"))
        let e2eSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/Phase1FunctionalTest.swift"),
            encoding: .utf8
        )
        #expect(e2eSource.contains("ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT"))
        #expect(e2eSource.contains("recordReleaseCandidateValidationSample"))
        #expect(e2eSource.contains("LocalModelReleaseCandidateValidationStore.clear"))
        #expect(source.contains("Agent turns"))
        #expect(source.contains("Tool calls"))
        #expect(source.contains("Tool timeout"))
        #expect(source.contains("Validate This Mac"))
        #expect(source.contains("Coverage"))
        #expect(source.contains("Copy Evidence"))
        #expect(source.contains("Import Evidence"))
        #expect(source.contains("mergeEvidence"))
        #expect(source.contains("runLocalModelValidation"))
        #expect(source.contains("localModelHardwareValidationDetail"))
        #expect(source.contains("More models"))
        #expect(!source.contains("Under validation"))
        #expect(!source.contains("LocalModelDeferredInstallCandidate"))
        #expect(!runtimeSource.contains("LM Studio or llama.cpp"))
        #expect(source.contains("Advanced manual setup"))
        #expect(source.contains("Only installed model IDs appear here"))
        #expect(source.contains("saveLocalModelDirectory"))
        #expect(source.contains("LocalModelCatalog.importModel"))
        #expect(!source.contains("GGUF folders from LM Studio"))
        #expect(!source.contains("Fallback model"))
        #expect(source.contains("Install Local MLX Model"))
        #expect(!source.contains("Terminal commands"))
        #expect(!source.contains("Copy Recommended Command"))
        #expect(!source.contains("Copy Higher Quality Command"))
    }

    @Test("Local settings persist runtime knobs and clamp invalid values")
    func localSettingsPersistRuntimeKnobsAndClampInvalidValues() throws {
        let defaultsName = "astra-local-model-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        defaults.set("Qwen/Qwen3-4B-MLX-4bit", forKey: LocalModelSettingsStore.preferredModelKey)
        defaults.set(512, forKey: LocalModelSettingsStore.maxContextTokensKey)
        defaults.set(16_384, forKey: LocalModelSettingsStore.maxOutputTokensKey)
        defaults.set(9_999, forKey: LocalModelSettingsStore.keepWarmTTLSecondsKey)
        defaults.set(6, forKey: LocalModelSettingsStore.memoryBudgetGBKey)
        defaults.set(0, forKey: LocalModelSettingsStore.localAgentMaxTurnsKey)
        defaults.set(99, forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
        defaults.set(2, forKey: LocalModelSettingsStore.localAgentToolTimeoutSecondsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.shellExecution.settingsKey)
        defaults.set(true, forKey: LocalAgentToolCapability.browserClick.settingsKey)

        #expect(LocalModelSettingsStore.providerEnabled(defaults: defaults, channel: .production) == false)
        #expect(LocalModelSettingsStore.providerEnabled(defaults: defaults, channel: .development) == true)
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        #expect(LocalModelSettingsStore.providerEnabled(defaults: defaults, channel: .production) == true)
        #expect(LocalModelSettingsStore.preferredModel(defaults: defaults) == "Qwen/Qwen3-4B-MLX-4bit")
        #expect(LocalModelSettingsStore.maxContextTokens(defaults: defaults) == 1_024)
        #expect(LocalModelSettingsStore.maxOutputTokens(defaults: defaults) == 8_192)
        #expect(LocalModelSettingsStore.keepWarmTTLSeconds(defaults: defaults) == 3_600)
        #expect(LocalModelSettingsStore.memoryBudgetOverrideGB(defaults: defaults) == 6)
        #expect(LocalModelSettingsStore.memoryBudgetOverrideBytes(defaults: defaults) == 6 * LocalModelMemoryBudget.gib)
        #expect(LocalModelSettingsStore.localAgentMaxTurns(defaults: defaults) == LocalModelSettingsStore.defaultLocalAgentMaxTurns)
        #expect(LocalModelSettingsStore.localAgentMaxToolCalls(defaults: defaults) == 50)
        #expect(LocalModelSettingsStore.localAgentToolTimeoutSeconds(defaults: defaults) == 5)
        let controls = LocalAgentRuntimeControls.current(defaults: defaults)
        #expect(controls.maxTurns == LocalModelSettingsStore.defaultLocalAgentMaxTurns)
        #expect(controls.maxToolCalls == 50)
        #expect(controls.toolTimeoutSeconds == 5)
        let capabilities = LocalModelSettingsStore.localAgentToolCapabilities(defaults: defaults)
        #expect(capabilities.contains(.shellExecution))
        #expect(capabilities.contains(.browserClick))
        #expect(!capabilities.contains(.networkFetch))
        #expect(capabilities.disabledCapability(for: "network.fetch") == .networkFetch)
        #expect(capabilities.disabledCapability(for: "workspace.read_file") == nil)
    }

    @Test("Local Agent prompt only advertises enabled high-risk tools")
    func localAgentPromptOnlyAdvertisesEnabledHighRiskTools() {
        let readOnlyPrompt = LocalAgentOrchestrator.systemPrompt(capabilities: .none)
        #expect(readOnlyPrompt.contains("workspace.read_file"))
        #expect(readOnlyPrompt.contains("browser.analyze"))
        #expect(!readOnlyPrompt.contains(#""tool":"task.write_output""#))
        #expect(!readOnlyPrompt.contains(#""tool":"workspace.write_file""#))
        #expect(!readOnlyPrompt.contains(#""tool":"shell.exec""#))
        #expect(!readOnlyPrompt.contains(#""tool":"network.fetch""#))
        #expect(!readOnlyPrompt.contains(#""tool":"browser.click""#))
        #expect(!readOnlyPrompt.contains(#""tool":"browser.type""#))
        #expect(readOnlyPrompt.contains("Do not request disabled Local Agent capabilities"))

        let fullPrompt = LocalAgentOrchestrator.systemPrompt(capabilities: .all)
        #expect(fullPrompt.contains(#""tool":"task.write_output""#))
        #expect(fullPrompt.contains(#""tool":"workspace.write_file""#))
        #expect(fullPrompt.contains(#""tool":"shell.exec""#))
        #expect(fullPrompt.contains(#""tool":"network.fetch""#))
        #expect(fullPrompt.contains(#""tool":"browser.click""#))
        #expect(fullPrompt.contains(#""tool":"browser.type""#))
        #expect(!fullPrompt.contains("Do not request disabled Local Agent capabilities"))
    }

    @Test("Local Agent beta surface defers browser mutations beyond click and type")
    func localAgentBetaSurfaceDefersBrowserMutationsBeyondClickAndType() throws {
        #expect(LocalAgentBetaToolSurface.readOnlyToolNames.contains("workspace.read_file"))
        #expect(LocalAgentBetaToolSurface.readOnlyToolNames.contains("browser.read_page"))
        #expect(LocalAgentBetaToolSurface.highRiskCapabilities == LocalAgentToolCapability.allCases)
        #expect(LocalAgentBetaToolSurface.browserMutationToolNames == ["browser.click", "browser.type"])
        #expect(LocalAgentBetaToolSurface.deferredBrowserMutationToolNames.contains("browser.navigate"))
        #expect(LocalAgentBetaToolSurface.deferredBrowserMutationToolNames.contains("browser.submit"))
        #expect(Set(LocalAgentBetaToolSurface.browserMutationToolNames).isDisjoint(with: Set(LocalAgentBetaToolSurface.deferredBrowserMutationToolNames)))

        let allCapabilities = LocalAgentToolCapabilities.all.supportedToolNames
        for tool in LocalAgentBetaToolSurface.browserMutationToolNames {
            #expect(allCapabilities.contains(tool))
        }
        for tool in LocalAgentBetaToolSurface.deferredBrowserMutationToolNames {
            #expect(!allCapabilities.contains(tool))
        }

        let prompt = LocalAgentOrchestrator.systemPrompt(capabilities: .all)
        #expect(prompt.contains("Browser changes in Local Agent beta are limited to `browser.click` and `browser.type`"))
        #expect(!prompt.contains(#""tool":"browser.navigate""#))
        #expect(!prompt.contains(#""tool":"browser.submit""#))

        let settingsSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Views/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settingsSource.contains("browser capability"))
        #expect(!settingsSource.contains("browser mutation capability"))
    }

    @Test("Local Agent tool surface audit covers prompt broker policy and capabilities")
    func localAgentToolSurfaceAuditCoversPromptBrokerPolicyAndCapabilities() throws {
        let specs = LocalAgentBetaToolSurface.toolSpecs
        let allToolNames = LocalAgentBetaToolSurface.allToolNames
        let releaseInspector = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_release_readiness.py"),
            encoding: .utf8
        )

        #expect(specs.map(\.name) == allToolNames)
        #expect(Set(allToolNames).count == allToolNames.count)
        #expect(Set(LocalAgentBetaToolSurface.readOnlyToolNames).isDisjoint(with: Set(LocalAgentBetaToolSurface.highRiskToolNames)))

        for tool in LocalAgentBetaToolSurface.readOnlyToolNames {
            let spec = try #require(LocalAgentBetaToolSurface.spec(for: tool))
            #expect(spec.capability == nil)
            #expect(LocalAgentToolCapability.capability(for: tool) == nil)
        }
        for capability in LocalAgentBetaToolSurface.highRiskCapabilities {
            let spec = try #require(LocalAgentBetaToolSurface.spec(for: capability.toolName))
            #expect(spec.capability == capability)
            #expect(LocalAgentToolCapability.capability(for: capability.toolName) == capability)
            #expect(capability.settingsKey.contains("astra.localModel.localAgent.capability"))
        }
        for tool in LocalAgentBetaToolSurface.deferredBrowserMutationToolNames {
            #expect(LocalAgentBetaToolSurface.spec(for: tool) == nil)
            #expect(!allToolNames.contains(tool))
        }

        let readOnlyPrompt = LocalAgentOrchestrator.systemPrompt(capabilities: .none)
        for tool in LocalAgentBetaToolSurface.readOnlyToolNames {
            #expect(readOnlyPrompt.contains(#""tool":"\#(tool)""#), "Prompt is missing read-only tool \(tool)")
        }
        for tool in LocalAgentBetaToolSurface.highRiskToolNames {
            #expect(!readOnlyPrompt.contains(#""tool":"\#(tool)""#), "Read-only prompt advertised gated tool \(tool)")
            #expect(releaseInspector.contains(#""\#(tool)""#), "Release readiness inspector is missing required high-risk tool \(tool)")
        }
        for tool in LocalAgentBetaToolSurface.readOnlyToolNames {
            #expect(releaseInspector.contains(#""\#(tool)""#), "Release readiness inspector is missing read-only tool \(tool)")
        }

        let fullPrompt = LocalAgentOrchestrator.systemPrompt(capabilities: .all)
        for tool in allToolNames {
            #expect(fullPrompt.contains(#""tool":"\#(tool)""#), "Full Local Agent prompt is missing \(tool)")
        }

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/LocalAgentOrchestrator.swift"),
            encoding: .utf8
        )
        let brokerSwitch = sourceSlice(source, from: "func execute(\n        callID", to: "    private func readFile")
        let policySwitch = sourceSlice(source, from: "private static func policyToolName", to: "private static func policyInput")
        let explicitApprovalSwitch = sourceSlice(
            source,
            from: "private static func localAgentExplicitApprovalRequest",
            to: "private static func localAgentExplicitApprovalName"
        )
        let fallbackApprovalMapping = sourceSlice(
            source,
            from: "private static func fallbackPermissionRequest",
            to: "private static func workspaceWriteDiffPreview"
        )
        for tool in allToolNames {
            #expect(brokerSwitch.contains(#"case "\#(tool)":"#), "Broker executor is missing \(tool)")
            #expect(policySwitch.contains(#""\#(tool)""#), "Policy mapping is missing \(tool)")
        }
        #expect(explicitApprovalSwitch.contains(#"case "task.write_output":"#))
        #expect(explicitApprovalSwitch.contains(#"case "workspace.write_file":"#))
        #expect(fallbackApprovalMapping.contains(#"tool == "task.write_output" || tool == "workspace.write_file""#))
    }

    @Test("Local MLX release gate audit reflects current shipping boundaries")
    func localMLXReleaseGateAuditReflectsCurrentShippingBoundaries() throws {
        let defaultsName = "astra-local-release-gates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let gates = LocalModelReleaseGateAudit.checks(defaults: defaults)
        #expect(gates.map(\.id) == [
            "gate-a-local-chat-preview",
            "gate-b-local-agent-developer-flag",
            "gate-c-local-agent-beta",
            "gate-d-general-availability"
        ])

        let gateA = try #require(gates.first { $0.id == "gate-a-local-chat-preview" })
        let gateB = try #require(gates.first { $0.id == "gate-b-local-agent-developer-flag" })
        let gateC = try #require(gates.first { $0.id == "gate-c-local-agent-beta" })
        let gateD = try #require(gates.first { $0.id == "gate-d-general-availability" })

        #expect(gateA.status == .inProgress)
        #expect(gateA.blockers.contains { $0.contains("Private Local Chat release-candidate live e2e") })
        #expect(gateA.evidence.contains { $0.contains("No Private Local Chat release-candidate live e2e evidence") })
        #expect(gateB.status == .inProgress)
        #expect(gateB.blockers.contains { $0.contains("Local Agent read-only release-candidate live e2e") })
        #expect(gateB.evidence.contains { $0.contains("experimental tools flag") })
        #expect(gateB.evidence.contains { $0.contains("No Local Agent read-only release-candidate live e2e evidence") })
        #expect(gateC.status == .inProgress)
        #expect(gateC.blockers.contains { $0.contains("broader beta soak") })
        #expect(gateC.blockers.contains { $0.contains("read-only Local Agent workflow") })
        #expect(gateC.evidence.contains { $0.contains("Beta-soak samples: 0 total") })
        #expect(gateC.evidence.contains { $0 == "Covered high-risk tools: none." })
        #expect(gateC.evidence.contains { $0.contains("Missing high-risk tools: task.write_output") })
        #expect(gateD.status == .inProgress)
        #expect(gateD.evidence.contains { $0.contains("Release packaging preflight: unavailable") })
        #expect(gateD.blockers.contains { $0.contains("Missing sustained local-model validation") })
        #expect(gateD.blockers.contains { $0.contains("Missing release-candidate live validation") })
        #expect(gateD.blockers.contains { $0.contains("Complete Gate C beta-soak evidence") })
        #expect(gateD.evidence.contains { $0.contains("Gate C beta-soak status: incomplete") })
        #expect(gateD.evidence.contains { $0.contains("Next beta collection: run script/local_mlx_collect_release_evidence.sh") })
        #expect(gateD.evidence.contains { $0.contains("--include-high-risk-tools") })
        #expect(gateD.evidence.contains { $0 == "Covered hardware tiers: none." })
        #expect(gateD.evidence.contains { $0.contains("Missing hardware tiers: 32 GB+ Pro-class") })
        #expect(gateD.evidence.contains { $0 == "Covered release-candidate modes: none." })
        #expect(gateD.evidence.contains { $0.contains("Missing release-candidate modes: Private Local Chat live e2e") })
        #expect(gateD.evidence.contains { $0.contains("Missing build-bound release-candidate modes: Private Local Chat live e2e") })
        #expect(gateD.evidence.contains { $0.contains("Next release-candidate collection: run script/local_mlx_collect_release_evidence.sh") })
        #expect(gateD.evidence.contains { $0.contains("--out /tmp/astra-local-mlx-release-evidence.json") })
        #expect(gateD.evidence.contains { $0 == "No build-bound release-candidate evidence." })
        #expect(gateD.evidence.contains { $0.contains("Qwen/Qwen3-4B-MLX-4bit") })
        let initialSummary = LocalModelReleaseReadinessSummaryBuilder.summary(for: gates)
        #expect(initialSummary.isReadyForGA == false)
        #expect(initialSummary.title == "Not ready for Local MLX general availability")
        #expect(initialSummary.detail == "0 of 4 Local MLX release gates have required evidence.")
        #expect(initialSummary.nextAction?.contains("Next actions (") == true)
        #expect(initialSummary.nextAction?.contains("Private Local Chat release-candidate live e2e") == true)
        #expect(initialSummary.nextAction?.contains("Local Agent read-only release-candidate live e2e") == true)
        #expect(initialSummary.nextAction?.contains("Complete Gate C beta-soak evidence") == true)
        #expect(initialSummary.nextAction?.contains("Missing sustained local-model validation") == true)
        let initialTextReport = LocalModelReleaseReadinessSummaryBuilder.textReport(for: gates)
        #expect(initialTextReport.contains("Local MLX Release Readiness"))
        #expect(initialTextReport.contains("Not ready for Local MLX general availability"))
        #expect(initialTextReport.contains("Next actions ("))
        #expect(initialTextReport.contains("Gate A: Local Chat preview: in progress"))
        #expect(initialTextReport.contains("Blockers:"))
        #expect(initialTextReport.contains("Private Local Chat release-candidate live e2e"))
        let inconsistentPassedGate = LocalModelReleaseReadinessSummaryBuilder.summary(for: [
            LocalModelReleaseGateCheck(
                id: "inconsistent",
                title: "Inconsistent gate",
                status: .passed,
                evidence: ["Test evidence."],
                blockers: ["Resolve inconsistent release evidence before GA."]
            )
        ])
        #expect(inconsistentPassedGate.isReadyForGA == false)
        #expect(inconsistentPassedGate.nextAction?.contains("Resolve inconsistent release evidence before GA.") == true)

        LocalAgentBetaSoakStore.record(betaSoakSample(successfulTools: ["workspace.read_file"]), defaults: defaults)
        for tool in LocalAgentBetaToolSurface.highRiskToolNames {
            LocalAgentBetaSoakStore.record(betaSoakSample(successfulTools: [tool]), defaults: defaults)
        }
        let betaReadyGate = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-c-local-agent-beta" }
        )
        #expect(betaReadyGate.status == .passed)
        #expect(betaReadyGate.blockers.isEmpty)
        #expect(betaReadyGate.evidence.contains { $0.contains("every high-risk beta tool") })
        #expect(betaReadyGate.evidence.contains { $0.contains("Covered high-risk tools: task.write_output") })
        #expect(betaReadyGate.evidence.contains { $0 == "Missing high-risk tools: none." })

        let gib = LocalModelMemoryBudget.gib
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
            defaults: defaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: defaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: defaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: defaults
        )

        let gateDWithoutReleaseEvidence = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-d-general-availability" }
        )
        #expect(gateDWithoutReleaseEvidence.status == .inProgress)
        #expect(!gateDWithoutReleaseEvidence.blockers.contains { $0.contains("Complete Gate C beta-soak evidence") })
        #expect(!gateDWithoutReleaseEvidence.blockers.contains { $0.contains("Missing sustained local-model validation") })
        #expect(!gateDWithoutReleaseEvidence.blockers.contains { $0.contains("Gemma 4 E2B") })
        #expect(gateDWithoutReleaseEvidence.blockers.contains { $0.contains("Missing release-candidate live validation") })
        #expect(gateDWithoutReleaseEvidence.blockers.contains { $0.contains("Missing build-bound release-candidate evidence") })
        #expect(gateDWithoutReleaseEvidence.evidence.contains { $0.contains("Covered hardware tiers: 32 GB+ Pro-class") })
        #expect(gateDWithoutReleaseEvidence.evidence.contains { $0 == "Missing hardware tiers: none." })
        #expect(gateDWithoutReleaseEvidence.evidence.contains { $0 == "Next hardware collection: none." })

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat, inputTokens: 0),
            defaults: defaults
        )
        let invalidChatGateA = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-a-local-chat-preview" }
        )
        #expect(invalidChatGateA.status == .inProgress)
        #expect(invalidChatGateA.blockers.contains { $0.contains("Private Local Chat release-candidate live e2e") })

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat),
            defaults: defaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly),
            defaults: defaults
        )
        let unboundGateD = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-d-general-availability" }
        )
        #expect(unboundGateD.status == .inProgress)
        #expect(unboundGateD.blockers.contains { $0.contains("Missing build-bound release-candidate evidence") })
        #expect(unboundGateD.evidence.contains { $0 == "Missing release-candidate modes: none." })
        #expect(unboundGateD.evidence.contains { $0.contains("Missing build-bound release-candidate modes: Private Local Chat live e2e") })
        #expect(unboundGateD.evidence.contains { $0.contains("Next release-candidate collection: run script/local_mlx_collect_release_evidence.sh") })
        #expect(unboundGateD.evidence.contains { $0 == "No build-bound release-candidate evidence." })

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+1"),
            defaults: defaults
        )
        let chatReadyGateA = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-a-local-chat-preview" }
        )
        let unboundAgentGateB = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-b-local-agent-developer-flag" }
        )
        #expect(chatReadyGateA.status == .passed)
        #expect(chatReadyGateA.blockers.isEmpty)
        #expect(chatReadyGateA.evidence.contains { $0.contains("Private Local Chat release-candidate live e2e evidence is recorded") })
        #expect(unboundAgentGateB.status == .passed)
        #expect(unboundAgentGateB.blockers.isEmpty)

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1"),
            defaults: defaults
        )
        let agentReadyGateB = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-b-local-agent-developer-flag" }
        )
        #expect(agentReadyGateB.status == .passed)
        #expect(agentReadyGateB.blockers.isEmpty)
        #expect(agentReadyGateB.evidence.contains { $0.contains("Local Agent read-only release-candidate live e2e evidence is recorded") })

        let completeEvidenceDefaultsName = "astra-local-ga-without-beta-\(UUID().uuidString)"
        let completeEvidenceDefaults = try #require(UserDefaults(suiteName: completeEvidenceDefaultsName))
        defer { completeEvidenceDefaults.removePersistentDomain(forName: completeEvidenceDefaultsName) }
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
            defaults: completeEvidenceDefaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: completeEvidenceDefaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: completeEvidenceDefaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed, iterations: 3, durationSeconds: 900),
            defaults: completeEvidenceDefaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+1"),
            defaults: completeEvidenceDefaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1"),
            defaults: completeEvidenceDefaults
        )
        let noBetaGateD = try #require(
            LocalModelReleaseGateAudit.checks(defaults: completeEvidenceDefaults)
                .first { $0.id == "gate-d-general-availability" }
        )
        #expect(noBetaGateD.status == .inProgress)
        #expect(noBetaGateD.blockers == ["Complete Gate C beta-soak evidence before claiming Local MLX general availability."])
        #expect(noBetaGateD.evidence.contains { $0.contains("Gate C beta-soak status: incomplete") })
        #expect(noBetaGateD.evidence.contains { $0.contains("Next beta collection: run script/local_mlx_collect_release_evidence.sh") })
        #expect(noBetaGateD.evidence.contains { $0.contains("--beta-out /tmp/astra-local-agent-beta-soak-evidence.json") })
        #expect(noBetaGateD.evidence.contains { $0 == "Missing hardware tiers: none." })
        #expect(noBetaGateD.evidence.contains { $0 == "Missing build-bound release-candidate modes: none." })

        let gaReadyGate = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-d-general-availability" }
        )
        #expect(gaReadyGate.status == .passed)
        #expect(gaReadyGate.blockers.isEmpty)
        #expect(gaReadyGate.evidence.contains { $0.contains("all required Mac tiers") })
        #expect(gaReadyGate.evidence.contains { $0 == "Next beta collection: none." })
        #expect(gaReadyGate.evidence.contains { $0.contains("Private Local Chat and Local Agent read-only e2e") })
        #expect(gaReadyGate.evidence.contains { $0 == "Missing hardware tiers: none." })
        #expect(gaReadyGate.evidence.contains { $0 == "Next hardware collection: none." })
        #expect(gaReadyGate.evidence.contains { $0 == "Release-candidate build ids: astra-0.1.0+1." })
        #expect(gaReadyGate.evidence.contains { $0 == "Missing release-candidate modes: none." })
        #expect(gaReadyGate.evidence.contains { $0 == "Missing build-bound release-candidate modes: none." })
        #expect(gaReadyGate.evidence.contains { $0 == "Next release-candidate collection: none." })
        #expect(gaReadyGate.evidence.contains { $0.contains("Qwen/Qwen3-4B-MLX-4bit") })
        #expect(gaReadyGate.evidence.contains { $0.contains("ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1") })
        #expect(gaReadyGate.evidence.contains { $0.contains("ASTRA_LOCAL_MLX_RELEASE_BUILD_ID=astra-0.1.0+1") })
        #expect(gaReadyGate.evidence.contains { $0.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json") })
        #expect(gaReadyGate.evidence.contains { $0.contains("script/release_update.sh") })
        let readySummary = LocalModelReleaseReadinessSummaryBuilder.summary(
            for: LocalModelReleaseGateAudit.checks(defaults: defaults)
        )
        #expect(readySummary.isReadyForGA)
        #expect(readySummary.title == "Ready for Local MLX general availability")
        #expect(readySummary.detail == "All 4 Local MLX release gates have required evidence.")
        #expect(readySummary.nextAction == nil)
        let readyTextReport = LocalModelReleaseReadinessSummaryBuilder.textReport(
            for: LocalModelReleaseGateAudit.checks(defaults: defaults)
        )
        #expect(readyTextReport.contains("Ready for Local MLX general availability"))
        #expect(readyTextReport.contains("Gate D: General availability: passed"))
        #expect(readyTextReport.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json"))
        #expect(!readyTextReport.contains("Blockers:"))

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(
                mode: .localChat,
                model: "Qwen/Qwen3-8B-MLX-4bit",
                buildIdentifier: "astra-0.1.0+1"
            ),
            defaults: defaults
        )
        let dirtyEvidenceGateD = try #require(
            LocalModelReleaseGateAudit.checks(defaults: defaults)
                .first { $0.id == "gate-d-general-availability" }
        )
        #expect(dirtyEvidenceGateD.status == .inProgress)
        #expect(dirtyEvidenceGateD.blockers.contains { $0.contains("non-covering release-candidate evidence") })
        #expect(dirtyEvidenceGateD.evidence.contains { $0.contains("1 release-candidate sample(s) do not count") })
        #expect(dirtyEvidenceGateD.evidence.contains { $0.contains("Release packaging preflight: unavailable") })
        let dirtySummary = LocalModelReleaseReadinessSummaryBuilder.summary(
            for: LocalModelReleaseGateAudit.checks(defaults: defaults)
        )
        #expect(!dirtySummary.isReadyForGA)
        #expect(dirtySummary.nextAction?.contains("non-covering release-candidate evidence") == true)
    }

    @Test("Local MLX fixed bug regression audit stays covered")
    func localMLXFixedBugRegressionAuditStaysCovered() throws {
        let testSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/LocalModelRuntimeTests.swift"),
            encoding: .utf8
        )
        let phase1Source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/Phase1FunctionalTest.swift"),
            encoding: .utf8
        )
        let coverage: [(bug: String, source: String, requiredTest: String)] = [
            ("GGUF folders from third-party apps were accepted as MLX assets", testSource, "Model catalog gives specific guidance for GGUF-only folders"),
            ("unsupported multimodal folders reached native smoke", testSource, "Model catalog blocks unsupported multimodal model types before smoke"),
            ("supported multimodal Gemma 4 folders were blocked before smoke", testSource, "Model catalog allows supported Gemma 4 multimodal MLX folders before smoke"),
            ("text-only Gemma 4 folders were blocked before smoke", testSource, "Model catalog supports text-only Gemma 4 folders before smoke"),
            ("Gemma 4 Unified folders reached native smoke", testSource, "Model catalog blocks Gemma 4 unified folders before smoke"),
            ("supported Gemma folders were hidden from selectable models", testSource, "Local helper scanner includes supported Gemma folders and skips unified Gemma"),
            ("Gemma 4 12B could be recommended without enough memory", testSource, "Memory budget requires 32 GB tier for Gemma 4 12B"),
            ("clipboard and file picker image inputs were dropped from local model requests", testSource, "Adapter writes image attachments from task inputs into local model request"),
            ("failed installs could leave partial models or replace the selected model", testSource, "Installer cleans failed partial downloads and preserves current model"),
            ("cancelled installs could leave partial models or replace the selected model", testSource, "Installer cancellation cleans partial download and preserves current model"),
            ("one-click installs could start large downloads without enough free disk space", testSource, "Installer checks free disk space before starting large downloads"),
            ("MLX diagnostics around smoke JSON hid valid readiness results", testSource, "Readiness parses structured smoke failure from helper"),
            ("missing metallib was reported as a generic model failure", testSource, "Readiness reports missing Metal shader library as helper packaging failure"),
            ("readiness copy exposed implementation wording to users", testSource, "Local MLX readiness copy stays user-facing"),
            ("Qwen thinking tags leaked into visible output", testSource, "Local reasoning filter removes Qwen think blocks across stream chunks"),
            ("echoed Local Chat system prompts leaked into visible output", testSource, "Local reasoning filter removes echoed Local Chat system prompts"),
            ("echoed utility prompts leaked into visible output", testSource, "Local reasoning filter removes echoed utility system prompts"),
            ("split reasoning tags were recorded before cleanup", testSource, "Local stream pipeline strips split reasoning tags before recording"),
            ("local model choices exposed uninstalled fallback models", testSource, "Local model choices only expose installed fallback models"),
            ("local runtime model menu ignored installed helper models", testSource, "Model availability for local runtime comes from helper installed models"),
            ("local policy asked for unsupported broad provider grants", testSource, "Local policy never grants broad provider permissions"),
            ("credential redaction policy blocked Local MLX before launch", testSource, "Local policy treats credential redaction as ASTRA-managed warning"),
            ("Local Agent could advertise high-risk tools when disabled", testSource, "Local Agent prompt only advertises enabled high-risk tools"),
            ("unsupported browser mutations could slip into the beta surface", testSource, "Local Agent beta surface defers browser mutations beyond click and type"),
            ("tool broker and policy mappings drifted apart", testSource, "Local Agent tool surface audit covers prompt broker policy and capabilities"),
            ("branch listing requests could ask vague clarification instead of checking git state", testSource, "Local Agent branch preflight reports selected workspace is not a git repo"),
            ("Gate C could be marked beta-ready without required tool coverage", testSource, "Local Agent beta soak report tracks required tool coverage"),
            ("release gates could pass without live Local Chat and Agent evidence", testSource, "Release candidate validation evidence exports and gates GA live e2e"),
            ("hardware validation could pass without representative tiers", testSource, "Hardware validation matrix reports missing sustained Mac tiers"),
            ("low-memory sustained validation launched the helper unnecessarily", testSource, "Sustained validation records expected low-memory blocks without launching the helper"),
            ("live high-risk Local Agent task output approval could regress", phase1Source, "Local MLX Agent → task output write approval loop"),
            ("live high-risk Local Agent workspace write approval could regress", phase1Source, "Local MLX Agent → workspace write approval loop"),
            ("live high-risk Local Agent shell approval could regress", phase1Source, "Local MLX Agent → shell exec approval loop"),
            ("live high-risk Local Agent network approval could regress", phase1Source, "Local MLX Agent → network fetch approval loop"),
            ("live high-risk Local Agent browser click approval could regress", phase1Source, "Local MLX Agent → browser click approval loop"),
            ("live high-risk Local Agent browser type approval could regress", phase1Source, "Local MLX Agent → browser type approval loop")
        ]

        for item in coverage {
            #expect(
                item.source.contains(item.requiredTest),
                "Missing Local MLX regression coverage for fixed bug: \(item.bug). Expected test containing: \(item.requiredTest)"
            )
        }
    }

    @Test("Release candidate validation evidence exports and gates GA live e2e")
    func releaseCandidateValidationEvidenceExportsAndGatesGALiveE2E() throws {
        let sourceDefaultsName = "astra-local-release-evidence-export-\(UUID().uuidString)"
        let targetDefaultsName = "astra-local-release-evidence-import-\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceDefaultsName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetDefaultsName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceDefaultsName)
            targetDefaults.removePersistentDomain(forName: targetDefaultsName)
        }

        #expect(throws: LocalModelReleaseCandidateValidationExchangeError.self) {
            _ = try LocalModelReleaseCandidateValidationStore.exportEvidence(defaults: sourceDefaults)
        }

        let chat = releaseCandidateSample(mode: .localChat)
        var chatRerun = chat
        chatRerun.recordedAt = Date(timeIntervalSince1970: 3_999)
        chatRerun.inputTokens = 14
        let agent = releaseCandidateSample(mode: .localAgentReadOnly)
        LocalModelReleaseCandidateValidationStore.record(chat, defaults: sourceDefaults)
        LocalModelReleaseCandidateValidationStore.record(chatRerun, defaults: sourceDefaults)
        LocalModelReleaseCandidateValidationStore.record(agent, defaults: sourceDefaults)
        #expect(LocalModelReleaseCandidateValidationStore.samples(defaults: sourceDefaults) == [chatRerun, agent])

        let report = LocalModelReleaseCandidateValidationStore.report(defaults: sourceDefaults)
        #expect(report.isCompleteForGA)
        #expect(!report.isBuildBoundCompleteForGA)
        #expect(report.coveredModes == [.localChat, .localAgentReadOnly])
        #expect(report.missingBuildBoundModes == [.localChat, .localAgentReadOnly])
        #expect(report.buildIdentifierSummary == "No build-bound release-candidate evidence.")

        let payload = try LocalModelReleaseCandidateValidationStore.exportEvidence(
            defaults: sourceDefaults,
            exportedAt: Date(timeIntervalSince1970: 3_300)
        )
        #expect(payload.contains(#""schemaVersion" : 1"#))
        #expect(payload.contains("local_agent_read_only"))

        let firstMerge = try LocalModelReleaseCandidateValidationStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(firstMerge.importedCount == 2)
        #expect(firstMerge.skippedCount == 0)
        #expect(firstMerge.report.isCompleteForGA)

        let duplicateMerge = try LocalModelReleaseCandidateValidationStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(duplicateMerge.importedCount == 0)
        #expect(duplicateMerge.skippedCount == 2)
        #expect(LocalModelReleaseCandidateValidationStore.samples(defaults: targetDefaults) == [chatRerun, agent])
        #expect(LocalModelSettingsStore.persistedKeys.contains(LocalModelReleaseCandidateValidationStore.samplesKey))

        let buildDefaultsName = "astra-local-release-evidence-build-ids-\(UUID().uuidString)"
        let buildDefaults = try #require(UserDefaults(suiteName: buildDefaultsName))
        defer { buildDefaults.removePersistentDomain(forName: buildDefaultsName) }
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+2"),
            defaults: buildDefaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1"),
            defaults: buildDefaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: " astra-0.1.0+1 "),
            defaults: buildDefaults
        )
        #expect(
            LocalModelReleaseCandidateValidationStore.report(defaults: buildDefaults).buildIdentifierSummary ==
            "Release-candidate build ids: astra-0.1.0+1, astra-0.1.0+2."
        )
        #expect(LocalModelReleaseCandidateValidationStore.report(defaults: buildDefaults).isBuildBoundCompleteForGA)

        #expect(throws: LocalModelReleaseCandidateValidationExchangeError.self) {
            _ = try LocalModelReleaseCandidateValidationStore.mergeEvidence(
                #"{"schemaVersion":99,"exportedAt":"2026-05-28T00:00:00Z","samples":[]}"#,
                defaults: targetDefaults
            )
        }
    }

    @Test("Local Agent beta soak report tracks required tool coverage")
    func localAgentBetaSoakReportTracksRequiredToolCoverage() throws {
        let defaultsName = "astra-local-agent-beta-soak-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let readOnly = betaSoakSample(successfulTools: ["workspace.read_file"])
        let wrongModelReadOnly = betaSoakSample(
            successfulTools: ["workspace.read_file"],
            model: "Qwen/Qwen3-8B-MLX-4bit"
        )
        let wrongModelShell = betaSoakSample(
            successfulTools: ["shell.exec"],
            model: "Qwen/Qwen3-8B-MLX-4bit"
        )
        let wrongModelReport = LocalAgentBetaSoakMatrix.report(samples: [
            wrongModelReadOnly,
            wrongModelShell
        ])
        #expect(!wrongModelReport.hasReadOnlyCompletedSample)
        #expect(wrongModelReport.missingHighRiskTools == LocalAgentBetaToolSurface.highRiskToolNames)
        #expect(wrongModelReport.nonCoveringSamples == [wrongModelReadOnly, wrongModelShell])
        #expect(wrongModelReport.nonCoveringSummary.contains(LocalMLXRuntime.recommendedModelRepository))
        #expect(!wrongModelReport.isCompleteForBeta)
        let approvalCheckpoint = betaSoakSample(
            successfulTools: [],
            outcome: .approvalRequired,
            stopReason: "permission_approval_required"
        )
        let approvalCheckpointReport = LocalAgentBetaSoakMatrix.report(samples: [readOnly, approvalCheckpoint])
        #expect(approvalCheckpointReport.hasReadOnlyCompletedSample)
        #expect(approvalCheckpointReport.nonCoveringSamples.isEmpty)
        #expect(approvalCheckpointReport.approvalRequiredCount == 1)
        #expect(approvalCheckpointReport.nonCoveringSummary == "All beta-soak samples satisfy Gate C evidence rules.")

        let blockedReadOnly = betaSoakSample(successfulTools: ["workspace.read_file"], outcome: .blocked)
        let blockedReport = LocalAgentBetaSoakMatrix.report(samples: [blockedReadOnly])
        #expect(!blockedReport.hasReadOnlyCompletedSample)
        #expect(blockedReport.nonCoveringSamples == [blockedReadOnly])
        #expect(blockedReport.nonCoveringSummary.contains("must complete with \(LocalMLXRuntime.recommendedModelRepository)"))

        let partial = LocalAgentBetaSoakMatrix.report(samples: [readOnly])
        #expect(partial.hasReadOnlyCompletedSample)
        #expect(partial.missingHighRiskTools == LocalAgentBetaToolSurface.highRiskToolNames)
        #expect(!partial.isCompleteForBeta)
        #expect(partial.summary.contains("task.write_output"))

        let highRiskSamples = LocalAgentBetaToolSurface.highRiskToolNames.map { tool in
            betaSoakSample(successfulTools: [tool])
        }
        let complete = LocalAgentBetaSoakMatrix.report(samples: [readOnly] + highRiskSamples)
        #expect(complete.isCompleteForBeta)
        #expect(complete.missingHighRiskTools.isEmpty)
        #expect(complete.nonCoveringSamples.isEmpty)
        #expect(complete.summary.contains("every high-risk beta tool"))

        LocalAgentBetaSoakStore.record(readOnly, defaults: defaults, maxSamples: 2)
        LocalAgentBetaSoakStore.record(highRiskSamples[0], defaults: defaults, maxSamples: 2)
        LocalAgentBetaSoakStore.record(highRiskSamples[1], defaults: defaults, maxSamples: 2)
        #expect(LocalAgentBetaSoakStore.samples(defaults: defaults) == [highRiskSamples[0], highRiskSamples[1]])
        #expect(LocalModelSettingsStore.persistedKeys.contains(LocalAgentBetaSoakStore.samplesKey))
        LocalAgentBetaSoakStore.clear(defaults: defaults)
        #expect(LocalAgentBetaSoakStore.samples(defaults: defaults).isEmpty)

        let orchestratorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/LocalAgentOrchestrator.swift"),
            encoding: .utf8
        )
        #expect(orchestratorSource.contains("LocalAgentBetaSoakStore.recordRuntimeSample"))
        #expect(orchestratorSource.contains("successfulToolNames.insert(tool)"))
        #expect(orchestratorSource.contains(#""successful_tools""#))
    }

    @Test("Local Agent beta soak evidence exports and merges cross-machine samples")
    func localAgentBetaSoakEvidenceExportsAndMergesCrossMachineSamples() throws {
        let sourceDefaultsName = "astra-local-agent-beta-export-\(UUID().uuidString)"
        let targetDefaultsName = "astra-local-agent-beta-import-\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceDefaultsName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetDefaultsName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceDefaultsName)
            targetDefaults.removePersistentDomain(forName: targetDefaultsName)
        }

        #expect(throws: LocalAgentBetaSoakExchangeError.self) {
            _ = try LocalAgentBetaSoakStore.exportEvidence(defaults: sourceDefaults)
        }

        let readOnly = betaSoakSample(successfulTools: ["workspace.read_file"])
        var readOnlyRerun = readOnly
        readOnlyRerun.recordedAt = Date(timeIntervalSince1970: 2_999)
        readOnlyRerun.turns = 3
        let shell = betaSoakSample(successfulTools: ["shell.exec"])
        LocalAgentBetaSoakStore.record(readOnly, defaults: sourceDefaults)
        LocalAgentBetaSoakStore.record(readOnlyRerun, defaults: sourceDefaults)
        LocalAgentBetaSoakStore.record(shell, defaults: sourceDefaults)
        #expect(LocalAgentBetaSoakStore.samples(defaults: sourceDefaults) == [readOnlyRerun, shell])

        let payload = try LocalAgentBetaSoakStore.exportEvidence(
            defaults: sourceDefaults,
            exportedAt: Date(timeIntervalSince1970: 2_900)
        )
        #expect(payload.contains(#""schemaVersion" : 1"#))
        #expect(payload.contains(#""samples""#))
        #expect(payload.contains("shell.exec"))

        let firstMerge = try LocalAgentBetaSoakStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(firstMerge.importedCount == 2)
        #expect(firstMerge.skippedCount == 0)
        #expect(firstMerge.report.hasReadOnlyCompletedSample)
        #expect(firstMerge.report.coveredHighRiskTools.contains("shell.exec"))

        let duplicateMerge = try LocalAgentBetaSoakStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(duplicateMerge.importedCount == 0)
        #expect(duplicateMerge.skippedCount == 2)
        #expect(LocalAgentBetaSoakStore.samples(defaults: targetDefaults) == [readOnlyRerun, shell])

        #expect(throws: LocalAgentBetaSoakExchangeError.self) {
            _ = try LocalAgentBetaSoakStore.mergeEvidence(
                #"{"schemaVersion":99,"exportedAt":"2026-05-28T00:00:00Z","samples":[]}"#,
                defaults: targetDefaults
            )
        }
    }

    @Test("Performance profile persists hardware and smoke throughput")
    func performanceProfilePersistsHardwareAndSmokeThroughput() throws {
        let defaultsName = "astra-local-model-performance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let gib: UInt64 = 1_073_741_824
        let profile = LocalModelPerformanceProfile(
            model: LocalMLXRuntime.defaultModel,
            backend: "mlx",
            checkedAt: Date(timeIntervalSince1970: 1_800),
            hardware: LocalHardwareProfile(
                isAppleSilicon: true,
                physicalMemoryBytes: 32 * gib,
                cpuBrand: "Apple M2 Max"
            ),
            inputTokens: 5,
            outputTokens: 1,
            durationMs: 1_200,
            firstTokenLatencyMs: 850,
            tokensPerSecond: 2.5
        )

        LocalModelPerformanceStore.record(profile, defaults: defaults)

        let restored = try #require(LocalModelPerformanceStore.profile(defaults: defaults))
        #expect(restored == profile)
        #expect(restored.physicalMemoryBytes == 32 * gib)
        #expect(restored.chipClass == "max")
    }

    @Test("Hardware validation matrix reports missing sustained Mac tiers")
    func hardwareValidationMatrixReportsMissingSustainedMacTiers() throws {
        let defaultsName = "astra-local-hardware-validation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let gib: UInt64 = 1_073_741_824
        let lowMemory = sustainedSample(
            memoryBytes: 8 * gib,
            chip: "Apple M2",
            outcome: .blockedAsExpected
        )
        let base = sustainedSample(
            memoryBytes: 16 * gib,
            chip: "Apple M2",
            outcome: .passed,
            iterations: 3,
            durationSeconds: 900
        )
        let pro = sustainedSample(
            memoryBytes: 32 * gib,
            chip: "Apple M2 Pro",
            outcome: .passed,
            iterations: 3,
            durationSeconds: 900
        )
        var missingInferenceTelemetry = base
        missingInferenceTelemetry.profile.inputTokens = nil
        var wrongModel = base
        wrongModel.profile.model = "Qwen/Qwen3-8B-MLX-4bit"
        let oneShot = sustainedSample(
            memoryBytes: 16 * gib,
            chip: "Apple M2",
            outcome: .passed,
            iterations: 1,
            durationSeconds: 60
        )

        #expect(LocalModelHardwareValidationMatrix.tier(for: lowMemory.profile) == .lowMemory8GB)
        #expect(LocalModelHardwareValidationMatrix.tier(for: base.profile) == .base16GB)
        #expect(LocalModelHardwareValidationMatrix.tier(for: pro.profile) == .pro32GBPlus)

        let telemetryMissing = LocalModelHardwareValidationMatrix.report(samples: [
            lowMemory,
            missingInferenceTelemetry,
            pro
        ])
        #expect(telemetryMissing.coveredTiers == [.pro32GBPlus])
        #expect(telemetryMissing.missingTiers.isEmpty)
        #expect(telemetryMissing.nonCoveringSamples.isEmpty)

        let wrongModelReport = LocalModelHardwareValidationMatrix.report(samples: [
            lowMemory,
            wrongModel,
            pro
        ])
        #expect(wrongModelReport.coveredTiers == [.pro32GBPlus])
        #expect(wrongModelReport.missingTiers.isEmpty)
        #expect(wrongModelReport.nonCoveringSamples.isEmpty)

        let oneShotReport = LocalModelHardwareValidationMatrix.report(samples: [lowMemory, oneShot, pro])
        #expect(oneShotReport.coveredTiers == [.pro32GBPlus])
        #expect(oneShotReport.missingTiers.isEmpty)
        #expect(oneShotReport.nonCoveringSamples.isEmpty)

        let proOnly = LocalModelHardwareValidationMatrix.report(samples: [pro])
        #expect(proOnly.coveredTiers == [.pro32GBPlus])
        #expect(proOnly.missingTiers.isEmpty)
        #expect(proOnly.isCompleteForGA)

        let noPro = LocalModelHardwareValidationMatrix.report(samples: [lowMemory, base])
        #expect(noPro.coveredTiers.isEmpty)
        #expect(noPro.missingTiers == [.pro32GBPlus])
        #expect(!noPro.isCompleteForGA)

        let max = sustainedSample(
            memoryBytes: 64 * gib,
            chip: "Apple M2 Max",
            outcome: .passed,
            iterations: 3,
            durationSeconds: 900
        )
        let complete = LocalModelHardwareValidationMatrix.report(samples: [lowMemory, base, pro, max])
        #expect(complete.missingTiers.isEmpty)
        #expect(complete.isCompleteForGA)

        LocalModelHardwareValidationStore.record(lowMemory, defaults: defaults, maxSamples: 2)
        LocalModelHardwareValidationStore.record(base, defaults: defaults, maxSamples: 2)
        LocalModelHardwareValidationStore.record(pro, defaults: defaults, maxSamples: 2)
        #expect(LocalModelHardwareValidationStore.samples(defaults: defaults) == [base, pro])
        #expect(LocalModelHardwareValidationStore.report(defaults: defaults).missingTiers.isEmpty)
        LocalModelHardwareValidationStore.clear(defaults: defaults)
        #expect(LocalModelHardwareValidationStore.samples(defaults: defaults).isEmpty)
    }

    @Test("Hardware validation evidence exports and merges cross-Mac samples")
    func hardwareValidationEvidenceExportsAndMergesCrossMacSamples() throws {
        let sourceDefaultsName = "astra-local-hardware-export-\(UUID().uuidString)"
        let targetDefaultsName = "astra-local-hardware-import-\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceDefaultsName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetDefaultsName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceDefaultsName)
            targetDefaults.removePersistentDomain(forName: targetDefaultsName)
        }

        #expect(throws: LocalModelHardwareValidationExchangeError.self) {
            _ = try LocalModelHardwareValidationStore.exportEvidence(defaults: sourceDefaults)
        }

        let base = sustainedSample(
            memoryBytes: 16 * LocalModelMemoryBudget.gib,
            chip: "Apple M2",
            outcome: .passed,
            iterations: 3,
            durationSeconds: 900
        )
        let max = sustainedSample(
            memoryBytes: 64 * LocalModelMemoryBudget.gib,
            chip: "Apple M2 Max",
            outcome: .passed,
            iterations: 4,
            durationSeconds: 1_200
        )
        var baseRerun = base
        baseRerun.profile.checkedAt = Date(timeIntervalSince1970: 2_100)
        baseRerun.iterations = 4
        baseRerun.durationSeconds = 1_200
        LocalModelHardwareValidationStore.record(base, defaults: sourceDefaults)
        LocalModelHardwareValidationStore.record(baseRerun, defaults: sourceDefaults)
        LocalModelHardwareValidationStore.record(max, defaults: sourceDefaults)
        #expect(LocalModelHardwareValidationStore.samples(defaults: sourceDefaults) == [baseRerun, max])

        let payload = try LocalModelHardwareValidationStore.exportEvidence(
            defaults: sourceDefaults,
            exportedAt: Date(timeIntervalSince1970: 2_500)
        )
        #expect(payload.contains(#""schemaVersion" : 1"#))
        #expect(payload.contains(#""samples""#))

        LocalModelHardwareValidationStore.record(base, defaults: targetDefaults)
        #expect(LocalModelHardwareValidationStore.samples(defaults: targetDefaults) == [base])
        let firstMerge = try LocalModelHardwareValidationStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(firstMerge.importedCount == 2)
        #expect(firstMerge.skippedCount == 0)
        #expect(LocalModelHardwareValidationStore.samples(defaults: targetDefaults) == [baseRerun, max])

        let duplicateMerge = try LocalModelHardwareValidationStore.mergeEvidence(payload, defaults: targetDefaults)
        #expect(duplicateMerge.importedCount == 0)
        #expect(duplicateMerge.skippedCount == 2)
        #expect(LocalModelHardwareValidationStore.samples(defaults: targetDefaults) == [baseRerun, max])

        #expect(throws: LocalModelHardwareValidationExchangeError.self) {
            _ = try LocalModelHardwareValidationStore.mergeEvidence(
                #"{"schemaVersion":99,"exportedAt":"2026-05-28T00:00:00Z","samples":[]}"#,
                defaults: targetDefaults
            )
        }
    }

    @Test("Evidence import accepts JSON copied from release notes or chat")
    func evidenceImportAcceptsJSONCopiedFromReleaseNotesOrChat() throws {
        let releaseDefaultsName = "astra-local-wrapped-release-\(UUID().uuidString)"
        let betaDefaultsName = "astra-local-wrapped-beta-\(UUID().uuidString)"
        let hardwareDefaultsName = "astra-local-wrapped-hardware-\(UUID().uuidString)"
        let releaseDefaults = try #require(UserDefaults(suiteName: releaseDefaultsName))
        let betaDefaults = try #require(UserDefaults(suiteName: betaDefaultsName))
        let hardwareDefaults = try #require(UserDefaults(suiteName: hardwareDefaultsName))
        defer {
            releaseDefaults.removePersistentDomain(forName: releaseDefaultsName)
            betaDefaults.removePersistentDomain(forName: betaDefaultsName)
            hardwareDefaults.removePersistentDomain(forName: hardwareDefaultsName)
        }

        let releasePayload = try releaseCandidateEvidencePayload(samples: [
            releaseCandidateSample(mode: .localChat, inputTokens: 0),
            releaseCandidateSample(mode: .localChat),
            releaseCandidateSample(mode: .localAgentReadOnly)
        ])
        let betaPayload = try betaSoakEvidencePayload(samples: [
            betaSoakSample(successfulTools: ["workspace.read_file"]),
            betaSoakSample(successfulTools: ["shell.exec"])
        ])
        let hardwarePayload = try hardwareEvidencePayload(samples: [
            sustainedSample(
                memoryBytes: 64 * LocalModelMemoryBudget.gib,
                chip: "Apple M2 Max",
                outcome: .passed,
                iterations: 3,
                durationSeconds: 900
            )
        ])

        let releaseMerge = try LocalModelReleaseCandidateValidationStore.mergeEvidence(
            wrappedEvidencePayload(releasePayload),
            defaults: releaseDefaults
        )
        let betaMerge = try LocalAgentBetaSoakStore.mergeEvidence(
            wrappedEvidencePayload(betaPayload),
            defaults: betaDefaults
        )
        let hardwareMerge = try LocalModelHardwareValidationStore.mergeEvidence(
            wrappedEvidencePayload(hardwarePayload),
            defaults: hardwareDefaults
        )

        #expect(releaseMerge.importedCount == 3)
        #expect(releaseMerge.report.isCompleteForGA)
        #expect(releaseMerge.report.coveredModes == [.localChat, .localAgentReadOnly])
        #expect(betaMerge.importedCount == 2)
        #expect(betaMerge.report.hasReadOnlyCompletedSample)
        #expect(betaMerge.report.coveredHighRiskTools.contains("shell.exec"))
        #expect(hardwareMerge.importedCount == 1)
    }

    @Test("Combined release evidence bundle exports and merges all readiness evidence")
    func combinedReleaseEvidenceBundleExportsAndMergesAllReadinessEvidence() throws {
        let sourceDefaultsName = "astra-local-combined-release-source-\(UUID().uuidString)"
        let targetDefaultsName = "astra-local-combined-release-target-\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceDefaultsName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetDefaultsName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceDefaultsName)
            targetDefaults.removePersistentDomain(forName: targetDefaultsName)
        }

        #expect(throws: LocalModelCombinedReleaseEvidenceExchangeError.self) {
            _ = try LocalModelCombinedReleaseEvidenceStore.exportEvidence(defaults: sourceDefaults)
        }

        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localChat),
            defaults: sourceDefaults
        )
        LocalModelReleaseCandidateValidationStore.record(
            releaseCandidateSample(mode: .localAgentReadOnly),
            defaults: sourceDefaults
        )
        LocalAgentBetaSoakStore.record(
            betaSoakSample(successfulTools: ["workspace.read_file"]),
            defaults: sourceDefaults
        )
        LocalAgentBetaSoakStore.record(
            betaSoakSample(successfulTools: ["shell.exec"]),
            defaults: sourceDefaults
        )
        LocalModelHardwareValidationStore.record(
            sustainedSample(
                memoryBytes: 64 * LocalModelMemoryBudget.gib,
                chip: "Apple M2 Max",
                outcome: .passed,
                iterations: 3,
                durationSeconds: 900
            ),
            defaults: sourceDefaults
        )

        let payload = try LocalModelCombinedReleaseEvidenceStore.exportEvidence(
            defaults: sourceDefaults,
            exportedAt: Date(timeIntervalSince1970: 4_000)
        )
        #expect(payload.contains(#""releaseCandidateSamples""#))
        #expect(payload.contains(#""betaSoakSamples""#))
        #expect(payload.contains(#""hardwareSamples""#))

        let firstMerge = try LocalModelCombinedReleaseEvidenceStore.mergeEvidence(
            wrappedEvidencePayload(payload),
            defaults: targetDefaults
        )
        #expect(firstMerge.releaseCandidate.importedCount == 2)
        #expect(firstMerge.betaSoak.importedCount == 2)
        #expect(firstMerge.hardware.importedCount == 1)
        #expect(firstMerge.releaseCandidate.report.isCompleteForGA)
        #expect(firstMerge.betaSoak.report.hasReadOnlyCompletedSample)
        #expect(firstMerge.betaSoak.report.coveredHighRiskTools.contains("shell.exec"))
        #expect(firstMerge.hardware.importedCount == 1)
        #expect(firstMerge.summary.contains("2 release-candidate samples"))

        let duplicateMerge = try LocalModelCombinedReleaseEvidenceStore.mergeEvidence(
            payload,
            defaults: targetDefaults
        )
        #expect(duplicateMerge.releaseCandidate.importedCount == 0)
        #expect(duplicateMerge.betaSoak.importedCount == 0)
        #expect(duplicateMerge.hardware.importedCount == 0)

        #expect(throws: LocalModelCombinedReleaseEvidenceExchangeError.self) {
            _ = try LocalModelCombinedReleaseEvidenceStore.mergeEvidence(
                #"{"schemaVersion":99,"exportedAt":"2026-05-28T00:00:00Z","releaseCandidateSamples":[],"betaSoakSamples":[],"hardwareSamples":[]}"#,
                defaults: targetDefaults
            )
        }
    }

    @Test("Hardware validation runbook stays aligned with Gate D evidence requirements")
    func hardwareValidationRunbookStaysAlignedWithGateDEvidenceRequirements() throws {
        let runbook = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/performance/local-mlx-hardware-validation.md"),
            encoding: .utf8
        )
        let plan = try String(
            contentsOf: repoRoot.appendingPathComponent("plan.md"),
            encoding: .utf8
        )
        let collectionScript = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_collect_hardware_evidence.sh"),
            encoding: .utf8
        )
        let releaseCollectionScript = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_collect_release_evidence.sh"),
            encoding: .utf8
        )
        let hardwareInspector = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_hardware_evidence.py"),
            encoding: .utf8
        )
        let releaseInspector = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_release_readiness.py"),
            encoding: .utf8
        )
        let phase1Source = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/Phase1FunctionalTest.swift"),
            encoding: .utf8
        )
        let localModelRuntimeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/LocalModelRuntime.swift"),
            encoding: .utf8
        )

        for tier in LocalModelHardwareValidationMatrix.requiredTiers {
            #expect(runbook.contains(tier.displayName), "Runbook is missing required hardware tier \(tier.displayName).")
            #expect(hardwareInspector.contains(#""\#(tier.rawValue)""#), "Hardware inspector is missing tier \(tier.rawValue).")
            #expect(hardwareInspector.contains(#""\#(tier.displayName)""#), "Hardware inspector is missing tier label \(tier.displayName).")
            #expect(releaseInspector.contains(#""\#(tier.rawValue)""#), "Release readiness inspector is missing tier \(tier.rawValue).")
            #expect(releaseInspector.contains(#""\#(tier.displayName)""#), "Release readiness inspector is missing tier label \(tier.displayName).")
        }
        #expect(hardwareInspector.contains(#"RECOMMENDED_MODEL = "\#(LocalMLXRuntime.recommendedModelRepository)""#))
        #expect(releaseInspector.contains(#"RECOMMENDED_MODEL = "\#(LocalMLXRuntime.recommendedModelRepository)""#))
        #expect(releaseInspector.contains("str(sample.get(\"model\") or \"\").strip() == RECOMMENDED_MODEL"))
        #expect(hardwareInspector.contains("str(profile.get(\"model\") or \"\").strip() == RECOMMENDED_MODEL"))
        #expect(hardwareInspector.contains("Preview this Mac's detected tier and output path first:"))
        #expect(hardwareInspector.contains("script/local_mlx_collect_hardware_evidence.sh --dry-run"))
        #expect(releaseInspector.contains("Bundle evidence for Runtime settings import:"))
        #expect(releaseInspector.contains("Preview this Mac's detected tier and output path first:"))
        #expect(releaseInspector.contains("Preview the build id, helper, model folder, and output path first:"))
        #expect(releaseInspector.contains("Preview high-risk Local Agent beta collection first:"))
        #expect(releaseInspector.contains("--require-clean-evidence"))
        #expect(releaseInspector.contains("Preview merged sample counts first by adding --dry-run"))
        #expect(releaseInspector.contains("Release packaging preflight:"))
        #expect(releaseInspector.contains("script/local_mlx_validation_bundle.py"))
        #expect(releaseInspector.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json"))
        #expect(releaseInspector.contains("script/release_update.sh"))
        #expect(releaseInspector.contains("/tmp/astra-local-mlx-validation-bundle.json"))
        let validationBundleScript = try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_validation_bundle.py"),
            encoding: .utf8
        )
        #expect(validationBundleScript.contains("def deduplicated_samples(samples):"))
        #expect(validationBundleScript.contains("json.dumps(sample, sort_keys=True"))
        #expect(runbook.contains("RUN_E2E=1"))
        #expect(runbook.contains("RUN_E2E_RUNTIME=local_mlx"))
        #expect(runbook.contains("RUN_E2E_LOCAL_MLX_HARDWARE=1"))
        #expect(runbook.contains("RUN_E2E_LOCAL_MLX_HARDWARE_ITERATIONS=3"))
        #expect(runbook.contains(LocalModelHardwareValidationStore.evidenceOutputEnvironmentKey))
        #expect(runbook.contains("localMLXSustainedHardwareValidationEndToEnd"))
        #expect(runbook.contains("script/local_mlx_collect_hardware_evidence.sh"))
        #expect(runbook.contains(LocalMLXRuntime.recommendedModelRepository))
        #expect(runbook.contains("LocalModels/Qwen3-4B-MLX-4bit"))
        #expect(runbook.contains("script/local_mlx_hardware_evidence.py"))
        #expect(runbook.contains("--require-tier"))
        #expect(runbook.contains("does not cover the expected tier"))
        #expect(runbook.contains("it prints the exact\n`script/local_mlx_collect_hardware_evidence.sh --dry-run` preview first"))
        #expect(runbook.contains("script/local_mlx_release_readiness.py"))
        #expect(runbook.contains("script/local_mlx_collect_release_evidence.sh"))
        #expect(runbook.contains("--out /tmp/astra-local-mlx-release-evidence.json"))
        #expect(runbook.contains("--include-high-risk-tools"))
        #expect(runbook.contains("--beta-out /tmp/astra-local-agent-beta-soak-evidence.json"))
        #expect(runbook.contains("task.write_output"))
        #expect(runbook.contains("workspace.write_file"))
        #expect(runbook.contains("shell.exec"))
        #expect(runbook.contains("network.fetch"))
        #expect(runbook.contains("browser.click"))
        #expect(runbook.contains("browser.type"))
        #expect(runbook.contains("script/local_mlx_validation_bundle.py"))
        #expect(runbook.contains("To preview the merged sample counts before writing a bundle"))
        #expect(runbook.contains("/tmp/astra-local-mlx-release-evidence.json"))
        #expect(runbook.contains("/tmp/astra-local-agent-beta-soak-evidence.json"))
        #expect(runbook.contains("/tmp/astra-local-mlx-validation-bundle.json"))
        #expect(runbook.contains("--require-complete"))
        #expect(runbook.contains("ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"))
        #expect(runbook.contains("ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1"))
        #expect(runbook.contains("ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1"))
        #expect(runbook.contains("reports all\nmissing Local MLX evidence variables together"))
        #expect(runbook.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE"))
        #expect(runbook.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES"))
        #expect(runbook.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE"))
        #expect(runbook.contains("supplemental evidence variables alongside a validation bundle"))
        #expect(runbook.contains("is aggregated when both are set"))
        #expect(runbook.contains("--require-build-id"))
        #expect(runbook.contains("build-bound"))
        #expect(runbook.contains("release-candidate evidence"))
        #expect(runbook.contains("proves real MLX inference"))
        #expect(runbook.contains("Incomplete folders fail immediately with guidance to install Qwen 3 4B"))
        #expect(runbook.contains("first-token latency"))
        #expect(runbook.contains("Import Evidence"))
        #expect(runbook.contains("Copy Evidence"))
        #expect(runbook.contains("Gate D"))
        #expect(plan.contains("Dry-run the evidence handoff before launching live MLX validation"))
        #expect(plan.contains("script/local_mlx_collect_hardware_evidence.sh --dry-run"))
        #expect(plan.contains("script/local_mlx_collect_release_evidence.sh \\\n  --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" \\\n  --include-high-risk-tools \\\n  --dry-run"))
        #expect(plan.contains("script/local_mlx_validation_bundle.py \\\n  --release-candidate /tmp/astra-local-mlx-release-evidence.json"))
        #expect(plan.contains("--out /tmp/astra-local-mlx-validation-bundle.json \\\n  --dry-run"))

        #expect(phase1Source.contains("RUN_E2E_LOCAL_MLX_HARDWARE"))
        #expect(phase1Source.contains("evidenceOutputEnvironmentKey"))
        #expect(phase1Source.contains("localMLXSustainedHardwareValidationEndToEnd"))
        #expect(collectionScript.contains("RUN_E2E=1"))
        #expect(collectionScript.contains("RUN_E2E_RUNTIME=local_mlx"))
        #expect(collectionScript.contains("RUN_E2E_LOCAL_MLX_HARDWARE=1"))
        #expect(collectionScript.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_OUT"))
        #expect(collectionScript.contains("EXPECTED_TIER"))
        #expect(collectionScript.contains("--dry-run"))
        #expect(collectionScript.contains("--require-tier"))
        #expect(collectionScript.contains("REQUIRED_TIER"))
        #expect(collectionScript.contains("Required Gate D tier:"))
        #expect(collectionScript.contains("Run this collection command on the required hardware tier"))
        #expect(collectionScript.contains("Local MLX hardware collection dry run"))
        #expect(collectionScript.contains("Detected Gate D tier:"))
        #expect(collectionScript.contains("script/local_mlx_hardware_evidence.py --require-tier"))
        #expect(collectionScript.contains("REAL_LOCAL_MLX_HELPER"))
        #expect(collectionScript.contains("REAL_LOCAL_MLX_MODEL_DIR"))
        #expect(collectionScript.contains("/usr/sbin/sysctl -n hw.memsize"))
        #expect(collectionScript.contains("/usr/sbin/sysctl -n machdep.cpu.brand_string"))
        #expect(collectionScript.contains("OUTPUT_PATH_EXPLICIT"))
        #expect(collectionScript.contains("LOW_MEMORY_THRESHOLD_BYTES"))
        #expect(collectionScript.contains("BASE_MEMORY_THRESHOLD_BYTES"))
        #expect(collectionScript.contains("validate_model_assets"))
        #expect(hardwareInspector.contains("MINIMUM_SUSTAINED_ITERATIONS = 3"))
        #expect(releaseInspector.contains("MINIMUM_SUSTAINED_ITERATIONS = 3"))
        #expect(localModelRuntimeSource.contains("hardwareEvidenceKey(for: sample)"))
        #expect(runbook.contains("3 sustained iterations"))
        #expect(plan.contains("at least 3 iterations"))
        #expect(collectionScript.contains("missing config.json"))
        #expect(collectionScript.contains("missing tokenizer.json or tokenizer.model"))
        #expect(collectionScript.contains("missing non-empty model weights"))
        #expect(collectionScript.contains("/tmp/astra-local-mlx-hardware-8gb.json"))
        #expect(collectionScript.contains("/tmp/astra-local-mlx-hardware-16gb.json"))
        #expect(collectionScript.contains("/tmp/astra-local-mlx-hardware-pro.json"))
        #expect(collectionScript.contains("/tmp/astra-local-mlx-hardware-max.json"))
        #expect(collectionScript.contains("Collecting expected low-memory block evidence without requiring an installed model."))
        #expect(collectionScript.contains("swift test --filter localMLXSustainedHardwareValidationEndToEnd"))
        #expect(runbook.contains("script/local_mlx_collect_hardware_evidence.sh --dry-run"))
        #expect(runbook.contains("The dry run prints the detected Gate D tier"))
        #expect(runbook.contains("Without `--out`, the wrapper writes to this Mac's Gate D tier file"))
        let dryRun = try runShellScript("script/local_mlx_collect_hardware_evidence.sh", arguments: ["--dry-run"])
        #expect(dryRun.status == 0)
        #expect(dryRun.output.contains("Local MLX hardware collection dry run"))
        #expect(dryRun.output.contains("Detected Gate D tier:"))
        #expect(dryRun.output.contains("Evidence output: /tmp/astra-local-mlx-hardware-"))
        #expect(dryRun.output.contains("Run without --dry-run") || dryRun.output.contains("expected low-memory block"))
        let mismatchedTierDryRun = try runShellScript("script/local_mlx_collect_hardware_evidence.sh", arguments: [
            "--require-tier",
            "low_memory_8gb",
            "--dry-run"
        ])
        #expect(mismatchedTierDryRun.status == 2)
        #expect(mismatchedTierDryRun.output.contains("not 8 GB class (low_memory_8gb)"))
        #expect(mismatchedTierDryRun.output.contains("Run this collection command on the required hardware tier"))
        let incompleteModelDirectory = temporaryDirectory()
        try "{}".write(
            to: incompleteModelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        let fakeHelper = temporaryDirectory().appendingPathComponent("astra-local-model")
        try "#!/bin/sh\nexit 0\n".write(to: fakeHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHelper.path)
        let incompleteHardwareRun = try runShellScript("script/local_mlx_collect_hardware_evidence.sh", arguments: [
            "--helper", fakeHelper.path,
            "--model-dir", incompleteModelDirectory.path,
            "--out", "/tmp/astra-local-mlx-hardware-test.json",
            "--iterations", "1"
        ])
        #expect(incompleteHardwareRun.status == 2)
        #expect(incompleteHardwareRun.output.contains("missing tokenizer.json or tokenizer.model"))
        #expect(incompleteHardwareRun.output.contains("complete MLX model folder"))
        #expect(releaseCollectionScript.contains("ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"))
        #expect(releaseCollectionScript.contains(#"BUILD_ID="${ASTRA_VERSION}+${ASTRA_BUILD}""#))
        #expect(releaseCollectionScript.contains("set ASTRA_VERSION and ASTRA_BUILD"))
        #expect(releaseCollectionScript.contains("ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT"))
        #expect(releaseCollectionScript.contains("RUN_E2E_RUNTIME=local_mlx"))
        #expect(releaseCollectionScript.contains("RUN_E2E_LOCAL_MLX_AGENT=1"))
        #expect(releaseCollectionScript.contains("REAL_LOCAL_MLX_HELPER"))
        #expect(releaseCollectionScript.contains("REAL_LOCAL_MLX_MODEL_DIR"))
        #expect(releaseCollectionScript.contains("swift test --filter workerTextResponseEndToEnd"))
        #expect(releaseCollectionScript.contains("swift test --filter localMLXAgentReadOnlyToolLoopEndToEnd"))
        #expect(releaseCollectionScript.contains("--include-high-risk-tools"))
        #expect(releaseCollectionScript.contains("--dry-run"))
        #expect(releaseCollectionScript.contains("Local MLX release evidence collection dry run"))
        #expect(releaseCollectionScript.contains("Release build id: $BUILD_ID"))
        #expect(releaseCollectionScript.contains("High-risk Local Agent beta tools: included"))
        #expect(releaseCollectionScript.contains("High-risk Local Agent beta tools: not included"))
        #expect(releaseCollectionScript.contains("validate_model_assets"))
        #expect(releaseCollectionScript.contains("missing config.json"))
        #expect(releaseCollectionScript.contains("missing tokenizer.json or tokenizer.model"))
        #expect(releaseCollectionScript.contains("missing non-empty model weights"))
        #expect(releaseCollectionScript.contains("RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1"))
        #expect(releaseCollectionScript.contains("localMLXAgentTaskOutputWriteApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("localMLXAgentWorkspaceWriteApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("localMLXAgentShellExecApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("localMLXAgentNetworkFetchApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("localMLXAgentBrowserClickApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("localMLXAgentBrowserTypeApprovalEndToEnd"))
        #expect(releaseCollectionScript.contains("ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT=\"$BETA_OUTPUT_PATH\""))
        #expect(releaseCollectionScript.contains(#"mkdir -p "$(dirname "$OUTPUT_PATH")""#))
        #expect(releaseCollectionScript.contains(#"mkdir -p "$(dirname "$BETA_OUTPUT_PATH")""#))
        #expect(releaseCollectionScript.contains(#"rm -f "$OUTPUT_PATH" "$BETA_OUTPUT_PATH""#))
        #expect(releaseCollectionScript.contains("--out and --beta-out must be different files"))
        #expect(try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_validation_bundle.py"),
            encoding: .utf8
        ).contains("--bundle"))
        #expect(try String(
            contentsOf: repoRoot.appendingPathComponent("script/local_mlx_validation_bundle.py"),
            encoding: .utf8
        ).contains("--dry-run"))
        #expect(releaseCollectionScript.contains("--require-build-id"))
        #expect(releaseCollectionScript.contains("Missing release build id."))
        #expect(runbook.contains("script/local_mlx_collect_release_evidence.sh"))
        #expect(runbook.contains("--dry-run"))
        #expect(runbook.contains("To preview the build id, output files, helper path, model folder, and high-risk"))
        #expect(runbook.contains("it prints the dry-run preview and the\n`script/local_mlx_collect_release_evidence.sh --build-id"))
        #expect(runbook.contains("the validation-bundle dry-run guidance and the exact"))
        let releaseDryRun = try runShellScript(
            "script/local_mlx_collect_release_evidence.sh",
            arguments: [
                "--build-id", "0.1.0+test",
                "--helper", "/tmp/missing-astra-local-model",
                "--model-dir", "/tmp/missing-local-model",
                "--out", "/tmp/release.json",
                "--beta-out", "/tmp/beta.json",
                "--include-high-risk-tools",
                "--dry-run"
            ]
        )
        #expect(releaseDryRun.status == 0)
        #expect(releaseDryRun.output.contains("Local MLX release evidence collection dry run"))
        #expect(releaseDryRun.output.contains("Release build id: 0.1.0+test"))
        #expect(releaseDryRun.output.contains("Release evidence output: /tmp/release.json"))
        #expect(releaseDryRun.output.contains("Beta-soak evidence output: /tmp/beta.json"))
        #expect(releaseDryRun.output.contains("Helper path: /tmp/missing-astra-local-model"))
        #expect(releaseDryRun.output.contains("Model folder: /tmp/missing-local-model"))
        #expect(releaseDryRun.output.contains("High-risk Local Agent beta tools: included"))
        #expect(releaseDryRun.output.contains("task.write_output, workspace.write_file, shell.exec, network.fetch, browser.click, browser.type"))
        let derivedBuildDryRun = try runShellScript(
            "script/local_mlx_collect_release_evidence.sh",
            arguments: ["--dry-run"],
            environment: [
                "ASTRA_VERSION": "0.1.0",
                "ASTRA_BUILD": "1",
                "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": ""
            ]
        )
        #expect(derivedBuildDryRun.status == 0)
        #expect(derivedBuildDryRun.output.contains("Release build id: 0.1.0+1"))
        let collidingEvidencePaths = try runShellScript(
            "script/local_mlx_collect_release_evidence.sh",
            arguments: [
                "--build-id", "0.1.0+test",
                "--out", "/tmp/astra-local-mlx-colliding-evidence.json",
                "--beta-out", "/tmp/astra-local-mlx-colliding-evidence.json",
                "--dry-run"
            ]
        )
        #expect(collidingEvidencePaths.status == 2)
        #expect(collidingEvidencePaths.output.contains("--out and --beta-out must be different files"))
        let incompleteReleaseRun = try runShellScript(
            "script/local_mlx_collect_release_evidence.sh",
            arguments: [
                "--build-id", "0.1.0+test",
                "--helper", fakeHelper.path,
                "--model-dir", incompleteModelDirectory.path,
                "--out", "/tmp/astra-local-mlx-release-test.json",
                "--beta-out", "/tmp/astra-local-agent-beta-test.json"
            ]
        )
        #expect(incompleteReleaseRun.status == 2)
        #expect(incompleteReleaseRun.output.contains("missing tokenizer.json or tokenizer.model"))
        #expect(incompleteReleaseRun.output.contains("complete MLX model folder"))
        #expect(releaseCollectionScript.contains("/tmp/astra-local-mlx-hardware-8gb.json"))
        #expect(releaseCollectionScript.contains("/tmp/astra-local-mlx-hardware-16gb.json"))
        #expect(releaseCollectionScript.contains("/tmp/astra-local-mlx-hardware-pro.json"))
        #expect(releaseCollectionScript.contains("/tmp/astra-local-mlx-hardware-max.json"))
        #expect(!releaseCollectionScript.contains("--hardware /tmp/astra-local-mlx-hardware-evidence.json"))
        #expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("script/local_mlx_validation_bundle.py").path))
    }

    @Test("Hardware validation evidence inspector reports missing and complete tiers")
    func hardwareValidationEvidenceInspectorReportsMissingAndCompleteTiers() throws {
        let directory = temporaryDirectory()
        let incompleteURL = directory.appendingPathComponent("incomplete-hardware.json")
        let malformedURL = directory.appendingPathComponent("malformed-hardware.json")
        let missingTelemetryURL = directory.appendingPathComponent("missing-telemetry-hardware.json")
        let wrongModelURL = directory.appendingPathComponent("wrong-model-hardware.json")
        let completeURL = directory.appendingPathComponent("complete-hardware.json")
        let gib = LocalModelMemoryBudget.gib

        let incompletePayload = try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed)
        ])
        try incompletePayload.write(to: incompleteURL, atomically: true, encoding: .utf8)

        let proOnlyInspector = try runHardwareEvidenceInspector([incompleteURL.path])
        #expect(proOnlyInspector.status == 0)
        #expect(proOnlyInspector.output.contains("32 GB+ Pro-class"))
        #expect(proOnlyInspector.output.contains("Missing tiers:\n  - none"))

        let proOnlyRequired = try runHardwareEvidenceInspector(["--require-complete", incompleteURL.path])
        #expect(proOnlyRequired.status == 0)
        #expect(proOnlyRequired.output.contains("Missing tiers:\n  - none"))

        let requiredCoveredTier = try runHardwareEvidenceInspector(["--require-tier", "pro_32gb_plus", incompleteURL.path])
        #expect(requiredCoveredTier.status == 0)
        #expect(requiredCoveredTier.output.contains("Required tier: 32 GB+ Pro-class"))
        let requiredMissingTier = try runHardwareEvidenceInspector(["--require-tier", "base_16gb", incompleteURL.path])
        #expect(requiredMissingTier.status == 1)
        #expect(requiredMissingTier.output.contains("Required tier: 16 GB base-class"))

        let malformedPayload = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-28T00:00:00Z",
          "samples": [
            {
              "profile": {
                "model": "Qwen/Qwen3-4B-MLX-4bit",
                "backend": "mlx",
                "checkedAt": "2026-05-28T00:00:00Z",
                "isAppleSilicon": true,
                "physicalMemoryBytes": "a lot",
                "chipClass": "pro"
              },
              "mode": "local_agent_read_only",
              "outcome": "blocked_as_expected",
              "iterations": "many",
              "durationSeconds": "long",
              "notes": "copied malformed evidence should not crash the inspector"
            }
          ]
        }
        """
        try malformedPayload.write(to: malformedURL, atomically: true, encoding: .utf8)
        let malformed = try runHardwareEvidenceInspector(["--require-complete", malformedURL.path])
        #expect(malformed.status == 1)
        #expect(malformed.output.contains("Local MLX hardware evidence samples: 1"))
        #expect(malformed.output.contains("Missing tiers:"))
        #expect(malformed.output.contains("Non-covering samples:"))
        #expect(malformed.output.contains("1 sample(s) did not satisfy Gate D evidence rules"))
        #expect(malformed.output.contains("32 GB+ Pro-class"))
        #expect(!malformed.output.contains("Covered tiers:\n  - 32 GB+ Pro-class"))
        #expect(!malformed.output.contains("Traceback"))

        let missingTelemetryPayload = try hardwareEvidencePayload(samples: [
            sustainedSample(
                memoryBytes: 16 * gib,
                chip: "Apple M2",
                outcome: .passed,
                inputTokens: nil
            )
        ])
        try missingTelemetryPayload.write(to: missingTelemetryURL, atomically: true, encoding: .utf8)
        let missingTelemetry = try runHardwareEvidenceInspector(["--require-complete", missingTelemetryURL.path])
        #expect(missingTelemetry.status == 1)
        #expect(missingTelemetry.output.contains("Local MLX hardware evidence samples: 1"))
        #expect(missingTelemetry.output.contains("Missing tiers:"))
        #expect(missingTelemetry.output.contains("32 GB+ Pro-class"))
        #expect(!missingTelemetry.output.contains("Traceback"))

        let wrongModelPayload = try hardwareEvidencePayload(samples: [
            sustainedSample(
                memoryBytes: 16 * gib,
                chip: "Apple M2",
                outcome: .passed,
                model: "Qwen/Qwen3-8B-MLX-4bit"
            )
        ])
        try wrongModelPayload.write(to: wrongModelURL, atomically: true, encoding: .utf8)
        let wrongModel = try runHardwareEvidenceInspector(["--require-tier", "base_16gb", wrongModelURL.path])
        #expect(wrongModel.status == 1)
        #expect(wrongModel.output.contains("Required tier: 16 GB base-class"))

        let completePayload = try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
            sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed),
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed),
            sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed)
        ])
        try completePayload.write(to: completeURL, atomically: true, encoding: .utf8)

        let complete = try runHardwareEvidenceInspector(["--require-complete", completeURL.path])
        #expect(complete.status == 0)
        #expect(complete.output.contains("Missing tiers:\n  - none"))
        #expect(!complete.output.contains("Next hardware collection:"))

        let wrappedURL = directory.appendingPathComponent("wrapped-complete-hardware.md")
        try wrappedEvidencePayload(completePayload).write(to: wrappedURL, atomically: true, encoding: .utf8)
        let wrapped = try runHardwareEvidenceInspector(["--require-complete", wrappedURL.path])
        #expect(wrapped.status == 0)
        #expect(wrapped.output.contains("Missing tiers:\n  - none"))
    }

    @Test("Local MLX release readiness inspector combines release beta and hardware evidence")
    func localMLXReleaseReadinessInspectorCombinesReleaseBetaAndHardwareEvidence() throws {
        let directory = temporaryDirectory()
        let releaseURL = directory.appendingPathComponent("release.json")
        let unboundReleaseURL = directory.appendingPathComponent("unbound-release.json")
        let invalidReleaseURL = directory.appendingPathComponent("invalid-release.json")
        let wrongModelReleaseURL = directory.appendingPathComponent("wrong-model-release.json")
        let malformedReleaseURL = directory.appendingPathComponent("malformed-release.json")
        let malformedBetaURL = directory.appendingPathComponent("malformed-beta.json")
        let wrongModelBetaURL = directory.appendingPathComponent("wrong-model-beta.json")
        let betaURL = directory.appendingPathComponent("beta.json")
        let betaWithApprovalCheckpointsURL = directory.appendingPathComponent("beta-with-approval-checkpoints.json")
        let incompleteHardwareURL = directory.appendingPathComponent("incomplete-hardware.json")
        let missingTelemetryHardwareURL = directory.appendingPathComponent("missing-telemetry-hardware.json")
        let wrongModelHardwareURL = directory.appendingPathComponent("wrong-model-hardware.json")
        let completeHardwareURL = directory.appendingPathComponent("complete-hardware.json")
        let lowMemoryHardwareURL = directory.appendingPathComponent("low-memory-hardware.json")
        let baseHardwareURL = directory.appendingPathComponent("base-hardware.json")
        let proHardwareURL = directory.appendingPathComponent("pro-hardware.json")
        let maxHardwareURL = directory.appendingPathComponent("max-hardware.json")
        let completeBundleURL = directory.appendingPathComponent("complete-bundle.json")
        let cliBundleURL = directory.appendingPathComponent("cli-bundle.json")
        let releaseBundleURL = directory.appendingPathComponent("release-bundle.json")
        let baseHardwareBundleURL = directory.appendingPathComponent("base-hardware-bundle.json")
        let gib = LocalModelMemoryBudget.gib

        let releasePayload = try releaseCandidateEvidencePayload(samples: [
            releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+1"),
            releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1")
        ])
        try releasePayload.write(to: releaseURL, atomically: true, encoding: .utf8)
        try releaseCandidateEvidencePayload(samples: [
            releaseCandidateSample(mode: .localChat),
            releaseCandidateSample(mode: .localAgentReadOnly)
        ]).write(to: unboundReleaseURL, atomically: true, encoding: .utf8)
        try releaseCandidateEvidencePayload(samples: [
            releaseCandidateSample(
                mode: .localChat,
                model: "Qwen/Qwen3-8B-MLX-4bit",
                buildIdentifier: "astra-0.1.0+1"
            ),
            releaseCandidateSample(
                mode: .localAgentReadOnly,
                model: "Qwen/Qwen3-8B-MLX-4bit",
                buildIdentifier: "astra-0.1.0+1"
            )
        ]).write(to: wrongModelReleaseURL, atomically: true, encoding: .utf8)

        let betaPayload = try betaSoakEvidencePayload(samples: [
            betaSoakSample(successfulTools: ["slack.thread"]),
            betaSoakSample(successfulTools: [
                "task.write_output",
                "workspace.write_file",
                "shell.exec",
                "network.fetch",
                "browser.click",
                "browser.type"
            ])
        ])
        try betaPayload.write(to: betaURL, atomically: true, encoding: .utf8)
        try betaSoakEvidencePayload(samples: [
            betaSoakSample(successfulTools: ["slack.thread"]),
            betaSoakSample(
                successfulTools: [],
                outcome: .approvalRequired,
                stopReason: "permission_approval_required"
            ),
            betaSoakSample(successfulTools: [
                "task.write_output",
                "workspace.write_file",
                "shell.exec",
                "network.fetch",
                "browser.click",
                "browser.type"
            ])
        ]).write(to: betaWithApprovalCheckpointsURL, atomically: true, encoding: .utf8)
        try betaSoakEvidencePayload(samples: [
            betaSoakSample(
                successfulTools: ["slack.thread"],
                model: "Qwen/Qwen3-8B-MLX-4bit"
            ),
            betaSoakSample(
                successfulTools: [
                    "task.write_output",
                    "workspace.write_file",
                    "shell.exec",
                    "network.fetch",
                    "browser.click",
                    "browser.type"
                ],
                model: "Qwen/Qwen3-8B-MLX-4bit"
            )
        ]).write(to: wrongModelBetaURL, atomically: true, encoding: .utf8)
        let malformedBetaPayload = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-28T00:00:00Z",
          "samples": [
            {
              "recordedAt": "2026-05-28T00:00:00Z",
              "model": "Qwen/Qwen3-4B-MLX-4bit",
              "outcome": "completed",
              "stopReason": "final",
              "enabledCapabilities": [],
              "proposedTools": [],
              "executedTools": [],
              "successfulTools": "workspace.read_file"
            }
          ]
        }
        """
        try malformedBetaPayload.write(to: malformedBetaURL, atomically: true, encoding: .utf8)

        let incompleteHardwarePayload = try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed)
        ])
        try incompleteHardwarePayload.write(to: incompleteHardwareURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(
                memoryBytes: 16 * gib,
                chip: "Apple M2",
                outcome: .passed,
                inputTokens: nil
            ),
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed)
        ]).write(to: missingTelemetryHardwareURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(
                memoryBytes: 16 * gib,
                chip: "Apple M2",
                outcome: .passed,
                model: "Qwen/Qwen3-8B-MLX-4bit"
            ),
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed)
        ]).write(to: wrongModelHardwareURL, atomically: true, encoding: .utf8)

        let proOnlyReadiness = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", incompleteHardwareURL.path,
            "--require-complete"
        ])
        #expect(proOnlyReadiness.status == 0)
        #expect(proOnlyReadiness.output.contains("Gate A Local Chat preview: passed"))
        #expect(proOnlyReadiness.output.contains("Gate B Local Agent developer flag: passed"))
        #expect(proOnlyReadiness.output.contains("Gate C Local Agent beta: passed"))
        #expect(proOnlyReadiness.output.contains("Gate D General availability: passed"))
        #expect(proOnlyReadiness.output.contains("Missing hardware tiers:\n  - none"))

        let missingTelemetry = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", missingTelemetryHardwareURL.path,
            "--require-complete"
        ])
        #expect(missingTelemetry.status == 0)
        #expect(missingTelemetry.output.contains("Gate D General availability: passed"))

        let wrongModelHardware = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", wrongModelHardwareURL.path,
            "--require-complete"
        ])
        #expect(wrongModelHardware.status == 0)
        #expect(wrongModelHardware.output.contains("Gate D General availability: passed"))

        let completeHardwarePayload = try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
            sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed),
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed),
            sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed)
        ])
        try completeHardwarePayload.write(to: completeHardwareURL, atomically: true, encoding: .utf8)
        try releaseCandidateEvidencePayload(samples: [
            releaseCandidateSample(mode: .localChat, inputTokens: 0),
            releaseCandidateSample(mode: .localAgentReadOnly, outputTokens: 0)
        ]).write(to: invalidReleaseURL, atomically: true, encoding: .utf8)
        let malformedReleasePayload = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-28T00:00:00Z",
          "samples": [
            {
              "mode": "local_chat",
              "model": "Qwen/Qwen3-4B-MLX-4bit",
              "modelDirectory": "/tmp/Qwen3-4B-MLX-4bit",
              "helperPath": "/tmp/astra-local-model",
              "outcome": "passed",
              "inputTokens": "several",
              "outputTokens": "one",
              "stopReason": "complete",
              "marker": "ASTRA_E2E_TEXT_OK"
            }
          ]
        }
        """
        try malformedReleasePayload.write(to: malformedReleaseURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected)
        ]).write(to: lowMemoryHardwareURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed)
        ]).write(to: baseHardwareURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed)
        ]).write(to: proHardwareURL, atomically: true, encoding: .utf8)
        try hardwareEvidencePayload(samples: [
            sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed)
        ]).write(to: maxHardwareURL, atomically: true, encoding: .utf8)

        let completeBundlePayload = try combinedReleaseEvidencePayload(
            releaseCandidateSamples: [
                releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+1"),
                releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1")
            ],
            betaSoakSamples: [
                betaSoakSample(successfulTools: ["slack.thread"]),
                betaSoakSample(successfulTools: [
                    "task.write_output",
                    "workspace.write_file",
                    "shell.exec",
                    "network.fetch",
                    "browser.click",
                    "browser.type"
                ])
            ],
            hardwareSamples: [
                sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
                sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed),
                sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed),
                sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed)
            ]
        )
        try completeBundlePayload.write(to: completeBundleURL, atomically: true, encoding: .utf8)
        try combinedReleaseEvidencePayload(
            releaseCandidateSamples: [
                releaseCandidateSample(mode: .localChat, buildIdentifier: "astra-0.1.0+1"),
                releaseCandidateSample(mode: .localAgentReadOnly, buildIdentifier: "astra-0.1.0+1")
            ],
            betaSoakSamples: [
                betaSoakSample(successfulTools: ["slack.thread"]),
                betaSoakSample(successfulTools: [
                    "task.write_output",
                    "workspace.write_file",
                    "shell.exec",
                    "network.fetch",
                    "browser.click",
                    "browser.type"
                ])
            ],
            hardwareSamples: [
                sustainedSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: .blockedAsExpected),
                sustainedSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: .passed),
                sustainedSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: .passed)
            ]
        ).write(to: releaseBundleURL, atomically: true, encoding: .utf8)
        try combinedReleaseEvidencePayload(
            releaseCandidateSamples: [],
            betaSoakSamples: [],
            hardwareSamples: [
                sustainedSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: .passed)
            ]
        ).write(to: baseHardwareBundleURL, atomically: true, encoding: .utf8)

        let invalidRelease = try runReleaseReadinessInspector([
            "--release-candidate", invalidReleaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(invalidRelease.status == 1)
        #expect(invalidRelease.output.contains("Gate A Local Chat preview: in_progress"))
        #expect(invalidRelease.output.contains("Gate B Local Agent developer flag: in_progress"))
        #expect(invalidRelease.output.contains("Missing release modes:"))
        #expect(invalidRelease.output.contains("Private Local Chat live e2e"))
        #expect(invalidRelease.output.contains("Local Agent read-only live e2e"))
        #expect(invalidRelease.output.contains("Next release-candidate collection:"))
        #expect(invalidRelease.output.contains("Preview the build id, helper, model folder, and output path first:"))
        #expect(invalidRelease.output.contains("--dry-run"))
        #expect(invalidRelease.output.contains("script/local_mlx_collect_release_evidence.sh"))
        #expect(invalidRelease.output.contains("--out /tmp/astra-local-mlx-release-evidence.json"))

        let malformedRelease = try runReleaseReadinessInspector([
            "--release-candidate", malformedReleaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(malformedRelease.status == 1)
        #expect(malformedRelease.output.contains("Release-candidate samples: 1"))
        #expect(malformedRelease.output.contains("Gate A Local Chat preview: in_progress"))
        #expect(!malformedRelease.output.contains("Traceback"))

        let wrongModelRelease = try runReleaseReadinessInspector([
            "--release-candidate", wrongModelReleaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(wrongModelRelease.status == 1)
        #expect(wrongModelRelease.output.contains("Gate A Local Chat preview: in_progress"))
        #expect(wrongModelRelease.output.contains("Gate B Local Agent developer flag: in_progress"))
        #expect(wrongModelRelease.output.contains("Missing release modes:"))
        #expect(wrongModelRelease.output.contains("Non-covering release-candidate samples:"))
        #expect(wrongModelRelease.output.contains("2 sample(s) did not satisfy Gate A/B evidence rules"))
        #expect(wrongModelRelease.output.contains("Private Local Chat live e2e"))
        #expect(wrongModelRelease.output.contains("Local Agent read-only live e2e"))

        let malformedBeta = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", malformedBetaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(malformedBeta.status == 1)
        #expect(malformedBeta.output.contains("Beta-soak samples: 1"))
        #expect(malformedBeta.output.contains("Read-only Local Agent workflow: missing"))
        #expect(malformedBeta.output.contains("Non-covering beta-soak samples:"))
        #expect(malformedBeta.output.contains("1 sample(s) did not satisfy Gate C evidence rules"))
        #expect(malformedBeta.output.contains("beta-soak samples must complete with Qwen/Qwen3-4B-MLX-4bit"))
        #expect(!malformedBeta.output.contains("Traceback"))

        let wrongModelBeta = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", wrongModelBetaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(wrongModelBeta.status == 1)
        #expect(wrongModelBeta.output.contains("Gate C Local Agent beta: in_progress"))
        #expect(wrongModelBeta.output.contains("Read-only Local Agent workflow: missing"))
        #expect(wrongModelBeta.output.contains("Non-covering beta-soak samples:"))
        #expect(wrongModelBeta.output.contains("2 sample(s) did not satisfy Gate C evidence rules"))
        #expect(wrongModelBeta.output.contains("beta-soak samples must complete with Qwen/Qwen3-4B-MLX-4bit"))
        #expect(wrongModelBeta.output.contains("task.write_output"))
        #expect(wrongModelBeta.output.contains("Gate D General availability: in_progress"))

        let incompleteBetaURL = directory.appendingPathComponent("incomplete-beta.json")
        try betaSoakEvidencePayload(samples: [
            betaSoakSample(successfulTools: ["slack.thread"])
        ]).write(to: incompleteBetaURL, atomically: true, encoding: .utf8)
        let otherwiseCompleteButMissingBeta = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", incompleteBetaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(otherwiseCompleteButMissingBeta.status == 1)
        #expect(otherwiseCompleteButMissingBeta.output.contains("Gate A Local Chat preview: passed"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Gate B Local Agent developer flag: passed"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Gate C Local Agent beta: in_progress"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Gate D General availability: in_progress"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Missing beta coverage:"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("task.write_output"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Next beta collection:"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Preview high-risk Local Agent beta collection first:"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("script/local_mlx_collect_release_evidence.sh"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("--include-high-risk-tools"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("--dry-run"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("--beta-out /tmp/astra-local-agent-beta-soak-evidence.json"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Missing hardware tiers:\n  - none"))
        #expect(otherwiseCompleteButMissingBeta.output.contains("Missing build-bound release modes:\n  - none"))

        let unboundRelease = try runReleaseReadinessInspector([
            "--release-candidate", unboundReleaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(unboundRelease.status == 1)
        #expect(unboundRelease.output.contains("Gate A Local Chat preview: passed"))
        #expect(unboundRelease.output.contains("Gate B Local Agent developer flag: passed"))
        #expect(unboundRelease.output.contains("Gate D General availability: in_progress"))
        #expect(unboundRelease.output.contains("Missing release modes:\n  - none"))
        #expect(unboundRelease.output.contains("Missing build-bound release modes:"))
        #expect(unboundRelease.output.contains("Private Local Chat live e2e"))
        #expect(unboundRelease.output.contains("Local Agent read-only live e2e"))
        #expect(unboundRelease.output.contains("Next release-candidate collection:"))

        let complete = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete"
        ])
        #expect(complete.status == 0)
        #expect(complete.output.contains("Gate D General availability: passed"))
        #expect(complete.output.contains("Missing beta coverage:\n  - none"))
        #expect(!complete.output.contains("Next release-candidate collection:"))
        #expect(!complete.output.contains("Next beta collection:"))
        #expect(complete.output.contains("Missing hardware tiers:\n  - none"))
        #expect(complete.output.contains("Missing build-bound release modes:\n  - none"))
        #expect(!complete.output.contains("Next hardware collection:"))
        #expect(complete.output.contains("Bundle evidence for Runtime settings import:"))
        #expect(complete.output.contains("Release packaging preflight:"))
        #expect(complete.output.contains("ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1"))
        #expect(complete.output.contains("ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1"))
        #expect(complete.output.contains("ASTRA_LOCAL_MLX_RELEASE_EVIDENCE="))
        #expect(complete.output.contains("ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE="))
        #expect(complete.output.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES="))
        #expect(complete.output.contains("script/release_update.sh"))

        let completeWithApprovalCheckpoints = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaWithApprovalCheckpointsURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-complete",
            "--require-clean-evidence"
        ])
        #expect(completeWithApprovalCheckpoints.status == 0)
        #expect(completeWithApprovalCheckpoints.output.contains("Gate C Local Agent beta: passed"))
        #expect(completeWithApprovalCheckpoints.output.contains("Beta-soak samples: 3"))
        #expect(completeWithApprovalCheckpoints.output.contains("Non-covering beta-soak samples:\n  - none"))

        let bundleCreate = try runValidationBundleBuilder([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--out", cliBundleURL.path
        ])
        #expect(bundleCreate.status == 0)
        #expect(bundleCreate.output.contains("Local MLX validation bundle written to:"))
        #expect(bundleCreate.output.contains("Bundle samples: 2 release-candidate, 2 beta-soak, 4 hardware."))
        let bundleDryRunURL = directory.appendingPathComponent("dry-run-bundle.json")
        let bundleDryRun = try runValidationBundleBuilder([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--out", bundleDryRunURL.path,
            "--dry-run"
        ])
        #expect(bundleDryRun.status == 0)
        #expect(bundleDryRun.output.contains("Local MLX validation bundle dry run"))
        #expect(bundleDryRun.output.contains("Bundle samples: 2 release-candidate, 2 beta-soak, 4 hardware."))
        #expect(bundleDryRun.output.contains("Bundle output would be written to: \(bundleDryRunURL.path)"))
        #expect(!FileManager.default.fileExists(atPath: bundleDryRunURL.path))
        let cliBundled = try runReleaseReadinessInspector([
            "--bundle", cliBundleURL.path,
            "--require-build-id", "astra-0.1.0+1",
            "--require-complete"
        ])
        #expect(cliBundled.status == 0)
        #expect(cliBundled.output.contains("Release-candidate samples: 2"))
        #expect(cliBundled.output.contains("Beta-soak samples: 2"))
        #expect(cliBundled.output.contains("Hardware samples: 4"))
        #expect(cliBundled.output.contains("Gate D General availability: passed"))
        #expect(cliBundled.output.contains("--out '/tmp/astra-local-mlx-validation-bundle-merged.json'"))
        #expect(!cliBundled.output.contains("--bundle '\(cliBundleURL.path)' \\\n    --out '\(cliBundleURL.path)'"))
        #expect(cliBundled.output.contains("Release packaging preflight:"))
        #expect(cliBundled.output.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE="))
        #expect(cliBundled.output.contains("script/release_update.sh"))

        let emptyBundle = try runValidationBundleBuilder([])
        #expect(emptyBundle.status == 2)
        #expect(emptyBundle.output.contains("no Local MLX evidence samples provided"))

        let malformedBundleReleaseURL = directory.appendingPathComponent("malformed-bundle-release.json")
        try "not json".write(to: malformedBundleReleaseURL, atomically: true, encoding: .utf8)
        let malformedBundle = try runValidationBundleBuilder([
            "--release-candidate", malformedBundleReleaseURL.path
        ])
        #expect(malformedBundle.status == 2)
        #expect(malformedBundle.output.contains("release-candidate evidence file \(malformedBundleReleaseURL.path): no JSON object found"))

        let currentBuild = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-build-id", "astra-0.1.0+1",
            "--require-complete"
        ])
        #expect(currentBuild.status == 0)
        #expect(currentBuild.output.contains("Required release build id: astra-0.1.0+1"))
        #expect(currentBuild.output.contains("Gate A Local Chat preview: passed"))
        #expect(currentBuild.output.contains("Gate D General availability: passed"))

        let staleBuild = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--require-build-id", "astra-0.1.0+2",
            "--require-complete"
        ])
        #expect(staleBuild.status == 1)
        #expect(staleBuild.output.contains("Required release build id: astra-0.1.0+2"))
        #expect(staleBuild.output.contains("Gate A Local Chat preview: in_progress"))
        #expect(staleBuild.output.contains("Missing release modes:"))
        #expect(staleBuild.output.contains("Private Local Chat live e2e"))
        #expect(staleBuild.output.contains("Local Agent read-only live e2e"))

        let splitHardware = try runReleaseReadinessInspector([
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", lowMemoryHardwareURL.path,
            "--hardware", baseHardwareURL.path,
            "--hardware", proHardwareURL.path,
            "--hardware", maxHardwareURL.path,
            "--require-complete"
        ])
        #expect(splitHardware.status == 0)
        #expect(splitHardware.output.contains("Hardware samples: 4"))
        #expect(splitHardware.output.contains("Gate D General availability: passed"))
        #expect(splitHardware.output.contains("Missing hardware tiers:\n  - none"))

        let bundled = try runReleaseReadinessInspector([
            "--bundle", completeBundleURL.path,
            "--require-complete"
        ])
        #expect(bundled.status == 0)
        #expect(bundled.output.contains("Gate A Local Chat preview: passed"))
        #expect(bundled.output.contains("Gate D General availability: passed"))

        let currentBuildBundle = try runReleaseReadinessInspector([
            "--bundle", completeBundleURL.path,
            "--require-build-id", "astra-0.1.0+1",
            "--require-complete"
        ])
        #expect(currentBuildBundle.status == 0)
        #expect(currentBuildBundle.output.contains("Required release build id: astra-0.1.0+1"))
        #expect(currentBuildBundle.output.contains("Gate D General availability: passed"))

        let staleBuildBundle = try runReleaseReadinessInspector([
            "--bundle", completeBundleURL.path,
            "--require-build-id", "astra-0.1.0+2",
            "--require-complete"
        ])
        #expect(staleBuildBundle.status == 1)
        #expect(staleBuildBundle.output.contains("Required release build id: astra-0.1.0+2"))
        #expect(staleBuildBundle.output.contains("Missing release modes:"))
        #expect(staleBuildBundle.output.contains("Private Local Chat live e2e"))
        #expect(staleBuildBundle.output.contains("Local Agent read-only live e2e"))

        let splitBundles = try runReleaseReadinessInspector([
            "--bundle", releaseBundleURL.path,
            "--bundle", baseHardwareBundleURL.path,
            "--require-complete"
        ])
        #expect(splitBundles.status == 0)
        #expect(splitBundles.output.contains("Hardware samples: 4"))
        #expect(splitBundles.output.contains("Gate D General availability: passed"))
        #expect(splitBundles.output.contains("Bundle evidence for Runtime settings import:"))
        #expect(splitBundles.output.contains("--bundle '\(releaseBundleURL.path)'"))
        #expect(splitBundles.output.contains("--bundle '\(baseHardwareBundleURL.path)'"))
        #expect(splitBundles.output.contains("# First run the bundle command above"))
        #expect(splitBundles.output.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json"))

        let mergedBundleURL = directory.appendingPathComponent("merged-bundle.json")
        let mergeBundles = try runValidationBundleBuilder([
            "--bundle", releaseBundleURL.path,
            "--bundle", baseHardwareBundleURL.path,
            "--out", mergedBundleURL.path
        ])
        #expect(mergeBundles.status == 0)
        #expect(mergeBundles.output.contains("Bundle samples: 2 release-candidate, 2 beta-soak, 4 hardware."))
        let selfOverwrite = try runValidationBundleBuilder([
            "--bundle", releaseBundleURL.path,
            "--out", releaseBundleURL.path
        ])
        #expect(selfOverwrite.status == 2)
        #expect(selfOverwrite.output.contains("--out must not point to the same file as an input --bundle"))
        let selfOverwriteDryRun = try runValidationBundleBuilder([
            "--bundle", releaseBundleURL.path,
            "--out", releaseBundleURL.path,
            "--dry-run"
        ])
        #expect(selfOverwriteDryRun.status == 0)
        #expect(selfOverwriteDryRun.output.contains("Local MLX validation bundle dry run"))
        let duplicateBundleURL = directory.appendingPathComponent("duplicate-bundle.json")
        let duplicateMerge = try runValidationBundleBuilder([
            "--bundle", releaseBundleURL.path,
            "--bundle", releaseBundleURL.path,
            "--bundle", baseHardwareBundleURL.path,
            "--bundle", baseHardwareBundleURL.path,
            "--release-candidate", releaseURL.path,
            "--beta-soak", betaURL.path,
            "--hardware", completeHardwareURL.path,
            "--out", duplicateBundleURL.path
        ])
        #expect(duplicateMerge.status == 0)
        #expect(duplicateMerge.output.contains("Bundle samples: 2 release-candidate, 2 beta-soak, 4 hardware."))
        let mergedBundlesReady = try runReleaseReadinessInspector([
            "--bundle", mergedBundleURL.path,
            "--require-complete"
        ])
        #expect(mergedBundlesReady.status == 0)
        #expect(mergedBundlesReady.output.contains("Gate D General availability: passed"))

        let wrappedBundleURL = directory.appendingPathComponent("wrapped-complete-bundle.md")
        try wrappedEvidencePayload(completeBundlePayload).write(to: wrappedBundleURL, atomically: true, encoding: .utf8)
        let wrappedBundle = try runReleaseReadinessInspector([
            "--bundle", wrappedBundleURL.path,
            "--require-complete"
        ])
        #expect(wrappedBundle.status == 0)
        #expect(wrappedBundle.output.contains("Gate D General availability: passed"))
    }

    @Test("Sustained validation service records repeated local smoke samples")
    func sustainedValidationServiceRecordsRepeatedLocalSmokeSamples() async throws {
        let defaultsName = "astra-local-sustained-validation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        defaults.set("test/local-model", forKey: LocalModelSettingsStore.preferredModelKey)

        let modelURL = try completeModelDirectory()
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let configuration = RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        )
        let smoke = LocalModelSmokeReport(
            status: "ok",
            backend: "mlx",
            model: "test/local-model",
            inputTokens: 7,
            outputTokens: 4,
            durationMs: 1_400,
            firstTokenLatencyMs: 520,
            tokensPerSecond: 3.75
        )
        let smokeJSON = String(data: try JSONEncoder().encode(smoke), encoding: .utf8) ?? "{}"
        let runner = RecordingInstallRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: smokeJSON,
            stderr: ""
        ))
        let service = LocalModelSustainedValidationService(
            runner: runner,
            detectExecutable: { _ in "/tmp/astra-local-model" },
            isExecutable: { $0 == "/tmp/astra-local-model" },
            hardwareProfile: {
                LocalHardwareProfile(
                    isAppleSilicon: true,
                    physicalMemoryBytes: 64 * LocalModelMemoryBudget.gib,
                    cpuBrand: "Apple M2 Max"
                )
            },
            now: { Date(timeIntervalSince1970: 2_200) }
        )

        let run = await service.run(
            configuration: configuration,
            mode: .localChat,
            iterations: 2,
            defaults: defaults
        )

        #expect(run.check.id == "local-mlx-sustained-validation")
        #expect(run.check.state == .warning)
        #expect(run.check.detail.contains("Completed 2 local response checks"))
        #expect(run.check.detail.contains("3.8 tok/s"))
        #expect(run.hardwareReport.missingTiers.contains(.pro32GBPlus))

        let samples = LocalModelHardwareValidationStore.samples(defaults: defaults)
        let sample = try #require(samples.last)
        #expect(sample.outcome == .passed)
        #expect(sample.mode == .localChat)
        #expect(sample.iterations == 2)
        #expect(sample.profile.chipClass == "max")
        #expect(sample.profile.tokensPerSecond == 3.75)
        #expect(LocalModelPerformanceStore.profile(defaults: defaults)?.tokensPerSecond == 3.75)

        let calls = await runner.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.path == "/tmp/astra-local-model" })
        #expect(calls.allSatisfy { $0.args.first == "--smoke" })
        #expect(calls.allSatisfy { $0.args.contains("--memory-budget-bytes") })
    }

    @Test("Sustained validation records expected low-memory blocks without launching the helper")
    func sustainedValidationRecordsExpectedLowMemoryBlocksWithoutLaunchingHelper() async throws {
        let defaultsName = "astra-local-low-memory-validation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let runner = RecordingInstallRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: ""
        ))
        let service = LocalModelSustainedValidationService(
            runner: runner,
            detectExecutable: { _ in "/tmp/astra-local-model" },
            isExecutable: { _ in true },
            hardwareProfile: {
                LocalHardwareProfile(
                    isAppleSilicon: true,
                    physicalMemoryBytes: 8 * LocalModelMemoryBudget.gib,
                    cpuBrand: "Apple M2"
                )
            },
            now: { Date(timeIntervalSince1970: 2_300) }
        )

        let run = await service.run(
            configuration: RuntimeReadinessConfiguration(
                runtime: .localMLX,
                providerSettings: AgentRuntimeProviderSettings(),
                claudeProvider: .anthropic,
                vertexProjectID: "",
                vertexRegion: "",
                vertexOpusModel: "",
                vertexSonnetModel: "",
                vertexHaikuModel: ""
            ),
            mode: .localAgentReadOnly,
            defaults: defaults
        )

        #expect(run.check.state == .warning)
        #expect(run.check.detail.contains("below the local model memory target"))
        let sample = try #require(LocalModelHardwareValidationStore.samples(defaults: defaults).last)
        #expect(sample.outcome == .blockedAsExpected)
        #expect(sample.mode == .localAgentReadOnly)
        #expect(run.hardwareReport.missingTiers.contains(.pro32GBPlus))
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test("Hardware tiers distinguish 8GB 16GB and 32GB class Macs")
    func hardwareTiersDistinguishMemoryClasses() {
        let gib: UInt64 = 1_073_741_824

        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 8 * gib,
            cpuBrand: "Apple M2"
        ).tier == .unsupported8GB)
        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * gib,
            cpuBrand: "Apple M2 Pro"
        ).tier == .minimum16GB)
        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Max"
        ).tier == .recommended32GBPlus)
        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Max"
        ).chipClass == "max")
        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * gib,
            cpuBrand: "Apple M2"
        ).capacityLabel == "16 GB minimum")
        #expect(LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Max"
        ).speedLabel == "Max-class bandwidth")
    }

    @Test("Local Agent hardware policy requires a stronger tier than Local Chat")
    func localAgentHardwarePolicyRequiresStrongerTierThanLocalChat() {
        let gib: UInt64 = 1_073_741_824
        let unsupported = LocalAgentHardwareSupport.readinessCheck(hardware: LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 8 * gib,
            cpuBrand: "Apple M2"
        ))
        let minimum = LocalAgentHardwareSupport.readinessCheck(hardware: LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * gib,
            cpuBrand: "Apple M2"
        ))
        let recommended = LocalAgentHardwareSupport.readinessCheck(hardware: LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Pro"
        ))

        #expect(unsupported.state == .blocked)
        #expect(unsupported.remediation?.contains("32 GB or larger for Local Agent beta") == true)
        #expect(minimum.state == .warning)
        #expect(minimum.detail.contains("32 GB or more is the supported beta target"))
        #expect(recommended.state == .ready)
    }

    @Test("Memory budget blocks models that exceed conservative tier capacity")
    func memoryBudgetBlocksModelsThatExceedConservativeTierCapacity() {
        let gib: UInt64 = 1_073_741_824
        let hardware = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * gib,
            cpuBrand: "Apple M2"
        )
        let metadata = LocalModelMetadata(
            directory: "/tmp/model",
            modelType: "gemma4",
            architectures: ["Gemma4TextForCausalLM"],
            quantizationMethod: "bitsandbytes",
            weightFileCount: 2,
            weightBytes: 9 * gib,
            hiddenSize: 4096,
            layerCount: 32,
            attentionHeadCount: 32,
            keyValueHeadCount: 8
        )

        let check = LocalModelMemoryBudget.readinessCheck(
            metadata: metadata,
            hardware: hardware,
            maxContextTokens: 16_384
        )

        #expect(check.id == "local-mlx-memory-fit")
        #expect(check.state == .blocked)
    }

    @Test("Memory budget requires 32 GB tier for Gemma 4 12B")
    func memoryBudgetRequires32GBTierForGemma412B() {
        let gib: UInt64 = 1_073_741_824
        let metadata = LocalModelMetadata(
            directory: "/tmp/gemma-4-12B-it-4bit",
            modelType: "gemma4_unified",
            architectures: ["Gemma4UnifiedForConditionalGeneration"],
            quantizationMethod: "4-bit",
            weightFileCount: 2,
            weightBytes: 5 * gib,
            hiddenSize: 4096,
            layerCount: 32,
            attentionHeadCount: 32,
            keyValueHeadCount: 8,
            hasVisionConfig: true
        )
        let minimum = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * gib,
            cpuBrand: "Apple M2"
        )
        let recommended = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Pro"
        )

        let minimumCheck = LocalModelMemoryBudget.readinessCheck(
            metadata: metadata,
            hardware: minimum,
            maxContextTokens: 4_096
        )
        let recommendedCheck = LocalModelMemoryBudget.readinessCheck(
            metadata: metadata,
            hardware: recommended,
            maxContextTokens: 4_096
        )

        #expect(minimumCheck.state == .blocked)
        #expect(minimumCheck.detail.contains("Gemma 4 12B"))
        #expect(recommendedCheck.state != .blocked)
    }

    @Test("Readiness guidance distinguishes common local model setup failures")
    func readinessGuidanceDistinguishesCommonLocalModelSetupFailures() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        var missingHelperSettings = AgentRuntimeProviderSettings()
        missingHelperSettings.setExecutablePath("/tmp/astra-missing-local-helper", for: .localMLX)
        let missingHelperService = RuntimeReadinessService(
            runner: StubBinaryRunner(),
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        )
        let missingHelperReport = await missingHelperService.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: missingHelperSettings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))
        let helper = try #require(missingHelperReport.checks.first { $0.id == "local-mlx-helper" })

        let noModel = LocalModelCatalog.validate(directory: "")

        let unsupportedDirectory = temporaryDirectory()
        try modelConfig(modelType: "unknown_research_model").write(
            to: unsupportedDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: unsupportedDirectory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: unsupportedDirectory.appendingPathComponent("model.safetensors"))
        let unsupported = LocalModelCatalog.validate(directory: unsupportedDirectory.path)

        let gib: UInt64 = 1_073_741_824
        let oversized = LocalModelMemoryBudget.readinessCheck(
            metadata: LocalModelMetadata(
                directory: "/tmp/oversized-model",
                modelType: "qwen3",
                architectures: ["Qwen3ForCausalLM"],
                quantizationMethod: "bitsandbytes",
                weightFileCount: 2,
                weightBytes: 10 * gib,
                hiddenSize: 4096,
                layerCount: 40,
                attentionHeadCount: 32,
                keyValueHeadCount: 8
            ),
            hardware: LocalHardwareProfile(
                isAppleSilicon: true,
                physicalMemoryBytes: 16 * gib,
                cpuBrand: "Apple M2"
            ),
            maxContextTokens: 32_768
        )

        #expect(helper.state == .blocked)
        #expect(helper.detail == "ASTRA local model support was not found.")
        #expect(helper.remediation == "Update or reinstall ASTRA so local model support is restored.")

        #expect(noModel.state == .blocked)
        #expect(noModel.detail == "No local model folder is selected.")
        #expect(noModel.remediation?.contains("Install the recommended local model") == true)

        #expect(unsupported.state == .blocked)
        #expect(unsupported.detail.contains("installed but unsupported"))
        #expect(unsupported.detail.contains("unknown_research_model"))
        #expect(unsupported.remediation?.contains("Install the recommended Qwen model") == true)
        #expect(unsupported.remediation?.contains("Gemma") != true)

        #expect(oversized.state == .blocked)
        #expect(oversized.remediation?.contains("too large for the current memory budget") == true)
    }

    @Test("Configured memory budget can only tighten automatic ceiling")
    func configuredMemoryBudgetCanOnlyTightenAutomaticCeiling() {
        let gib: UInt64 = 1_073_741_824
        let hardware = LocalHardwareProfile(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * gib,
            cpuBrand: "Apple M2 Max"
        )

        let automatic = LocalModelMemoryBudget.budgetBytes(for: hardware)

        #expect(LocalModelMemoryBudget.effectiveBudgetBytes(for: hardware, configuredBudgetBytes: nil) == automatic)
        #expect(LocalModelMemoryBudget.effectiveBudgetBytes(for: hardware, configuredBudgetBytes: 6 * gib) == 6 * gib)
        #expect(LocalModelMemoryBudget.effectiveBudgetBytes(for: hardware, configuredBudgetBytes: 64 * gib) == automatic)
    }

    @Test("Native MLX helper is bundled by default and isolated from default package")
    func nativeMLXHelperIsBundledByDefaultAndIsolatedFromDefaultPackage() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let nativePackage = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Tools/AstraLocalModelNative/Package.swift"),
            encoding: .utf8
        )
        let nativeEntrypoint = try String(
            contentsOf: repoRoot
                .appendingPathComponent("Tools/AstraLocalModelNative/Sources/AstraLocalModelNative/main.swift"),
            encoding: .utf8
        )
        let scaffoldEntrypoint = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/AstraLocalModelTool/main.swift"),
            encoding: .utf8
        )
        let nativeReadme = try String(
            contentsOf: repoRoot.appendingPathComponent("Tools/AstraLocalModelNative/README.md"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        #expect(!package.contains("mlx-swift-lm"))
        #expect(!package.contains("swift-transformers"))
        #expect(nativePackage.contains("mlx-swift-lm"))
        #expect(nativePackage.contains(".product(name: \"MLX\", package: \"mlx-swift\")"))
        #expect(nativePackage.contains(".product(name: \"MLXVLM\", package: \"mlx-swift-lm\")"))
        #expect(nativePackage.contains("swift-transformers"))
        #expect(nativePackage.contains("astra-local-model-native"))
        #expect(!nativePackage.contains("executable(name: \"astra-local-model\""))
        #expect(nativePackage.contains(".product(name: \"ASTRACore\", package: \"ASTRA\")"))
        #expect(nativeEntrypoint.contains("MLXLMCommon.loadModelContainer"))
        #expect(nativeEntrypoint.contains("import MLXVLM"))
        #expect(!nativeEntrypoint.contains("registerAstraVLMCompatibilityAliases"))
        #expect(!nativeEntrypoint.contains(#""gemma4_unified""#))
        #expect(!nativeEntrypoint.contains("Gemma4UnifiedProcessor"))
        #expect(nativeEntrypoint.contains("UserInput.Image.url"))
        #expect(nativeEntrypoint.contains("Memory.memoryLimit"))
        #expect(nativeEntrypoint.contains("Memory.snapshot()"))
        #expect(nativeEntrypoint.contains("memoryBudgetBytes"))
        #expect(nativeEntrypoint.contains("waitForKeepWarmTTL"))
        #expect(nativeEntrypoint.contains("idle_keep_warm"))
        let completedRange = try #require(nativeEntrypoint.range(of: #"try emit(.init(type: "completed""#))
        let runOnceAfterCompletion = nativeEntrypoint[completedRange.upperBound...]
        let unsupportedArchitectureRange = try #require(runOnceAfterCompletion.range(of: "#else"))
        #expect(!runOnceAfterCompletion[..<unsupportedArchitectureRange.lowerBound].contains("waitForKeepWarmTTL"))
        #expect(nativeEntrypoint.contains("runSmoke"))
        #expect(nativeEntrypoint.contains("LocalModelSmokeReport"))
        #expect(nativeEntrypoint.contains("modelRootArgumentValue"))
        #expect(nativeEntrypoint.contains(#"argumentValue("--models-root", in: arguments) ?? argumentValue("--models-dir", in: arguments)"#))
        #expect(nativeEntrypoint.contains("protocolChannelClosed"))
        #expect(nativeEntrypoint.contains("F_SETNOSIGPIPE"))
        #expect(nativeEntrypoint.contains("#huggingFaceTokenizerLoader()"))
        #expect(nativeEntrypoint.contains(#""backend":"mlx""#))
        #expect(scaffoldEntrypoint.contains("modelRootArgumentValue"))
        #expect(scaffoldEntrypoint.contains(#"argumentValue("--models-root", in: arguments) ?? argumentValue("--models-dir", in: arguments)"#))
        #expect(scaffoldEntrypoint.contains(#"argumentValue("--request-file", in: arguments) != nil"#))
        #expect(buildScript.contains(#"LOCAL_MODEL_BACKEND="${ASTRA_LOCAL_MODEL_BACKEND:-mlx}""#))
        #expect(buildScript.contains("scaffold|mlx)"))
        #expect(buildScript.contains(#""$LOCAL_MODEL_BACKEND" == "scaffold""#))
        #expect(buildScript.contains("Production and beta ASTRA bundles must include the native MLX local model helper."))
        #expect(buildScript.contains("The scaffold helper is only allowed for development-channel builds."))
        #expect(!buildScript.contains("ASTRA_ALLOW_SCAFFOLD_LOCAL_MODEL_RELEASE"))
        #expect(buildScript.contains("build_native_local_model_metallib"))
        #expect(buildScript.contains("default.metallib"))
        #expect(buildScript.contains("mlx.metallib"))
        #expect(buildScript.contains("xcodebuild -downloadComponent MetalToolchain"))
        #expect(buildScript.contains("Tools/AstraLocalModelNative"))
        #expect(nativeReadme.contains("Runtime settings downloads supported MLX"))
        #expect(nativeReadme.contains("LocalModels"))
        #expect(nativeReadme.contains("Manual"))
        #expect(nativeReadme.contains("advanced import path"))
        #expect(!nativeReadme.contains("does not download model weights"))
    }

    @Test("Local model chat messages round trip image attachments")
    func localModelChatMessagesRoundTripImageAttachments() throws {
        let message = LocalModelChatMessage(
            role: "user",
            content: "What is in this image?",
            attachments: [.image(path: "/tmp/screenshot.png", source: "clipboard", mimeType: "image/png")]
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LocalModelChatMessage.self, from: data)
        let legacyDecoded = try JSONDecoder().decode(
            LocalModelChatMessage.self,
            from: #"{"role":"user","content":"hello"}"#.data(using: .utf8) ?? Data()
        )

        #expect(decoded == message)
        #expect(decoded.attachments.first?.isImage == true)
        #expect(legacyDecoded.attachments.isEmpty)
    }

    @Test("Local model input media extracts clipboard and file picker images")
    func localModelInputMediaExtractsClipboardAndFilePickerImages() throws {
        let root = temporaryDirectory()
        let image = root.appendingPathComponent("pasted.png")
        let text = root.appendingPathComponent("notes.txt")
        try Data([0]).write(to: image)
        try "notes".write(to: text, atomically: true, encoding: .utf8)

        let prompt = """
        Review this.

        Attached files:
        - \(image.path)
        - \(text.path)
        """
        let attachments = LocalModelInputMedia.imageAttachments(
            prompt: prompt,
            taskInputs: [image.path, text.path]
        )

        #expect(attachments == [
            .image(path: image.standardizedFileURL.path, source: "task_input", mimeType: "image/png")
        ])
    }

    @Test("Adapter plans dedicated FD3 local helper launch")
    @MainActor
    func adapterPlansDedicatedFD3LocalHelperLaunch() throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)
        UserDefaults.standard.set(512, forKey: LocalModelSettingsStore.maxOutputTokensKey)
        UserDefaults.standard.set(90, forKey: LocalModelSettingsStore.keepWarmTTLSecondsKey)
        UserDefaults.standard.set(6, forKey: LocalModelSettingsStore.memoryBudgetGBKey)
        UserDefaults.standard.set(5, forKey: LocalModelSettingsStore.localAgentMaxTurnsKey)
        UserDefaults.standard.set(4, forKey: LocalModelSettingsStore.localAgentMaxToolCallsKey)
        UserDefaults.standard.set(20, forKey: LocalModelSettingsStore.localAgentToolTimeoutSecondsKey)

        let workspaceURL = temporaryDirectory()
        let modelURL = temporaryDirectory()
        let workspace = Workspace(name: "Local", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Local",
            goal: "Say hi",
            workspace: workspace,
            model: LocalMLXRuntime.defaultModel,
            runtime: .localMLX
        )
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .localMLX)
        let plan = adapter.makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
            prompt: "hello",
            task: task,
            workspacePath: workspaceURL.path,
            executablePath: "/tmp/astra-local-model",
            providerHomeDirectory: modelURL.path,
            permissionPolicy: .restricted,
            executionPolicy: .default,
            permissionManifest: nil,
            timeoutSeconds: 30
        ))

        #expect(plan.runtime == .localMLX)
        #expect(plan.eventStream == .fileDescriptor(3))
        #expect(plan.controlStream == .fileDescriptor(4))
        #expect(plan.parsesJSONLines)
        #expect(plan.arguments.starts(with: ["run", "--request-file"]))
        #expect(plan.environment["ASTRA_LOCAL_MODEL_PROTOCOL_FD"] == "3")
        #expect(plan.environment["ASTRA_LOCAL_MODEL_CONTROL_FD"] == "4")
        #expect(plan.environment["ASTRA_LOCAL_MODEL_PROVIDER_ENABLED"] == "1")
        #expect(plan.environment["ASTRA_LOCAL_MODEL_EXPERIMENTAL_TOOLS"] == "0")
        #expect(plan.commandPlannedFields["event_stream"] == "fd3")
        #expect(plan.commandPlannedFields["control_stream"] == "fd4")

        let requestPath = try #require(plan.arguments.last)
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let request = try JSONDecoder().decode(LocalModelRunRequest.self, from: data)
        #expect(request.prompt == "hello")
        #expect(request.model == LocalMLXRuntime.defaultModel)
        #expect(request.modelDirectory == modelURL.path)
        #expect(request.maxOutputTokens == 512)
        #expect(request.keepWarmTTLSeconds == 90)
        #expect(plan.commandPlannedFields["max_output_tokens"] == "512")
        #expect(plan.commandPlannedFields["keep_warm_ttl_seconds"] == "90")
        #expect(plan.commandPlannedFields["memory_budget_gb"] == "6")
        #expect(plan.commandPlannedFields["local_agent_max_turns"] == "5")
        #expect(plan.commandPlannedFields["local_agent_max_tool_calls"] == "4")
        #expect(plan.commandPlannedFields["local_agent_tool_timeout_seconds"] == "20")
        if let memoryBudgetBytes = request.memoryBudgetBytes {
            #expect(memoryBudgetBytes > 0)
            #expect((request.cacheLimitBytes ?? 0) > 0)
            #expect((request.cacheLimitBytes ?? Int.max) <= memoryBudgetBytes)
        }
    }

    @Test("Adapter writes image attachments from task inputs into local model request")
    @MainActor
    func adapterWritesImageAttachmentsFromTaskInputsIntoLocalModelRequest() throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let workspaceURL = temporaryDirectory()
        let modelURL = temporaryDirectory()
        let image = workspaceURL.appendingPathComponent("selected.png")
        try Data([0]).write(to: image)
        let workspace = Workspace(name: "Local", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Local image",
            goal: "Describe the image",
            workspace: workspace,
            model: LocalMLXRuntime.defaultModel,
            runtime: .localMLX
        )
        task.inputs = [image.path]
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .localMLX)
        let plan = adapter.makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
            prompt: "Describe the image.",
            task: task,
            workspacePath: workspaceURL.path,
            executablePath: "/tmp/astra-local-model",
            providerHomeDirectory: modelURL.path,
            permissionPolicy: .restricted,
            executionPolicy: .default,
            permissionManifest: nil,
            timeoutSeconds: 30
        ))

        let requestPath = try #require(plan.arguments.last)
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let request = try JSONDecoder().decode(LocalModelRunRequest.self, from: data)

        #expect(request.messages.first?.attachments == [
            .image(path: image.standardizedFileURL.path, source: "task_input", mimeType: "image/png")
        ])
    }

    @Test("Readiness blocks while rollout gate is disabled")
    func readinessBlocksWhileRolloutGateDisabled() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(false, forKey: LocalModelSettingsStore.providerEnabledKey)

        let service = RuntimeReadinessService(
            runner: StubBinaryRunner(),
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: AgentRuntimeProviderSettings(),
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.checks == [
            RuntimeReadinessCheck(
                id: "local-mlx-rollout-gate",
                title: "Local provider rollout gate",
                detail: "Local MLX is disabled for this ASTRA channel.",
                state: .blocked,
                remediation: "Enable the Local MLX provider setting in a development or beta build while this runtime is under validation."
            )
        ])
    }

    @Test("Readiness includes helper and local model folder checks")
    func readinessIncludesHelperAndLocalModelFolderChecks() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"scaffold"}"#, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        #expect(report.checks.contains(RuntimeReadinessCheck(
            id: "local-mlx-helper",
            title: "Local model support",
            detail: "astra-local-model 0.1.0",
            state: .ready,
            remediation: nil
        )))
        #expect(report.checks.contains {
            $0.id == "local-mlx-model-folder" && $0.state == .ready
        })
        #expect(report.checks.contains {
            $0.id == "local-mlx-memory-fit" && ($0.state == .ready || $0.state == .warning)
        })
        #expect(report.checks.contains {
            $0.id == "local-mlx-backend" && $0.state == .blocked
        })
    }

    @Test("Readiness adds Local Agent hardware check only when tools are enabled")
    func readinessAddsLocalAgentHardwareCheckOnlyWhenToolsAreEnabled() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"scaffold"}"#, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )
        let configuration = RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        )

        UserDefaults.standard.set(false, forKey: LocalModelSettingsStore.experimentalToolsKey)
        let chatReport = await service.check(configuration: configuration)
        #expect(!chatReport.checks.contains { $0.id == "local-agent-hardware" })

        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.experimentalToolsKey)
        let agentReport = await service.check(configuration: configuration)
        let agentHardware = try #require(agentReport.checks.first { $0.id == "local-agent-hardware" })
        #expect(agentHardware.title == "Local Agent hardware")
        #expect(agentHardware.detail.contains("Local Agent"))
    }

    @Test("Readiness reports deleted model folder as recoverable setup failure")
    func readinessReportsDeletedModelFolderAsRecoverableSetupFailure() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"mlx"}"#, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory("/tmp/astra-deleted-model-\(UUID().uuidString)", for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let folder = try #require(report.checks.first { $0.id == "local-mlx-model-folder" })
        #expect(folder.state == .blocked)
        #expect(folder.detail == "Selected local model folder does not exist.")
        #expect(folder.remediation == "Choose a local MLX model folder that ASTRA can read.")
    }

    @Test("Readiness runs tiny smoke check only after native backend is available")
    func readinessRunsTinySmokeCheckAfterNativeBackendAvailable() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"mlx"}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --smoke --model-dir \(modelURL.path) --model \(LocalMLXRuntime.defaultModel) --max-context-tokens \(LocalModelSettingsStore.defaultMaxContextTokens) --max-output-tokens 1",
            result: RunResult(
                outcome: .exited(code: 0),
                stdout: """
                MLX diagnostic: warming Metal kernels
                {"status":"ok","backend":"mlx","model":"Qwen/Qwen3-4B-MLX-4bit","inputTokens":5,"outputTokens":1,"durationMs":1200,"firstTokenLatencyMs":850,"tokensPerSecond":2.5}
                MLX diagnostic: cache ready
                """,
                stderr: ""
            )
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let smoke = try #require(report.checks.first { $0.id == "local-mlx-smoke" })
        #expect(smoke.state == .ready)
        #expect(smoke.detail.contains("first token 850ms"))
        #expect(smoke.detail.contains("2.5 tok/s"))

        let profile = try #require(LocalModelPerformanceStore.profile())
        #expect(profile.model == LocalMLXRuntime.defaultModel)
        #expect(profile.backend == "mlx")
        #expect(profile.firstTokenLatencyMs == 850)
        #expect(profile.tokensPerSecond == 2.5)

        let pollutedSmoke = LocalModelSmokeReportCodec.decode(stdout: """
        MLX debug {not-json}
        {"status":"ok","backend":"mlx","message":"brace in string {ok}","durationMs":5}
        """)
        #expect(pollutedSmoke?.status == "ok")
        #expect(pollutedSmoke?.message == "brace in string {ok}")
    }

    @Test("Readiness parses structured smoke failure from helper")
    func readinessParsesStructuredSmokeFailureFromHelper() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"mlx"}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --smoke --model-dir \(modelURL.path) --model \(LocalMLXRuntime.defaultModel) --max-context-tokens \(LocalModelSettingsStore.defaultMaxContextTokens) --max-output-tokens 1",
            result: RunResult(
                outcome: .exited(code: 64),
                stdout: #"{"status":"blocked","backend":"mlx","message":"model weights could not be loaded"}"#,
                stderr: "debug noise"
            )
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let smoke = try #require(report.checks.first { $0.id == "local-mlx-smoke" })
        #expect(smoke.state == .blocked)
        #expect(smoke.detail == "Exited with status 64: model weights could not be loaded")
    }

    @Test("Readiness reports missing Metal shader library as helper packaging failure")
    func readinessReportsMissingMetalLibraryAsHelperPackagingFailure() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"mlx"}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --smoke --model-dir \(modelURL.path) --model \(LocalMLXRuntime.defaultModel) --max-context-tokens \(LocalModelSettingsStore.defaultMaxContextTokens) --max-output-tokens 1",
            result: RunResult(
                outcome: .exited(code: 255),
                stdout: "",
                stderr: "MLX error: Failed to load the default metallib. library not found library not found"
            )
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)
        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        )

        let report = await service.check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let smoke = try #require(report.checks.first { $0.id == "local-mlx-smoke" })
        #expect(smoke.state == .blocked)
        #expect(smoke.detail == "ASTRA is missing a required local model runtime file.")
        #expect(smoke.remediation == "Update or reinstall ASTRA, then run readiness again. This is an ASTRA packaging issue, not a model setup issue.")
    }

    @Test("Local MLX readiness copy stays user-facing")
    func localMLXReadinessCopyStaysUserFacing() async throws {
        let restoreSettings = clearStandardLocalModelSettings()
        defer { restoreSettings() }
        UserDefaults.standard.set(true, forKey: LocalModelSettingsStore.providerEnabledKey)

        var missingSupportSettings = AgentRuntimeProviderSettings()
        missingSupportSettings.setExecutablePath("/tmp/astra-missing-local-support", for: .localMLX)
        let missingSupportReport = await RuntimeReadinessService(
            runner: StubBinaryRunner(),
            detectExecutable: { _ in "" },
            isExecutable: { _ in false }
        ).check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: missingSupportSettings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))
        let missingSupport = try #require(missingSupportReport.checks.first { $0.id == "local-mlx-helper" })
        assertUserFacingLocalReadinessCopy(missingSupport)

        let modelURL = try completeModelDirectory()
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "astra-local-model 0.1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"scaffold"}"#, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(modelURL.path, for: .localMLX)

        let packagedWithoutLocalSupport = await RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        ).check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))
        let localEngine = try #require(packagedWithoutLocalSupport.checks.first { $0.id == "local-mlx-backend" })
        assertUserFacingLocalReadinessCopy(localEngine)

        await runner.setResponse(
            forKey: "/tmp/astra-local-model --health",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"status":"ok","backend":"mlx"}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --smoke --model-dir \(modelURL.path) --model \(LocalMLXRuntime.defaultModel) --max-context-tokens \(LocalModelSettingsStore.defaultMaxContextTokens) --max-output-tokens 1",
            result: RunResult(
                outcome: .exited(code: 255),
                stdout: "",
                stderr: "MLX error: Failed to load the default metallib. library not found library not found"
            )
        )
        let missingRuntimeFile = await RuntimeReadinessService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        ).check(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))
        let responseTest = try #require(missingRuntimeFile.checks.first { $0.id == "local-mlx-smoke" })
        assertUserFacingLocalReadinessCopy(responseTest)

        let settingsSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Views/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(!settingsSource.contains("ASTRA helper process"))
        #expect(!settingsSource.contains("Wire MLX Swift inference"))
    }

    @Test("Model availability for local runtime comes from helper installed models")
    func modelAvailabilityForLocalRuntimeComesFromHelperInstalledModels() async throws {
        RuntimeModelAvailability.clearAvailableModels(for: .localMLX)
        defer { RuntimeModelAvailability.clearAvailableModels(for: .localMLX) }

        let runner = StubBinaryRunner()
        let selectedDirectory = "/tmp/astra-local-qwen"
        let listReport = LocalModelListReport(
            status: "ok",
            backend: "scaffold",
            models: [
                LocalModelListEntry(
                    model: "Qwen/Qwen3-4B-MLX-4bit",
                    displayName: "Qwen 3 4B",
                    directory: selectedDirectory,
                    selected: true
                )
            ]
        )
        let listOutput = """
        MLX diagnostic: scanning models
        \(String(data: try JSONEncoder().encode(listReport), encoding: .utf8) ?? "")
        MLX diagnostic: done
        """
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --list-models --models-root \(LocalMLXRuntime.recommendedModelsRoot) --model-dir \(selectedDirectory)",
            result: RunResult(outcome: .exited(code: 0), stdout: listOutput, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)
        settings.setHomeDirectory(selectedDirectory, for: .localMLX)

        let check = await LocalModelAvailabilityService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        ).refreshAndPersist(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let raw = try #require(UserDefaults.standard.string(
            forKey: AppStorageKeys.runtimeAvailableModelsKey(for: .localMLX)
        ))
        let data = try #require(raw.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(RuntimeModelAvailabilitySnapshot.self, from: data)

        #expect(check.state == .ready)
        #expect(check.title == "Installed local models")
        #expect(snapshot.authority == .authoritative)
        #expect(snapshot.models == ["Qwen/Qwen3-4B-MLX-4bit"])
    }

    @Test("Model availability falls back to installable suggestions when no local model is installed")
    func modelAvailabilityFallsBackToInstallableSuggestionsWhenNoLocalModelIsInstalled() async throws {
        RuntimeModelAvailability.clearAvailableModels(for: .localMLX)
        defer { RuntimeModelAvailability.clearAvailableModels(for: .localMLX) }

        let runner = StubBinaryRunner()
        let listReport = LocalModelListReport(status: "ok", backend: "scaffold", models: [])
        let listOutput = String(data: try JSONEncoder().encode(listReport), encoding: .utf8) ?? ""
        await runner.setResponse(
            forKey: "/tmp/astra-local-model --list-models --models-root \(LocalMLXRuntime.recommendedModelsRoot)",
            result: RunResult(outcome: .exited(code: 0), stdout: listOutput, stderr: "")
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/tmp/astra-local-model", for: .localMLX)

        let check = await LocalModelAvailabilityService(
            runner: runner,
            detectExecutable: { _ in "" },
            isExecutable: { $0 == "/tmp/astra-local-model" }
        ).refreshAndPersist(configuration: RuntimeReadinessConfiguration(
            runtime: .localMLX,
            providerSettings: settings,
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        ))

        let raw = try #require(UserDefaults.standard.string(
            forKey: AppStorageKeys.runtimeAvailableModelsKey(for: .localMLX)
        ))
        let data = try #require(raw.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(RuntimeModelAvailabilitySnapshot.self, from: data)

        #expect(check.state == .warning)
        #expect(snapshot.authority == .suggestions)
        #expect(snapshot.models == LocalMLXRuntime.defaultModels)
    }

    @Test("Local policy never grants broad provider permissions")
    func localPolicyNeverGrantsBroadProviderPermissions() {
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: .localMLX)
        let context = PolicyRenderContext(
            runtimeID: .localMLX,
            model: LocalMLXRuntime.defaultModel,
            workspacePath: "/tmp/astra-local-policy",
            additionalPaths: [],
            requestedAllowedTools: ["Bash"],
            localToolCommands: ["swift test"],
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )

        let render = adapter.render(policy: .preset(.autonomous), context: context)

        #expect(render.enforcementTiers == [.astraBrokered])
        #expect(render.allowedTools.contains("Read"))
        #expect(render.allowedTools.contains("Write"))
        #expect(render.usesBroadProviderPermissions == false)
        #expect(render.diagnostics.contains { $0.id == "local-mlx.autonomous-no-provider-bypass" })
    }

    @Test("Local policy treats credential redaction as ASTRA-managed warning")
    func localPolicyTreatsCredentialRedactionAsASTRAManagedWarning() {
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: .localMLX)
        let context = PolicyRenderContext(
            runtimeID: .localMLX,
            model: LocalMLXRuntime.defaultModel,
            workspacePath: "/tmp/astra-local-policy",
            additionalPaths: [],
            requestedAllowedTools: [],
            localToolCommands: [],
            environmentKeyNames: ["JIRA_API_TOKEN"],
            credentialLabels: ["JIRA_API_TOKEN"],
            providerFeatures: adapter.supportedFeatures
        )

        let render = adapter.render(policy: .preset(.review), context: context)
        let redactionDiagnostic = render.diagnostics.first {
            $0.id == "\(AgentRuntimeID.localMLX.rawValue).secret-redaction-unsupported"
        }

        #expect(render.diagnostics.contains { $0.severity == .blocked } == false)
        #expect(redactionDiagnostic?.severity == .warning)
        #expect(redactionDiagnostic?.title == "Credential redaction is ASTRA-managed")
    }

    private func completeModelDirectory(modelType: String = "qwen3") throws -> URL {
        let directory = temporaryDirectory()
        try writeCompleteModelDirectory(at: directory, modelType: modelType)
        return directory
    }

    private func writeCompleteModelDirectory(at directory: URL, modelType: String = "qwen3") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try modelConfig(modelType: modelType).write(
            to: directory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
    }

    private func modelConfig(modelType: String, modelID: String? = nil) -> String {
        let modelIDLine = modelID.map { #""model_id": "\#($0)","# } ?? ""
        return """
        {
          \(modelIDLine)
          "model_type": "\(modelType)",
          "architectures": ["Gemma4TextForCausalLM"],
          "hidden_size": 2048,
          "num_hidden_layers": 18,
          "num_attention_heads": 8,
          "num_key_value_heads": 4,
          "quantization_config": {
            "quant_method": "bitsandbytes"
          }
        }
        """
    }

    private func multimodalGemmaConfig() -> String {
        """
        {
          "model_type": "gemma4",
          "architectures": ["Gemma4ForConditionalGeneration"],
          "text_config": {
            "model_type": "gemma4_text",
            "hidden_size": 1536,
            "num_hidden_layers": 35,
            "num_attention_heads": 8,
            "num_key_value_heads": 1
          },
          "vision_config": {
            "model_type": "gemma4_vision",
            "hidden_size": 768
          },
          "quantization_config": {
            "group_size": 64,
            "bits": 4,
            "mode": "affine"
          }
        }
        """
    }

    private func gemma4UnifiedConfig() -> String {
        """
        {
          "model_type": "gemma4_unified",
          "architectures": ["Gemma4UnifiedForConditionalGeneration"],
          "text_config": {
            "model_type": "gemma4_text",
            "hidden_size": 1536,
            "num_hidden_layers": 35,
            "num_attention_heads": 8,
            "num_key_value_heads": 1
          },
          "vision_config": {
            "model_type": "gemma4_vision",
            "hidden_size": 768
          },
          "audio_config": {
            "model_type": "gemma4_unified_audio"
          },
          "quantization": {
            "group_size": 64,
            "bits": 4,
            "mode": "affine"
          }
        }
        """
    }

    private func unsupportedMultimodalConfig() -> String {
        """
        {
          "model_type": "experimental_vlm",
          "architectures": ["ExperimentalVLMForConditionalGeneration"],
          "vision_config": {
            "model_type": "experimental_vision",
            "hidden_size": 768
          }
        }
        """
    }

    private func quantizedGemmaPLEConfig() -> String {
        """
        {
          "model_type": "gemma4",
          "architectures": ["Gemma4ForConditionalGeneration"],
          "text_config": {
            "model_type": "gemma4_text",
            "hidden_size": 1536,
            "hidden_size_per_layer_input": 256,
            "num_hidden_layers": 35,
            "num_attention_heads": 8,
            "num_key_value_heads": 1
          },
          "quantization_config": {
            "group_size": 64,
            "bits": 4,
            "mode": "affine"
          }
        }
        """
    }

    private func quantizedGemmaTextPLEConfig() -> String {
        """
        {
          "model_type": "gemma4_text",
          "text_config": {
            "model_type": "gemma4_text",
            "hidden_size": 1536,
            "hidden_size_per_layer_input": 256,
            "num_hidden_layers": 35,
            "num_attention_heads": 8,
            "num_key_value_heads": 1
          },
          "quantization_config": {
            "group_size": 64,
            "bits": 3,
            "mode": "affine"
          }
        }
        """
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-local-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func clearStandardLocalModelSettings() -> () -> Void {
        let defaults = UserDefaults.standard
        let previous = Dictionary(
            uniqueKeysWithValues: LocalModelSettingsStore.persistedKeys.map { key in
                (key, defaults.object(forKey: key))
            }
        )
        for key in LocalModelSettingsStore.persistedKeys {
            defaults.removeObject(forKey: key)
        }
        return {
            for key in LocalModelSettingsStore.persistedKeys {
                if let stored = previous[key], let value = stored {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    private func assertUserFacingLocalReadinessCopy(_ check: RuntimeReadinessCheck) {
        let visible = [
            check.title,
            check.detail,
            check.remediation ?? ""
        ].joined(separator: "\n").lowercased()
        let technicalFragments = [
            "helper",
            "native inference",
            "mlx swift",
            "metallib",
            "metal shader",
            "scaffold",
            "smoke test"
        ]
        for fragment in technicalFragments {
            #expect(!visible.contains(fragment), "Readiness copy leaked technical setup term: \(fragment)")
        }
    }

    private func sustainedSample(
        memoryBytes: UInt64,
        chip: String,
        outcome: LocalModelSustainedValidationOutcome,
        model: String = LocalMLXRuntime.defaultModel,
        iterations: Int = 3,
        durationSeconds: Int = 60,
        inputTokens: Int? = 8,
        outputTokens: Int? = 2,
        durationMs: Int? = 1_000,
        firstTokenLatencyMs: Int? = 250,
        tokensPerSecond: Double? = 8
    ) -> LocalModelSustainedValidationSample {
        LocalModelSustainedValidationSample(
            profile: LocalModelPerformanceProfile(
                model: model,
                backend: "mlx",
                checkedAt: Date(timeIntervalSince1970: 2_000),
                hardware: LocalHardwareProfile(
                    isAppleSilicon: true,
                    physicalMemoryBytes: memoryBytes,
                    cpuBrand: chip
                ),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: durationMs,
                firstTokenLatencyMs: firstTokenLatencyMs,
                tokensPerSecond: tokensPerSecond
            ),
            mode: .localAgentReadOnly,
            outcome: outcome,
            iterations: iterations,
            durationSeconds: durationSeconds
        )
    }

    private func betaSoakSample(
        successfulTools: [String],
        outcome: LocalAgentBetaSoakOutcome = .completed,
        model: String = LocalMLXRuntime.defaultModel,
        stopReason: String? = nil
    ) -> LocalAgentBetaSoakSample {
        LocalAgentBetaSoakSample(
            recordedAt: Date(timeIntervalSince1970: 2_800),
            model: model,
            outcome: outcome,
            stopReason: stopReason ?? (outcome == .completed ? "completed" : outcome.rawValue),
            enabledCapabilities: LocalAgentToolCapability.allCases.map(\.rawValue).sorted(),
            proposedTools: successfulTools,
            executedTools: successfulTools,
            successfulTools: successfulTools,
            turns: 2,
            toolCalls: successfulTools.count,
            toolSuccesses: successfulTools.count,
            toolErrors: 0,
            policyDecisions: successfulTools.count,
            policyApprovalRequests: successfulTools.filter {
                LocalAgentBetaToolSurface.highRiskToolNames.contains($0)
            }.count,
            policyViolations: 0,
            invalidActionRepairs: 0,
            missingToolFinalRepairs: 0,
            watchdogWarnings: 0,
            memoryDiagnostics: 0,
            firstTokenLatencyMs: 250,
            tokensPerSecond: 8.0
        )
    }

    private func releaseCandidateSample(
        mode: LocalModelReleaseCandidateValidationMode,
        outcome: LocalModelReleaseCandidateValidationOutcome = .passed,
        inputTokens: Int = 12,
        outputTokens: Int = 4,
        model: String = LocalMLXRuntime.defaultModel,
        buildIdentifier: String? = nil
    ) -> LocalModelReleaseCandidateValidationSample {
        LocalModelReleaseCandidateValidationSample(
            recordedAt: Date(timeIntervalSince1970: 3_200 + Double(mode.rawValue.count)),
            buildIdentifier: buildIdentifier,
            mode: mode,
            outcome: outcome,
            model: model,
            modelDirectory: "/tmp/astra-local-model",
            helperPath: "/tmp/astra-local-model-helper",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            stopReason: outcome == .passed ? "completed" : "failed",
            marker: mode == .localChat ? "ASTRA_E2E_TEXT_OK" : "ASTRA_LOCAL_AGENT_LIVE_TOOL_OK"
        )
    }

    private func hardwareEvidencePayload(samples: [LocalModelSustainedValidationSample]) throws -> String {
        let bundle = LocalModelHardwareValidationEvidenceBundle(
            exportedAt: Date(timeIntervalSince1970: 3_500),
            samples: samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func releaseCandidateEvidencePayload(
        samples: [LocalModelReleaseCandidateValidationSample]
    ) throws -> String {
        let bundle = LocalModelReleaseCandidateValidationEvidenceBundle(
            exportedAt: Date(timeIntervalSince1970: 3_600),
            samples: samples
        )
        return try encodedEvidencePayload(bundle)
    }

    private func betaSoakEvidencePayload(samples: [LocalAgentBetaSoakSample]) throws -> String {
        let bundle = LocalAgentBetaSoakEvidenceBundle(
            exportedAt: Date(timeIntervalSince1970: 3_700),
            samples: samples
        )
        return try encodedEvidencePayload(bundle)
    }

    private func combinedReleaseEvidencePayload(
        releaseCandidateSamples: [LocalModelReleaseCandidateValidationSample],
        betaSoakSamples: [LocalAgentBetaSoakSample],
        hardwareSamples: [LocalModelSustainedValidationSample]
    ) throws -> String {
        let bundle = LocalModelCombinedReleaseEvidenceBundle(
            exportedAt: Date(timeIntervalSince1970: 3_800),
            releaseCandidateSamples: releaseCandidateSamples,
            betaSoakSamples: betaSoakSamples,
            hardwareSamples: hardwareSamples
        )
        return try encodedEvidencePayload(bundle)
    }

    private func encodedEvidencePayload<T: Encodable>(_ bundle: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func wrappedEvidencePayload(_ payload: String) -> String {
        """
        Here is the Local MLX release evidence copied from another Mac:

        ```json
        \(payload)
        ```

        Import this into ASTRA's release validation set.
        """
    }

    private func runHardwareEvidenceInspector(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runPythonScript("script/local_mlx_hardware_evidence.py", arguments: arguments)
    }

    private func runReleaseReadinessInspector(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runPythonScript("script/local_mlx_release_readiness.py", arguments: arguments)
    }

    private func runValidationBundleBuilder(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runPythonScript("script/local_mlx_validation_bundle.py", arguments: arguments)
    }

    private func runShellScript(
        _ relativePath: String,
        arguments: [String],
        environment overrides: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent(relativePath).path] + arguments
        if !overrides.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in overrides {
                environment[key] = value
            }
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func runPythonScript(
        _ relativePath: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent(relativePath).path] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start) else { return "" }
        guard let endRange = source[startRange.upperBound...].range(of: end) else {
            return String(source[startRange.lowerBound...])
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor RecordingInstallRunner: BinaryRunner {
    struct Call: Equatable {
        var path: String
        var args: [String]
    }

    private let result: RunResult
    private let materializeModelType: String?
    private var calls: [Call] = []

    init(result: RunResult, materializeModelType: String? = nil) {
        self.result = result
        self.materializeModelType = materializeModelType
    }

    func recordedCalls() -> [Call] {
        calls
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment _: [String: String]?
    ) async -> RunResult {
        await record(path: path, args: args)
        return result
    }

    private func record(path: String, args: [String]) {
        calls.append(Call(path: path, args: args))
        if let materializeModelType,
           let targetDirectory = args.last {
            Self.writeCompleteModelDirectory(atPath: targetDirectory, modelType: materializeModelType)
        }
    }

    fileprivate static func writeCompleteModelDirectory(atPath path: String, modelType: String) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
        {
          "model_type": "\(modelType)",
          "architectures": ["Gemma4TextForCausalLM"],
          "hidden_size": 2048,
          "num_hidden_layers": 18,
          "num_attention_heads": 8,
          "num_key_value_heads": 4
        }
        """
        try? config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try? "{}".write(to: directory.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try? Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
    }
}

private actor ProgressRecorder {
    private var recordedSamples: [LocalModelInstallProgress] = []

    func record(_ progress: LocalModelInstallProgress) {
        recordedSamples.append(progress)
    }

    func samples() -> [LocalModelInstallProgress] {
        recordedSamples
    }
}

private final class RecordingDiskSpaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let availableBytes: UInt64?
    private var paths: [String] = []

    init(availableBytes: UInt64?) {
        self.availableBytes = availableBytes
    }

    func availableDiskSpace(for path: String) -> UInt64? {
        lock.lock()
        paths.append(path)
        lock.unlock()
        return availableBytes
    }

    func checkedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private actor ProgressInstallRunner: BinaryRunner {
    nonisolated func run(
        path _: String,
        args: [String],
        timeout _: TimeInterval,
        environment _: [String: String]?
    ) async -> RunResult {
        guard let targetDirectory = args.last else {
            return RunResult(outcome: .exited(code: 64), stdout: "", stderr: "missing target")
        }
        let directory = URL(fileURLWithPath: targetDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(repeating: 1, count: 500_000)
            .write(to: directory.appendingPathComponent("partial.safetensors"))
        try? await Task.sleep(for: .milliseconds(650))
        RecordingInstallRunner.writeCompleteModelDirectory(atPath: targetDirectory, modelType: "qwen3")
        return RunResult(outcome: .exited(code: 0), stdout: "ok", stderr: "")
    }
}

private actor CancellableInstallRunner: BinaryRunner {
    struct Call: Equatable {
        var path: String
        var args: [String]
    }

    private var calls: [Call] = []

    func recordedCalls() -> [Call] {
        calls
    }

    nonisolated func run(
        path: String,
        args: [String],
        timeout _: TimeInterval,
        environment _: [String: String]?
    ) async -> RunResult {
        await record(path: path, args: args)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return RunResult(outcome: .timedOut, stdout: "", stderr: "")
    }

    private func record(path: String, args: [String]) {
        calls.append(Call(path: path, args: args))
        guard let targetDirectory = args.last else { return }
        let directory = URL(fileURLWithPath: targetDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "partial".write(
            to: directory.appendingPathComponent("partial-download.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private final class LocalJiraSearchMockTransport: ConnectorHTTPTransport {
    let body: String
    private(set) var requests: [URLRequest] = []

    init(body: String) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }
}

private final class LocalConnectorSearchMockTransport: ConnectorHTTPTransport {
    let body: String
    private(set) var requests: [URLRequest] = []

    init(body: String) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }
}

private final class LocalConnectorRouteMockTransport: ConnectorHTTPTransport {
    struct Route {
        var pathContains: String
        var body: String
        var statusCode: Int = 200
    }

    let routes: [Route]
    private(set) var requests: [URLRequest] = []

    init(routes: [Route]) {
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let route = routes.first { url.path.contains($0.pathContains) || url.absoluteString.contains($0.pathContains) }
            ?? Route(pathContains: "", body: #"{"error":{"message":"missing test route"}}"#, statusCode: 404)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: route.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(route.body.utf8), response)
    }
}
