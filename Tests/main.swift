// Logic tests for EnvStore.swift. Run on any OS with Swift:  bash Tests/run.sh
import Foundation

var failures = 0
var checks = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL (line \(line)): \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    checks += 1
    if a != b { failures += 1; print("FAIL (line \(line)): \(msg)\n   got:      \(a)\n   expected: \(b)") }
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("envvars-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func shellRun(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? "<non-utf8>"
}

// --- Names
for ok in ["A", "_", "_x", "MY_KEY_2", "a1"] { check(EnvFormat.isValidName(ok), "valid: \(ok)") }
for bad in ["", "1A", "A-B", "A B", "A.B", "é", "A\n", " A", "A=", "$A"] { check(!EnvFormat.isValidName(bad), "invalid: \(bad.debugDescription)") }

// --- Quoting
eq(EnvFormat.singleQuote("plain"), "'plain'", "plain")
eq(EnvFormat.singleQuote("it's"), "'it'\\''s'", "single quote")
eq(EnvFormat.singleQuote(""), "''", "empty")
eq(EnvFormat.doubleQuote("a\"b$c`d\\e"), "\"a\\\"b\\$c\\`d\\\\e\"", "double quote escapes")
eq(EnvFormat.exportLine(name: "A", value: "x y"), "export A=\"x y\"", "exportLine basic")
eq(EnvFormat.exportLine(name: "A", value: "hi!"), "export A='hi!'", "exportLine with bang uses single quotes")

let tricky: [String] = [
    "simple", "with space", "  leading and trailing  ", "it's", "'", "''", "a'b'c",
    "$HOME", "${HOME}", "$(whoami)", "`whoami`", "back\\slash", "\\", "\\'", "\"dq\"",
    "unicode: héllo wörld ✓ 日本語 😀", "tab\there", "line1\nline2", "crlf\r\nend", "star * ? [x] ~ # ; & | < > ( ) { }",
    "!bang", "100%", "=equals=", "# not a comment", "", "export X='y'", "end with newline\n",
]

// --- Round trip through document + file
var doc = EnvDocument()
for (i, v) in tricky.enumerated() { doc.upsert(name: "VAR_\(i)", value: v) }
let text = doc.serialize()
let parsed = EnvDocument.parse(text)
eq(parsed.vars, doc.vars, "round-trip all tricky values")
eq(parsed.extraLines, [], "no extras after round trip")
eq(EnvDocument.parse(parsed.serialize()).serialize(), text, "serialize is stable")

// --- A real shell reads the same values back
let fileURL = tmp.appendingPathComponent("env.sh")
try! text.write(to: fileURL, atomically: true, encoding: .utf8)
for (i, v) in tricky.enumerated() {
    // Print the value as hex to dodge any echo/newline trimming.
    let out = shellRun(". '\(fileURL.path)'; printf %s \"$VAR_\(i)\" | od -An -tx1 | tr -d ' \\n'")
    let expectedHex = v.utf8.map { String(format: "%02x", $0) }.joined()
    eq(out, expectedHex, "sh reads back value #\(i): \(v.debugDescription)")
}
// exportLine (double-quoted form) also evaluates to the right value in sh
for (i, v) in tricky.enumerated() {
    let line = EnvFormat.exportLine(name: "DQ", value: v)
    let out = shellRun("\(line); printf %s \"$DQ\" | od -An -tx1 | tr -d ' \\n'")
    let expectedHex = v.utf8.map { String(format: "%02x", $0) }.joined()
    eq(out, expectedHex, "exportLine evaluates correctly #\(i): \(v.debugDescription)")
}

// --- Duplicate handling
var d2 = EnvDocument()
check(d2.upsert(name: "A", value: "1") == .added, "first add")
check(d2.upsert(name: "B", value: "2") == .added, "second add")
check(d2.upsert(name: "A", value: "3") == .updated, "duplicate updates")
eq(d2.vars.count, 2, "no duplicate row")
eq(d2.value(of: "A") ?? "", "3", "updated value")
eq(d2.vars.first?.name ?? "", "A", "position kept")
d2.remove(name: "A")
eq(d2.vars.map { $0.name }, ["B"], "remove")

// --- Rename / update
var d3 = EnvDocument()
d3.upsert(name: "A", value: "1"); d3.upsert(name: "B", value: "2")
do { try d3.update(oldName: "A", newName: "B", value: "x"); check(false, "should throw nameTaken") } catch { eq(error as? EnvError, EnvError.nameTaken("B"), "nameTaken") }
do { try d3.update(oldName: "A", newName: "1bad", value: "x"); check(false, "should throw invalid") } catch { eq(error as? EnvError, EnvError.invalidName, "invalid") }
do { try d3.update(oldName: "Z", newName: "Z", value: "x"); check(false, "should throw notFound") } catch { eq(error as? EnvError, EnvError.notFound("Z"), "notFound") }
try! d3.update(oldName: "A", newName: "C", value: "new")
eq(d3.vars, [EnvVar(name: "C", value: "new"), EnvVar(name: "B", value: "2")], "rename keeps position")

// --- Parsing hand-written files
let hand = """
# my stuff
export PLAIN=abc
export DQ="hello world"   # trailing comment
export MIX='a'"b"\\ c
export HOME_REL="$HOME/bin"
export CMD=$(date)
alias ll='ls -l'
PATH=$PATH:/x
export NOEQ
export EMPTY=
export DUP=1
export DUP=2
   export INDENT=ok
export MULTI='line1
line2'
export ESC="q\\"uote \\$dollar \\\\ back"
"""
let h = EnvDocument.parse(hand)
eq(h.value(of: "PLAIN") ?? "?", "abc", "unquoted")
eq(h.value(of: "DQ") ?? "?", "hello world", "double quoted + comment")
eq(h.value(of: "MIX") ?? "?", "abb c".replacingOccurrences(of: "abb", with: "ab"), "mixed quoting")
eq(h.value(of: "EMPTY") ?? "?", "", "empty")
eq(h.value(of: "DUP") ?? "?", "2", "later duplicate wins")
eq(h.vars.filter { $0.name == "DUP" }.count, 1, "dup once")
eq(h.value(of: "INDENT") ?? "?", "ok", "indented")
eq(h.value(of: "MULTI") ?? "?", "line1\nline2", "multi-line single quote")
eq(h.value(of: "ESC") ?? "?", "q\"uote $dollar \\ back", "double-quote escapes")
check(h.value(of: "HOME_REL") == nil, "expansion lines are not interpreted")
check(h.value(of: "CMD") == nil, "command substitution not interpreted")
check(h.extraLines.contains("export HOME_REL=\"$HOME/bin\""), "expansion line preserved")
check(h.extraLines.contains("export CMD=$(date)"), "cmd line preserved")
check(h.extraLines.contains("alias ll='ls -l'"), "alias preserved")
check(h.extraLines.contains("PATH=$PATH:/x"), "bare assignment preserved")
check(h.extraLines.contains("export NOEQ"), "no-equals preserved")
let h2 = EnvDocument.parse(h.serialize())
eq(h2.vars, h.vars, "hand file round-trips vars")
eq(h2.extraLines, h.extraLines, "hand file round-trips extras")
eq(EnvDocument.parse("").vars.count, 0, "empty text")
eq(EnvDocument.parse("export A='unterminated").extraLines, ["export A='unterminated"], "unterminated quote preserved")
eq(EnvDocument.parse("export A='x'\r\nexport B='y'\r\n").vars.count, 2, "CRLF file")

// --- File store: perms + persistence
let home = tmp.appendingPathComponent("home")
try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
let store = EnvFileStore(home: home)
eq(try! store.load(), EnvDocument(), "missing file -> empty")
var sd = EnvDocument(); sd.upsert(name: "TOKEN", value: "it's a \"secret\" $x")
try! store.save(sd)
func perms(_ u: URL) -> Int { (try! FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
eq(perms(store.directory), 0o700, "dir 700")
eq(perms(store.fileURL), 0o600, "file 600")
eq(try! store.load().vars, sd.vars, "load after save")
try! store.save(sd)
eq(perms(store.fileURL), 0o600, "file 600 after rewrite")
try! Data([0xff, 0xfe, 0xfd]).write(to: store.fileURL)
do { _ = try store.load(); check(false, "should throw on non-utf8") } catch { eq(error as? EnvError, EnvError.unreadableFile, "unreadable") }

// --- zshrc block
let zhome = tmp.appendingPathComponent("zhome")
try! FileManager.default.createDirectory(at: zhome, withIntermediateDirectories: true)
let z = ZshrcManager(home: zhome)
check(!z.isEnabled(), "off when no .zshrc")
try! z.disable()   // no-op, must not create file
check(!FileManager.default.fileExists(atPath: z.zshrcURL.path), "disable does not create .zshrc")

// no .zshrc at all
try! z.enable()
check(z.isEnabled(), "enabled")
eq(try! String(contentsOf: z.zshrcURL), "# >>> EnvVars app >>>\n[ -f ~/.envvars/env.zsh ] && source ~/.envvars/env.zsh\n# <<< EnvVars app <<<\n", "block text, new file")
check(!FileManager.default.fileExists(atPath: z.backupURL.path), "no backup when no original")
try! z.disable()
eq(try! String(contentsOf: z.zshrcURL), "", "disable leaves empty file")
try! FileManager.default.removeItem(at: z.zshrcURL)

// existing .zshrc
let original = "export PATH=\"$HOME/bin:$PATH\"\nalias gs='git status'\n"
try! original.write(to: z.zshrcURL, atomically: true, encoding: .utf8)
try! z.enable()
try! z.enable()  // idempotent
let enabledText = try! String(contentsOf: z.zshrcURL)
eq(enabledText.components(separatedBy: "# >>> EnvVars app >>>").count, 2, "block added once")
check(enabledText.hasPrefix(original), "original content untouched at top")
eq(try! String(contentsOf: z.backupURL), original, "backup equals original")
// user edits after enabling; second enable must not overwrite the backup
try! (enabledText + "echo later\n").write(to: z.zshrcURL, atomically: true, encoding: .utf8)
try! z.disable()
try! z.enable()
eq(try! String(contentsOf: z.backupURL), original, "backup only once")
try! z.disable()
eq(try! String(contentsOf: z.zshrcURL), original + "echo later\n", "disable removes only the block")
check(!z.isEnabled(), "disabled")

// no trailing newline originally
try! "echo hi".write(to: z.zshrcURL, atomically: true, encoding: .utf8)
try! z.enable()
check(try! String(contentsOf: z.zshrcURL).hasPrefix("echo hi\n\n# >>> EnvVars app >>>"), "newline added before block")
try! z.disable()
eq(try! String(contentsOf: z.zshrcURL), "echo hi\n", "disable after no-newline original")

// broken markers
try! "a\n# >>> EnvVars app >>>\nb\n".write(to: z.zshrcURL, atomically: true, encoding: .utf8)
do { try z.disable(); check(false, "should throw") } catch { eq(error as? EnvError, EnvError.zshrcMarkersBroken, "broken markers") }
eq(try! String(contentsOf: z.zshrcURL), "a\n# >>> EnvVars app >>>\nb\n", "untouched on broken markers")

// and the sourced block really works in sh-like semantics (file exists & sourced)
// --- Message template
let defaultMessage = "Hi, I've added a new environment variable that is called MY_KEY. Please follow the workflow that's associated with that."
eq(MessageTemplate.render(MessageTemplate.defaultTemplate, name: "MY_KEY"), defaultMessage, "default renders the original sentence")
check(MessageTemplate.defaultTemplate.contains("{{NAME}}"), "default has the placeholder")
eq(MessageTemplate.render("{{NAME}} and {{NAME}} again, {{NAME}}!", name: "X_1"), "X_1 and X_1 again, X_1!", "multiple placeholders")
eq(MessageTemplate.render("No placeholder here.", name: "X"), "No placeholder here.", "no placeholder is unchanged")
eq(MessageTemplate.render("", name: "MY_KEY"), defaultMessage, "empty falls back to default")
eq(MessageTemplate.render("  \n\t \n", name: "MY_KEY"), defaultMessage, "whitespace-only falls back to default")
eq(MessageTemplate.render("line1 {{NAME}}\nline2", name: "K"), "line1 K\nline2", "multi-line template")
eq(MessageTemplate.render("{{name}} {{ NAME }}", name: "K"), "{{name}} {{ NAME }}", "placeholder is exact and case-sensitive")
eq(MessageTemplate.normalized("hi\n\n"), "hi", "trailing newlines dropped")
eq(MessageTemplate.normalized("hi\r\n"), "hi", "trailing CRLF dropped")
eq(MessageTemplate.normalized("  hi  \n"), "  hi  ", "other whitespace kept")

let msgHome = tmp.appendingPathComponent("msg-home")
try! FileManager.default.createDirectory(at: msgHome, withIntermediateDirectories: true)
let ms = MessageTemplateStore(home: msgHome)
eq(ms.load(), MessageTemplate.defaultTemplate, "no file -> default")
try! ms.save("Please use {{NAME}} from my shell, never print it.")
eq(ms.load(), "Please use {{NAME}} from my shell, never print it.", "saved template loads back")
eq(try! String(contentsOf: ms.fileURL), "Please use {{NAME}} from my shell, never print it.\n", "file is plain text with one trailing newline")
let msgAttrs = try! FileManager.default.attributesOfItem(atPath: ms.fileURL.path)
eq((msgAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "message.txt is 600")
// hand-edited file with extra newlines
try! "Hand edited {{NAME}}\n\n\n".write(to: ms.fileURL, atomically: true, encoding: .utf8)
eq(ms.load(), "Hand edited {{NAME}}", "hand-edited file: trailing newlines trimmed")
// blank file -> default
try! "\n  \n".write(to: ms.fileURL, atomically: true, encoding: .utf8)
eq(ms.load(), MessageTemplate.defaultTemplate, "blank file -> default")
// saving blank or the default removes the file
try! ms.save("custom {{NAME}}")
try! ms.save("   ")
check(!FileManager.default.fileExists(atPath: ms.fileURL.path), "saving blank removes the file")
try! ms.save("custom {{NAME}}")
try! ms.save(MessageTemplate.defaultTemplate)
check(!FileManager.default.fileExists(atPath: ms.fileURL.path), "saving the default removes the file")
try! ms.reset()  // reset with no file is fine
eq(ms.load(), MessageTemplate.defaultTemplate, "after reset -> default")
// directory is created (700) when missing
let freshHome = tmp.appendingPathComponent("msg-home-fresh")
try! FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)
let ms2 = MessageTemplateStore(home: freshHome)
try! ms2.save("hello {{NAME}}")
let dirAttrs = try! FileManager.default.attributesOfItem(atPath: ms2.directory.path)
eq((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "created ~/.envvars is 700")
eq(MessageTemplate.render(ms2.load(), name: "Z"), "hello Z", "end to end render from file")

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
