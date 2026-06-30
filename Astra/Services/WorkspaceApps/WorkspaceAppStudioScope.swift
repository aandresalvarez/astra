import Foundation

/// Honest scope detection for App Studio. The Studio builds DATA and WORKFLOW apps
/// (tables, dashboards, review queues, pipelines, report generators, AI workflows) —
/// it has no view type for a content/marketing web page, so an intent like "a landing
/// page for the foundation" can only ever produce a mislabeled data shell. Rather than
/// silently ship that, we surface a plain-language notice. Pure + value-typed so the
/// SwiftUI banner is a thin renderer and this is unit-tested.
enum WorkspaceAppStudioScope {
    /// Strong signals that the user wants a website / marketing / content page.
    private static let contentSiteTokens = [
        "landing page", "landing-page", "website", "web site", "web page", "webpage",
        "marketing site", "marketing page", "home page", "homepage", "splash page",
        "microsite", "static site", "html page", "brochure site", "company site",
        "about page", "portfolio site", "personal site", "blog", "blog post",
    ]

    /// Data/workflow signals. When present alongside a content token, the intent is
    /// probably a data app *about* pages ("track landing page performance"), so we do
    /// not flag it — avoiding false positives.
    private static let dataAppTokens = [
        "track", "log", "manage", "database", "records", "record", "inventory",
        "catalog", "queue", "pipeline", "report", "monitor", "dashboard", "table",
        "crm", "ledger", "form", "intake", "review", "approval", "workflow", "metrics",
        "spreadsheet", "checklist", "roster", "registry", "tracker", "kanban",
    ]

    /// A plain-language notice when the intent looks like a content/marketing website
    /// rather than a data or workflow app. Returns nil when the intent is in scope (or
    /// ambiguous enough that generation should just attempt it).
    static func outOfScopeNotice(for intent: String) -> String? {
        let text = intent.lowercased()
        guard contentSiteTokens.contains(where: { text.contains($0) }) else { return nil }
        if dataAppTokens.contains(where: { containsWord(text, $0) }) { return nil }
        // App Studio now ALSO builds self-contained HTML/CSS/JS tools, so a TOOL intent phrased as
        // a "page" is buildable. Reuse the SAME tight token set `classify` routes to `.htmlApp`, so
        // "in scope as a tool" and "classifies as an HTML app" agree — generic nouns (tool/widget/
        // game) are deliberately excluded so a real marketing site still warns.
        if WorkspaceAppArchetype.htmlToolIntentTokens.contains(where: { text.contains($0) }) { return nil }
        return "App Studio builds data and workflow apps — tables, dashboards, review queues, "
            + "pipelines, and AI workflows — not websites or marketing pages. This intent looks "
            + "like a web page, so generating will produce a data app, not a site. Try something "
            + "like \u{201C}track donors and donations\u{201D}, \u{201C}a dashboard of campaign "
            + "metrics\u{201D}, or \u{201C}a volunteer intake form\u{201D}."
    }

    /// Whether the intent reads as out of scope (drives the banner's presence).
    static func isLikelyOutOfScope(_ intent: String) -> Bool {
        outOfScopeNotice(for: intent) != nil
    }

    /// External-service / live-data signals — intents that need a connector (GitHub, Jira, …) or
    /// internet access to be truly functional.
    private static let connectorTokens = [
        "github", "gitlab", "bitbucket", "pull request", "open pr", "open prs",
        "jira", "linear", "asana", "trello", "slack", "notion", "salesforce", "zendesk",
        "fetch from", "sync with", "pull from", "live data", "real-time data", "from the api",
        "rest api", "google sheets", "airtable",
    ]

    /// GitHub pull-request signals — these ARE supported live (read-only, through the user's `gh` CLI
    /// via the `pullRequest.read` connector), so the notice is POSITIVE, not a limitation.
    private static let githubPRTokens = [
        "github", "pull request", "pull requests", "open pr", "open prs", "my prs", "my pull requests",
    ]

    /// A non-blocking notice for an intent that touches live/external data. UNLIKE `outOfScopeNotice`
    /// (which blocks a marketing-site build), this is additive: the caller surfaces it and then
    /// proceeds. For GitHub PRs the notice is POSITIVE (we wire real data); for connectors we don't yet
    /// bridge, it honestly says sample data only. Returns nil when no connector signal is present.
    static func needsConnectorNotice(for intent: String) -> String? {
        let text = intent.lowercased()
        if githubPRTokens.contains(where: { text.contains($0) }) {
            return "I can wire this to your REAL GitHub pull requests (read-only) through your `gh` CLI "
                + "sign-in \u{2014} no sample data. Other GitHub data (issues, commits) and any writes "
                + "aren\u{2019}t bridged yet."
        }
        guard connectorTokens.contains(where: { text.contains($0) }) else { return nil }
        return "Heads up: apps built here run in a locked sandbox with no internet access, so this "
            + "one can\u{2019}t pull live data (Jira, Slack, etc.) yet. I\u{2019}ll build the "
            + "interactive UI with sample data \u{2014} live connector sync is planned for a later "
            + "release."
    }

    /// Word-ish containment so "log" doesn't match "blog" / "catalog" and "form"
    /// doesn't match "platform". Matches the token at a word boundary.
    private static func containsWord(_ text: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        // Multi-word tokens are matched as plain substrings.
        if token.contains(" ") { return text.contains(token) }
        let separators = CharacterSet.alphanumerics.inverted
        return text.components(separatedBy: separators).contains(token)
    }
}
