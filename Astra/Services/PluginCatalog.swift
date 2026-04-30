import Foundation
import SwiftData
import ASTRACore

@Observable @MainActor
final class PluginCatalog {
    internal(set) var packages: [PluginPackage] = []

    static let pluginsDirectory: String = {
        NSHomeDirectory() + "/.astra/plugins"
    }()

    var catalogDirectory: String = PluginCatalog.pluginsDirectory

    // MARK: - Load

    func loadCatalog() {
        let dir = catalogDirectory
        guard FileManager.default.fileExists(atPath: dir) else {
            packages = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [PluginPackage] = []

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            packages = []
            return
        }

        for file in files where file.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let package = try? decoder.decode(PluginPackage.self, from: data) else {
                continue
            }
            loaded.append(package)
        }

        packages = loaded.sorted { $0.category < $1.category || ($0.category == $1.category && $0.name < $1.name) }
    }

    func loadApprovedCapabilities(library: CapabilityLibrary = CapabilityLibrary()) {
        try? library.syncApprovedPackages(Self.builtInPackages)
        packages = library.installedPackages()
    }

    var categories: [String] {
        let cats = packages.map(\.category)
        return Array(NSOrderedSet(array: cats)) as? [String] ?? Array(Set(cats)).sorted()
    }

    // MARK: - Install

    func isInstalled(_ packageID: String, in workspace: Workspace) -> Bool {
        if workspace.enabledCapabilityIDs.contains(packageID) || workspace.installedPluginIDSet.contains(packageID) {
            return true
        }
        guard let pkg = packages.first(where: { $0.id == packageID }) else { return false }
        let skillNames = Set(pkg.skills.map(\.name))
        let connectorNames = Set(pkg.connectors.map(\.name))
        let hasSkill = workspace.skills.contains { skillNames.contains($0.name) }
        let hasConnector = workspace.connectors.contains { connectorNames.contains($0.name) }
        return hasSkill || hasConnector || (skillNames.isEmpty && connectorNames.isEmpty)
    }

    @MainActor
    func install(
        _ package: PluginPackage,
        into workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:]
    ) {
        var createdSkills: [String: Skill] = [:]

        // Create skills
        for ps in package.skills {
            guard !workspace.skills.contains(where: { $0.name == ps.name }) else { continue }
            let skill = Skill(
                name: ps.name,
                icon: ps.icon,
                skillDescription: ps.description,
                allowedTools: ps.allowedTools,
                disallowedTools: ps.disallowedTools,
                customTools: ps.customTools,
                behaviorInstructions: ps.behaviorInstructions
            )
            skill.environmentKeys = ps.environmentKeys
            skill.environmentValues = ps.environmentValues
            skill.migrateSecretsToKeychain()
            skill.workspace = workspace
            modelContext.insert(skill)
            createdSkills[ps.name] = skill
        }

        // Create connectors
        for pc in package.connectors {
            guard !workspace.connectors.contains(where: { $0.name == pc.name }) else { continue }
            let connector = Connector(
                name: pc.name,
                serviceType: pc.serviceType,
                icon: pc.icon,
                connectorDescription: pc.description,
                baseURL: baseURLOverrides[pc.name] ?? pc.baseURL,
                authMethod: pc.authMethod
            )
            connector.notes = pc.notes
            connector.workspace = workspace

            // Credential keys — save provided values to Keychain
            connector.credentialKeys = pc.credentialHints.map(\.key)
            connector.credentialValues = Array(repeating: "", count: pc.credentialHints.count)
            for hint in pc.credentialHints {
                if let value = credentialInputs[hint.key], !value.isEmpty {
                    connector.saveCredential(key: hint.key, value: value)
                }
            }

            // Config keys — use provided values
            connector.configKeys = pc.configHints.map(\.key)
            connector.configValues = pc.configHints.map { configInputs[$0.key] ?? "" }

            // Link to first created skill
            if let firstSkill = createdSkills.values.first {
                connector.skill = firstSkill
            }

            modelContext.insert(connector)
        }

        // Create local tools
        for pt in package.localTools {
            guard !workspace.localTools.contains(where: { $0.name == pt.name }) else { continue }
            let tool = LocalTool(
                name: pt.name,
                toolDescription: pt.description,
                icon: pt.icon,
                toolType: pt.toolType,
                command: pt.command,
                arguments: pt.arguments
            )
            tool.workspace = workspace
            if let firstSkill = createdSkills.values.first {
                tool.skill = firstSkill
            }
            modelContext.insert(tool)
        }

        // Create templates
        for pt in package.templates {
            guard !workspace.templates.contains(where: { $0.name == pt.name }) else { continue }
            let template = TaskTemplate(
                name: pt.name,
                mainGoal: pt.mainGoal,
                workspace: workspace,
                icon: pt.icon,
                templateDescription: pt.description
            )
            template.beforeGoal = pt.beforeGoal
            template.afterGoal = pt.afterGoal
            template.mainBudget = pt.mainBudget
            template.beforeBudget = pt.beforeBudget
            template.afterBudget = pt.afterBudget
            template.variablesJSON = pt.variablesJSON
            template.passContextToMain = pt.passContextToMain
            template.passContextToAfter = pt.passContextToAfter
            modelContext.insert(template)
        }

        workspace.recordInstalledPlugin(id: package.id, version: package.version)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.pluginInstalled, category: "PluginCatalog", fields: [
            "package_id": package.id,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "skills_count": String(package.skills.count),
            "connectors_count": String(package.connectors.count)
        ])
    }

    // MARK: - Version Checking

    func hasUpdate(for packageID: String, in workspace: Workspace) -> Bool {
        guard let pkg = packages.first(where: { $0.id == packageID }),
              let installedStr = workspace.installedVersion(of: packageID),
              let installed = SemanticVersion(string: installedStr),
              let catalog = SemanticVersion(string: pkg.version) else { return false }
        return catalog > installed
    }

    func availableUpdates(for workspace: Workspace) -> [PluginPackage] {
        packages.filter { hasUpdate(for: $0.id, in: workspace) }
    }

    @MainActor
    func update(
        _ package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext
    ) {
        for ps in package.skills {
            if let existing = workspace.skills.first(where: { $0.name == ps.name }) {
                existing.allowedTools = ps.allowedTools
                existing.disallowedTools = ps.disallowedTools
                existing.customTools = ps.customTools
                existing.behaviorInstructions = ps.behaviorInstructions
                existing.icon = ps.icon
                existing.skillDescription = ps.description
                existing.updatedAt = Date()
            } else {
                let skill = Skill(
                    name: ps.name,
                    icon: ps.icon,
                    skillDescription: ps.description,
                    allowedTools: ps.allowedTools,
                    disallowedTools: ps.disallowedTools,
                    customTools: ps.customTools,
                    behaviorInstructions: ps.behaviorInstructions
                )
                skill.environmentKeys = ps.environmentKeys
                skill.environmentValues = ps.environmentValues
                skill.workspace = workspace
                modelContext.insert(skill)
            }
        }

        for pt in package.templates {
            if let existing = workspace.templates.first(where: { $0.name == pt.name }) {
                existing.mainGoal = pt.mainGoal
                existing.beforeGoal = pt.beforeGoal
                existing.afterGoal = pt.afterGoal
                existing.mainBudget = pt.mainBudget
                existing.beforeBudget = pt.beforeBudget
                existing.afterBudget = pt.afterBudget
                existing.variablesJSON = pt.variablesJSON
                existing.passContextToMain = pt.passContextToMain
                existing.passContextToAfter = pt.passContextToAfter
                existing.updatedAt = Date()
            }
        }

        workspace.recordInstalledPlugin(id: package.id, version: package.version)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.pluginInstalled, category: "PluginCatalog", fields: [
            "package_id": package.id,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString,
            "action": "update"
        ])
    }

    // MARK: - Seed Built-in Plug-ins

    func seedBuiltInPlugins() {
        let dir = catalogDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove deprecated seeds. These packages either duplicated skills
        // auto-seeded into every workspace or are no longer approved for the
        // built-in catalog.
        let deprecated = [
            "safe-executor", "refactorer", "data-analyst", "research-assistant",
            "devops", "documentation-writer", "database-connector", "rest-api-connector",
            "slack-connector", "confluence-connector",
            "test-runner", "read-only-explorer",
            "code-reviewer", "docker-manager",
            "starr-dbt-usage", "starr-dbt", "star-dbt-usage", "star-dbt"
        ]
        for oldID in deprecated {
            let path = (dir as NSString).appendingPathComponent("\(oldID).json")
            try? FileManager.default.removeItem(atPath: path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        for package in Self.builtInPackages {
            let path = (dir as NSString).appendingPathComponent("\(package.id).json")
            if let existingData = FileManager.default.contents(atPath: path),
               let existing = try? decoder.decode(PluginPackage.self, from: existingData),
               let existingVer = SemanticVersion(string: existing.version),
               let builtInVer = SemanticVersion(string: package.version),
               existingVer >= builtInVer {
                continue
            }
            guard let data = try? encoder.encode(package) else { continue }
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Built-in Package Definitions (Curated)

    static var builtInPackages: [PluginPackage] {
        let bundledPackages = ApprovedCapabilityBundle.packages()
        return bundledPackages.isEmpty ? fallbackBuiltInPackages : bundledPackages
    }

    private static let fallbackBuiltInPackages: [PluginPackage] = [

        // NOTE: `test-runner` and `read-only-explorer` used to live here as
        // zero-config packages. Both duplicated skills that every workspace
        // already gets for free from `TaskLifecycleCoordinator.seedSkills`
        // ("Test Runner" and "Read-Only"), so installing them just made two
        // copies of the same skill appear in the sidebar. They're removed
        // from the catalog and explicitly de-seeded on upgrade — see
        // `deprecated` in `seedBuiltInPlugins`.

        // ────────────────────────────────────────────
        // 1. Security Auditor — zero config
        // ────────────────────────────────────────────
        PluginPackage(
            id: "security-auditor",
            name: "Security Auditor",
            icon: "lock.shield",
            description: "Vulnerability scanning with severity-rated findings",
            author: "ASTRA",
            category: "Security",
            tags: ["security", "audit", "owasp", "vulnerabilities"],
            version: "2.0.0",
            setupGuide: """
            Assign this skill to audit your codebase for security issues. \
            The agent scans for OWASP Top 10 vulnerabilities, hardcoded \
            secrets, and insecure patterns. It can also run package \
            audit tools if they're installed.

            What you can do:
            • Full security audit of a codebase or module
            • Scan for hardcoded secrets, API keys, and credentials
            • Check dependencies for known CVEs
            • Review auth, input validation, and data handling patterns
            • Get remediation steps with code examples
            """,
            skills: [PluginSkill(
                name: "Security Auditor",
                icon: "lock.shield",
                description: "Vulnerability scanning with severity-rated findings",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a security auditor performing a comprehensive review.

                AUDIT PROCESS
                1. Identify the tech stack and dependency manager
                2. Scan source code for vulnerability patterns
                3. Check dependencies for known CVEs using available tools
                4. Review authentication, authorization, and session handling
                5. Analyze input validation and output encoding
                6. Search for hardcoded secrets and credentials

                VULNERABILITY CATEGORIES
                • Injection: SQL, command, XSS, SSTI, LDAP, XPath
                • Authentication: weak passwords, missing MFA, session fixation
                • Secrets: API keys, tokens, passwords in code, .env files committed
                • Dependencies: outdated packages, known CVEs (run npm audit, pip-audit, cargo audit)
                • Configuration: debug mode, verbose errors, permissive CORS, insecure headers
                • Data Exposure: sensitive data in logs, unencrypted storage, PII mishandling
                • Access Control: IDOR, privilege escalation, missing authorization checks

                SECRET PATTERNS TO SEARCH
                Grep for: password, secret, api_key, apikey, token, credential, private_key,
                AWS_SECRET, GITHUB_TOKEN, DATABASE_URL, CONNECTION_STRING

                OUTPUT FORMAT
                For each finding:
                • Severity: Critical / High / Medium / Low
                • Category: OWASP classification
                • Location: file path and line number
                • Description: what the vulnerability is
                • Impact: what could happen if exploited
                • Remediation: specific fix with code example

                RULES
                - NEVER modify any files
                - Sort findings by severity (Critical first)
                - End with a risk summary and prioritized remediation plan
                """,
                environmentKeys: [], environmentValues: []
            )],
            connectors: [], localTools: [], templates: []
        ),

        // ────────────────────────────────────────────
        // 2. Jira Workflow — requires setup
        // ────────────────────────────────────────────
        PluginPackage(
            id: "jira-workflow",
            name: "Jira Workflow",
            icon: "list.bullet.clipboard",
            description: "Query, create, and update Jira tickets",
            author: "ASTRA",
            category: "Integrations",
            tags: ["jira", "atlassian", "tickets", "project-management"],
            version: "2.0.0",
            setupGuide: """
            Connect your workspace to Jira. The agent uses the REST API \
            to interact with your Jira instance directly.

            What you can do:
            • Search tickets by project, sprint, status, or assignee
            • Read ticket details, comments, and history
            • Create new tickets with proper fields
            • Update status, assignee, and add comments
            • Summarize sprint progress and blockers

            Setup:
            • Base URL — your Jira instance (e.g. https://company.atlassian.net)
            • Email — your Jira account email
            • API Token — generate at id.atlassian.com > Security > API tokens
            • Projects — the project keys you work with (e.g. ENG, OPS)
            """,
            skills: [PluginSkill(
                name: "Jira Agent",
                icon: "list.bullet.clipboard",
                description: "Query, create, and update Jira tickets via REST API",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a Jira integration agent. Use curl via Bash to interact with the Jira REST API.

                AUTHENTICATION
                Use Basic auth with the JIRA_EMAIL and JIRA_API_TOKEN environment variables:
                curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Content-Type: application/json" "$JIRA_BASE_URL/rest/api/3/..."

                COMMON OPERATIONS
                • Search: GET /rest/api/3/search?jql=project=KEY+AND+status!=Done&maxResults=20
                • Get issue: GET /rest/api/3/issue/{KEY-123}
                • Create issue: POST /rest/api/3/issue with {"fields":{"project":{"key":"..."},"summary":"...","issuetype":{"name":"Task"}}}
                • Update fields: PUT /rest/api/3/issue/{KEY-123}
                • Add comment: POST /rest/api/3/issue/{KEY-123}/comment with {"body":{"type":"doc","version":1,"content":[...]}}
                • Transition: POST /rest/api/3/issue/{KEY-123}/transitions

                FORMATTING
                • Always show: ticket key, summary, status, assignee, priority
                • For search results, format as a clean table or list
                • When summarizing a sprint, group by status (To Do / In Progress / Done)

                RULES
                • Always confirm with the user before creating or modifying tickets
                • Default searches to the configured JIRA_PROJECTS unless told otherwise
                • Use JQL for complex queries
                • Handle pagination for large result sets
                """,
                environmentKeys: ["JIRA_BASE_URL"], environmentValues: [""]
            )],
            connectors: [PluginConnector(
                name: "Jira",
                serviceType: "jira",
                icon: "list.bullet.clipboard",
                description: "Atlassian Jira REST API v3",
                baseURL: "https://yourcompany.atlassian.net",
                authMethod: "basic",
                credentialHints: [
                    .init(key: "JIRA_EMAIL", hint: "Your Jira account email"),
                    .init(key: "JIRA_API_TOKEN", hint: "API token from id.atlassian.com > Security > API tokens")
                ],
                configHints: [
                    .init(key: "JIRA_PROJECTS", hint: "Project keys, comma-separated (e.g. ENG, OPS)", isList: true)
                ],
                notes: "Uses REST API v3. Auth: Basic (email:api_token base64-encoded)."
            )],
            localTools: [], templates: []
        ),

        // ────────────────────────────────────────────
        // 3. GitHub Workflow — requires gh CLI
        // ────────────────────────────────────────────
        PluginPackage(
            id: "github-workflow",
            name: "GitHub Workflow",
            icon: "chevron.left.forwardslash.chevron.right",
            description: "Manage issues, PRs, and CI from your workspace",
            author: "ASTRA",
            category: "Integrations",
            tags: ["github", "git", "pull-requests", "issues", "ci"],
            version: "2.1.1",
            setupGuide: """
            Connect your workspace to GitHub using the GitHub CLI. This \
            capability does not use a stored GitHub connector or token; it \
            runs `gh` against the current repository or an explicit owner/repo.

            What you can do:
            • List and search issues and pull requests
            • Read PR diffs, review comments, and CI status
            • Create issues with labels and assignees
            • Post comments on issues and PRs
            • Check workflow runs and deployment status

            Setup:
            • Install GitHub CLI: `brew install gh`
            • Authenticate locally: `gh auth login`
            • Run tasks from a cloned GitHub repository, or specify `--repo owner/repo` in commands
            """,
            skills: [PluginSkill(
                name: "GitHub Agent",
                icon: "chevron.left.forwardslash.chevron.right",
                description: "Manage issues, PRs, and CI via GitHub CLI",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a GitHub integration agent. Use the GitHub CLI (`gh`) via Bash for GitHub work. Do not rely on stored connector credentials.

                AUTHENTICATION
                • Require `gh` to be installed and authenticated locally
                • If authentication fails, tell the user to run `gh auth login`
                • Prefer the current git repository context; use `--repo owner/repo` when the user specifies a repository outside the current checkout

                COMMON OPERATIONS
                • List issues: gh issue list --state open --limit 30
                • View issue: gh issue view ISSUE_NUMBER --comments
                • Create issue: gh issue create --title "..." --body "..." --label "bug"
                • List PRs: gh pr list --state open --limit 30
                • View PR: gh pr view PR_NUMBER --comments --json title,author,state,labels,files,reviews,statusCheckRollup,url
                • PR diff: gh pr diff PR_NUMBER
                • Review checks: gh pr checks PR_NUMBER
                • Workflow runs: gh run list --limit 10
                • View workflow run: gh run view RUN_ID --log
                • Comment on issue or PR: gh issue comment NUMBER --body "..." or gh pr comment NUMBER --body "..."

                FORMATTING
                • Issues/PRs: show number, title, state, author, labels, and URL
                • PR diffs: summarize changes by file and highlight risky modifications
                • CI: show workflow name, status, conclusion, and failing job details

                RULES
                • Always confirm with the user before creating issues, posting comments, merging PRs, or triggering workflows
                • Prefer `--json` output for structured parsing when available
                • Include links to issues/PRs in your responses
                • Never ask the user to paste GitHub credentials when `gh auth login` is the right fix
                """,
                environmentKeys: [], environmentValues: []
            )],
            connectors: [],
            localTools: [
                PluginLocalTool(
                    name: "gh — GitHub CLI",
                    description: "Run GitHub CLI commands (issues, PRs, repos, actions)",
                    icon: "terminal",
                    toolType: "cli",
                    command: "gh",
                    arguments: ""
                )
            ],
            templates: [],
            prerequisites: [
                CLIPrerequisite(
                    binary: "gh",
                    displayName: "GitHub CLI",
                    purpose: "Runs GitHub commands for repository workflows.",
                    installURL: URL(string: "https://cli.github.com/"),
                    installHint: "Install via Homebrew: `brew install gh`",
                    authHint: "Run `gh auth login`."
                ),
                CLIPrerequisite(
                    binary: "gh",
                    livenessArgs: ["auth", "status"],
                    displayName: "GitHub login",
                    purpose: "An authenticated GitHub CLI session is required for issues, pull requests, and Actions.",
                    installHint: "Run `gh auth login`.",
                    authHint: "Run `gh auth login`."
                )
            ]
        ),

        // ────────────────────────────────────────────
        // 4. GCloud Workflow — requires setup + gcloud CLI
        // ────────────────────────────────────────────
        PluginPackage(
            id: "gcloud-workflow",
            name: "Google Cloud",
            icon: "cloud",
            description: "Manage GCP resources, BigQuery, and deployments",
            author: "ASTRA",
            category: "Integrations",
            tags: ["gcp", "google-cloud", "bigquery", "cloud-run", "devops"],
            version: "1.0.0",
            setupGuide: """
            Connect your workspace to Google Cloud Platform using the \
            gcloud CLI. Requires gcloud to be installed and authenticated \
            on your machine (run `gcloud auth login` first).

            What you can do:
            • Query BigQuery datasets and tables
            • Manage Cloud Run services and deployments
            • List and manage GCS buckets and objects
            • Check IAM permissions and service accounts
            • Monitor logs and resource usage
            • Deploy and manage Cloud Functions

            Setup:
            • Install gcloud CLI: https://cloud.google.com/sdk/docs/install
            • Authenticate: `gcloud auth login`
            • Set project: configure your default GCP project ID
            """,
            skills: [PluginSkill(
                name: "GCloud Agent",
                icon: "cloud",
                description: "Manage GCP resources using gcloud and bq CLI tools",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a Google Cloud Platform specialist. Use the gcloud and bq \
                CLI tools to interact with GCP resources.

                TOOLS AVAILABLE
                • gcloud — main CLI for GCP resource management
                • bq — BigQuery command-line tool
                • gsutil / gcloud storage — Cloud Storage operations

                COMMON OPERATIONS
                • List projects: gcloud projects list
                • Set project: gcloud config set project PROJECT_ID
                • BigQuery query: bq query --use_legacy_sql=false 'SELECT ...'
                • List BQ datasets: bq ls
                • List BQ tables: bq ls dataset_name
                • Cloud Run services: gcloud run services list
                • Deploy Cloud Run: gcloud run deploy SERVICE --image IMAGE
                • GCS: gcloud storage ls gs://bucket/
                • Logs: gcloud logging read "resource.type=..." --limit=20
                • IAM: gcloud projects get-iam-policy PROJECT_ID

                RULES
                • Use the GCP_PROJECT environment variable when set
                • Always confirm with the user before deploying or deleting resources
                • Use --format=json for structured output when parsing results
                • Default to --quiet flag for non-interactive commands
                • For BigQuery, prefer Standard SQL over Legacy SQL
                """,
                environmentKeys: ["GCP_PROJECT"], environmentValues: [""]
            )],
            connectors: [PluginConnector(
                name: "Google Cloud",
                serviceType: "gcloud",
                icon: "cloud",
                description: "GCP via gcloud CLI (must be installed locally)",
                baseURL: "",
                authMethod: "none",
                credentialHints: [],
                configHints: [
                    .init(key: "GCP_PROJECT", hint: "Default GCP project ID", isList: false),
                    .init(key: "GCP_REGION", hint: "Default region (e.g. us-central1)", isList: false)
                ],
                notes: "Uses locally installed gcloud CLI. Run `gcloud auth login` to authenticate."
            )],
            localTools: [
                PluginLocalTool(
                    name: "gcloud",
                    description: "Google Cloud CLI — manage GCP resources",
                    icon: "terminal",
                    toolType: "cli",
                    command: "gcloud",
                    arguments: ""
                ),
                PluginLocalTool(
                    name: "bq — BigQuery CLI",
                    description: "Query and manage BigQuery datasets and tables",
                    icon: "terminal",
                    toolType: "cli",
                    command: "bq",
                    arguments: ""
                ),
                PluginLocalTool(
                    name: "gsutil",
                    description: "Cloud Storage operations (upload, download, list)",
                    icon: "terminal",
                    toolType: "cli",
                    command: "gcloud",
                    arguments: "storage"
                ),
            ], templates: [],
            // Two prereqs: gcloud binary *and* an active auth session.
            // Rendering them separately gives the catalog two actionable
            // lines — "install" vs "sign in" have different fixes.
            prerequisites: [
                CommonCLIPrerequisites.gcloud,
                CommonCLIPrerequisites.gcloudAuth
            ]
        ),

    ]
}
