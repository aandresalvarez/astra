import Foundation

enum GoogleWorkspaceBrowserService {
    static let googleDriveOpenDefaultTimeoutSeconds: Double = 24
    static let googleDriveOpenMaximumTimeoutSeconds: Double = 45

    static func googleDocsFullDocumentClipboardRequiresControlled(
        engine: ShelfBrowserEngine,
        autoPromoteGoogleWorkspace: Bool
    ) -> Bool {
        engine != .controlled && !autoPromoteGoogleWorkspace
    }

    static func googleDriveSearchURL(for name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "drive.google.com"
        components.path = "/drive/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: name)
        ]
        return components.url ?? URL(string: "https://drive.google.com/drive/search")!
    }

    static func isOpenedDriveTarget(urlString: String, title: String, name: String, startURL: String?) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "docs.google.com" {
            guard isGoogleWorkspaceEditorURL(urlString) else { return false }
            return googleDriveOpenedTitleMatches(title, name)
        }
        guard host != "drive.google.com" else {
            return false
        }
        if let startURL, !startURL.isEmpty, urlString == startURL {
            return false
        }
        guard url.scheme == "https" || url.scheme == "http" else { return false }
        return googleDriveOpenedTitleMatches(title, name)
    }

    static func isGoogleWorkspaceEditorURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == "docs.google.com" else {
            return false
        }
        return url.path.hasPrefix("/document/")
            || url.path.hasPrefix("/spreadsheets/")
            || url.path.hasPrefix("/presentation/")
    }

    static func googleDriveOpenedTitleMatches(_ title: String, _ requestedName: String) -> Bool {
        googleDriveFileNameMatches(title, requestedName: requestedName)
    }

    static func googleDriveFileNameMatches(_ text: String, requestedName: String) -> Bool {
        let requested = googleDriveComparableName(requestedName)
        guard !requested.isEmpty else { return false }
        let direct = googleDriveComparableName(text)
        if direct == requested { return true }
        let hinted = googleDriveComparableName(GoogleDriveBrowserAdapter.nameHint(from: text))
        if hinted == requested { return true }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownSuffixes = [
            " google docs",
            " google sheets",
            " google slides",
            " google drawings",
            " - google docs",
            " - google sheets",
            " - google slides",
            " - google drawings"
        ]
        return knownSuffixes.contains { suffix in
            googleDriveComparableName(normalized.replacingOccurrences(of: suffix, with: "")) == requested
        } || googleDriveMetadataPrefixedNameMatches(direct, requestedName: requested)
            || googleDriveMetadataPrefixedNameMatches(hinted, requestedName: requested)
    }

    static func googleDriveOpenCandidates(
        controls: [[String: Any]],
        name: String,
        pageURL: String
    ) -> [[String: Any]] {
        let scored: [(score: Int, index: Int, control: [String: Any])] = controls.enumerated().compactMap { index, control in
            let label = control["label"] as? String ?? ""
            let controlName = control["name"] as? String ?? ""
            let value = control["value"] as? String ?? ""
            let selector = control["selector"] as? String ?? ""
            let role = control["role"] as? String ?? ""
            let tag = control["tag"] as? String ?? ""
            let type = control["type"] as? String ?? ""
            let href = control["href"] as? String ?? ""
            let placeholder = control["placeholder"] as? String ?? ""
            let lowerRole = role.lowercased()
            let lowerTag = tag.lowercased()
            let lowerType = type.lowercased()
            let visibleTextLength = max(label.count, max(controlName.count, value.count))
            let combined = [label, controlName, value, selector, role, tag, type, href, placeholder]
                .joined(separator: " ")

            guard !GoogleDriveBrowserAdapter.isSearchOrFilterControl(
                selector: selector,
                label: label,
                name: controlName,
                value: value,
                role: role,
                tag: tag,
                type: type,
                placeholder: placeholder
            ) else {
                return nil
            }
            var nameSources = [label, controlName]
            if lowerTag != "input",
               !lowerRole.contains("textbox"),
               lowerRole != "search",
               label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               controlName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nameSources.append(value)
            }
            let hintedName = GoogleDriveBrowserAdapter.nameHint(from: label.isEmpty ? controlName : label)
            let hasNameMatch = nameSources.contains(where: { googleDriveFileNameMatches($0, requestedName: name) })
                || (!hintedName.isEmpty && googleDriveFileNameMatches(hintedName, requestedName: name))
            guard hasNameMatch else { return nil }

            let fileControl = GoogleDriveBrowserAdapter.isFileControl(
                pageURL: pageURL,
                selector: selector,
                label: label,
                name: controlName,
                role: role,
                tag: tag,
                href: href
            )
            let likelyResult = fileControl
                || lowerRole.contains("gridcell")
                || lowerRole.contains("row")
                || lowerRole.contains("listitem")
                || lowerRole.contains("option")
                || href.contains("docs.google.com")
                || lowerTag == "drive-collection"
                || (hasNameMatch && lowerRole.contains("button"))
                || (hasNameMatch && lowerTag == "div" && lowerType == "button")
                || (hasNameMatch && (lowerTag == "tr" || lowerTag == "td"))
            guard likelyResult else { return nil }

            var score = 0
            if !hintedName.isEmpty && googleDriveFileNameMatches(hintedName, requestedName: name) { score += 50 }
            if googleDriveFileNameMatches(label, requestedName: name)
                || googleDriveFileNameMatches(controlName, requestedName: name) {
                score += 30
            }
            if combined.localizedCaseInsensitiveContains("google docs")
                || combined.localizedCaseInsensitiveContains("google sheets")
                || combined.localizedCaseInsensitiveContains("google slides")
                || href.contains("docs.google.com") {
                score += 25
            }
            if lowerRole.contains("row") || lowerRole.contains("gridcell") || lowerRole.contains("listitem") {
                score += 35
            }
            if lowerTag == "drive-collection" || (lowerRole.contains("button") && lowerType == "button") {
                score += 30
            }
            if visibleTextLength >= name.count + 20 {
                score += 20
            }
            if visibleTextLength <= name.count + 2, !href.contains("docs.google.com") {
                score += lowerTag == "drive-collection" || lowerRole.contains("button") ? 15 : -25
            }
            if lowerTag == "input" || containsNormalized(combined, "Search in Drive") {
                score -= 50
            }
            if fileControl { score += 20 }
            if boolValue(control["actionable"]) { score += 10 }
            if let bounds = control["bounds"] as? [String: Any],
               let y = doubleValue(bounds["centerY"]),
               y >= 0 {
                score += 8
            }

            return (score, index, control)
        }

        return scored
            .sorted {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            .map(\.control)
    }

    static func googleDriveOpenCandidateKey(_ control: [String: Any]) -> String {
        if let selector = ShelfBrowserCommandNormalization.normalized(control["selector"] as? String) {
            return "selector:\(selector)"
        }
        let bounds = control["bounds"] as? [String: Any]
        let x = Int(doubleValue(bounds?["centerX"]) ?? -1)
        let y = Int(doubleValue(bounds?["centerY"]) ?? -1)
        let label = control["label"] as? String ?? control["name"] as? String ?? ""
        return "point:\(x),\(y):\(label)"
    }

    static func compactGoogleDriveCandidate(_ control: [String: Any]) -> [String: Any] {
        let bounds = control["bounds"] as? [String: Any] ?? [:]
        return [
            "labelLength": (control["label"] as? String ?? "").count,
            "nameLength": (control["name"] as? String ?? "").count,
            "role": control["role"] as? String ?? "",
            "tag": control["tag"] as? String ?? "",
            "hasSelector": ShelfBrowserCommandNormalization.normalized(control["selector"] as? String) != nil,
            "centerX": Int(doubleValue(bounds["centerX"]) ?? -1),
            "centerY": Int(doubleValue(bounds["centerY"]) ?? -1)
        ]
    }

    static func googleDocsVerificationQuery(explicit: String?, text: String) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let flat = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return String(flat.prefix(80))
    }

    static func isPendingGoogleWorkspaceTitle(_ title: String) -> Bool {
        let comparable = googleDriveComparableName(title)
        return comparable.isEmpty
            || comparable == "google docs"
            || comparable == "google sheets"
            || comparable == "google slides"
            || comparable == "loading"
            || comparable == "untitled"
    }

    private static func googleDriveMetadataPrefixedNameMatches(_ comparableText: String, requestedName: String) -> Bool {
        let prefix = "\(requestedName) "
        guard comparableText.hasPrefix(prefix) else { return false }
        let suffixStart = comparableText.index(comparableText.startIndex, offsetBy: prefix.count)
        let suffix = comparableText[suffixStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return false }

        let metadataPrefixes = [
            #"^\d{1,2}:\d{2}\s*(am|pm)\b"#,
            #"^\d{1,2}/\d{1,2}/\d{2,4}\b"#,
            #"^\d{4}-\d{1,2}-\d{1,2}\b"#,
            #"^(today|yesterday)\b"#,
            #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b"#,
            #"^(more actions|modified|owner|shared|google docs|google sheets|google slides|google drawings)\b"#
        ]
        return metadataPrefixes.contains {
            suffix.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func googleDriveComparableName(_ text: String) -> String {
        var value = text
            .replacingOccurrences(
                of: #"(?i)\s*[-–—]\s*Google\s+(Docs|Sheets|Slides|Drawings)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+Google\s+(Docs|Sheets|Slides|Drawings)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\s+(Located in|More info|More actions).*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[\s\-–—:|]+$"#,
                with: "",
                options: .regularExpression
            )
        value = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value
    }

    private static func containsNormalized(_ text: String, _ query: String) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedQuery.isEmpty && normalizedText.contains(normalizedQuery)
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
