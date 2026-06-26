import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Contract Registry")
struct WorkspaceAppContractRegistryTests {
    @Test("built-in registry defines stable foundation families")
    func builtInRegistryDefinesStableFoundationFamilies() {
        let registry = WorkspaceAppContractRegistry()
        let familyIDs = Set(registry.families.map(\.id))

        #expect(familyIDs.contains("appStorage.records"))
        #expect(familyIDs.contains("task.launch"))
        #expect(familyIDs.contains("artifact.read"))
        #expect(familyIDs.contains("file.readWrite"))
        #expect(familyIDs.contains("tabularQuery.read"))
        #expect(familyIDs.contains("recordProject.read"))
        #expect(familyIDs.contains("recordProject.write"))
        #expect(familyIDs.contains("formSchema.read"))
        #expect(familyIDs.contains("message.send"))
        #expect(familyIDs.contains("issueTracker.mutate"))

        #expect(registry.family(id: "recordProject.write")?.operations.contains {
            $0.name == "submitUpdate" && $0.effect == .externalWrite && $0.requiresApproval
        } == true)
        #expect(registry.implementation(id: "bigquery-read-native")?.transport == .native)
        #expect(registry.implementation(id: "bigquery-read-native")?.operations == ["previewRows", "runReadOnlyQuery"])
        #expect(registry.implementation(id: "redcap-read-native")?.transport == .native)
        #expect(registry.implementation(id: "redcap-write-native")?.transport == .native)
        #expect(registry.implementation(id: "redcap-form-schema-native")?.transport == .native)
    }

    @Test("provider hint orders compatible implementations without filtering alternates")
    func providerHintOrdersCompatibleImplementationsWithoutFilteringAlternates() {
        let registry = WorkspaceAppContractRegistry(
            families: WorkspaceAppContractRegistry.builtInFamilies,
            implementations: [
                WorkspaceAppContractImplementation(
                    id: "warehouse-read",
                    familyID: "tabularQuery.read",
                    provider: "warehouse",
                    transport: .http,
                    operations: ["describeTable", "runReadOnlyQuery"]
                ),
                WorkspaceAppContractImplementation(
                    id: "bigquery-read",
                    familyID: "tabularQuery.read",
                    provider: "bigQuery",
                    transport: .mcp,
                    operations: ["describeTable", "runReadOnlyQuery"]
                )
            ]
        )
        let requirement = WorkspaceAppRequirement(
            id: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["describeTable", "runReadOnlyQuery"],
            providerHint: "bigQuery"
        )

        let resolution = registry.resolve(requirement)

        #expect(resolution.isSatisfied)
        #expect(resolution.implementations.map(\.id) == ["bigquery-read", "warehouse-read"])
        #expect(resolution.selectedImplementation?.provider == "bigQuery")
    }

    @Test("providerRequired filters out otherwise compatible providers")
    func providerRequiredFiltersOutOtherwiseCompatibleProviders() {
        let registry = WorkspaceAppContractRegistry(
            families: WorkspaceAppContractRegistry.builtInFamilies,
            implementations: [
                WorkspaceAppContractImplementation(
                    id: "generic-record-read",
                    familyID: "recordProject.read",
                    provider: "genericEhr",
                    transport: .http,
                    operations: ["describeProject", "readRecords"]
                ),
                WorkspaceAppContractImplementation(
                    id: "redcap-record-read",
                    familyID: "recordProject.read",
                    provider: "redcap",
                    transport: .taskBacked,
                    operations: ["describeProject", "readRecords"]
                )
            ]
        )
        let requirement = WorkspaceAppRequirement(
            id: "targetRecords",
            contract: "recordProject.read",
            operations: ["describeProject", "readRecords"],
            providerRequired: "redcap"
        )

        let resolution = registry.resolve(requirement)

        #expect(resolution.implementations.map(\.id) == ["redcap-record-read"])
    }

    @Test("implementations missing required operations do not satisfy a requirement")
    func implementationsMissingRequiredOperationsDoNotSatisfyRequirement() {
        let incomplete = WorkspaceAppContractImplementation(
            id: "redcap-record-read",
            familyID: "recordProject.read",
            provider: "redcap",
            transport: .taskBacked,
            operations: ["describeProject", "readRecords"]
        )
        let registry = WorkspaceAppContractRegistry(
            families: WorkspaceAppContractRegistry.builtInFamilies,
            implementations: [incomplete]
        )
        let requirement = WorkspaceAppRequirement(
            id: "targetRecords",
            contract: "recordProject.read",
            operations: ["describeProject", "readRecords", "validateRecord"]
        )

        let resolution = registry.resolve(requirement)

        #expect(!resolution.isSatisfied)
        #expect(resolution.implementations.isEmpty)
        #expect(registry.missingOperations(for: requirement, implementation: incomplete) == ["validateRecord"])
    }

    @Test("optional missing requirement remains non-blocking")
    func optionalMissingRequirementRemainsNonBlocking() {
        let registry = WorkspaceAppContractRegistry(implementations: [])
        let requirement = WorkspaceAppRequirement(
            id: "optionalMessaging",
            contract: "message.send",
            operations: ["sendMessage"],
            optional: true
        )

        let resolution = registry.resolve(requirement)

        #expect(resolution.isSatisfied)
        #expect(resolution.implementations.isEmpty)
    }

    @Test("package declared implementations extend registry without replacing existing IDs")
    func packageDeclaredImplementationsExtendRegistryWithoutReplacingExistingIDs() {
        let registry = WorkspaceAppContractRegistry(implementations: [
            WorkspaceAppContractImplementation(
                id: "warehouse-read",
                familyID: "tabularQuery.read",
                provider: "installedWarehouse",
                transport: .native,
                operations: ["describeTable", "runReadOnlyQuery"]
            )
        ])
        let extended = registry.including(packageImplementations: [
            WorkspaceAppContractImplementation(
                id: "warehouse-read",
                familyID: "tabularQuery.read",
                provider: "packageDuplicate",
                transport: .http,
                operations: ["describeTable", "runReadOnlyQuery"]
            ),
            WorkspaceAppContractImplementation(
                id: "package-warehouse-http",
                familyID: "tabularQuery.read",
                provider: "packageWarehouse",
                transport: .http,
                operations: ["describeTable", "runReadOnlyQuery"]
            )
        ])
        let requirement = WorkspaceAppRequirement(
            id: "warehouse",
            contract: "tabularQuery.read",
            operations: ["describeTable", "runReadOnlyQuery"],
            providerRequired: "packageWarehouse"
        )

        let resolution = extended.resolve(requirement)

        #expect(extended.implementation(id: "warehouse-read")?.provider == "installedWarehouse")
        #expect(resolution.implementations.map(\.id) == ["package-warehouse-http"])
        #expect(resolution.selectedImplementation?.transport == .http)
    }
}
