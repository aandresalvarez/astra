import Foundation

extension AgentRuntimeProcessLaunchPlan {
    func addingSandboxReadablePaths(
        _ paths: [String],
        plannedFields: [String: String] = [:]
    ) -> AgentRuntimeProcessLaunchPlan {
        let readable = Self.uniqueNonEmpty(sandboxReadablePaths + paths)
        guard readable != sandboxReadablePaths || !plannedFields.isEmpty else { return self }

        var updatedPlannedFields = commandPlannedFields
        for (key, value) in plannedFields {
            updatedPlannedFields[key] = value
        }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: readable,
            sandboxHomeStateAccess: sandboxHomeStateAccess,
            sandboxProtectedWriteDenyPaths: sandboxProtectedWriteDenyPaths,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: updatedPlannedFields,
            interactiveAsk: interactiveAsk,
            pathMapper: pathMapper,
            executionEnvironment: executionEnvironment
        )
    }

    func addingSandboxProtectedWriteDenyPaths(_ paths: [String]) -> AgentRuntimeProcessLaunchPlan {
        let protected = Self.uniqueNonEmpty(sandboxProtectedWriteDenyPaths + paths)
        guard protected != sandboxProtectedWriteDenyPaths else { return self }

        return AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: parsesJSONLines,
            directoriesToCreate: directoriesToCreate,
            sandboxReadablePaths: sandboxReadablePaths,
            sandboxHomeStateAccess: sandboxHomeStateAccess,
            sandboxProtectedWriteDenyPaths: protected,
            providerDetectedFields: providerDetectedFields,
            commandPlannedFields: commandPlannedFields,
            interactiveAsk: interactiveAsk,
            pathMapper: pathMapper,
            executionEnvironment: executionEnvironment
        )
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}
