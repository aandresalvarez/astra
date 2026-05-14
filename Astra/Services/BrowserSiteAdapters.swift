import Foundation

enum BrowserSiteAdapterID {
    static let googleDrive = "googleDrive"
    static let github = "github"

    static func normalized(_ value: String) -> String? {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        guard !compact.isEmpty else { return nil }
        switch compact {
        case "googledrive", "googledrivebrowser", "drive":
            return googleDrive
        case "github", "githubbrowser", "githubworkflow", "gh":
            return github
        default:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.compactMap(normalized))
    }

    static func contains(_ id: String, in values: Set<String>) -> Bool {
        guard let normalizedID = normalized(id) else { return false }
        return values.contains(normalizedID)
    }
}

struct BrowserSiteAdapterDescriptor {
    let id: String
    let name: String
    let hostPatterns: [String]
    let capabilities: [String]
    let actions: [BrowserActionKind]

    var jsonObject: [String: Any] {
        [
            "id": id,
            "name": name,
            "hostPatterns": hostPatterns,
            "capabilities": capabilities,
            "actions": actions.map(\.rawValue)
        ]
    }
}

enum GoogleDriveBrowserAdapter {
    static let descriptor = BrowserSiteAdapterDescriptor(
        id: BrowserSiteAdapterID.googleDrive,
        name: "Google Drive Browser",
        hostPatterns: ["drive.google.com"],
        capabilities: ["google.drive.open"],
        actions: [.googleDriveOpen]
    )

    static func isEnabled(in adapterIDs: Set<String>) -> Bool {
        BrowserSiteAdapterID.contains(BrowserSiteAdapterID.googleDrive, in: adapterIDs)
    }

    static func matches(pageURL: String) -> Bool {
        URL(string: pageURL)?.host?.lowercased() == "drive.google.com"
    }

    static func activeMetadata(pageURL: String, enabledAdapterIDs: Set<String>) -> [String: Any]? {
        guard isEnabled(in: enabledAdapterIDs), matches(pageURL: pageURL) else { return nil }
        var object = descriptor.jsonObject
        object["active"] = true
        return object
    }

    static func isFileControl(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        href: String
    ) -> Bool {
        guard matches(pageURL: pageURL) else { return false }
        let text = [selector, label, name, role, tag, href].joined(separator: " ").lowercased()
        let roleText = role.lowercased()
        let likelyFileRole = roleText.contains("gridcell")
            || roleText.contains("row")
            || roleText.contains("listitem")
            || roleText.contains("option")
            || selector.lowercased().contains("aria-label")
        let fileTypeHint = containsAny(text, [
            "google docs",
            "google sheets",
            "google slides",
            "google drawings",
            "located in",
            "opened",
            "modified",
            "more info (option"
        ])
        let fileNameHint = !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !containsAny(text, ["search in drive", "new folder", "upload file"])
        return likelyFileRole && (fileTypeHint || fileNameHint)
    }

    static func nameHint(from label: String) -> String {
        let stopPhrases = [
            " Google Docs",
            " Google Sheets",
            " Google Slides",
            " Google Drawings",
            " Located in",
            " More info",
            " More actions"
        ]
        var result = label
        for phrase in stopPhrases {
            if let range = result.range(of: phrase, options: [.caseInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var recommendations: [[String: Any]] {
        [
            [
                "action": BrowserActionKind.googleDriveOpen.rawValue,
                "adapterID": BrowserSiteAdapterID.googleDrive,
                "reason": "Use Drive search/open helper before manual row clicks."
            ]
        ]
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

enum GitHubBrowserAdapter {
    static let descriptor = BrowserSiteAdapterDescriptor(
        id: BrowserSiteAdapterID.github,
        name: "GitHub Browser",
        hostPatterns: ["github.com"],
        capabilities: ["github.browser.open", "github.api.prefer"],
        actions: [.open]
    )

    static func isEnabled(in adapterIDs: Set<String>) -> Bool {
        BrowserSiteAdapterID.contains(BrowserSiteAdapterID.github, in: adapterIDs)
    }

    static func matches(pageURL: String) -> Bool {
        URL(string: pageURL)?.host?.lowercased() == "github.com"
    }

    static func activeMetadata(pageURL: String, enabledAdapterIDs: Set<String>) -> [String: Any]? {
        guard isEnabled(in: enabledAdapterIDs), matches(pageURL: pageURL) else { return nil }
        var object = descriptor.jsonObject
        object["active"] = true
        object["preferredReadPath"] = "Use gh CLI for durable issue, PR, repository, and Actions reads when possible."
        return object
    }

    static func isEntityControl(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        href: String
    ) -> Bool {
        guard matches(pageURL: pageURL) else { return false }
        let target = href.isEmpty ? selector : href
        guard let path = URL(string: target)?.path.lowercased()
            ?? URL(string: pageURL)?.path.lowercased() else {
            return false
        }
        let text = [selector, label, name, role, tag, href].joined(separator: " ").lowercased()
        return path.contains("/issues/")
            || path.contains("/pull/")
            || path.contains("/actions/")
            || path.contains("/blob/")
            || path.contains("/tree/")
            || containsAny(text, ["issue #", "pull request", "checks", "workflow", "commits"])
    }

    static func nameHint(from label: String) -> String {
        label
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var recommendations: [[String: Any]] {
        [
            [
                "action": "prefer-api",
                "adapterID": BrowserSiteAdapterID.github,
                "reason": "Use gh CLI/API reads before broad browser scraping for GitHub issues, PRs, repos, and Actions."
            ],
            [
                "action": BrowserActionKind.open.rawValue,
                "adapterID": BrowserSiteAdapterID.github,
                "reason": "Use browser open for authenticated pages or visual inspection, then verify URL/title outcome."
            ]
        ]
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
