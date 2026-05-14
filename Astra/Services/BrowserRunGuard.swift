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
    private let warningThreshold: Int
    private let hardStopThreshold: Int

    init(warningThreshold: Int = 30, hardStopThreshold: Int = 60) {
        self.warningThreshold = warningThreshold
        self.hardStopThreshold = hardStopThreshold
    }

    mutating func reset() {
        totalBrowserCalls = 0
        firstCommands = []
        recentCommands = []
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
                "currentURL": currentURL,
                "currentTitle": currentTitle,
                "pageType": pageType,
                "warningThreshold": warningThreshold,
                "hardStopThreshold": hardStopThreshold
            ]
        )
    }
}
