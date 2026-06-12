import Foundation

enum SlashWizardType: String {
    case skill = "/skill"
    case tool = "/tool"
    case connector = "/connector"
    case template = "/template"
    case schedule = "/routine"
    case recap = "/recap"
}

struct SlashWizard {
    let type: SlashWizardType
    var step: Int = 0
    var collected: [String: String] = [:]

    var currentPrompt: String {
        switch type {
        case .skill:
            switch step {
            case 0: return "What should this skill be called?"
            case 1: return "Describe what this skill does (behavior instructions for the agent):"
            case 2: return "Which tools should be **allowed**? (comma-separated, e.g. `Read, Glob, Grep, Bash`)\n\nAvailable: `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `Agent`, `NotebookEdit`"
            case 3: return "Which tools should be **blocked**? (comma-separated, or type `none`):"
            default: return ""
            }
        case .tool:
            switch step {
            case 0: return "What should this tool be called?"
            case 1: return "What type of tool is it?\n\n`1` — CLI Command (e.g. jq, curl, docker)\n`2` — Script File (e.g. /path/to/script.sh)\n`3` — MCP Tool (e.g. mcp__server__tool)"
            case 2:
                let toolType = collected["type"] ?? "cli"
                switch toolType {
                case "script": return "Enter the path to the script file:"
                case "mcp": return "Enter the MCP tool name (e.g. `mcp__server__tool_name`):"
                default: return "Enter the CLI command (e.g. `jq`, `curl`, `docker`):"
                }
            case 3: return "Description (optional, press Enter to skip):"
            default: return ""
            }
        case .connector:
            switch step {
            case 0: return "What should this connector be called?"
            case 1: return "What service type?\n\n`1` — Jira\n`2` — GitHub\n`3` — Slack\n`4` — Database\n`5` — REST API\n`6` — Confluence\n`7` — Custom"
            case 2: return "Enter the base URL (e.g. `https://mysite.atlassian.net`):"
            case 3: return "Auth method?\n\n`1` — None\n`2` — Basic (username/password)\n`3` — Bearer token\n`4` — API Key"
            case 4:
                // Smart credential prompts based on service type
                if let key = nextCredentialKey {
                    return "Enter the value for `\(key)` (stored securely):"
                }
                return "Add a credential key name (e.g. `API_TOKEN`), or type `done` to finish:"
            case 5: return "Enter the value for `\(collected["pendingCredKey"] ?? "")` (stored securely):"
            case 6:
                // After known credentials, offer to add more
                return "Add another credential key name, or type `done` to finish:"
            default: return ""
            }
        case .template:
            switch step {
            case 0:
                // Show available templates (list is set externally before wizard starts)
                let list = collected["templateList"] ?? "No templates available."
                return "\(list)\n\nEnter the number of the template to use:"
            case 1:
                // Ask for task title
                return "What should this task be called?"
            default:
                // Variable prompts — dynamically generated
                let varLabel = collected["currentVarLabel"] ?? "value"
                let varDefault = collected["currentVarDefault"] ?? ""
                let defaultHint = varDefault.isEmpty ? "" : " (default: `\(varDefault)`)"
                return "Enter **\(varLabel)**\(defaultHint):"
            }
        case .schedule:
            return "" // Routine uses provider-assisted conversation, not wizard steps
        case .recap:
            return "" // Recap is one-shot, bypasses the wizard
        }
    }

    /// Known credential keys for common service types
    private static let knownCredentials: [String: [String]] = [
        "jira": ["JIRA_EMAIL", "JIRA_API_TOKEN"],
        "github": ["GITHUB_TOKEN"],
        "slack": ["SLACK_TOKEN"],
        "database": ["DATABASE_URL"],
        "rest_api": ["API_TOKEN"],
        "confluence": ["CONFLUENCE_EMAIL", "CONFLUENCE_API_TOKEN"],
    ]

    /// The next credential key to ask for (nil if all known keys collected or custom type)
    var nextCredentialKey: String? {
        guard let serviceType = collected["serviceType"],
              let keys = Self.knownCredentials[serviceType] else { return nil }
        let existingKeys = (collected["credKeys"] ?? "").split(separator: ",").map(String.init)
        return keys.first { !existingKeys.contains($0) }
    }

    var totalSteps: Int {
        switch type {
        case .skill: return 4
        case .tool: return 4
        case .connector: return 4 // base steps, credentials are variable
        case .template: return 10 // variable, depends on template variables
        case .schedule: return 0
        case .recap: return 0
        }
    }

    var isComplete: Bool {
        switch type {
        case .skill: return step >= 4
        case .tool: return step >= 4
        case .connector:
            return collected["credentialsDone"] == "true"
        case .template:
            return collected["templateDone"] == "true"
        case .schedule: return false
        case .recap: return false
        }
    }

    static func introMessage(for type: SlashWizardType) -> String {
        switch type {
        case .skill:
            return "Let's create a new **skill**. A skill defines what tools an agent can use and how it should behave.\n\nI'll guide you through 4 steps."
        case .tool:
            return "Let's create a new **tool**. Tools are local scripts, CLI commands, or MCP integrations your agent can use.\n\nI'll guide you through 4 steps."
        case .connector:
            return "Let's create a new **connector**. Connectors provide authentication and configuration for external services.\n\nI'll guide you through the setup."
        case .template:
            return "Let's create a task from a **template**. Templates define multi-phase workflows with before, main, and after agents."
        case .schedule:
            return "Let's create a **routine**. I'll help you set up recurring work."
        case .recap:
            return "" // Recap is one-shot, bypasses the wizard
        }
    }

    mutating func processInput(_ input: String) -> String? {
        switch type {
        case .skill: return processSkillStep(input)
        case .tool: return processToolStep(input)
        case .connector: return processConnectorStep(input)
        case .template: return processTemplateStep(input)
        case .schedule: return nil
        case .recap: return nil
        }
    }

    private mutating func processSkillStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            collected["behavior"] = input
            step = 2
            return "Behavior set.\n\n\(currentPrompt)"
        case 2:
            collected["allowed"] = input
            step = 3
            return "Allowed tools: `\(input)`\n\n\(currentPrompt)"
        case 3:
            collected["blocked"] = input.lowercased() == "none" ? "" : input
            step = 4
            return nil // signals completion
        default:
            return nil
        }
    }

    private mutating func processToolStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            let typeMap = ["1": "cli", "2": "script", "3": "mcp",
                          "cli": "cli", "script": "script", "mcp": "mcp"]
            let resolved = typeMap[input.lowercased().trimmingCharacters(in: .whitespaces)] ?? "cli"
            collected["type"] = resolved
            step = 2
            let label = resolved == "cli" ? "CLI Command" : resolved == "script" ? "Script File" : "MCP Tool"
            return "Type: **\(label)**\n\n\(currentPrompt)"
        case 2:
            collected["command"] = input
            step = 3
            return "Command: `\(input)`\n\n\(currentPrompt)"
        case 3:
            collected["description"] = input
            step = 4
            return nil // signals completion
        default:
            return nil
        }
    }

    private mutating func processConnectorStep(_ input: String) -> String? {
        switch step {
        case 0:
            collected["name"] = input
            step = 1
            return "Got it — **\(input)**.\n\n\(currentPrompt)"
        case 1:
            let typeMap = ["1": "jira", "2": "github", "3": "slack", "4": "database",
                          "5": "rest_api", "6": "confluence", "7": "custom"]
            let resolved = typeMap[input.trimmingCharacters(in: .whitespaces)] ?? input.lowercased()
            collected["serviceType"] = resolved
            step = 2
            return "Service: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\n\(currentPrompt)"
        case 2:
            collected["baseURL"] = input
            step = 3
            return "Base URL: `\(input)`\n\n\(currentPrompt)"
        case 3:
            let authMap = ["1": "none", "2": "basic", "3": "bearer", "4": "api_key"]
            let resolved = authMap[input.trimmingCharacters(in: .whitespaces)] ?? input.lowercased()
            collected["authMethod"] = resolved
            step = 4
            // For known service types, go straight to asking for values
            if nextCredentialKey != nil {
                return "Auth: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\nNow let's add your credentials.\n\n\(currentPrompt)"
            }
            return "Auth: **\(resolved.replacingOccurrences(of: "_", with: " ").capitalized)**\n\n\(currentPrompt)"
        case 4:
            // Smart mode: if we have a known credential key, the user just types the VALUE
            if let key = nextCredentialKey {
                let existingKeys = collected["credKeys"] ?? ""
                let existingVals = collected["credVals"] ?? ""
                collected["credKeys"] = existingKeys.isEmpty ? key : existingKeys + "," + key
                collected["credVals"] = existingVals.isEmpty ? input : existingVals + "," + input

                // Check if there's another known key to collect
                if nextCredentialKey != nil {
                    return "Saved `\(key)`.\n\n\(currentPrompt)"
                } else {
                    // All known credentials collected — done
                    collected["credentialsDone"] = "true"
                    return nil
                }
            }

            // Manual mode (custom service types): user enters key name or "done"
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "done" || trimmed.isEmpty {
                collected["credentialsDone"] = "true"
                return nil
            }
            collected["pendingCredKey"] = trimmed.uppercased()
            step = 5
            return currentPrompt
        case 5:
            // Manual mode: user enters the value for a custom key
            let key = collected["pendingCredKey"] ?? ""
            let existingKeys = collected["credKeys"] ?? ""
            let existingVals = collected["credVals"] ?? ""
            collected["credKeys"] = existingKeys.isEmpty ? key : existingKeys + "," + key
            collected["credVals"] = existingVals.isEmpty ? input : existingVals + "," + input
            collected.removeValue(forKey: "pendingCredKey")
            step = 6
            return "Saved `\(key)`.\n\n\(currentPrompt)"
        case 6:
            // After manual credential, ask for more or done
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "done" || trimmed.isEmpty {
                collected["credentialsDone"] = "true"
                return nil
            }
            collected["pendingCredKey"] = trimmed.uppercased()
            step = 5
            return currentPrompt
        default:
            return nil
        }
    }

    private mutating func processTemplateStep(_ input: String) -> String? {
        switch step {
        case 0:
            // User selected a template by number
            collected["templateIndex"] = input.trimmingCharacters(in: .whitespaces)
            step = 1
            let templateName = collected["templateName_\(input.trimmingCharacters(in: .whitespaces))"] ?? "template"
            return "Using **\(templateName)**.\n\n\(currentPrompt)"
        case 1:
            // Task title
            collected["taskTitle"] = input
            step = 2
            // Check if there are variables to collect
            let varCount = Int(collected["varCount"] ?? "0") ?? 0
            if varCount == 0 {
                collected["templateDone"] = "true"
                return nil
            }
            // Set up first variable prompt
            collected["currentVarIndex"] = "0"
            let varName = collected["var_0_name"] ?? ""
            let varLabel = collected["var_0_label"] ?? varName
            let varDefault = collected["var_0_default"] ?? ""
            collected["currentVarLabel"] = varLabel
            collected["currentVarDefault"] = varDefault
            return "Title: **\(input)**\n\nNow let's fill in the template variables.\n\n\(currentPrompt)"
        default:
            // Collecting variable values
            let varIndex = Int(collected["currentVarIndex"] ?? "0") ?? 0
            let varName = collected["var_\(varIndex)_name"] ?? ""
            let varDefault = collected["var_\(varIndex)_default"] ?? ""
            let value = input.trimmingCharacters(in: .whitespaces).isEmpty ? varDefault : input
            collected["varValue_\(varName)"] = value

            let varCount = Int(collected["varCount"] ?? "0") ?? 0
            let nextIndex = varIndex + 1

            if nextIndex >= varCount {
                collected["templateDone"] = "true"
                return nil
            }

            // Set up next variable
            collected["currentVarIndex"] = "\(nextIndex)"
            let nextName = collected["var_\(nextIndex)_name"] ?? ""
            let nextLabel = collected["var_\(nextIndex)_label"] ?? nextName
            let nextDefault = collected["var_\(nextIndex)_default"] ?? ""
            collected["currentVarLabel"] = nextLabel
            collected["currentVarDefault"] = nextDefault
            step = nextIndex + 2
            return "Set `\(varName)` = `\(value)`\n\n\(currentPrompt)"
        }
    }
}
