import Foundation
import ASTRACore

/// Read-side catalog of capability packages. All mutations (enable, disable,
/// remove, import, create) go through `CapabilityCatalogActionService` →
/// `CapabilityInstaller`/`CapabilityUninstaller`; this type only loads the
/// approved/built-in package set and exposes the curated definitions.
@Observable @MainActor
final class PluginCatalog {
    /// Scalar change token for presentation consumers. Catalog packages are
    /// value types, so observing the array through a cached projection does not
    /// reliably register later replacements with Observation.
    private(set) var revision = 0
    var packages: [PluginPackage] = [] {
        didSet { revision &+= 1 }
    }
    private var isLoadingApprovedCapabilities = false

    func loadApprovedCapabilities(
        library: CapabilityLibrary = CapabilityLibrary(),
        announceLibraryMutations: Bool = true
    ) {
        // A repair can publish a synchronous global persistence event. The
        // event handler is the sole reload owner, but it may be invoked before
        // this load returns; ignore that nested request because this load has
        // already read the repaired library and assigned the current snapshot.
        guard !isLoadingApprovedCapabilities else { return }
        isLoadingApprovedCapabilities = true
        defer { isLoadingApprovedCapabilities = false }
        let libraryChanged = (try? library.syncApprovedPackages(Self.builtInPackages)) == true
        packages = library.installedPackages()
        if libraryChanged, announceLibraryMutations {
            CapabilityCatalogPersistenceEvents.post(.global)
        }
    }

    // MARK: - Built-in Package Definitions (Curated)

    nonisolated static let builtInPackages: [PluginPackage] = {
        let bundledPackages = ApprovedCapabilityBundle.packages()
        return bundledPackages.isEmpty ? fallbackBuiltInPackages : bundledPackages
    }()

    private nonisolated static let fallbackBuiltInPackages: [PluginPackage] = [

        // NOTE: `test-runner` and `read-only-explorer` used to live here as
        // zero-config packages. Both duplicated skills that every workspace
        // already gets for free from `TaskLifecycleCoordinator.seedSkills`
        // ("Test Runner" and "Read-Only"), so installing them just made two
        // copies of the same skill appear in the sidebar. They're removed
        // from the catalog; `CapabilityLibrary.syncApprovedPackages` drops
        // stale built-in package files on launch.

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
            version: "2.0.1",
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
            connectors: [], localTools: [], templates: [],
            governance: .builtInApproved(
                riskLevel: .medium,
                dataAccess: [.workspaceFiles, .network],
                externalEffects: [.readOnly],
                policyNotes: "Read-only security review capability. It may inspect workspace files and run local audit commands, but package policy disallows file edits."
            )
        ),

        // ────────────────────────────────────────────
        // 2. Jira Workflow — requires setup
        // ────────────────────────────────────────────
        PluginPackage(
            id: "jira-workflow",
            name: "Jira Workflow",
            icon: "list.bullet.clipboard",
            iconDescriptor: .brand("jira", fallbackSystemName: "list.bullet.clipboard"),
            description: "Search and read Jira through ASTRA's credential broker",
            author: "ASTRA",
            category: "Integrations",
            tags: ["jira", "atlassian", "tickets", "project-management"],
            version: "2.2.0",
            setupGuide: """
            Connect your workspace to Jira. The agent uses the REST API \
            to read ticket metadata from your Jira instance through ASTRA's \
            typed host-control broker. Jira credentials stay in ASTRA and are \
            not placed in the provider environment.

            What you can do:
            • Search tickets by project, sprint, status, or assignee
            • Read ticket summaries, status, assignee, priority, project, and issue type
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
                description: "Search and read Jira tickets via typed read-only operations",
                allowedTools: ["Read", "Glob", "Grep", "Bash"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a Jira integration agent. Use only ASTRA's typed Jira host-control tool.

                AUTHENTICATION
                ASTRA resolves the selected connector's email, API token, and base URL inside its broker. Never ask for, inspect, print, or use Jira credential environment variables.

                ASTRA HOST-CONTROL
                Always use the ASTRA host-control route shown in the connector runtime example: `mcp__astra_host__jira`/`astra_host-jira` when MCP is attached, or the typed `astra-host-control jira` command when ASTRA projects its CLI relay. Shell is permitted only to invoke that exact broker command; do not use curl, Python HTTP clients, or direct Jira REST calls. First verify auth with operation status. It reports whether the selected connector has a base URL, email, and API token without revealing secret values.
                For configured projects, use operation search_jql with a narrow project JQL and max_results 1. If status is ready but project checks fail or return no issues, report project visibility, Browse Projects, selected connector projects, or site membership problems instead of saying the token is invalid.
                Do not call raw Jira permission or identity endpoints through the bridge. Only recommend generating a new API token when operation status reports missing or rejected credentials, or typed Jira operations return 401/403.

                READ-ONLY OPERATIONS
                • Status: operation status
                • Search: operation search_jql with jql, optional max_results, and optional next_page_token for Jira pagination
                • Get issue: operation get_issue with issue_key
                • The bridge owns Jira paths and returns a vetted field set. Do not request raw method, path, or body inputs.

                If ASTRA does not attach either Jira host-control route, stop and report that the selected runtime is incompatible. Never fall back to direct REST credential use.

                FORMATTING
                • Always show: ticket key, summary, status, assignee, priority
                • For search results, format as a clean table or list
                • When summarizing a sprint, group by status (To Do / In Progress / Done)

                RULES
                • Do not create, update, comment on, transition, delete, or otherwise mutate Jira tickets with this capability
                • Default searches to the selected connector's configured project keys unless told otherwise
                • Use JQL for complex queries
                • Handle pagination for large result sets by passing returned nextPageToken values as next_page_token
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
            localTools: [], templates: [],
            governance: .builtInApproved(
                riskLevel: .medium,
                dataAccess: [.connectorCredentials, .externalService, .network],
                externalEffects: [.readOnly],
                policyNotes: "Jira access is limited to typed read-only ASTRA host-control operations. Keychain-backed credentials remain inside ASTRA's broker and are not projected into provider environments."
            )
        ),

        // ────────────────────────────────────────────
        // 3. REDCap Workflow — requires setup
        // ────────────────────────────────────────────
        PluginPackage(
            id: "redcap-workflow",
            name: "REDCap Workflow",
            icon: "tablecells",
            description: "Query and manage Stanford REDCap projects through the API",
            author: "ASTRA",
            category: "Integrations",
            tags: ["redcap", "stanford", "research", "clinical-data", "api"],
            version: "1.0.0",
            setupGuide: """
            Connect your workspace to Stanford REDCap using the project API token. \
            The API endpoint is prefilled as https://redcap.stanford.edu/api/.

            What you can do:
            - Export project metadata, instruments, events, arms, DAGs, reports, and records
            - Inspect longitudinal event and instrument-event mappings
            - Import records, metadata, arms, events, DAGs, and instrument-event mappings after explicit confirmation
            - Download or upload REDCap files when the user asks for that workflow

            Setup:
            - Add the project API token as REDCAP_API_TOKEN
            - Keep tokens out of prompts, logs, files, commits, and shell history
            - Use the task output folder for exports and summaries, especially when data may include PHI
            """,
            skills: [PluginSkill(
                name: "REDCap Agent",
                icon: "tablecells",
                description: "Query and manage Stanford REDCap projects via API",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit"],
                customTools: [],
                behaviorInstructions: """
                You are a REDCap API specialist for Stanford REDCap. Use curl via Bash to interact with the REDCap API using form-encoded POST requests.

                AUTHENTICATION
                Use the API token and API endpoint env vars shown for the selected REDCap connector in Available Connectors / ASTRA_CONNECTORS. The prompt may include a connector-specific runtime example; follow those projected env names instead of assuming bare legacy names. Never print, log, echo, save, or commit the token.

                Base curl pattern:
                Use the connector-specific runtime example shown in Available Connectors for project info, then change the content field for the operation below.

                COMMON READ OPERATIONS
                - Project info: content=project&format=json&returnFormat=json
                - Metadata: content=metadata&format=json&returnFormat=json
                - Records: content=record&format=json&type=flat&returnFormat=json
                - Reports: content=report&format=json&report_id=REPORT_ID&returnFormat=json
                - Events: content=event&format=json&returnFormat=json
                - Instrument-event mappings: content=formEventMapping&format=json&returnFormat=json
                - Instruments/forms: content=instrument&format=json&returnFormat=json
                - Arms: content=arm&format=json&returnFormat=json
                - DAGs: content=dag&format=json&returnFormat=json
                - Users: content=user&format=json&returnFormat=json
                - Logging: content=log&format=json&returnFormat=json

                WRITE AND DELETE SAFETY
                - Always confirm with the user before import, update, delete, file upload, DAG/user changes, event changes, or metadata changes.
                - Prefer a dry-run style explanation first: endpoint, content value, records affected, and the exact file you will send.
                - For imports, read data from a file in the task output folder or workspace and send it with --data-urlencode data@path when possible.

                DATA HANDLING
                - Treat REDCap exports as sensitive research data and potential PHI.
                - Save exports only to the task output folder unless the user explicitly names another location.
                - Do not paste large record exports into chat. Summarize schema, counts, fields, and validation issues instead.
                - Use jq or Python for parsing when output is large. Prefer JSON for structured work.

                FORMATTING
                - Report API calls by content value and purpose, not by token.
                - For project summaries, include project title, purpose, record count if known, instruments, events, arms, and reports discovered.
                - For data-quality checks, cite field names, event names, record IDs only when needed, and keep examples minimal.
                """,
                environmentKeys: ["REDCAP_API_URL"], environmentValues: ["https://redcap.stanford.edu/api/"]
            )],
            connectors: [PluginConnector(
                name: "REDCap",
                serviceType: "redcap",
                icon: "tablecells",
                description: "Stanford REDCap API",
                baseURL: "https://redcap.stanford.edu/api/",
                authMethod: "api_key",
                credentialHints: [
                    .init(
                        key: "REDCAP_API_TOKEN",
                        hint: "Project API token from REDCap > API. This is stored in Keychain and exposed to tasks through connector-specific env vars and ASTRA_CONNECTORS."
                    )
                ],
                configHints: [],
                notes: "Uses form-encoded POST requests to the Stanford REDCap API. The API token identifies the project and must never be printed or committed."
            )],
            localTools: [
                PluginLocalTool(
                    name: "curl - REDCap API",
                    description: "Call the REDCap API with form-encoded POST requests",
                    icon: "terminal",
                    toolType: "cli",
                    command: "curl",
                    arguments: ""
                )
            ],
            templates: [],
            governance: .builtInApproved(
                riskLevel: .restricted,
                dataAccess: [.connectorCredentials, .clinicalData, .externalService, .network],
                externalEffects: [.readOnly, .externalAPIWrite],
                policyNotes: "REDCap access can expose sensitive research data and potential PHI. Writes, imports, uploads, and destructive actions require explicit user confirmation at task time."
            )
        ),

        // ────────────────────────────────────────────
        // 4. GitHub Workflow — requires host-control mediated gh CLI
        // ────────────────────────────────────────────
        PluginPackage(
            id: "github-workflow",
            name: "GitHub Workflow",
            icon: "chevron.left.forwardslash.chevron.right",
            iconDescriptor: .brand("github", fallbackSystemName: "chevron.left.forwardslash.chevron.right"),
            description: "Inspect issues, PRs, and CI from your workspace",
            author: "ASTRA",
            category: "Integrations",
            tags: ["github", "git", "pull-requests", "issues", "ci"],
            version: "2.2.0",
            setupGuide: """
            Connect your workspace to GitHub using ASTRA's host-control \
            GitHub tool. This capability does not use a stored GitHub \
            connector or token; ASTRA brokers read-only `gh` operations \
            against the current repository or an explicit owner/repo.

            What you can do:
            • List and search issues and pull requests
            • Read PR diffs, review comments, and CI status
            • Check workflow runs and deployment status

            Setup:
            • Install GitHub CLI: `brew install gh`
            • Authenticate locally: `gh auth login`
            • If ASTRA reports organization SSO is required, choose Repair access. ASTRA coordinates GitHub CLI refresh, browser approval, and repository verification.
            • Run tasks from a cloned GitHub repository, or specify `--repo owner/repo` in commands
            """,
            skills: [PluginSkill(
                name: "GitHub Agent",
                icon: "chevron.left.forwardslash.chevron.right",
                description: "Inspect issues, PRs, and CI via ASTRA host-control GitHub",
                allowedTools: ["Read", "Glob", "Grep"],
                disallowedTools: ["Write", "Edit", "Bash"],
                customTools: [],
                behaviorInstructions: """
                You are a GitHub integration agent. Use the ASTRA host-control route shown for this run. The broker is always read-only; never attempt to use it for mutations. When the effective policy makes native Bash available, normal developer `git`/`gh` commands may be used only for an explicit user-requested branch, commit, push, or draft-PR workflow. Otherwise, do not use direct `gh`, browser clicks, or raw GitHub API calls to bypass the broker.

                ASTRA HOST-CONTROL TRANSPORT
                • MCP runtimes: call `mcp__astra_host__github` (GitHub Copilot CLI may display it as `astra_host-github`) with an `arguments` array
                • CLI-relay runtimes such as Cursor, OpenCode, and Antigravity: invoke exactly `astra-host-control github -- ARGUMENT...` through the shell
                • The CLI relay is a typed policy exception only for that exact executable and argument shape. Do not compose it with pipes, redirects, command substitution, environment expansion, or another shell command.
                • If ASTRA attaches neither route, stop and report that the selected runtime is incompatible.

                AUTHENTICATION
                • Require `gh` to be installed and authenticated locally on the host
                • Distinguish a signed-out CLI from repository-specific organization SSO: use `gh auth login` only when no valid account is active
                • When ASTRA reports SAML SSO authorization is required, direct the user to Manage Capabilities > GitHub > Repair access; ASTRA owns credential refresh and repository verification, so do not ask the user to run auth commands
                • Prefer the current git repository context; use `--repo owner/repo` when the user specifies a repository outside the current checkout

                COMMON OPERATIONS
                • List issues: arguments `["issue", "list", "--state", "open", "--limit", "30"]`; CLI relay `astra-host-control github -- issue list --state open --limit 30`
                • Search issues: arguments `["search", "issues", "query terms", "--state", "open", "--limit", "30", "--json", "number,title,state,author,repository,url,createdAt,updatedAt"]`; CLI relay `astra-host-control github -- search issues "query terms" --state open --limit 30 --json number,title,state,author,repository,url,createdAt,updatedAt`
                • View issue: arguments `["issue", "view", "ISSUE_NUMBER", "--comments"]`; CLI relay `astra-host-control github -- issue view ISSUE_NUMBER --comments`
                • List recent PRs across repositories: arguments `["search", "prs", "--author", "@me", "--state", "all", "--limit", "30", "--sort", "updated", "--order", "desc", "--json", "number,title,state,author,repository,url,createdAt,updatedAt"]`
                • List PRs in current repo: arguments `["pr", "list", "--state", "open", "--limit", "30"]`; CLI relay `astra-host-control github -- pr list --state open --limit 30`
                • View PR: arguments `["pr", "view", "PR_NUMBER", "--comments", "--json", "title,author,state,labels,files,reviews,statusCheckRollup,url"]`; CLI relay `astra-host-control github -- pr view PR_NUMBER --comments --json title,author,state,labels,files,reviews,statusCheckRollup,url`
                • PR diff: arguments `["pr", "diff", "PR_NUMBER"]`; CLI relay `astra-host-control github -- pr diff PR_NUMBER`
                • Review checks: arguments `["pr", "checks", "PR_NUMBER"]`; CLI relay `astra-host-control github -- pr checks PR_NUMBER`
                • Workflow runs: arguments `["run", "list", "--limit", "10"]`; CLI relay `astra-host-control github -- run list --limit 10`
                • View workflow run: arguments `["run", "view", "RUN_ID", "--log"]`; CLI relay `astra-host-control github -- run view RUN_ID --log`

                FORMATTING
                • Issues/PRs: show number, title, state, author, labels, and URL
                • PR diffs: summarize changes by file and highlight risky modifications
                • CI: show workflow name, status, conclusion, and failing job details

                RULES
                • The host-control capability is read-only. Do not create issues, post comments, merge PRs, trigger workflows, or call raw mutating GitHub APIs through it.
                • In Ask, GitHub writes require ASTRA's confirmed typed publication workflow. In Auto, native developer tools may perform an explicitly requested normal branch/commit/push/draft-PR workflow when Bash is available.
                • Never merge, force-push, delete branches or repositories, change secrets, or modify repository administration through this inspection capability.
                • Use `--json` for structured output; do not use `--jq` or `-q` because ASTRA's host-control GitHub broker rejects jq filters.
                • Do not pipe JSON into `python3 - <<'PY'`; the heredoc consumes stdin, so Python will not receive the command output. If Python parsing is required, write JSON to a temp file first or pass it as an argument.
                • Prefer the brokered `search issues` and `search prs` operations for cross-repository searches; raw GitHub API calls are outside this read-only capability.
                • Include links to issues/PRs in your responses
                • Never ask the user to paste GitHub credentials or run a refresh command; use login for a signed-out CLI and the capability's Repair access workflow for organization SSO
                """,
                environmentKeys: [], environmentValues: []
            )],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [],
            prerequisites: [
                CommonCLIPrerequisites.githubCLI,
                CommonCLIPrerequisites.githubAuth
            ],
            governance: .builtInApproved(
                riskLevel: .high,
                dataAccess: [.workspaceFiles, .externalService, .network],
                externalEffects: [.readOnly],
                policyNotes: "GitHub inspection uses ASTRA host-control mediated gh commands and remains read-only. Ask uses a confirmed typed publication workflow for writes; Auto may separately grant provider-native developer tools. Browser mutations and destructive/admin operations are not part of this built-in capability."
            )
        ),

        // ────────────────────────────────────────────
        // 5. GCloud Workflow — requires setup + gcloud CLI
        // ────────────────────────────────────────────
        PluginPackage(
            id: "gcloud-workflow",
            name: "Google Cloud",
            icon: "cloud",
            iconDescriptor: .brand("googlecloud", fallbackSystemName: "cloud"),
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
                • Use the projected project and region env vars shown in Available Connectors / ASTRA_CONNECTORS when set
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
            ],
            governance: .builtInApproved(
                riskLevel: .restricted,
                dataAccess: [.externalService, .network, .workspaceFiles],
                externalEffects: [.readOnly, .externalAPIWrite, .deploy, .delete],
                policyNotes: "Google Cloud operations use local gcloud authentication and can affect cloud infrastructure. Deployments, IAM changes, and deletes require explicit user confirmation."
            )
        ),

        PluginPackage(
            id: "google-drive-browser",
            name: "Google Drive Browser",
            icon: "folder.badge.gearshape",
            iconDescriptor: .brand("googledrive", fallbackSystemName: "folder.badge.gearshape"),
            description: "Adds Google Drive-specific browser open semantics to the Shelf browser",
            author: "ASTRA",
            category: "Browser",
            tags: ["browser", "google-drive", "automation", "site-adapter"],
            version: "1.0.0",
            setupGuide: """
            Enable this capability when a task needs to operate on Google Drive in the Shelf browser. \
            It does not grant account access or store credentials; the user remains signed in directly in the browser.

            What it adds:
            - Google Drive file controls expose open-oriented analysis outcomes
            - `astra-browser google-drive-open` opens a file by visible name and verifies editor navigation
            - Drive row clicks are treated as selection unless an editor actually opens
            """,
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [BrowserSiteAdapterID.googleDrive],
            governance: .builtInApproved(
                riskLevel: .high,
                dataAccess: [.authenticatedBrowserContent, .externalService],
                externalEffects: [.browserNavigation],
                policyNotes: "This package enables Google Drive-specific semantics on ASTRA's trusted Shelf browser bridge. It does not store Google credentials."
            )
        ),

    ]
}
