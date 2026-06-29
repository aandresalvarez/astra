import Foundation
import Darwin
import MailToolSupport

private let defaultAccount = ProcessInfo.processInfo.environment["ASTRA_APPLE_MAIL_ACCOUNT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
private let defaultTimeout = parseInt(ProcessInfo.processInfo.environment["ASTRA_APPLE_MAIL_TIMEOUT"], default: 20)
private let maxBulkBodyRead = 1
private let fieldSeparator = "\u{1f}"
private let recordSeparator = "\u{1e}"

private enum AppleMailOperation {
    case metadata
    case messageBody
}

private struct AppleMailOptions {
    var globalAccount = defaultAccount
    var globalTimeout = defaultTimeout
    var commandAccount: String?
    var commandTimeout: Int?
    var mailbox = "INBOX"
    var limit = 10
    var query = ""
    var includeBody = false
    var messageID: String?

    var effectiveAccount: String {
        commandAccount ?? globalAccount
    }

    var effectiveTimeout: Int {
        commandTimeout ?? globalTimeout
    }
}

@main
struct StanfordAppleMailTool {
    static func main() {
        let code: Int32
        do {
            try run()
            code = 0
        } catch {
            code = exitWithError(prefix: "stanford-apple-mail", error: error)
        }
        if code != 0 {
            Darwin.exit(code)
        }
    }

    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            throw ToolError(usage())
        }

        var options = AppleMailOptions()
        try parseGlobalOptions(args: &args, options: &options)
        guard !args.isEmpty else {
            throw ToolError(usage())
        }

        let command = args.removeFirst()
        switch command {
        case "accounts":
            try parseAccounts(args, options: &options)
            try cmdAccounts(options)
        case "folders":
            try parseFolders(args, options: &options)
            try cmdFolders(options)
        case "latest":
            options.limit = 1
            try parseLatest(args, options: &options)
            try cmdLatest(options)
        case "today":
            options.limit = 50
            try parseToday(args, options: &options)
            try cmdToday(options)
        case "search":
            options.limit = 10
            try parseSearch(args, options: &options)
            try cmdSearch(options)
        case "get":
            try parseGet(args, options: &options)
            try cmdGet(options)
        case "-h", "--help", "help":
            print(usage())
        default:
            throw ToolError("Unknown command \(command).\n\n\(usage())")
        }
    }

    private static func usage() -> String {
        """
        stanford-apple-mail - read-only Apple Mail bridge for Stanford.edu mail.

        Commands:
          stanford-apple-mail accounts
          stanford-apple-mail folders [--account user@stanford.edu]
          stanford-apple-mail latest [--account user@stanford.edu] [--mailbox INBOX] [--limit 1]
          stanford-apple-mail today [--account user@stanford.edu] [--mailbox INBOX] [--limit 50]
          stanford-apple-mail search [--account user@stanford.edu] [--mailbox INBOX] [--query "term"] [--limit 10]
          stanford-apple-mail get [--account user@stanford.edu] [--mailbox INBOX] --message-id MESSAGE_ID
        """
    }

    private static let commonAppleScript = #"""
on replaceText(findText, replacementText, sourceText)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to findText
  set textParts to text items of sourceText
  set AppleScript's text item delimiters to replacementText
  set replacedText to textParts as text
  set AppleScript's text item delimiters to previousDelimiters
  return replacedText
end replaceText

on cleanText(valueText)
  try
    set normalizedText to valueText as text
  on error
    set normalizedText to ""
  end try
  set normalizedText to my replaceText(ASCII character 31, " ", normalizedText)
  set normalizedText to my replaceText(ASCII character 30, " ", normalizedText)
  set normalizedText to my replaceText(return, " ", normalizedText)
  return normalizedText
end cleanText

on joinText(itemsList, delimiterText)
  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delimiterText
  try
    set joinedText to itemsList as text
  on error
    set joinedText to ""
  end try
  set AppleScript's text item delimiters to previousDelimiters
  return joinedText
end joinText

on selectedAccount(selectorText)
  set matchList to {}
  tell application "Mail"
    repeat with accountRef in accounts
      set accountObject to contents of accountRef
      set addressesText to ""
      set userNameText to ""
      set hasStanfordAddress to false
      set selectorMatches to false
      try
        set addressesText to my joinText(email addresses of accountObject, ", ")
      end try
      try
        set userNameText to user name of accountObject as text
      end try
      if addressesText contains "@stanford.edu" or userNameText ends with "@stanford.edu" then
        set hasStanfordAddress to true
        if selectorText is "" or addressesText contains selectorText or userNameText is selectorText or userNameText contains selectorText or selectorText contains userNameText then
          set selectorMatches to true
        end if
      end if

      if hasStanfordAddress is true then
        if selectorText is "" or selectorMatches is true or userNameText is selectorText then
          set end of matchList to accountObject
        end if
      end if
    end repeat

    if (count of matchList) is 1 then return item 1 of matchList
    if (count of matchList) is 0 then
      if selectorText is "" then
        error "No @stanford.edu account was found in Apple Mail. Add a Stanford University account in Apple Mail and let it sync."
      end if
      error "No @stanford.edu Apple Mail account matches " & selectorText & ". Set ASTRA_APPLE_MAIL_ACCOUNT to the Stanford email address configured in Apple Mail."
    end if
  end tell
  error "Multiple @stanford.edu accounts are configured in Apple Mail. Set ASTRA_APPLE_MAIL_ACCOUNT or pass --account with the intended Stanford email address."
end selectedAccount

on mailboxPath(targetMailbox)
  tell application "Mail"
    set pathParts to {my cleanText(name of targetMailbox)}
    set cursorMailbox to targetMailbox
    repeat
      try
        set cursorMailbox to container of cursorMailbox
        set beginning of pathParts to my cleanText(name of cursorMailbox)
      on error
        exit repeat
      end try
    end repeat
  end tell
  return my joinText(pathParts, "/")
end mailboxPath

on mailboxRows(mailboxList)
  set rowList to {}
  tell application "Mail"
    repeat with mailboxRef in mailboxList
      set mailboxObject to contents of mailboxRef
      set pathText to my mailboxPath(mailboxObject)
      set unreadText to ""
      try
        set unreadText to unread count of mailboxObject as text
      end try
      set rowText to pathText & (ASCII character 31) & my cleanText(name of mailboxObject) & (ASCII character 31) & my cleanText(unreadText)
      set end of rowList to rowText
      set rowList to rowList & my mailboxRows(mailboxes of mailboxObject)
    end repeat
  end tell
  return rowList
end mailboxRows

on matchingMailboxes(mailboxList, selectorText)
  set matchList to {}
  tell application "Mail"
    repeat with mailboxRef in mailboxList
      set mailboxObject to contents of mailboxRef
      set pathText to my mailboxPath(mailboxObject)
      set nameText to name of mailboxObject as text
      if nameText is selectorText or pathText is selectorText or pathText ends with ("/" & selectorText) then
        set end of matchList to mailboxObject
      end if
      set matchList to matchList & my matchingMailboxes(mailboxes of mailboxObject, selectorText)
    end repeat
  end tell
  return matchList
end matchingMailboxes

on selectedMailbox(targetAccount, selectorText)
  tell application "Mail"
    if selectorText is "INBOX" or selectorText is "Inbox" or selectorText is "inbox" then
      try
        return mailbox "Inbox" of targetAccount
      end try
    end if
    try
      return mailbox selectorText of targetAccount
    end try
    set matchesList to my matchingMailboxes(mailboxes of targetAccount, selectorText)
    if (count of matchesList) > 0 then return item 1 of matchesList
  end tell
  error "No Apple Mail mailbox named " & selectorText & " was found for the selected account."
end selectedMailbox

on previewText(sourceText, previewLength)
  if (length of sourceText) > previewLength then
    return (text 1 thru previewLength of sourceText) & "..."
  end if
  return sourceText
end previewText

on messageRow(targetMessage, includeBody)
  tell application "Mail"
    set idText to ""
    set internetIDText to ""
    set mailboxText to ""
    set subjectText to ""
    set senderText to ""
    set receivedText to ""
    set sentText to ""
    set readText to ""
    set bodyText to ""

    try
      set idText to id of targetMessage as text
    end try
    try
      set mailboxText to my mailboxPath(mailbox of targetMessage)
    end try
    try
      set subjectText to subject of targetMessage as text
    end try
    try
      set senderText to sender of targetMessage as text
    end try
    try
      set receivedText to date received of targetMessage as text
    end try
    try
      set sentText to date sent of targetMessage as text
    end try
    try
      set readText to read status of targetMessage as text
    end try
    if includeBody is true then
      try
        set bodyText to content of targetMessage as text
      end try
    end if

    if includeBody is false then
      set bodyText to my previewText(bodyText, 500)
    end if

    return my cleanText(idText) & (ASCII character 31) & my cleanText(internetIDText) & (ASCII character 31) & my cleanText(mailboxText) & (ASCII character 31) & my cleanText(subjectText) & (ASCII character 31) & my cleanText(senderText) & (ASCII character 31) & my cleanText(receivedText) & (ASCII character 31) & my cleanText(sentText) & (ASCII character 31) & my cleanText(readText) & (ASCII character 31) & my cleanText(bodyText)
  end tell
end messageRow

on messageMatches(targetMessage, queryText)
  if queryText is "" then return true
  tell application "Mail"
    try
      if (subject of targetMessage as text) contains queryText then return true
    end try
    try
      if (sender of targetMessage as text) contains queryText then return true
    end try
  end tell
  return false
end messageMatches

on searchMailbox(targetMailbox, queryText, limitCount)
  set rowList to {}
  tell application "Mail"
    try
      repeat with messageRef in messages of targetMailbox
        set messageObject to contents of messageRef
        if my messageMatches(messageObject, queryText) then
          set end of rowList to my messageRow(messageObject, false)
          if (count of rowList) >= limitCount then return rowList
        end if
      end repeat
    end try

    repeat with childRef in mailboxes of targetMailbox
      if (count of rowList) >= limitCount then exit repeat
      set remainingCount to limitCount - (count of rowList)
      set rowList to rowList & my searchMailbox(contents of childRef, queryText, remainingCount)
    end repeat
  end tell
  return rowList
end searchMailbox

on recentMessages(targetMailbox, limitCount, includeBody)
  set rowList to {}
  tell application "Mail"
    try
      repeat with messageRef in messages 1 thru limitCount of targetMailbox
        set end of rowList to my messageRow(contents of messageRef, includeBody)
      end repeat
    end try
  end tell
  return rowList
end recentMessages

on todayMessages(targetMailbox, limitCount)
  set rowList to {}
  set startDate to current date
  set time of startDate to 0
  tell application "Mail"
    try
      repeat with messageRef in messages 1 thru limitCount of targetMailbox
        set messageObject to contents of messageRef
        try
          if date received of messageObject < startDate then return rowList
        end try
        set end of rowList to my messageRow(messageObject, false)
      end repeat
    end try
  end tell
  return rowList
end todayMessages

on findMessageInMailbox(targetMailbox, selectorText)
  set numericID to missing value
  try
    set numericID to selectorText as integer
  end try
  tell application "Mail"
    try
      if numericID is not missing value then
        set matchesList to messages of targetMailbox whose id is numericID
      else
        set matchesList to messages of targetMailbox whose message id is selectorText
      end if
      if (count of matchesList) > 0 then return item 1 of matchesList
    end try

    repeat with childRef in mailboxes of targetMailbox
      set foundMessage to my findMessageInMailbox(contents of childRef, selectorText)
      if foundMessage is not missing value then return foundMessage
    end repeat
  end tell
  return missing value
end findMessageInMailbox

on findMessage(mailboxList, selectorText)
  tell application "Mail"
    repeat with mailboxRef in mailboxList
      set foundMessage to my findMessageInMailbox(contents of mailboxRef, selectorText)
      if foundMessage is not missing value then return foundMessage
    end repeat
  end tell
  return missing value
end findMessage
"""#

    private static func appleLiteral(_ value: String) -> String {
        AppleScriptSource.stringLiteral(value)
    }

    private static func scriptWith(_ body: String) -> String {
        commonAppleScript + "\n" + body
    }

    private static func ensureMailLaunched() throws {
        _ = try runProcess(
            "/usr/bin/open",
            arguments: ["-gj", "-a", "Mail"],
            timeout: 5,
            timeoutMessage: "Apple Mail did not launch within 5 seconds. Open Apple Mail manually, then retry."
        )
    }

    private static func runOsaScript(_ script: String, timeout: Int, operation: AppleMailOperation = .metadata) throws -> String {
        try ensureMailLaunched()
        do {
            let result = try runProcess(
                "/usr/bin/osascript",
                input: script,
                timeout: TimeInterval(timeout),
                timeoutMessage: timeoutMessage(timeout: timeout, operation: operation)
            )
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "osascript exit \(result.exitCode)"
                if detail.contains("-1743") ||
                    detail.lowercased().contains("not authorized") ||
                    detail.lowercased().contains("not permitted") {
                    throw ToolError(
                        "macOS has not granted ASTRA permission to control Mail. " +
                        "Open System Settings > Privacy & Security > Automation and allow ASTRA or ASTRA Dev to control Mail."
                    )
                }
                throw ToolError(detail)
            }
            return result.stdout.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        } catch let error as ToolError {
            throw error
        }
    }

    private static func timeoutMessage(timeout: Int, operation: AppleMailOperation) -> String {
        switch operation {
        case .messageBody:
            return """
            Apple Mail timed out after \(timeout) seconds while reading a full message body. If metadata commands such as `today` or `latest` work, automation permission is already OK; Mail is likely still syncing or has not materialized that message body locally. Open Mail and the selected message, or retry with a larger --timeout. Do not use bulk body reads.
            """
        case .metadata:
            return """
            Apple Mail automation timed out after \(timeout) seconds. This usually means Mail is waiting for macOS Automation permission, Mail is syncing, or Mail is not responding. Open Apple Mail, approve any automation prompt, and check System Settings > Privacy & Security > Automation for ASTRA, ASTRA Dev, Terminal, or osascript permission to control Mail.
            """
        }
    }

    private static func splitRows(_ output: String, fields: [String]) -> [[String: Any]] {
        guard !output.isEmpty else { return [] }
        return output.split(separator: Character(recordSeparator), omittingEmptySubsequences: false).map { row in
            var values = row.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
            if values.count < fields.count {
                values.append(contentsOf: Array(repeating: "", count: fields.count - values.count))
            }
            var dictionary: [String: Any] = [:]
            for (index, field) in fields.enumerated() {
                dictionary[field] = index < values.count ? values[index] : ""
            }
            return dictionary
        }
    }

    private static func parseBool(_ value: Any?) -> Bool {
        String(describing: value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private static func guardBulkBodyRead(includeBody: Bool, limit: Int) throws {
        if includeBody && limit > maxBulkBodyRead {
            throw ToolError(
                "Refusing to read \(limit) full message bodies through Apple Mail automation. " +
                "Bulk body reads are slow and capped at \(maxBulkBodyRead). " +
                "Run metadata first, for example `stanford-apple-mail today --limit 50` or " +
                "`stanford-apple-mail latest --limit 50`, then fetch selected messages with " +
                "`stanford-apple-mail get --message-id MESSAGE_ID`."
            )
        }
    }

    private static func cmdAccounts(_ options: AppleMailOptions) throws {
        let script = scriptWith(#"""
set rowList to {}
tell application "Mail"
  repeat with accountRef in accounts
    set idText to ""
    set nameText to ""
    set addressesText to ""
    set fullNameText to ""
    set userNameText to ""
    set enabledText to ""
    try
      set idText to id of accountRef as text
    end try
    try
      set nameText to name of accountRef as text
    end try
    try
      set addressesText to my joinText(email addresses of accountRef, ", ")
    end try
    try
      set fullNameText to full name of accountRef as text
    end try
    try
      set userNameText to user name of accountRef as text
    end try
    try
      set enabledText to enabled of accountRef as text
    end try
    set rowText to my cleanText(idText) & (ASCII character 31) & my cleanText(nameText) & (ASCII character 31) & my cleanText(addressesText) & (ASCII character 31) & my cleanText(fullNameText) & (ASCII character 31) & my cleanText(userNameText) & (ASCII character 31) & my cleanText(enabledText)
    set end of rowList to rowText
  end repeat
end tell
return my joinText(rowList, ASCII character 30)
"""#)
        var rows = splitRows(try runOsaScript(script, timeout: options.effectiveTimeout), fields: ["id", "name", "emailAddresses", "fullName", "userName", "enabled"])
        for index in rows.indices {
            let addresses = (rows[index]["emailAddresses"] as? String ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            rows[index]["emailAddresses"] = addresses
            rows[index]["enabled"] = parseBool(rows[index]["enabled"])
        }
        try printJSON(["accounts": rows, "source": "Apple Mail"])
    }

    private static func cmdFolders(_ options: AppleMailOptions) throws {
        let account = options.effectiveAccount
        let script = scriptWith("""
        set accountRef to my selectedAccount(\(appleLiteral(account)))
        set rowList to my mailboxRows(mailboxes of accountRef)
        return my joinText(rowList, ASCII character 30)
        """)
        var rows = splitRows(try runOsaScript(script, timeout: options.effectiveTimeout), fields: ["path", "name", "unreadCount"])
        for index in rows.indices {
            rows[index]["unreadCount"] = Int(rows[index]["unreadCount"] as? String ?? "") ?? 0
        }
        try printJSON(["account": account, "folders": rows, "source": "Apple Mail"])
    }

    private static func cmdSearch(_ options: AppleMailOptions) throws {
        let account = options.effectiveAccount
        let limit = clamp(options.limit, min: 1, max: 25)
        let mailbox = options.mailbox.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "INBOX"
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let script: String
        if query.isEmpty && mailbox.lowercased() != "all" {
            script = scriptWith("""
            set accountRef to my selectedAccount(\(appleLiteral(account)))
            set targetMailbox to my selectedMailbox(accountRef, \(appleLiteral(mailbox)))
            set rowList to my recentMessages(targetMailbox, \(limit), false)
            return my joinText(rowList, ASCII character 30)
            """)
        } else if mailbox.lowercased() == "all" {
            script = scriptWith("""
            set accountRef to my selectedAccount(\(appleLiteral(account)))
            set targetMailboxes to mailboxes of accountRef
            set rowList to {}
            repeat with mailboxRef in targetMailboxes
              if (count of rowList) >= \(limit) then exit repeat
              set remainingCount to \(limit) - (count of rowList)
              set rowList to rowList & my searchMailbox(contents of mailboxRef, \(appleLiteral(query)), remainingCount)
            end repeat
            return my joinText(rowList, ASCII character 30)
            """)
        } else {
            script = scriptWith("""
            set accountRef to my selectedAccount(\(appleLiteral(account)))
            set targetMailboxes to {my selectedMailbox(accountRef, \(appleLiteral(mailbox)))}
            set rowList to {}
            repeat with mailboxRef in targetMailboxes
              if (count of rowList) >= \(limit) then exit repeat
              set remainingCount to \(limit) - (count of rowList)
              set rowList to rowList & my searchMailbox(contents of mailboxRef, \(appleLiteral(query)), remainingCount)
            end repeat
            return my joinText(rowList, ASCII character 30)
            """)
        }
        var rows = splitRows(
            try runOsaScript(script, timeout: options.effectiveTimeout),
            fields: messageFields(lastField: "bodyPreview")
        )
        coerceReadStatus(&rows)
        try printJSON([
            "account": account,
            "mailbox": mailbox,
            "messages": rows,
            "query": query,
            "source": "Apple Mail"
        ])
    }

    private static func cmdLatest(_ options: AppleMailOptions) throws {
        let account = options.effectiveAccount
        let requestedLimit = max(1, options.limit)
        try guardBulkBodyRead(includeBody: options.includeBody, limit: requestedLimit)
        let limit = min(requestedLimit, 100)
        let mailbox = options.mailbox.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "INBOX"
        let script = scriptWith("""
        set accountRef to my selectedAccount(\(appleLiteral(account)))
        set targetMailbox to my selectedMailbox(accountRef, \(appleLiteral(mailbox)))
        set rowList to my recentMessages(targetMailbox, \(limit), \(options.includeBody ? "true" : "false"))
        return my joinText(rowList, ASCII character 30)
        """)
        var rows = splitRows(
            try runOsaScript(script, timeout: options.effectiveTimeout, operation: options.includeBody ? .messageBody : .metadata),
            fields: messageFields(lastField: options.includeBody ? "body" : "bodyPreview")
        )
        coerceReadStatus(&rows)
        try printJSON([
            "account": account,
            "mailbox": mailbox,
            "messages": rows,
            "source": "Apple Mail"
        ])
    }

    private static func cmdToday(_ options: AppleMailOptions) throws {
        let account = options.effectiveAccount
        let limit = clamp(options.limit, min: 1, max: 100)
        let mailbox = options.mailbox.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "INBOX"
        let script = scriptWith("""
        set accountRef to my selectedAccount(\(appleLiteral(account)))
        set targetMailbox to my selectedMailbox(accountRef, \(appleLiteral(mailbox)))
        set rowList to my todayMessages(targetMailbox, \(limit))
        return my joinText(rowList, ASCII character 30)
        """)
        var rows = splitRows(
            try runOsaScript(script, timeout: options.effectiveTimeout),
            fields: messageFields(lastField: "bodyPreview")
        )
        coerceReadStatus(&rows)
        try printJSON([
            "account": account,
            "mailbox": mailbox,
            "messages": rows,
            "source": "Apple Mail"
        ])
    }

    private static func cmdGet(_ options: AppleMailOptions) throws {
        let account = options.effectiveAccount
        let mailbox = options.mailbox.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "INBOX"
        guard let messageID = options.messageID, !messageID.isEmpty else {
            throw ToolError("get requires --message-id MESSAGE_ID.")
        }
        let lookupScript: String
        if mailbox.lowercased() == "all" {
            lookupScript = "set foundMessage to my findMessage(mailboxes of accountRef, \(appleLiteral(messageID)))"
        } else {
            lookupScript = """
            set targetMailbox to my selectedMailbox(accountRef, \(appleLiteral(mailbox)))
            set foundMessage to my findMessageInMailbox(targetMailbox, \(appleLiteral(messageID)))
            """
        }
        let missingMessageError = AppleScriptSource.errorStatement(
            "No Apple Mail message matches message id \(messageID)."
        )
        let script = scriptWith("""
        set accountRef to my selectedAccount(\(appleLiteral(account)))
        \(lookupScript)
        if foundMessage is missing value then \(missingMessageError)
        return my messageRow(foundMessage, true)
        """)
        var rows = splitRows(
            try runOsaScript(script, timeout: options.effectiveTimeout, operation: .messageBody),
            fields: messageFields(lastField: "body")
        )
        coerceReadStatus(&rows)
        try printJSON([
            "account": account,
            "mailbox": mailbox,
            "message": rows.first ?? [:],
            "source": "Apple Mail"
        ])
    }

    private static func messageFields(lastField: String) -> [String] {
        ["id", "internetMessageID", "mailbox", "subject", "sender", "dateReceived", "dateSent", "read", lastField]
    }

    private static func coerceReadStatus(_ rows: inout [[String: Any]]) {
        for index in rows.indices {
            rows[index]["read"] = parseBool(rows[index]["read"])
        }
    }

    private static func parseGlobalOptions(args: inout [String], options: inout AppleMailOptions) throws {
        var parsed: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.globalAccount = try requireValue(after: arg, in: &args)
            case "--timeout":
                options.globalTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                parsed.append(arg)
                parsed.append(contentsOf: args)
                args = parsed
                return
            }
        }
        args = parsed
    }

    private static func parseAccounts(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
    }

    private static func parseFolders(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.commandAccount = try requireValue(after: arg, in: &args)
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
    }

    private static func parseLatest(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.commandAccount = try requireValue(after: arg, in: &args)
            case "--mailbox":
                options.mailbox = try requireValue(after: arg, in: &args)
            case "--limit":
                options.limit = parseInt(try requireValue(after: arg, in: &args), default: 1)
            case "--include-body":
                options.includeBody = true
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
    }

    private static func parseToday(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.commandAccount = try requireValue(after: arg, in: &args)
            case "--mailbox":
                options.mailbox = try requireValue(after: arg, in: &args)
            case "--limit":
                options.limit = parseInt(try requireValue(after: arg, in: &args), default: 50)
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
    }

    private static func parseSearch(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.commandAccount = try requireValue(after: arg, in: &args)
            case "--mailbox":
                options.mailbox = try requireValue(after: arg, in: &args)
            case "--query":
                options.query = try requireValue(after: arg, in: &args)
            case "--limit":
                options.limit = parseInt(try requireValue(after: arg, in: &args), default: 10)
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
    }

    private static func parseGet(_ rawArgs: [String], options: inout AppleMailOptions) throws {
        var args = rawArgs
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--account":
                options.commandAccount = try requireValue(after: arg, in: &args)
            case "--mailbox":
                options.mailbox = try requireValue(after: arg, in: &args)
            case "--message-id":
                options.messageID = try requireValue(after: arg, in: &args)
            case "--timeout":
                options.commandTimeout = parseInt(try requireValue(after: arg, in: &args), default: defaultTimeout)
            default:
                throw ToolError("Unknown option \(arg).")
            }
        }
        guard options.messageID?.isEmpty == false else {
            throw ToolError("get requires --message-id MESSAGE_ID.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
