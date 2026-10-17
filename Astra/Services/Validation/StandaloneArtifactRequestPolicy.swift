import Foundation

/// Classifies the object the user asks to produce. A text answer's subject
/// ("sentences about an app") is not itself a requested artifact.
enum StandaloneArtifactRequestPolicy {
    private static let creationActions: Set<String> = [
        "write", "create", "creat", "cerate", "crefate", "build", "buid", "make", "generate", "save"
    ]
    private static let informationalActions: Set<String> = [
        "explain", "describe", "discuss", "summarize", "summarise", "review", "analyze", "analyse", "propose",
        "how", "what", "why", "whether"
    ]
    private static let answerObjects: Set<String> = [
        "sentence", "sentences", "paragraph", "paragraphs", "line", "lines", "text", "answer", "answers",
        "summary", "summaries", "explanation", "explanations", "description", "descriptions", "report", "reports",
        "document", "documents", "diagram", "diagrams", "guide", "guides", "checklist", "checklists",
        "list", "lists", "outline", "outlines", "tutorial", "tutorials", "notes", "email", "message", "poem", "story", "json", "sql"
    ]
    private static let answerModifiers: Set<String> = [
        "a", "an", "the", "some", "several", "few", "many", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "twenty", "thirty", "forty", "fifty", "sixty", "hundred",
        "exactly", "short", "brief", "concise", "detailed", "numbered", "bulleted", "different", "simple",
        "plain", "new", "quick", "technical", "markdown"
    ]
    private static let artifactPhrases = [
        "web page", "webpage", "html", "javascript", "css", ".html", ".js", ".css",
        "demo app", "game", "script", "file", "slide deck", "slides", "presentation", "deck",
        "user interface", "web site", "spreadsheet", "wireframe", "mockup", "prototype", "dashboard", "notebook", "readme"
    ]
    private static let artifactWords: Set<String> = ["app", "ui", "website", "csv"]

    static func requiresArtifact(in fields: [String]) -> Bool {
        fields.contains { field in
            TaskIntentLanguagePolicy.affirmativeActionObjects(
                in: field, words: creationActions.union(informationalActions).union(["put"])
            ).contains { action in
                guard !informationalActions.contains(action.verb) else { return false }
                if action.verb == "put" {
                    // This is an explicit delivery instruction, unlike an
                    // app-control request such as "put the app in front".
                    return action.object.split { !$0.isLetter && !$0.isNumber }
                        .prefix(3).map(String.init) == ["this", "in", "files"]
                }
                return namesArtifact(requestedObject(action.object, verb: action.verb))
            }
        }
    }

    private static func requestedObject(_ object: String, verb: String) -> String {
        let words = object.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let head = words.first { !answerModifiers.contains($0) && !$0.allSatisfy(\.isNumber) }
        // "Write about an app" implicitly requests prose. A nominal modifier
        // in "generate a what-if dashboard" is still part of the artifact.
        let implicitProse = verb == "write" && object.range(
            of: #"^\s*(?:about|regarding|concerning|how|why|what|whether)\s+"#, options: .regularExpression
        ) != nil
        guard let head, answerObjects.contains(head) || implicitProse,
              let topic = object.range(
                of: #"\b(?:about|on|of|for|how|why|what|whether|regarding|concerning|describing|explaining|discussing|covering|containing)\b"#,
                options: .regularExpression
              ) else { return object }
        // An explicitly requested delivery format can follow the subject:
        // "a paragraph about the app into a text file" still owes that file.
        if let destination = object.range(
            of: #"\b(?:as|in|into|to)\s+(?:(?:a|an|the|new|plain|text|markdown)\s+)*file\b"#,
            options: .regularExpression
        ) {
            return String(object[destination])
        }
        // Preserve explicit destinations before the topic: "write a paragraph
        // into a file about the app" still owes a file. Named output filenames
        // are independently enforced by TaskDeliverableExpectation.
        return String(object[..<topic.lowerBound])
    }

    private static func namesArtifact(_ object: String) -> Bool {
        artifactPhrases.contains { object.contains($0) }
            || object.split { !$0.isLetter && !$0.isNumber }.contains { artifactWords.contains(String($0)) }
    }
}
