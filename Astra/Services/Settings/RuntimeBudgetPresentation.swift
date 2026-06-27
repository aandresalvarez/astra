enum RuntimeBudgetPresentation {
    static func isEnabled(_ budget: Int) -> Bool {
        budget > 0
    }

    static func settingsLabel(for budget: Int) -> String {
        isEnabled(budget) ? "\(budget / 1000)k tokens" : "Disabled"
    }

    static func compactLabel(for budget: Int) -> String {
        isEnabled(budget) ? "\(budget / 1000)k" : "Disabled"
    }

    static func runtimeStatusText(
        runtimeName: String,
        modelName: String,
        budget: Int,
        includeRuntime: Bool
    ) -> String {
        var segments: [String] = []
        if includeRuntime {
            segments.append(runtimeName)
        }
        segments.append(modelName)
        if isEnabled(budget) {
            segments.append(compactLabel(for: budget))
        }
        return segments.joined(separator: " · ")
    }

    static func runtimeStatusHelp(
        runtimeName: String,
        modelName: String,
        budget: Int,
        enforcementLabel: String
    ) -> String {
        var segments = [runtimeName, modelName]
        if isEnabled(budget) {
            segments.append(compactLabel(for: budget))
            segments.append(enforcementLabel)
        }
        return segments.joined(separator: " · ")
    }
}
