import Foundation
import ASTRACore

enum WorkspaceAppContractEffect: String, Codable, Sendable, Equatable, CaseIterable {
    case read
    case localWrite
    case externalWrite
    case destructive
}

struct WorkspaceAppContractOperation: Codable, Sendable, Equatable {
    var name: String
    var effect: WorkspaceAppContractEffect
    var supportsDryRun: Bool
    var requiresApproval: Bool

    init(
        name: String,
        effect: WorkspaceAppContractEffect,
        supportsDryRun: Bool = false,
        requiresApproval: Bool = false
    ) {
        self.name = name
        self.effect = effect
        self.supportsDryRun = supportsDryRun
        self.requiresApproval = requiresApproval
    }
}

struct WorkspaceAppContractFamily: Codable, Sendable, Equatable {
    var id: String
    var version: String
    var displayName: String
    var operations: [WorkspaceAppContractOperation]

    init(
        id: String,
        version: String = "1.0.0",
        displayName: String,
        operations: [WorkspaceAppContractOperation]
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.operations = operations
    }
}

struct WorkspaceAppContractImplementation: Codable, Sendable, Equatable {
    var id: String
    var familyID: String
    var provider: String
    var transport: WorkspaceAppContractTransport
    var operations: [String]
    var dataAccess: [String]
    var externalEffects: [String]
    /// How to run a READ for this implementation GENERICALLY (no per-provider Swift). nil for the
    /// built-in native clients (BigQuery/REDCap/GitHub keep their hand-written fast paths); set for an
    /// implementation derived from an ENABLED capability's CLI tool. Optional ⇒ auto-synth Codable
    /// decodes absent JSON as nil, so this is backward-compatible with existing persisted implementations.
    var readExecution: WorkspaceAppCapabilityReadExecution?

    init(
        id: String,
        familyID: String,
        provider: String,
        transport: WorkspaceAppContractTransport,
        operations: [String],
        dataAccess: [String] = [],
        externalEffects: [String] = [],
        readExecution: WorkspaceAppCapabilityReadExecution? = nil
    ) {
        self.id = id
        self.familyID = familyID
        self.provider = provider
        self.transport = transport
        self.operations = operations
        self.dataAccess = dataAccess
        self.externalEffects = externalEffects
        self.readExecution = readExecution
    }
}

struct WorkspaceAppContractResolution: Equatable {
    var requirement: WorkspaceAppRequirement
    var implementations: [WorkspaceAppContractImplementation]

    var isSatisfied: Bool {
        !implementations.isEmpty || requirement.optional
    }

    var selectedImplementation: WorkspaceAppContractImplementation? {
        implementations.first
    }
}

struct WorkspaceAppContractRegistry: Equatable {
    var families: [WorkspaceAppContractFamily]
    var implementations: [WorkspaceAppContractImplementation]

    init(
        families: [WorkspaceAppContractFamily] = Self.builtInFamilies,
        implementations: [WorkspaceAppContractImplementation] = Self.builtInImplementations
    ) {
        self.families = families
        self.implementations = implementations
    }

    func resolve(_ requirement: WorkspaceAppRequirement) -> WorkspaceAppContractResolution {
        let matches = implementations.filter { implementation in
            guard implementation.familyID == requirement.contract else { return false }
            let available = Set(implementation.operations)
            guard Set(requirement.operations).isSubset(of: available) else { return false }
            if let providerRequired = requirement.providerRequired,
               implementation.provider != providerRequired {
                return false
            }
            return true
        }
        let sorted = matches.sorted { lhs, rhs in
            let lhsHint = lhs.provider == requirement.providerHint
            let rhsHint = rhs.provider == requirement.providerHint
            if lhsHint != rhsHint { return lhsHint && !rhsHint }
            return lhs.id < rhs.id
        }
        return WorkspaceAppContractResolution(requirement: requirement, implementations: sorted)
    }

    func resolveAll(_ requirements: [WorkspaceAppRequirement]) -> [WorkspaceAppContractResolution] {
        requirements.map(resolve)
    }

    func family(id: String) -> WorkspaceAppContractFamily? {
        families.first { $0.id == id }
    }

    func implementation(id: String) -> WorkspaceAppContractImplementation? {
        implementations.first { $0.id == id }
    }

    func including(packageImplementations: [WorkspaceAppContractImplementation]) -> WorkspaceAppContractRegistry {
        let existingIDs = Set(implementations.map(\.id))
        let additions = packageImplementations
            .filter { !existingIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        return WorkspaceAppContractRegistry(
            families: families,
            implementations: implementations + additions
        )
    }

    /// Extend the registry with BOTH families and implementations contributed by ENABLED capabilities
    /// (see `WorkspaceAppCapabilityContractDeriver`). Families are needed so the contract CATALOG +
    /// validator accept the derived contract; implementations are needed so a published app's requirement
    /// auto-maps to a `.mapped` binding. Existing ids win (built-ins are never shadowed by a capability).
    func including(
        capabilityFamilies: [WorkspaceAppContractFamily],
        implementations newImplementations: [WorkspaceAppContractImplementation]
    ) -> WorkspaceAppContractRegistry {
        let existingFamilyIDs = Set(families.map(\.id))
        let familyAdditions = capabilityFamilies.filter { !existingFamilyIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let existingImplIDs = Set(implementations.map(\.id))
        let implAdditions = newImplementations.filter { !existingImplIDs.contains($0.id) }.sorted { $0.id < $1.id }
        return WorkspaceAppContractRegistry(
            families: families + familyAdditions,
            implementations: implementations + implAdditions
        )
    }

    func satisfies(
        binding: WorkspaceAppDependencyBinding,
        implementation: WorkspaceAppContractImplementation
    ) -> Bool {
        guard implementation.familyID == binding.contract else { return false }
        let available = Set(implementation.operations)
        return Set(binding.operations).isSubset(of: available)
    }

    func missingOperations(
        for requirement: WorkspaceAppRequirement,
        implementation: WorkspaceAppContractImplementation
    ) -> [String] {
        let available = Set(implementation.operations)
        return requirement.operations.filter { !available.contains($0) }
    }

    static let builtInFamilies: [WorkspaceAppContractFamily] = [
        WorkspaceAppContractFamily(
            id: "appStorage.records",
            displayName: "App Storage Records",
            operations: [
                WorkspaceAppContractOperation(name: "createTable", effect: .localWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "insertRecord", effect: .localWrite),
                WorkspaceAppContractOperation(name: "updateRecord", effect: .localWrite),
                WorkspaceAppContractOperation(name: "deleteRecord", effect: .destructive, requiresApproval: true),
                WorkspaceAppContractOperation(name: "queryRecords", effect: .read),
                WorkspaceAppContractOperation(name: "exportTable", effect: .read),
                WorkspaceAppContractOperation(name: "importCSV", effect: .localWrite)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "task.launch",
            displayName: "ASTRA Task Launch",
            operations: [
                WorkspaceAppContractOperation(name: "createDraftTask", effect: .localWrite),
                WorkspaceAppContractOperation(name: "createAndRunTask", effect: .localWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "continueTask", effect: .localWrite),
                WorkspaceAppContractOperation(name: "openTask", effect: .read),
                WorkspaceAppContractOperation(name: "bindTaskOutput", effect: .read),
                WorkspaceAppContractOperation(name: "readTaskArtifactMetadata", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "artifact.read",
            displayName: "Artifact Read",
            operations: [
                WorkspaceAppContractOperation(name: "listArtifacts", effect: .read),
                WorkspaceAppContractOperation(name: "readArtifactMetadata", effect: .read),
                WorkspaceAppContractOperation(name: "readArtifactContents", effect: .read),
                WorkspaceAppContractOperation(name: "openArtifact", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "file.readWrite",
            displayName: "Workspace File Read Write",
            operations: [
                WorkspaceAppContractOperation(name: "readFile", effect: .read),
                WorkspaceAppContractOperation(name: "listFiles", effect: .read),
                WorkspaceAppContractOperation(name: "writeFile", effect: .localWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "deleteFile", effect: .destructive, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "tabularQuery.read",
            displayName: "Tabular Query Read",
            operations: [
                WorkspaceAppContractOperation(name: "listDatasets", effect: .read),
                WorkspaceAppContractOperation(name: "listTables", effect: .read),
                WorkspaceAppContractOperation(name: "describeTable", effect: .read),
                WorkspaceAppContractOperation(name: "previewRows", effect: .read),
                WorkspaceAppContractOperation(name: "dryRunQuery", effect: .read, supportsDryRun: true),
                WorkspaceAppContractOperation(name: "runReadOnlyQuery", effect: .read),
                WorkspaceAppContractOperation(name: "exportResults", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "recordProject.read",
            displayName: "Record Project Read",
            operations: [
                WorkspaceAppContractOperation(name: "describeProject", effect: .read),
                WorkspaceAppContractOperation(name: "listForms", effect: .read),
                WorkspaceAppContractOperation(name: "listFields", effect: .read),
                WorkspaceAppContractOperation(name: "readRecords", effect: .read),
                WorkspaceAppContractOperation(name: "lookupRecord", effect: .read),
                WorkspaceAppContractOperation(name: "validateRecord", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "recordProject.write",
            displayName: "Record Project Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareCreate", effect: .read),
                WorkspaceAppContractOperation(name: "prepareUpdate", effect: .read),
                WorkspaceAppContractOperation(name: "validateWrite", effect: .read),
                WorkspaceAppContractOperation(name: "submitCreate", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "submitUpdate", effect: .externalWrite, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "formSchema.read",
            displayName: "Form Schema Read",
            operations: [
                WorkspaceAppContractOperation(name: "describeForms", effect: .read),
                WorkspaceAppContractOperation(name: "describeFields", effect: .read),
                WorkspaceAppContractOperation(name: "describeBranchingRules", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "message.send",
            displayName: "Message Send",
            operations: [
                WorkspaceAppContractOperation(name: "prepareMessage", effect: .read),
                WorkspaceAppContractOperation(name: "sendMessage", effect: .externalWrite, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "issueTracker.mutate",
            displayName: "Issue Tracker Mutate",
            operations: [
                WorkspaceAppContractOperation(name: "prepareIssue", effect: .read),
                WorkspaceAppContractOperation(name: "createIssue", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "updateIssue", effect: .externalWrite, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "pullRequest.read",
            displayName: "Pull Request Read",
            operations: [
                WorkspaceAppContractOperation(name: "listMyPullRequests", effect: .read),
                WorkspaceAppContractOperation(name: "listRepoPullRequests", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "gmail.thread.read",
            displayName: "Gmail Thread Read",
            operations: [
                WorkspaceAppContractOperation(name: "listThreads", effect: .read),
                WorkspaceAppContractOperation(name: "getThread", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "gmail.message.write",
            displayName: "Gmail Message Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareMessage", effect: .read),
                WorkspaceAppContractOperation(name: "sendMessage", effect: .externalWrite, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "drive.file.read",
            displayName: "Drive File Read",
            operations: [
                WorkspaceAppContractOperation(name: "listFiles", effect: .read),
                WorkspaceAppContractOperation(name: "getFileMetadata", effect: .read),
                WorkspaceAppContractOperation(name: "readFileContents", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "drive.file.write",
            displayName: "Drive File Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareFile", effect: .read),
                WorkspaceAppContractOperation(name: "createFile", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "updateFile", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "trashFile", effect: .destructive, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "calendar.event.read",
            displayName: "Calendar Event Read",
            operations: [
                WorkspaceAppContractOperation(name: "listCalendars", effect: .read),
                WorkspaceAppContractOperation(name: "listEvents", effect: .read),
                WorkspaceAppContractOperation(name: "getEvent", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "calendar.event.write",
            displayName: "Calendar Event Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareEvent", effect: .read),
                WorkspaceAppContractOperation(name: "createEvent", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "updateEvent", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "deleteEvent", effect: .destructive, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "docs.document.read",
            displayName: "Docs Document Read",
            operations: [
                WorkspaceAppContractOperation(name: "getDocumentMetadata", effect: .read),
                WorkspaceAppContractOperation(name: "readDocument", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "docs.document.write",
            displayName: "Docs Document Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareDocumentEdit", effect: .read),
                WorkspaceAppContractOperation(name: "insertText", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "replaceDocument", effect: .externalWrite, requiresApproval: true)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "sheets.range.read",
            displayName: "Sheets Range Read",
            operations: [
                WorkspaceAppContractOperation(name: "getSpreadsheetMetadata", effect: .read),
                WorkspaceAppContractOperation(name: "readRange", effect: .read)
            ]
        ),
        WorkspaceAppContractFamily(
            id: "sheets.range.write",
            displayName: "Sheets Range Write",
            operations: [
                WorkspaceAppContractOperation(name: "prepareRangeEdit", effect: .read),
                WorkspaceAppContractOperation(name: "updateRange", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "appendRows", effect: .externalWrite, requiresApproval: true),
                WorkspaceAppContractOperation(name: "clearRange", effect: .destructive, requiresApproval: true)
            ]
        )
    ]

    static let builtInImplementations: [WorkspaceAppContractImplementation] = [
        WorkspaceAppContractImplementation(
            id: "app-storage-native",
            familyID: "appStorage.records",
            provider: "astra",
            transport: .native,
            operations: ["createTable", "insertRecord", "updateRecord", "deleteRecord", "queryRecords", "exportTable", "importCSV"],
            dataAccess: ["workspaceFiles"],
            externalEffects: ["localFileWrite"]
        ),
        WorkspaceAppContractImplementation(
            id: "task-launch-native",
            familyID: "task.launch",
            provider: "astra",
            transport: .native,
            operations: ["createDraftTask", "createAndRunTask", "continueTask", "openTask", "bindTaskOutput", "readTaskArtifactMetadata"],
            dataAccess: ["workspaceFiles"],
            externalEffects: ["localFileWrite"]
        ),
        WorkspaceAppContractImplementation(
            id: "artifact-read-native",
            familyID: "artifact.read",
            provider: "astra",
            transport: .native,
            operations: ["listArtifacts", "readArtifactMetadata", "readArtifactContents", "openArtifact"],
            dataAccess: ["workspaceFiles"],
            externalEffects: []
        ),
        WorkspaceAppContractImplementation(
            id: "workspace-file-native",
            familyID: "file.readWrite",
            provider: "astra",
            transport: .native,
            operations: ["readFile", "listFiles", "writeFile", "deleteFile"],
            dataAccess: ["workspaceFiles"],
            externalEffects: ["localFileWrite"]
        ),
        WorkspaceAppContractImplementation(
            id: "bigquery-read-native",
            familyID: "tabularQuery.read",
            provider: "bigQuery",
            transport: .native,
            operations: ["previewRows", "runReadOnlyQuery"],
            dataAccess: ["externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "bigquery-read-task-backed",
            familyID: "tabularQuery.read",
            provider: "bigQuery",
            transport: .taskBacked,
            operations: ["listDatasets", "listTables", "describeTable", "previewRows", "dryRunQuery", "runReadOnlyQuery", "exportResults"],
            dataAccess: ["externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-read-native",
            familyID: "recordProject.read",
            provider: "redcap",
            transport: .native,
            operations: ["describeProject", "listForms", "listFields", "readRecords", "lookupRecord", "validateRecord"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-write-native",
            familyID: "recordProject.write",
            provider: "redcap",
            transport: .native,
            operations: ["prepareCreate", "prepareUpdate", "validateWrite", "submitCreate", "submitUpdate"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["externalAPIWrite"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-form-schema-native",
            familyID: "formSchema.read",
            provider: "redcap",
            transport: .native,
            operations: ["describeForms", "describeFields", "describeBranchingRules"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-read-task-backed",
            familyID: "recordProject.read",
            provider: "redcap",
            transport: .taskBacked,
            operations: ["describeProject", "listForms", "listFields", "readRecords", "lookupRecord", "validateRecord"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-write-task-backed",
            familyID: "recordProject.write",
            provider: "redcap",
            transport: .taskBacked,
            operations: ["prepareCreate", "prepareUpdate", "validateWrite", "submitCreate", "submitUpdate"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["externalAPIWrite"]
        ),
        WorkspaceAppContractImplementation(
            id: "redcap-form-schema-task-backed",
            familyID: "formSchema.read",
            provider: "redcap",
            transport: .taskBacked,
            operations: ["describeForms", "describeFields", "describeBranchingRules"],
            dataAccess: ["clinicalData", "externalService"],
            externalEffects: ["readOnly"]
        ),
        WorkspaceAppContractImplementation(
            id: "github-pr-read-native",
            familyID: "pullRequest.read",
            provider: "github",
            transport: .native,
            operations: ["listMyPullRequests", "listRepoPullRequests"],
            dataAccess: ["externalService"],
            externalEffects: ["readOnly"]
        )
    ]
}
