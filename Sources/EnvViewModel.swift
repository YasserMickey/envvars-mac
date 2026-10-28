// EnvViewModel.swift
// Glue between the UI and EnvStore.swift. The file ~/.envvars/env.zsh is always the source of truth:
// it is re-read on launch, whenever the app comes to the front, and before every change.

import SwiftUI
import AppKit

struct EditTarget: Identifiable {
    let id: String   // the variable's current name
}

final class EnvViewModel: ObservableObject {
    // Data
    @Published var doc = EnvDocument()

    // Add form
    @Published var nameInput = ""
    @Published var valueInput = ""
    @Published var showValueInput = false

    // List
    @Published var search = ""
    @Published var revealed: Set<String> = []

    // Feedback / dialogs
    @Published var toast: String? = nil
    @Published var errorMessage: String? = nil
    @Published var showDeleteAlert = false
    @Published var deleteTarget = ""
    @Published var showTerminalConfirm = false
    @Published var editing: EditTarget? = nil
    @Published var showMessageEditor = false

    // Terminal loading
    @Published var terminalEnabled = false

    private let store: EnvFileStore
    private let zshrc: ZshrcManager
    private let messageStore: MessageTemplateStore
    private var toastToken = 0

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        store = EnvFileStore(home: home)
        zshrc = ZshrcManager(home: home)
        messageStore = MessageTemplateStore(home: home)
        reload()
    }

    // MARK: Loading

    func reload() {
        do {
            doc = try store.load()
        } catch {
            errorMessage = describe(error)
        }
        terminalEnabled = zshrc.isEnabled()
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? EnvError, let text = e.errorDescription { return text }
        return error.localizedDescription
    }

    /// Re-reads the file, applies `change`, writes the file. Returns true on success.
    private func apply(_ change: (inout EnvDocument) throws -> Void) -> Bool {
        do {
            var fresh = try store.load()
            try change(&fresh)
            try store.save(fresh)
            doc = fresh
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    // MARK: Derived

    var filtered: [EnvVar] {
        let sorted = doc.vars.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return sorted }
        return sorted.filter { $0.name.lowercased().contains(q) }
    }

    var trimmedName: String {
        return nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small hint shown under the Add form.
    var nameHint: (text: String, isProblem: Bool)? {
        let n = trimmedName
        if n.isEmpty { return nil }
        if !EnvFormat.isValidName(n) {
            return ("Names can use letters, digits and underscores, and can't start with a digit.", true)
        }
        if doc.index(of: n) != nil {
            return ("\(n) already exists. Adding will update its value.", true)
        }
        return nil
    }

    // MARK: Actions

    @discardableResult
    func addCurrent() -> Bool {
        let name = trimmedName
        guard EnvFormat.isValidName(name) else {
            errorMessage = EnvError.invalidName.errorDescription
            return false
        }
        let value = valueInput
        var result = EnvDocument.UpsertResult.added
        let ok = apply { d in result = d.upsert(name: name, value: value) }
        if ok {
            nameInput = ""
            valueInput = ""
            showToast(result == .added ? "Added \(name)" : "Updated \(name)")
        }
        return ok
    }

    func saveEdit(original: String, newName: String, value: String) -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var failure: String? = nil
        let ok = apply { d in
            do {
                try d.update(oldName: original, newName: name, value: value)
            } catch {
                failure = self.describe(error)
                throw error
            }
        }
        if ok {
            if revealed.contains(original) && original != name {
                revealed.remove(original)
                revealed.insert(name)
            }
            showToast("Saved \(name)")
            return nil
        }
        // apply() put the message in errorMessage; show it inside the sheet instead.
        errorMessage = nil
        return failure ?? "Could not save."
    }

    func requestDelete(_ name: String) {
        deleteTarget = name
        showDeleteAlert = true
    }

    func confirmDelete() {
        let name = deleteTarget
        if apply({ d in d.remove(name: name) }) {
            revealed.remove(name)
            showToast("Deleted \(name)")
        }
    }

    func toggleReveal(_ name: String) {
        if revealed.contains(name) { revealed.remove(name) } else { revealed.insert(name) }
    }

    // MARK: Copying

    func copy(_ text: String, what: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showToast("Copied \(what)")
    }

    func copyValue(_ v: EnvVar) {
        copy(v.value, what: "value of \(v.name)")
    }

    func copyName(_ v: EnvVar) {
        copy(v.name, what: "name \(v.name)")
    }

    func copyMessage(_ v: EnvVar) {
        // Read the template file every time, so hand edits to ~/.envvars/message.txt apply immediately.
        let text = MessageTemplate.render(messageStore.load(), name: v.name)
        copy(text, what: "message for \(v.name)")
    }

    /// The template currently in use (the default if ~/.envvars/message.txt is missing or blank).
    func currentMessageTemplate() -> String {
        return messageStore.load()
    }

    /// Saves the template. Returns nil on success, or an error text to show inside the sheet.
    func saveMessageTemplate(_ template: String) -> String? {
        do {
            try messageStore.save(template)
            showToast("Message saved")
            return nil
        } catch {
            return describe(error)
        }
    }

    func copyExport(_ v: EnvVar) {
        copy(EnvFormat.exportLine(name: v.name, value: v.value), what: "export line for \(v.name)")
    }

    func copyAll() {
        if doc.vars.isEmpty {
            showToast("Nothing to copy yet")
            return
        }
        let text = doc.vars.map { EnvFormat.exportLine(name: $0.name, value: $0.value) }.joined(separator: "\n") + "\n"
        copy(text, what: "all \(doc.vars.count) export lines")
    }

    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self else { return }
            if self.toastToken == token { self.toast = nil }
        }
    }

    // MARK: Terminal loading (~/.zshrc)

    /// Called by the toggle. Turning on asks for confirmation first; turning off happens right away.
    func requestTerminal(_ wantOn: Bool) {
        if wantOn {
            if !terminalEnabled { showTerminalConfirm = true }
        } else if terminalEnabled {
            do {
                try zshrc.disable()
                terminalEnabled = zshrc.isEnabled()
                showToast("Terminal loading turned off")
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    func confirmEnableTerminal() {
        do {
            try zshrc.enable()
            terminalEnabled = zshrc.isEnabled()
            showToast("New Terminal windows will load your variables")
        } catch {
            errorMessage = describe(error)
        }
    }
}
