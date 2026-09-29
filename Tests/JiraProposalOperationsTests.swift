import CryptoKit
import Foundation
import Testing
import ASTRACore
@testable import ASTRA
@testable import HostControlToolSupport

/// The broker half of the write operations beyond creating a ticket: comment on
/// one, edit one, move one. Same contract as `propose_issue` — compose, validate,
/// stage, send nothing — so every test here also asserts that no request reached
/// the network.
///
/// `arguments_file` gets the harshest treatment because it is the one place this
/// module reads a path an agent chose. It is checked against each way a name can
/// be made to point somewhere it should not.
@Suite("Jira proposal operations", .serialized)
struct JiraProposalOperationsTests {
    // MARK: - Comment

    @Test("A public comment stages a POST to the ticket's comment route and sends nothing")
    func publicCommentStagesTheCommentRoute() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let text = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment",
            "issue_key": "SS-617",
            "comment": "Hi Atousa,\n\nStar the production project, then re-run the query.",
            "visibility": "public"
        ]))

        #expect(text.contains("staged_operation: add_comment"))
        #expect(text.contains("target: SS-617 · public comment"))
        #expect(text.contains("visibility: public"))
        #expect(text.contains("sent: false"))
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)

        let path = try #require(value(of: "staged_path", in: text))
        let digest = try #require(value(of: "request_digest", in: text))
        let staged = try ConnectorMutationStaging.read(atPath: path, containedIn: folder, expectedDigest: digest)
        #expect(staged.operation == "add_comment")
        #expect(staged.requestMethod == "POST")
        // v2, so the text is wiki markup Jira renders rather than an ADF tree.
        #expect(staged.requestPath == "/rest/api/2/issue/SS-617/comment")

        let body = try #require(try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any])
        #expect(body["body"] as? String == "Hi Atousa,\n\nStar the production project, then re-run the query.")
        // A public comment names nothing: absence is Jira's own meaning of "public".
        #expect(body["properties"] == nil)
    }

    @Test("An internal comment carries the service-desk property, and only that")
    func internalCommentCarriesTheServiceDeskProperty() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let text = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment",
            "issue_key": "SS-617",
            "comment": "Note to self: billing project mismatch.",
            "visibility": "Internal"
        ]))
        let path = try #require(value(of: "staged_path", in: text))
        let staged = try ConnectorMutationStaging.read(atPath: path, containedIn: folder)

        #expect(staged.target == "SS-617 · internal comment")
        let body = try #require(try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any])
        let properties = try #require(body["properties"] as? [[String: Any]])
        #expect(properties.count == 1)
        #expect(properties.first?["key"] as? String == "sd.public.comment")
        #expect((properties.first?["value"] as? [String: Any])?["internal"] as? Bool == true)
    }

    /// The default is the dangerous half: with no property Jira treats a service-desk
    /// comment as public, so an unstated visibility is a customer reply.
    @Test("A comment must say who can see it")
    func commentMustSayWhoCanSeeIt() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        for visibility in [nil, "team", "", "private"] as [String?] {
            var arguments: [String: Any] = [
                "operation": "propose_comment", "issue_key": "SS-617", "comment": "hello"
            ]
            arguments["visibility"] = visibility
            let message = try errorMessage(try call(server, tool: "jira", arguments: arguments))
            #expect(message.contains("requires visibility"), "visibility \(String(describing: visibility))")
        }
        #expect(!stagingDirectoryExists(folder))
    }

    @Test("A comment proposal refuses what it cannot represent")
    func commentProposalRefusesWhatItCannotRepresent() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        func message(_ overrides: [String: Any]) throws -> String {
            var arguments: [String: Any] = [
                "operation": "propose_comment", "issue_key": "SS-617", "comment": "hello", "visibility": "public"
            ]
            for (key, value) in overrides { arguments[key] = value }
            return try errorMessage(try call(server, tool: "jira", arguments: arguments))
        }

        #expect(try message(["issue_key": "ss-617"]).contains("issue_key must be an issue key"))
        // The key becomes a path segment, so anything shaped like a path is refused.
        #expect(try message(["issue_key": "SS-617/../SS-1"]).contains("issue_key must be an issue key"))
        #expect(try message(["issue_key": "SS-0"]).contains("issue_key must be an issue key"))
        #expect(try message(["comment": "   "]).contains("requires comment"))
        #expect(try message(["comment": String(repeating: "x", count: 32_769)]).contains("at most 32768"))
        // `body` is the runtime guard's word for a raw request body; the tool's
        // field is `comment`, and the old spelling stays refused.
        #expect(try message(["body": "hello"]).contains("does not accept body"))
        #expect(try message(["comment": 42]).contains("comment must be a string"))
        #expect(!stagingDirectoryExists(folder))
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)
    }

    // MARK: - Update

    @Test("An update stages a PUT carrying only the fields it was given")
    func updateStagesOnlyTheGivenFields() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let text = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_update",
            "issue_key": "STAR-7",
            "summary": "Age filter missing on cost",
            "labels": ["deid", "age90"],
            "priority": "High"
        ]))
        let path = try #require(value(of: "staged_path", in: text))
        let staged = try ConnectorMutationStaging.read(atPath: path, containedIn: folder)

        #expect(staged.operation == "update_issue")
        #expect(staged.requestMethod == "PUT")
        #expect(staged.requestPath == "/rest/api/2/issue/STAR-7")
        #expect(staged.target == "STAR-7 · update summary, priority, labels")

        let body = try #require(try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any])
        #expect(Set(body.keys) == ["fields"])
        let fields = try #require(body["fields"] as? [String: Any])
        #expect(Set(fields.keys) == ["summary", "priority", "labels"])
        #expect(fields["summary"] as? String == "Age filter missing on cost")
        #expect((fields["priority"] as? [String: String])?["name"] == "High")
        #expect(fields["labels"] as? [String] == ["deid", "age90"])
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)
    }

    /// "Leave the labels alone" and "remove every label" are different requests,
    /// and the array is what tells them apart.
    @Test("An empty label list is a request to clear the labels")
    func emptyLabelListClearsTheLabels() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let text = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_update", "issue_key": "STAR-7", "labels": [String]()
        ]))
        let path = try #require(value(of: "staged_path", in: text))
        let staged = try ConnectorMutationStaging.read(atPath: path, containedIn: folder)
        let fields = try #require(
            (try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any])?["fields"] as? [String: Any]
        )

        #expect(fields["labels"] as? [String] == [])
        #expect(text.contains("labels: (remove all)"))
    }

    @Test("An update that changes nothing, or changes it ambiguously, is refused")
    func updateThatChangesNothingIsRefused() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let nothing = try call(server, tool: "jira", arguments: [
            "operation": "propose_update", "issue_key": "STAR-7"
        ])
        #expect(try errorMessage(nothing).contains("needs at least one of"))

        // A wrongly typed value is refused rather than read as "not provided" —
        // otherwise this becomes the "changes nothing" case above, or worse, a
        // partial update the user reviewed without the field they asked for.
        let wrongType = try call(server, tool: "jira", arguments: [
            "operation": "propose_update", "issue_key": "STAR-7", "summary": 42
        ])
        #expect(try errorMessage(wrongType).contains("summary must be a string"))

        let notAnArray = try call(server, tool: "jira", arguments: [
            "operation": "propose_update", "issue_key": "STAR-7", "labels": "deid"
        ])
        #expect(try errorMessage(notAnArray).contains("labels must be an array"))

        // Fields that only make sense on creation are not silently dropped here.
        let creationOnly = try call(server, tool: "jira", arguments: [
            "operation": "propose_update", "issue_key": "STAR-7", "summary": "x", "project_key": "STAR"
        ])
        #expect(try errorMessage(creationOnly).contains("does not accept project_key"))
        #expect(!stagingDirectoryExists(folder))
    }

    // MARK: - Transition

    @Test("A transition stages the id, and the resolution only when one is given")
    func transitionStagesTheIdAndOptionalResolution() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let plain = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_transition", "issue_key": "SS-617",
            "transition_id": "21", "transition_name": "Waiting for customer"
        ]))
        let plainStaged = try ConnectorMutationStaging.read(
            atPath: try #require(value(of: "staged_path", in: plain)), containedIn: folder
        )
        #expect(plainStaged.operation == "transition_issue")
        #expect(plainStaged.requestMethod == "POST")
        #expect(plainStaged.requestPath == "/rest/api/2/issue/SS-617/transitions")
        #expect(plainStaged.target == "SS-617 · transition 21")
        #expect(plainStaged.summary == "Move SS-617 to “Waiting for customer” (transition 21)")
        let plainBody = try #require(
            try JSONSerialization.jsonObject(with: plainStaged.requestBody) as? [String: Any]
        )
        #expect((plainBody["transition"] as? [String: String]) == ["id": "21"])
        #expect(plainBody["fields"] == nil)

        let resolved = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_transition", "issue_key": "SS-617",
            "transition_id": "31", "transition_name": "Done", "resolution": "Done"
        ]))
        let resolvedStaged = try ConnectorMutationStaging.read(
            atPath: try #require(value(of: "staged_path", in: resolved)), containedIn: folder
        )
        let resolvedBody = try #require(
            try JSONSerialization.jsonObject(with: resolvedStaged.requestBody) as? [String: Any]
        )
        let fields = try #require(resolvedBody["fields"] as? [String: Any])
        #expect((fields["resolution"] as? [String: String]) == ["name": "Done"])
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)
    }

    @Test("A transition needs a numeric id and a name to show the user")
    func transitionNeedsANumericIdAndAName() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        for id in ["done", "21; DROP", "", "12345678901"] {
            let response = try call(server, tool: "jira", arguments: [
                "operation": "propose_transition", "issue_key": "SS-617",
                "transition_id": id, "transition_name": "Done"
            ])
            #expect(try errorMessage(response).contains("numeric transition_id"), "id \(id)")
        }
        let noName = try call(server, tool: "jira", arguments: [
            "operation": "propose_transition", "issue_key": "SS-617", "transition_id": "21"
        ])
        #expect(try errorMessage(noName).contains("requires transition_name"))
        #expect(!stagingDirectoryExists(folder))
    }

    @Test("Reading a ticket's transitions is a plain GET")
    func readingTransitionsIsAPlainGET() throws {
        let request = try JiraRequestPolicy.readRequest(
            operation: "get_transitions", arguments: ["issue_key": "SS-617"]
        )
        #expect(request.method == "GET")
        #expect(request.path == "/rest/api/3/issue/SS-617/transitions")
        #expect(request.queryItems.isEmpty)

        #expect(throws: JiraRequestPolicyError.self) {
            try JiraRequestPolicy.readRequest(operation: "get_transitions", arguments: ["issue_key": "nope"])
        }
    }

    // MARK: - One list, everywhere

    @Test("Every operation the tool advertises is one the server dispatches")
    func everyAdvertisedOperationIsDispatched() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        #expect(JiraHostControlOperations.proposalOperations == [
            "propose_issue", "propose_comment", "propose_update", "propose_transition"
        ])
        let minimal: [String: [String: Any]] = [
            "propose_issue": ["project_key": "STAR", "issue_type": "Bug", "summary": "s"],
            "propose_comment": ["issue_key": "STAR-1", "comment": "c", "visibility": "public"],
            "propose_update": ["issue_key": "STAR-1", "summary": "s"],
            "propose_transition": ["issue_key": "STAR-1", "transition_id": "5", "transition_name": "Done"]
        ]
        for operation in JiraHostControlOperations.proposalOperations {
            var arguments = try #require(minimal[operation])
            arguments["operation"] = operation
            let text = try resultText(try call(server, tool: "jira", arguments: arguments))
            #expect(text.contains("sent: false"), "\(operation) did not stage")
        }
    }

    /// The runtime guard kills a run over an unlisted input key, and `body` is
    /// one it reads as a raw request body. The vocabulary has to stay inside what
    /// the projection allows.
    @Test("The tool schema advertises the proposals and stays inside the guard's vocabulary")
    func schemaAdvertisesTheProposals() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        let response = try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let tools = try #require((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let jira = try #require(tools.first { $0["name"] as? String == "jira" })
        let properties = try #require((jira["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])

        for key in ["comment", "visibility", "transition_id", "transition_name", "resolution"] {
            #expect(properties.keys.contains(key), "schema is missing \(key)")
        }
        #expect(!properties.keys.contains("body"))
        // The file input is for the CLI relay only; an MCP runtime passes fields.
        #expect(!properties.keys.contains(JiraHostControlOperations.argumentsFileKey))
        let visibility = try #require(properties["visibility"] as? [String: Any])
        #expect(visibility["enum"] as? [String] == ["public", "internal"])
        let operation = try #require((properties["operation"] as? [String: Any])?["description"] as? String)
        for name in JiraHostControlOperations.proposalOperations.union(["get_transitions"]) {
            #expect(operation.contains(name), "operation description does not name \(name)")
        }

        let advertised = Set(properties.keys)
        let allowedByTheGuard = Set(
            HostControlPlaneMCPProjection.runtimeSupportToolDescriptors(for: .claudeCode)
                .first { $0.name == HostControlPlaneMCPProjection.providerToolPermission(for: "jira") }?
                .allowedInputKeys ?? []
        )
        #expect(
            advertised.subtracting(allowedByTheGuard).isEmpty,
            "The schema offers keys the runtime guard would stop a run for: \(advertised.subtracting(allowedByTheGuard).sorted())"
        )
    }

    // MARK: - arguments_file

    @Test("A proposal's fields can come from a JSON file in the task folder")
    func argumentsFileSuppliesTheProposalFields() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }
        // The point of the file: text a shell command line cannot carry.
        let comment = "Hi,\n\nRun `SELECT count(1) FROM t` and it's fine — don't worry about $HOME."
        try writeJSON(
            ["issue_key": "SS-617", "comment": comment, "visibility": "public"],
            named: "jira_comment_SS-617.json",
            in: folder
        )

        let text = try resultText(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "alias": "jira", "arguments_file": "jira_comment_SS-617.json"
        ]))
        let staged = try ConnectorMutationStaging.read(
            atPath: try #require(value(of: "staged_path", in: text)), containedIn: folder
        )
        let body = try #require(try JSONSerialization.jsonObject(with: staged.requestBody) as? [String: Any])

        #expect(staged.requestPath == "/rest/api/2/issue/SS-617/comment")
        #expect(body["body"] as? String == comment)
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)
    }

    @Test("An arguments file must be a bare .json file name")
    func argumentsFileMustBeABareName() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }

        for name in ["../x.json", "/tmp/x.json", "sub/x.json", ".hidden.json", "x.txt", "x.json/", "", "a b.json"] {
            let message = try errorMessage(try call(server, tool: "jira", arguments: [
                "operation": "propose_comment", "arguments_file": name
            ]))
            #expect(message.contains("arguments_file must be the name of a .json file"), "\(name)")
        }
        // A non-string is not "no file", or it would fall through to inline fields.
        let numeric = try errorMessage(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "arguments_file": 7
        ]))
        #expect(numeric.contains("arguments_file must be the name of a .json file"))
        #expect(!stagingDirectoryExists(folder))
    }

    /// The broker is not sandboxed to the task folder and the agent can write to
    /// it, so each way of making a name mean something else has a case.
    @Test("An arguments file cannot be a link, a second name, or anything but a regular file")
    func argumentsFileCannotBeRedirected() throws {
        let folder = try temporaryTaskFolder()
        let outside = try temporaryTaskFolder()
        defer {
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }
        let valid = ["issue_key": "SS-617", "comment": "outside", "visibility": "public"]
        try writeJSON(valid, named: "target.json", in: outside)

        // A symlink named like a proposal.
        try FileManager.default.createSymbolicLink(
            atPath: (folder as NSString).appendingPathComponent("link.json"),
            withDestinationPath: (outside as NSString).appendingPathComponent("target.json")
        )
        // A hard link cannot be told from a copy by name.
        try FileManager.default.linkItem(
            atPath: (outside as NSString).appendingPathComponent("target.json"),
            toPath: (folder as NSString).appendingPathComponent("hard.json")
        )
        // A directory and a fifo: neither is a file, and a fifo nobody writes to
        // would block a plain read forever.
        try FileManager.default.createDirectory(
            atPath: (folder as NSString).appendingPathComponent("dir.json"), withIntermediateDirectories: false
        )
        #expect(mkfifo((folder as NSString).appendingPathComponent("pipe.json"), 0o600) == 0)

        let expectations: [(String, String)] = [
            ("link.json", "symbolic link"),
            ("hard.json", "more than one hard link"),
            ("dir.json", "not a regular file"),
            ("pipe.json", "not a regular file"),
            ("missing.json", "does not exist")
        ]
        for (name, expected) in expectations {
            let message = try errorMessage(try call(server, tool: "jira", arguments: [
                "operation": "propose_comment", "arguments_file": name
            ]))
            #expect(message.contains(expected), "\(name): \(message)")
        }
        #expect(!stagingDirectoryExists(folder))
        #expect(JiraOperationsCaptureURLProtocol.capturedURLs.isEmpty)
    }

    @Test("An oversized arguments file is refused")
    func oversizedArgumentsFileIsRefused() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }
        try Data(count: JiraProposalPolicy.argumentsFileByteLimit + 1).write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("big.json")
        )

        let message = try errorMessage(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "arguments_file": "big.json"
        ]))
        #expect(message.contains("larger than"))
    }

    @Test("An arguments file that is not one JSON object is refused without quoting it")
    func malformedArgumentsFileIsRefusedWithoutQuotingIt() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }
        try Data(#"{"comment": "SECRET-MARKER-123""#.utf8).write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("broken.json")
        )
        try Data(#"["SECRET-MARKER-123"]"#.utf8).write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("array.json")
        )

        for name in ["broken.json", "array.json"] {
            let message = try errorMessage(try call(server, tool: "jira", arguments: [
                "operation": "propose_comment", "arguments_file": name
            ]))
            #expect(message.contains("must hold a single JSON object"), "\(name)")
            // The file is not necessarily the agent's own, and a parser error can quote it.
            #expect(!message.contains("SECRET-MARKER-123"), "\(name) leaked its content")
        }
    }

    @Test("A file replaces the other arguments instead of merging with them")
    func argumentsFileReplacesTheOtherArguments() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let server = try proposalServer(taskFolder: folder)
        defer { endCapture() }
        try writeJSON(
            ["issue_key": "SS-617", "comment": "from the file", "visibility": "public"],
            named: "c.json", in: folder
        )
        try writeJSON(
            ["issue_key": "SS-617", "comment": "x", "visibility": "public", "operation": "propose_issue"],
            named: "routing.json", in: folder
        )

        // Two sources for one payload leaves the user reviewing whichever won.
        let both = try errorMessage(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "arguments_file": "c.json", "comment": "inline"
        ]))
        #expect(both.contains("replaces the other arguments; move comment into c.json"))

        // And the file may not steer the call: which operation runs, and against
        // which connector, is decided by the command the policy already vetted.
        let routing = try errorMessage(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "arguments_file": "routing.json"
        ]))
        #expect(routing.contains("must not set operation"))
        #expect(!stagingDirectoryExists(folder))
    }

    @Test("Reading an arguments file needs a projected task folder")
    func argumentsFileNeedsATaskFolder() throws {
        let server = try proposalServer(taskFolder: "")
        defer { endCapture() }

        let message = try errorMessage(try call(server, tool: "jira", arguments: [
            "operation": "propose_comment", "arguments_file": "c.json"
        ]))
        #expect(message.contains("No task folder is projected"))
    }

    @Test("The argument-name gate is one shared definition")
    func argumentsFileNameGateIsShared() {
        #expect(JiraHostControlOperations.isValidArgumentsFileName("jira_comment_SS-617.json"))
        #expect(JiraHostControlOperations.isValidArgumentsFileName("a.json"))
        #expect(!JiraHostControlOperations.isValidArgumentsFileName("noextension"))
        #expect(!JiraHostControlOperations.isValidArgumentsFileName("..json"))
        #expect(!JiraHostControlOperations.isValidArgumentsFileName(String(repeating: "a", count: 130) + ".json"))
        #expect(JiraHostControlOperations.isValidIssueKey("SS-617"))
        #expect(!JiraHostControlOperations.isValidIssueKey("SS-617/comment"))
    }

    // MARK: - Fixtures

    private func temporaryTaskFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-jira-operations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Resolved, because the broker resolves the folder before comparing and
        // `/var` and `/private/var` are the same place spelled two ways.
        return url.resolvingSymlinksInPath().path
    }

    private func writeJSON(_ object: [String: Any], named name: String, in folder: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    private func stagingDirectoryExists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: ConnectorMutationStaging.stagingDirectory(taskFolder: folder).path)
    }

    private func proposalServer(taskFolder: String) throws -> HostControlMCPServer {
        JiraOperationsCaptureURLProtocol.reset()
        HostControlURLSessionConfiguration.registerTestingProtocolClass(JiraOperationsCaptureURLProtocol.self)
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira",\
        "serviceType":"jira","baseURL":"https://jira.operations.test","authMethod":"basic",\
        "env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},\
        "credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        return HostControlMCPServer(configuration: HostControlToolConfiguration(
            taskFolder: taskFolder,
            runID: "run-1",
            connectorsJSON: connectors,
            environment: [
                "ASTRA_CONNECTORS": connectors,
                "JIRA_EMAIL_ENV": "user@example.com",
                "JIRA_TOKEN_ENV": "super-secret-token"
            ]
        ))
    }

    private func endCapture() {
        HostControlURLSessionConfiguration.unregisterTestingProtocolClass(JiraOperationsCaptureURLProtocol.self)
        JiraOperationsCaptureURLProtocol.reset()
    }

    private func value(of key: String, in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }

    private func call(
        _ server: HostControlMCPServer, tool: String, arguments: [String: Any]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let line = try #require(String(data: data, encoding: .utf8))
        let response = try #require(server.handleLine(line))
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func errorMessage(_ object: [String: Any]) throws -> String {
        let error = try #require(object["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }
}

/// Fails any request that reaches it. A proposal that produced a URL at all is
/// the bug this suite exists to catch.
private final class JiraOperationsCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URL] = []

    static var capturedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jira.operations.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.captured.append(url)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
