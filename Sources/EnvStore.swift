// EnvStore.swift
// Pure logic for the EnvVars app. Foundation only (no UI), so it can be unit-tested anywhere.

import Foundation

// MARK: - Basic types

struct EnvVar: Equatable {
    var name: String
    var value: String
}

enum EnvError: Error, LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case notFound(String)
    case unreadableFile
    case zshrcMarkersBroken

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Names must start with a letter or underscore and contain only letters, digits and underscores (for example MY_API_KEY)."
        case .nameTaken(let n):
            return "A variable named \(n) already exists."
        case .notFound(let n):
            return "\(n) was not found."
        case .unreadableFile:
            return "The saved file ~/.envvars/env.zsh could not be read as text. Nothing was changed."
        case .zshrcMarkersBroken:
            return "Your ~/.zshrc has the EnvVars start marker but no end marker, so it was left untouched. Please fix it by hand."
        }
    }
}

// MARK: - Formatting / quoting

enum EnvFormat {
    static let beginMarker = "# >>> EnvVars app >>>"
    static let endMarker = "# <<< EnvVars app <<<"
    static let sourceLine = "[ -f ~/.envvars/env.zsh ] && source ~/.envvars/env.zsh"

    /// Name must match [A-Za-z_][A-Za-z0-9_]* (checked by hand, ASCII only).
    static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        if scalars.isEmpty { return false }
        for (index, scalar) in scalars.enumerated() {
            let v = scalar.value
            let isLetter = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
            let isDigit = v >= 48 && v <= 57
            if index == 0 {
                if !isLetter { return false }
            } else if !(isLetter || isDigit) {
                return false
            }
        }
        return true
    }

    /// 'value' with every single quote written as '\''  (safe for zsh/bash/sh).
    static func singleQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "value" with \ " $ ` escaped.
    static func doubleQuote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "\"" || scalar == "$" || scalar == "`" {
                out.append("\\")
            }
            out.unicodeScalars.append(scalar)
        }
        out.append("\"")
        return out
    }

    /// The line stored in env.zsh.
    static func fileLine(name: String, value: String) -> String {
        return "export \(name)=\(singleQuote(value))"
    }

    /// The line copied to the clipboard: export NAME="value".
    /// Values containing "!" (history expansion in an interactive shell) or line breaks use single quotes instead.
    static func exportLine(name: String, value: String) -> String {
        if value.contains("!") || value.contains("\n") || value.contains("\r") {
            return fileLine(name: name, value: value)
        }
        return "export \(name)=\(doubleQuote(value))"
    }
}

// MARK: - Document (the contents of env.zsh)

struct EnvDocument: Equatable {
    var vars: [EnvVar] = []
    /// Lines in the file that the app doesn't understand (e.g. hand-written ones). Kept as-is.
    var extraLines: [String] = []

    enum UpsertResult { case added, updated }

    func index(of name: String) -> Int? {
        return vars.firstIndex(where: { $0.name == name })
    }

    func value(of name: String) -> String? {
        if let i = index(of: name) { return vars[i].value }
        return nil
    }

    @discardableResult
    mutating func upsert(name: String, value: String) -> UpsertResult {
        if let i = index(of: name) {
            vars[i].value = value
            return .updated
        }
        vars.append(EnvVar(name: name, value: value))
        return .added
    }

    mutating func remove(name: String) {
        vars.removeAll(where: { $0.name == name })
    }

    /// Change name and/or value of an existing variable.
    mutating func update(oldName: String, newName: String, value: String) throws {
        guard let i = index(of: oldName) else { throw EnvError.notFound(oldName) }
        guard EnvFormat.isValidName(newName) else { throw EnvError.invalidName }
        if newName != oldName && index(of: newName) != nil { throw EnvError.nameTaken(newName) }
        vars[i] = EnvVar(name: newName, value: value)
    }

    // MARK: Serialise

    func serialize() -> String {
        var lines: [String] = [
            "# Managed by the EnvVars app. You can edit this file by hand too."
        ]
        for v in vars {
            lines.append(EnvFormat.fileLine(name: v.name, value: v.value))
        }
        lines.append(contentsOf: extraLines)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Parse

    private static let specialUnquoted: Set<Unicode.Scalar> = Set("$`&|;<>(){}*?[]!~#".unicodeScalars)

    static func parse(_ text: String) -> EnvDocument {
        let s = Array(text.unicodeScalars)
        let n = s.count
        var doc = EnvDocument()
        var i = 0
        while i < n {
            let lineStart = i
            while i < n && (s[i] == " " || s[i] == "\t") { i += 1 }
            if i >= n { break }
            if s[i] == "\n" || s[i] == "\r" { i += 1; continue }
            if s[i] == "#" { i = endOfLine(s, i); continue }
            if let result = parseAssignment(s, from: i) {
                doc.upsert(name: result.name, value: result.value)
                i = result.end
                continue
            }
            // Not something we understand: keep the whole line untouched.
            let eol = endOfLine(s, lineStart)
            doc.extraLines.append(string(from: s, lineStart, eol))
            i = eol
        }
        return doc
    }

    private static func endOfLine(_ s: [Unicode.Scalar], _ start: Int) -> Int {
        var i = start
        while i < s.count && s[i] != "\n" && s[i] != "\r" { i += 1 }
        return i
    }

    private static func string(from s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        var k = from
        while k < to { view.append(s[k]); k += 1 }
        return String(view)
    }

    private static func isNameScalar(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 || (v >= 48 && v <= 57)
    }

    /// Parses `export NAME=<shell word>` starting at `start`. Returns nil if the line is anything fancier
    /// (variable expansion, command substitution, etc.) so that it is preserved rather than altered.
    private static func parseAssignment(_ s: [Unicode.Scalar], from start: Int) -> (name: String, value: String, end: Int)? {
        let n = s.count
        var i = start

        let keyword = Array("export".unicodeScalars)
        if i + keyword.count >= n { return nil }
        for (k, c) in keyword.enumerated() {
            if s[i + k] != c { return nil }
        }
        i += keyword.count
        if !(s[i] == " " || s[i] == "\t") { return nil }
        while i < n && (s[i] == " " || s[i] == "\t") { i += 1 }

        var nameView = String.UnicodeScalarView()
        while i < n && isNameScalar(s[i]) { nameView.append(s[i]); i += 1 }
        let name = String(nameView)
        if !EnvFormat.isValidName(name) { return nil }
        if i >= n || s[i] != "=" { return nil }
        i += 1

        var value = String.UnicodeScalarView()
        while i < n {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { break }
            if c == "'" {
                i += 1
                var closed = false
                while i < n {
                    if s[i] == "'" { closed = true; i += 1; break }
                    value.append(s[i])
                    i += 1
                }
                if !closed { return nil }
            } else if c == "\"" {
                i += 1
                var closed = false
                while i < n {
                    let d = s[i]
                    if d == "\"" { closed = true; i += 1; break }
                    if d == "\\" {
                        if i + 1 >= n { return nil }
                        let e = s[i + 1]
                        if e == "\\" || e == "\"" || e == "$" || e == "`" {
                            value.append(e)
                            i += 2
                            continue
                        }
                        if e == "\n" { i += 2; continue }
                        value.append(d)
                        i += 1
                        continue
                    }
                    if d == "$" || d == "`" { return nil }
                    value.append(d)
                    i += 1
                }
                if !closed { return nil }
            } else if c == "\\" {
                if i + 1 >= n { return nil }
                let e = s[i + 1]
                if e == "\n" { i += 2; continue }
                if e == "\r" { return nil }
                value.append(e)
                i += 2
            } else if specialUnquoted.contains(c) {
                return nil
            } else {
                value.append(c)
                i += 1
            }
        }

        // Only whitespace or a comment may follow on the line.
        var j = i
        while j < n && (s[j] == " " || s[j] == "\t") { j += 1 }
        if j < n && s[j] != "\n" && s[j] != "\r" && s[j] != "#" { return nil }
        return (name, String(value), j)
    }
}

// MARK: - env.zsh on disk

final class EnvFileStore {
    let directory: URL
    let fileURL: URL

    init(home: URL) {
        directory = home.appendingPathComponent(".envvars", isDirectory: true)
        fileURL = directory.appendingPathComponent("env.zsh")
    }

    func load() throws -> EnvDocument {
        if !FileManager.default.fileExists(atPath: fileURL.path) { return EnvDocument() }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { throw EnvError.unreadableFile }
        return EnvDocument.parse(text)
    }

    /// Writes the file (directory 700, file 600).
    func save(_ doc: EnvDocument) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = Data(doc.serialize().utf8)
        try data.write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - "Message" copy button: editable template

/// The text copied by the "Message" button. `{{NAME}}` is replaced with the variable's name.
enum MessageTemplate {
    static let placeholder = "{{NAME}}"

    /// Change this if you fork the repo and want a different built-in default.
    static let defaultTemplate = "Hi, I've added a new environment variable that is called {{NAME}}. Please follow the workflow that's associated with that."

    /// True when the template is empty or only whitespace (it then falls back to the default).
    static func isBlank(_ template: String) -> Bool {
        return template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Replaces every {{NAME}} with `name`. A blank template renders the default one.
    /// A template without the placeholder is returned unchanged.
    static func render(_ template: String, name: String) -> String {
        let source = isBlank(template) ? defaultTemplate : template
        return source.replacingOccurrences(of: placeholder, with: name)
    }

    /// Drops trailing line breaks (text editors love adding one) but keeps everything else as typed.
    static func normalized(_ template: String) -> String {
        var text = template
        while let last = text.last, last == "\n" || last == "\r" || last == "\r\n" {
            text.removeLast()
        }
        return text
    }
}

/// Reads and writes ~/.envvars/message.txt. No file (or a blank one) means "use the default".
final class MessageTemplateStore {
    let directory: URL
    let fileURL: URL

    init(home: URL) {
        directory = home.appendingPathComponent(".envvars", isDirectory: true)
        fileURL = directory.appendingPathComponent("message.txt")
    }

    /// The template to use right now. Never throws: any problem reading means the default.
    func load() -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return MessageTemplate.defaultTemplate
        }
        let template = MessageTemplate.normalized(text)
        return MessageTemplate.isBlank(template) ? MessageTemplate.defaultTemplate : template
    }

    /// Saves the template. Saving a blank template, or the default itself, removes the file.
    func save(_ template: String) throws {
        let cleaned = MessageTemplate.normalized(template)
        if MessageTemplate.isBlank(cleaned) || cleaned == MessageTemplate.defaultTemplate {
            try reset()
            return
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try Data((cleaned + "\n").utf8).write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Deletes message.txt so the built-in default applies again.
    func reset() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

// MARK: - ~/.zshrc block

final class ZshrcManager {
    let zshrcURL: URL
    let backupURL: URL

    init(home: URL) {
        zshrcURL = home.appendingPathComponent(".zshrc")
        backupURL = home.appendingPathComponent(".zshrc.envvars-backup")
    }

    private func readLines() -> [String]? {
        guard FileManager.default.fileExists(atPath: zshrcURL.path),
              let data = try? Data(contentsOf: zshrcURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
    }

    func isEnabled() -> Bool {
        guard let lines = readLines() else { return false }
        return lines.contains(EnvFormat.beginMarker)
    }

    /// Adds the marked block. Backs up ~/.zshrc first (only if no backup exists yet).
    func enable() throws {
        if isEnabled() { return }
        let fm = FileManager.default
        let block = [EnvFormat.beginMarker, EnvFormat.sourceLine, EnvFormat.endMarker].joined(separator: "\n") + "\n"

        if fm.fileExists(atPath: zshrcURL.path) {
            if !fm.fileExists(atPath: backupURL.path) {
                try fm.copyItem(at: zshrcURL, to: backupURL)
            }
            let existing = try Data(contentsOf: zshrcURL)
            var prefix = ""
            if !existing.isEmpty {
                prefix = (existing.last == 10) ? "\n" : "\n\n"
            }
            let handle = try FileHandle(forWritingTo: zshrcURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data((prefix + block).utf8))
        } else {
            try Data(block.utf8).write(to: zshrcURL)
        }
    }

    /// Removes only the marked block (and the one blank line added before it).
    func disable() throws {
        guard let lines = readLines() else { return }
        guard let begin = lines.firstIndex(of: EnvFormat.beginMarker) else { return }
        guard let end = lines[begin...].firstIndex(of: EnvFormat.endMarker) else {
            throw EnvError.zshrcMarkersBroken
        }
        var kept = lines
        var removeFrom = begin
        if removeFrom > 0 && kept[removeFrom - 1].isEmpty { removeFrom -= 1 }
        kept.removeSubrange(removeFrom...end)
        let text = kept.joined(separator: "\n")
        // Non-atomic write keeps the file's permissions (and symlink, if any).
        try Data(text.utf8).write(to: zshrcURL)
    }
}
