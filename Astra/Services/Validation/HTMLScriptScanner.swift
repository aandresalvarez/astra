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

    static func scriptElements(in html: String) -> [ScriptElement] {
        let scalars = Array(html.unicodeScalars)
        var elements: [ScriptElement] = []
        var foreignDepth = 0
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "<", index + 1 < scalars.count else {
                index += 1
                continue
            }
            let next = scalars[index + 1]
            if hasPrefix("<!--", in: scalars, at: index) {
                guard let end = commentEnd(in: scalars, from: index + 4) else { break }
                index = end
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
                    if foreignRootElements.contains(name) {
                        foreignDepth = max(0, foreignDepth - 1)
                    }
                    continue
                }
                if foreignRootElements.contains(name), !tag.selfClosing {
                    foreignDepth += 1
                } else if name == "script" {
                    var attributes = tag.attributes
                    if foreignDepth > 0, attributes["src"] == nil,
                       let href = attributes["href"] ?? attributes["xlink:href"] {
                        attributes["src"] = href
                    }
                    if foreignDepth > 0, tag.selfClosing {
                        elements.append(ScriptElement(attributes: attributes, body: ""))
                        continue
                    }
                    let close = findEndTag("script", in: scalars, from: tag.end)
                    elements.append(ScriptElement(
                        attributes: attributes,
                        body: string(scalars[tag.end..<(close?.start ?? scalars.count)])
                    ))
                    guard let close else { break }
                    index = close.end
                } else if foreignDepth == 0, textOnlyElements.contains(name) {
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
        let close = find("-->", in: scalars, from: start).map { $0 + 3 }
        let bangClose = find("--!>", in: scalars, from: start).map { $0 + 4 }
        switch (close, bangClose) {
        case let (close?, bangClose?): return min(close, bangClose)
        case let (close, bangClose): return close ?? bangClose
        }
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

    /// Decodes the character references an attribute value realistically
    /// uses: numeric (`&#47;`, `&#x2f;`) and a few named ones (`&sol;`).
    static func decodingCharacterReferences(_ value: String) -> String {
        guard value.contains("&") else { return value }
        // Named references are case-sensitive; only these spellings exist.
        let named: [String: String] = [
            "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">",
            "quot": "\"", "QUOT": "\"", "apos": "'",
            "sol": "/", "plus": "+", "period": "."
        ]
        var decoded = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";") else {
                decoded.append(value[index])
                index = value.index(after: index)
                continue
            }
            let reference = value[value.index(after: index)..<semicolon]
            var replacement: String?
            if reference.hasPrefix("#") {
                let digits = reference.dropFirst()
                let scalarValue = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits, radix: 10)
                replacement = scalarValue.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(reference)]
            }
            if let replacement {
                decoded += replacement
                index = value.index(after: semicolon)
            } else {
                decoded.append(value[index])
                index = value.index(after: index)
            }
        }
        return decoded
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
        let needle = Array(prefix.unicodeScalars)
        return index + needle.count <= scalars.count
            && matches(needle, in: scalars, at: index, caseInsensitive: false)
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
