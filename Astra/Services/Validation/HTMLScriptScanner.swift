import Foundation

struct HTMLInlineScript: Equatable {
    var type: String?
    var language: String? = nil
    var body: String

    /// Mirrors the HTML "prepare the script element" type rules: a block
    /// is classic or module JavaScript only when its type string is a
    /// JavaScript MIME type essence (parameters make it inert) or exactly
    /// `module`; any other type makes it an inert data block.
    /// https://html.spec.whatwg.org/multipage/scripting.html#prepare-the-script-element
    var isJavaScript: Bool {
        let typeString: String
        if let type {
            if type.isEmpty { return true }
            typeString = type
        } else if let language, !language.isEmpty {
            typeString = "text/" + language
        } else {
            return true
        }
        if Self.javascriptMIMETypes.contains(typeString.lowercased()) {
            return true
        }
        // Only a `type` attribute gets its ASCII whitespace stripped, and
        // only for the MIME comparison; `module` must match exactly.
        if type != nil,
           Self.javascriptMIMETypes.contains(
               typeString.trimmingCharacters(in: Self.asciiWhitespace).lowercased()
           ) {
            return true
        }
        return typeString.lowercased() == "module"
    }

    private static let asciiWhitespace = CharacterSet(charactersIn: "\t\n\u{0C}\r ")

    // https://html.spec.whatwg.org/multipage/scripting.html#javascript-mime-type
    private static let javascriptMIMETypes: Set<String> = [
        "application/ecmascript",
        "application/javascript",
        "application/x-ecmascript",
        "application/x-javascript",
        "text/ecmascript",
        "text/javascript",
        "text/javascript1.0",
        "text/javascript1.1",
        "text/javascript1.2",
        "text/javascript1.3",
        "text/javascript1.4",
        "text/javascript1.5",
        "text/jscript",
        "text/livescript",
        "text/x-ecmascript",
        "text/x-javascript"
    ]
}

/// Finds `<script>` elements in an HTML document with a small, linear
/// tokenizer: it tracks tags, quoted attribute values, comments and
/// text-only elements in document order, so script-like text in any of
/// those places is never mistaken for a script element. It is not a full
/// HTML parser; it covers what deliverable verification needs.
enum HTMLScriptScanner {
    struct ScriptElement: Equatable {
        /// Lowercased names; the first occurrence of a name wins.
        var attributes: [String: String]
        var body: String
    }

    static func inlineScripts(in html: String) -> [HTMLInlineScript] {
        scriptElements(in: html)
            .filter { $0.attributes["src"] == nil }
            .map {
                HTMLInlineScript(
                    type: $0.attributes["type"],
                    language: $0.attributes["language"],
                    body: $0.body
                )
            }
    }

    static func externalScriptCount(in html: String) -> Int {
        scriptElements(in: html).filter { $0.attributes["src"] != nil }.count
    }

    // Elements whose content the HTML tokenizer reads as text (RCDATA,
    // RAWTEXT, and noscript with scripting enabled), so no tags start inside.
    private static let textOnlyElements: Set<String> = [
        "textarea", "title", "style", "xmp", "iframe", "noembed", "noframes", "noscript"
    ]

    // Elements that switch the parser to foreign (SVG/MathML) content, where
    // `<script/>` self-closes, SVG scripts load via `href`, and RAWTEXT rules
    // do not apply.
    private static let foreignRootElements: Set<String> = ["svg", "math"]

    // Foreign elements whose children are parsed as HTML again.
    private static let htmlIntegrationPoints: Set<String> = [
        "foreignobject", "desc", "title", "mi", "mo", "mn", "ms", "mtext"
    ]

    static func scriptElements(in html: String) -> [ScriptElement] {
        let scalars = Array(html.unicodeScalars)
        var elements: [ScriptElement] = []
        // Open SVG/MathML roots and HTML integration points, innermost last.
        var contexts: [(name: String, foreign: Bool)] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "<", index + 1 < scalars.count else {
                index += 1
                continue
            }
            let inForeign = contexts.last?.foreign ?? false
            let next = scalars[index + 1]
            if hasPrefix("<!--", in: scalars, at: index) {
                guard let end = commentEnd(in: scalars, from: index + 4) else { break }
                index = end
            } else if inForeign, hasPrefix("<![CDATA[", in: scalars, at: index) {
                guard let end = find("]]>", in: scalars, from: index + 9) else { break }
                index = end + 3
            } else if next == "!" || next == "?" {
                // Doctype or bogus comment: ends at the next `>`.
                guard let end = find(">", in: scalars, from: index + 2) else { break }
                index = end + 1
            } else if next == "/" || isASCIILetter(next) {
                let isEndTag = next == "/"
                var cursor = index + (isEndTag ? 2 : 1)
                let nameStart = cursor
                while cursor < scalars.count, !isTagNameTerminator(scalars[cursor]) {
                    cursor += 1
                }
                let name = string(scalars[nameStart..<cursor]).lowercased()
                guard let tag = parseAttributes(scalars, from: cursor) else { break }
                index = tag.end
                if isEndTag {
                    if contexts.last?.name == name {
                        contexts.removeLast()
                    }
                    continue
                }
                if foreignRootElements.contains(name) {
                    if !tag.selfClosing { contexts.append((name, true)) }
                } else if inForeign, isHTMLIntegrationPoint(name, attributes: tag.attributes) {
                    if !tag.selfClosing { contexts.append((name, false)) }
                } else if name == "script" {
                    var attributes = tag.attributes
                    if inForeign, attributes["src"] == nil,
                       let href = attributes["href"] ?? attributes["xlink:href"] {
                        attributes["src"] = href
                    }
                    if inForeign, tag.selfClosing {
                        elements.append(ScriptElement(attributes: attributes, body: ""))
                        continue
                    }
                    // A script that never gets an end tag is never run.
                    guard let close = inForeign
                        ? findForeignScriptEnd(in: scalars, from: tag.end)
                        : findScriptDataEnd(in: scalars, from: tag.end) else { break }
                    elements.append(ScriptElement(
                        attributes: attributes,
                        body: inForeign
                            ? foreignScriptText(scalars, in: tag.end..<close.start)
                            : string(scalars[tag.end..<close.start])
                    ))
                    index = close.end
                } else if !inForeign, name == "plaintext" {
                    // Everything after `<plaintext>` is text.
                    break
                } else if !inForeign, textOnlyElements.contains(name) {
                    guard let close = findEndTag(name, in: scalars, from: tag.end) else { break }
                    index = close.end
                }
            } else {
                index += 1
            }
        }
        return elements
    }

    /// Reads attributes up to the tag's closing `>`, honoring quoted values.
    /// Returns nil when the document ends inside the tag.
    private static func parseAttributes(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (attributes: [String: String], end: Int, selfClosing: Bool)? {
        var attributes: [String: String] = [:]
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" {
                return (attributes, index + 1, false)
            }
            if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == ">" {
                return (attributes, index + 2, true)
            }
            if isASCIIWhitespace(scalar) || scalar == "/" {
                index += 1
                continue
            }
            let nameStart = index
            index += 1
            while index < scalars.count, !isTagNameTerminator(scalars[index]), scalars[index] != "=" {
                index += 1
            }
            let name = string(scalars[nameStart..<index]).lowercased()
            var value = ""
            var lookahead = index
            while lookahead < scalars.count, isASCIIWhitespace(scalars[lookahead]) {
                lookahead += 1
            }
            if lookahead < scalars.count, scalars[lookahead] == "=" {
                index = lookahead + 1
                while index < scalars.count, isASCIIWhitespace(scalars[index]) {
                    index += 1
                }
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    guard let valueEnd = scalars[(index + 1)...].firstIndex(of: quote) else { return nil }
                    value = string(scalars[(index + 1)..<valueEnd])
                    index = valueEnd + 1
                } else {
                    let valueStart = index
                    while index < scalars.count, !isASCIIWhitespace(scalars[index]), scalars[index] != ">" {
                        index += 1
                    }
                    value = string(scalars[valueStart..<index])
                }
            }
            if attributes[name] == nil {
                attributes[name] = decodingCharacterReferences(value)
            }
        }
        return nil
    }

    /// Finds where a comment whose content starts at `start` ends: `-->` or
    /// `--!>`, or the abrupt `<!-->` / `<!--->` forms.
    private static func commentEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        if hasPrefix(">", in: scalars, at: start) { return start + 1 }
        if hasPrefix("->", in: scalars, at: start) { return start + 2 }
        // One forward pass: searching for each ending separately rescans to
        // the end of the document for every comment.
        var index = start
        while index < scalars.count {
            if hasPrefix("-->", in: scalars, at: index) { return index + 3 }
            if hasPrefix("--!>", in: scalars, at: index) { return index + 4 }
            index += 1
        }
        return nil
    }

    private static func isHTMLIntegrationPoint(_ name: String, attributes: [String: String]) -> Bool {
        if name == "annotation-xml" {
            let encoding = attributes["encoding"]?.lowercased()
            return encoding == "text/html" || encoding == "application/xhtml+xml"
        }
        return htmlIntegrationPoints.contains(name)
    }

    /// Finds the end tag of an SVG/MathML script; a `</script>` inside a
    /// CDATA section is text and does not close it.
    private static func findForeignScriptEnd(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> (start: Int, end: Int)? {
        var index = start
        while index < scalars.count {
            if hasPrefix("<![CDATA[", in: scalars, at: index) {
                guard let end = find("]]>", in: scalars, from: index + 9) else { return nil }
                index = end + 3
            } else if isTag("</script", in: scalars, at: index) {
                guard let tag = parseAttributes(scalars, from: index + 8) else { return nil }
                return (index, tag.end)
            } else {
                index += 1
            }
        }
        return nil
    }

    /// The text a browser runs for an SVG/MathML script: foreign content is
    /// tokenized as ordinary data, so character references such as `&lt;`
    /// are decoded, while a CDATA section contributes its contents verbatim.
    private static func foreignScriptText(
        _ scalars: [Unicode.Scalar],
        in range: Range<Int>
    ) -> String {
        var text = ""
        var segmentStart = range.lowerBound
        var index = range.lowerBound
        while index < range.upperBound {
            if hasPrefix("<![CDATA[", in: scalars, at: index),
               let end = find("]]>", in: scalars, from: index + 9),
               end + 3 <= range.upperBound {
                text += decodingCharacterReferences(string(scalars[segmentStart..<index]))
                text += string(scalars[(index + 9)..<end])
                index = end + 3
                segmentStart = index
            } else {
                index += 1
            }
        }
        return text + decodingCharacterReferences(string(scalars[segmentStart..<range.upperBound]))
    }

    /// Finds the end tag that closes an HTML script, following the tokenizer's
    /// script-data escape states: inside `<!--`, a nested `<script>` is
    /// double-escaped and its `</script>` does not close the outer script.
    private static func findScriptDataEnd(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> (start: Int, end: Int)? {
        enum State { case data, escaped, doubleEscaped }
        var state = State.data
        var index = start
        while index < scalars.count {
            if state != .data, hasPrefix("-->", in: scalars, at: index) {
                state = .data
                index += 3
            } else if state == .data, hasPrefix("<!--", in: scalars, at: index) {
                state = .escaped
                // Leave the dashes so `<!-->` and `<!--->` end the escape.
                index += 2
            } else if isTag("</script", in: scalars, at: index) {
                if state == .doubleEscaped {
                    state = .escaped
                    index += 8
                } else {
                    guard let tag = parseAttributes(scalars, from: index + 8) else { return nil }
                    return (index, tag.end)
                }
            } else if state == .escaped, isTag("<script", in: scalars, at: index) {
                state = .doubleEscaped
                index += 7
            } else {
                index += 1
            }
        }
        return nil
    }

    /// True when `marker` (ASCII case-insensitive) starts at `index` and is
    /// followed by whitespace, `/` or `>`.
    private static func isTag(_ marker: String, in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let needle = Array(marker.unicodeScalars)
        let after = index + needle.count
        return after < scalars.count
            && matches(needle, in: scalars, at: index, caseInsensitive: true)
            && isTagNameTerminator(scalars[after])
    }

    /// Finds `</name` followed by whitespace, `/` or `>`, and the index just
    /// past that end tag's `>`, honoring quoted values inside the end tag.
    private static func findEndTag(
        _ name: String,
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> (start: Int, end: Int)? {
        let marker = Array("</\(name)".unicodeScalars)
        var index = start
        while let found = find(marker, in: scalars, from: index, caseInsensitive: true) {
            let after = found + marker.count
            if after >= scalars.count { return nil }
            if isTagNameTerminator(scalars[after]) {
                guard let tag = parseAttributes(scalars, from: after) else { return nil }
                return (found, tag.end)
            }
            index = after
        }
        return nil
    }

    // Every named reference in the HTML table that decodes to ASCII. Only
    // ASCII can form a JavaScript type, so references to other characters
    // never change how a script is classified and may stay literal.
    // https://html.spec.whatwg.org/multipage/named-characters.html
    private static let asciiNamedReferences: [String: String] = [
        "Tab": "\t", "NewLine": "\n", "excl": "!", "quot": "\"", "QUOT": "\"",
        "num": "#", "dollar": "$", "percnt": "%", "amp": "&", "AMP": "&",
        "apos": "'", "lpar": "(", "rpar": ")", "ast": "*", "midast": "*",
        "plus": "+", "comma": ",", "period": ".", "sol": "/", "colon": ":",
        "semi": ";", "lt": "<", "LT": "<", "equals": "=", "gt": ">", "GT": ">",
        "quest": "?", "commat": "@", "lsqb": "[", "lbrack": "[", "bsol": "\\",
        "rsqb": "]", "rbrack": "]", "Hat": "^", "lowbar": "_", "UnderBar": "_",
        "grave": "`", "DiacriticalGrave": "`", "lcub": "{", "lbrace": "{",
        "verbar": "|", "vert": "|", "VerticalLine": "|", "rcub": "}", "rbrace": "}",
        "fjlig": "fj"
    ]

    /// Decodes character references in an attribute value or foreign text: numeric ones
    /// (`&#47;`, `&#x2f`, with or without `;`) and every named reference
    /// that yields ASCII (case-sensitive, with its `;`).
    static func decodingCharacterReferences(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named = asciiNamedReferences
        let scalars = Array(value.unicodeScalars)
        var decoded = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                decoded.append(scalars[index])
                index += 1
                continue
            }
            if index + 1 < scalars.count, scalars[index + 1] == "#" {
                var cursor = index + 2
                let hex = cursor < scalars.count && (scalars[cursor] == "x" || scalars[cursor] == "X")
                if hex { cursor += 1 }
                let digitsStart = cursor
                while cursor < scalars.count, isDigit(scalars[cursor], hex: hex) {
                    cursor += 1
                }
                if cursor > digitsStart {
                    let code = UInt32(string(scalars[digitsStart..<cursor]), radix: hex ? 16 : 10)
                    decoded.append(code.flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
                    if cursor < scalars.count, scalars[cursor] == ";" { cursor += 1 }
                    index = cursor
                    continue
                }
            } else if let semicolon = scalars[(index + 1)...].prefix(20).firstIndex(of: ";"),
                      let replacement = named[string(scalars[(index + 1)..<semicolon])] {
                decoded.append(contentsOf: replacement.unicodeScalars)
                index = semicolon + 1
                continue
            }
            decoded.append(scalars[index])
            index += 1
        }
        return String(decoded)
    }

    private static func isDigit(_ scalar: Unicode.Scalar, hex: Bool) -> Bool {
        (48...57).contains(scalar.value)
            || (hex && ((65...70).contains(scalar.value) || (97...102).contains(scalar.value)))
    }

    private static func find(
        _ needle: String,
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        find(Array(needle.unicodeScalars), in: scalars, from: start, caseInsensitive: false)
    }

    private static func find(
        _ needle: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        from start: Int,
        caseInsensitive: Bool
    ) -> Int? {
        guard !needle.isEmpty, start >= 0, scalars.count >= needle.count else { return nil }
        var index = start
        while index + needle.count <= scalars.count {
            if matches(needle, in: scalars, at: index, caseInsensitive: caseInsensitive) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func hasPrefix(_ prefix: String, in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var cursor = index
        for scalar in prefix.unicodeScalars {
            guard cursor < scalars.count, scalars[cursor] == scalar else { return false }
            cursor += 1
        }
        return true
    }

    private static func matches(
        _ needle: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        at index: Int,
        caseInsensitive: Bool
    ) -> Bool {
        for offset in 0..<needle.count {
            let lhs = scalars[index + offset]
            let rhs = needle[offset]
            if lhs == rhs { continue }
            if caseInsensitive, asciiLowercased(lhs) == asciiLowercased(rhs) { continue }
            return false
        }
        return true
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    /// HTML's ASCII whitespace; U+00A0 and other Unicode spaces are not
    /// separators inside tags.
    private static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r" || scalar == " "
    }

    private static func isTagNameTerminator(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIWhitespace(scalar) || scalar == "/" || scalar == ">"
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
