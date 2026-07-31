import ASTRACore

enum CapabilityPrerequisiteStatusSelection {
    static func allVerified(
        _ prerequisites: [CLIPrerequisite],
        statuses: [String: HealthStatus]
    ) -> Bool {
        prerequisites.allSatisfy { prerequisite in
            guard let status = statuses[prerequisite.id],
                  case .healthy = status else {
                return false
            }
            return true
        }
    }

    static func firstUnready(
        _ prerequisites: [CLIPrerequisite],
        statuses: [String: HealthStatus]
    ) -> (CLIPrerequisite, HealthStatus?)? {
        for prerequisite in prerequisites {
            guard let status = statuses[prerequisite.id] else {
                return (prerequisite, nil)
            }
            if case .healthy = status {
                continue
            }
            return (prerequisite, status)
        }
        return nil
    }

    static func firstBlocking(
        _ prerequisites: [CLIPrerequisite],
        statuses: [String: HealthStatus]
    ) -> (CLIPrerequisite, HealthStatus?)? {
        for prerequisite in prerequisites {
            guard let status = statuses[prerequisite.id] else {
                return (prerequisite, nil)
            }
            if status.isUsable {
                continue
            }
            return (prerequisite, status)
        }
        return nil
    }
}
