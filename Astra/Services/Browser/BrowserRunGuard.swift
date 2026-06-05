import Foundation

struct BrowserRunGuardDecision: Equatable {
    let shouldStop: Bool
    let warning: String?
    let diagnostics: [String: Any]

    static func == (lhs: BrowserRunGuardDecision, rhs: BrowserRunGuardDecision) -> Bool {
        lhs.shouldStop == rhs.shouldStop && lhs.warning == rhs.warning
    }
}

struct BrowserRunGuard {
    private(set) var totalBrowserCalls = 0
    private var firstCommands: [String] = []
    private var recentCommands: [String] = []
    private var repeatedErrors: [String: Int] = [:]
    private var driveOpenFailureSeen = false
    private var drivePostFailureGenericNoProgressMutations = 0
    private let warningThreshold: Int
    private let hardStopThreshold: Int
    private let drivePostFailureNoProgressHardStopThreshold: Int

    init(
        warningThreshold: Int = 30,
        hardStopThreshold: Int = 60,
        drivePostFailureNoProgressHardStopThreshold: Int = 2
    ) {
        self.warningThreshold = warningThreshold
        self.hardStopThreshold = hardStopThreshold
        self.drivePostFailureNoProgressHardStopThreshold = drivePostFailureNoProgressHardStopThreshold
    }

    mutating func reset() {
        totalBrowserCalls = 0
        firstCommands = []
        recentCommands = []
        repeatedErrors = [:]
        driveOpenFailureSeen = false
        drivePostFailureGenericNoProgressMutations = 0
    }

    mutating func record(path: String, currentURL: String, currentTitle: String, pageType: String) -> BrowserRunGuardDecision {
        totalBrowserCalls += 1
        let command = path
        if firstCommands.count < 5 {
            firstCommands.append(command)
        }
        recentCommands.append(command)
        if recentCommands.count > 8 {
            recentCommands.removeFirst(recentCommands.count - 8)
        }

        let warning = totalBrowserCalls >= warningThreshold
            ? "Browser control has used \(totalBrowserCalls) bridge calls in this task. Switch to a deterministic helper or stop for user input if page state is not changing."
            : nil
        let shouldStop = totalBrowserCalls > hardStopThreshold
        return BrowserRunGuardDecision(
            shouldStop: shouldStop,
            warning: warning,
            diagnostics: [
                "totalBrowserCalls": totalBrowserCalls,
                "firstCommands": firstCommands,
                "recentCommands": recentCommands,
                "repeatedErrors": repeatedErrors,
                "currentURL": currentURL,
                "currentTitle": currentTitle,
                "pageType": pageType,
                "warningThreshold": warningThreshold,
                "hardStopThreshold": hardStopThreshold
            ]
        )
    }

    mutating func recordOutcome(
        path: String,
        response: [String: Any],
        currentURL: String,
        currentTitle: String,
        pageType: String,
        urlChanged: Bool = false
    ) -> BrowserRunGuardDecision {
        let error = (response["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if path == "POST /googleDriveOpen", error == "drive_file_not_opened" {
            driveOpenFailureSeen = true
            drivePostFailureGenericNoProgressMutations = 0
        }

        if let driveDecision = recordDrivePostFailureNoProgress(
            path: path,
            currentURL: currentURL,
            currentTitle: currentTitle,
            pageType: pageType,
            urlChanged: urlChanged
        ) {
            return driveDecision
        }

        guard Self.isFailedResponse(response),
              !error.isEmpty else {
            return BrowserRunGuardDecision(
                shouldStop: false,
                warning: nil,
                diagnostics: diagnostics(
                    currentURL: currentURL,
                    currentTitle: currentTitle,
                    pageType: pageType
                )
            )
        }

        let key = "\(path)|\(error)"
        let count = (repeatedErrors[key] ?? 0) + 1
        repeatedErrors[key] = count

        let repeatedDriveOpenFailure = path == "POST /googleDriveOpen"
            && error == "drive_file_not_opened"
            && count >= 2
        let repeatedUnsupportedOpenAction = (path == "POST /open" || path == "POST /doubleClick")
            && error == "unsupported_action"
            && count >= 2

        let shouldStop = repeatedDriveOpenFailure || repeatedUnsupportedOpenAction
        let warning: String?
        if repeatedDriveOpenFailure {
            warning = "Google Drive open helper failed \(count) times without opening a file. Stop browser probing and ask for user direction or a deterministic Drive/Docs capability."
        } else if repeatedUnsupportedOpenAction {
            warning = "The same unsupported browser open action failed \(count) times. Stop repeating this control path and switch strategy."
        } else {
            warning = nil
        }

        var fields = diagnostics(
            currentURL: currentURL,
            currentTitle: currentTitle,
            pageType: pageType
        )
        fields["lastError"] = error
        fields["lastErrorPath"] = path
        fields["lastErrorRepeatCount"] = count

        return BrowserRunGuardDecision(
            shouldStop: shouldStop,
            warning: warning,
            diagnostics: fields
        )
    }

    private mutating func recordDrivePostFailureNoProgress(
        path: String,
        currentURL: String,
        currentTitle: String,
        pageType: String,
        urlChanged: Bool
    ) -> BrowserRunGuardDecision? {
        guard driveOpenFailureSeen else { return nil }

        guard Self.isGoogleDriveContext(currentURL: currentURL, pageType: pageType) else {
            driveOpenFailureSeen = false
            drivePostFailureGenericNoProgressMutations = 0
            return nil
        }

        guard Self.isGenericDriveMutation(path), !urlChanged else {
            if urlChanged {
                drivePostFailureGenericNoProgressMutations = 0
            }
            return nil
        }

        drivePostFailureGenericNoProgressMutations += 1
        let shouldStop = drivePostFailureGenericNoProgressMutations >= drivePostFailureNoProgressHardStopThreshold
        var fields = diagnostics(
            currentURL: currentURL,
            currentTitle: currentTitle,
            pageType: pageType
        )
        fields["drivePostFailureGenericNoProgressMutations"] = drivePostFailureGenericNoProgressMutations
        fields["drivePostFailureNoProgressHardStopThreshold"] = drivePostFailureNoProgressHardStopThreshold
        fields["triggerCommand"] = path

        let warning = "Google Drive open helper failed, and generic Drive actions are not changing page state. Stop browser probing and use a deterministic Drive/Docs capability or ask the user for direction."
        return BrowserRunGuardDecision(
            shouldStop: shouldStop,
            warning: shouldStop ? warning : nil,
            diagnostics: fields
        )
    }

    private func diagnostics(currentURL: String, currentTitle: String, pageType: String) -> [String: Any] {
        [
            "totalBrowserCalls": totalBrowserCalls,
            "firstCommands": firstCommands,
            "recentCommands": recentCommands,
            "repeatedErrors": repeatedErrors,
            "driveOpenFailureSeen": driveOpenFailureSeen,
            "drivePostFailureGenericNoProgressMutations": drivePostFailureGenericNoProgressMutations,
            "currentURL": currentURL,
            "currentTitle": currentTitle,
            "pageType": pageType,
            "warningThreshold": warningThreshold,
            "hardStopThreshold": hardStopThreshold,
            "drivePostFailureNoProgressHardStopThreshold": drivePostFailureNoProgressHardStopThreshold
        ]
    }

    private static func isFailedResponse(_ response: [String: Any]) -> Bool {
        if let ok = response["ok"] as? Bool {
            return !ok
        }
        if let ok = response["ok"] as? String {
            return ok.lowercased() == "false"
        }
        return response["error"] != nil
    }

    private static func isGoogleDriveContext(currentURL: String, pageType: String) -> Bool {
        if pageType == "googleDrive" { return true }
        return URL(string: currentURL)?.host?.lowercased() == "drive.google.com"
    }

    private static func isGenericDriveMutation(_ path: String) -> Bool {
        switch path {
        case "POST /click",
             "POST /clickControl",
             "POST /doubleClick",
             "POST /open",
             "POST /keypress",
             "POST /setValue",
             "POST /text",
             "POST /replaceText",
             "POST /googleFindReplace",
             "POST /batch",
             "POST /act":
            return true
        default:
            return false
        }
    }
}
