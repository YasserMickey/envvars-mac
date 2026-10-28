// ContentView.swift
// All the screens: add form, list, edit sheet, footer.

import SwiftUI
import AppKit

private let mono = Font.system(.body, design: .monospaced)

struct ContentView: View {
    @EnvironmentObject var vm: EnvViewModel
    @FocusState private var focused: Field?

    enum Field { case name, value }

    var body: some View {
        VStack(spacing: 0) {
            addForm
            Divider()
            searchBar
            variableList
            Divider()
            TerminalFooter()
        }
        .frame(minWidth: 740, minHeight: 540)
        .overlay(alignment: .bottom) {
            if let text = vm.toast {
                Text(text)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 86)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
        .sheet(item: $vm.editing) { target in
            EditView(original: target.id, initialValue: vm.doc.value(of: target.id) ?? "")
                .environmentObject(vm)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { vm.errorMessage != nil },
                                    set: { if !$0 { vm.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { } },
               message: { Text(vm.errorMessage ?? "") })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.reload()
        }
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a variable")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("NAME", text: $vm.nameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(mono)
                    .frame(width: 220)
                    .focused($focused, equals: .name)
                    .onSubmit {
                        if vm.valueInput.isEmpty {
                            focused = .value
                        } else {
                            submitAdd()
                        }
                    }

                Group {
                    if vm.showValueInput {
                        TextField("value", text: $vm.valueInput)
                    } else {
                        SecureField("value", text: $vm.valueInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(mono)
                .focused($focused, equals: .value)
                .onSubmit { submitAdd() }

                Button(action: { vm.showValueInput.toggle() }) {
                    Image(systemName: vm.showValueInput ? "eye.slash" : "eye")
                        .frame(width: 18)
                }
                .help(vm.showValueInput ? "Hide the value" : "Show the value")

                Button("Add") { submitAdd() }
                    .help("Add (or update) this variable. Pressing Return does the same.")
            }
            if let hint = vm.nameHint {
                Text(hint.text)
                    .font(.caption)
                    .foregroundColor(hint.isProblem ? .orange : .secondary)
            }
        }
        .padding(16)
    }

    private func submitAdd() {
        if vm.addCurrent() {
            focused = .name
        }
    }

    // MARK: Search + copy all

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("Search names", text: $vm.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Text("\(vm.doc.vars.count) saved")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Edit message…") { vm.showMessageEditor = true }
                .help("Change the text the Message button copies (saved in ~/.envvars/message.txt)")
            Button("Copy all as export lines") { vm.copyAll() }
                .help("Copies every variable as an export NAME=\"value\" line")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .sheet(isPresented: $vm.showMessageEditor) {
            MessageEditView(initialText: vm.currentMessageTemplate())
                .environmentObject(vm)
        }
    }

    // MARK: List

    private var variableList: some View {
        let items = vm.filtered
        return Group {
            if items.isEmpty {
                VStack {
                    Spacer()
                    Text(vm.doc.vars.isEmpty ? "No variables yet. Add your first one above." : "No names match your search.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items, id: \.name) { item in
                        VarRow(variable: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete \(vm.deleteTarget)?",
               isPresented: $vm.showDeleteAlert,
               actions: {
                   Button("Delete", role: .destructive) { vm.confirmDelete() }
                   Button("Cancel", role: .cancel) { }
               },
               message: { Text("This removes it from ~/.envvars/env.zsh. It can't be undone.") })
    }
}

// MARK: - One row

struct VarRow: View {
    @EnvironmentObject var vm: EnvViewModel
    let variable: EnvVar

    private var isShown: Bool { vm.revealed.contains(variable.name) }

    private var shownValue: String {
        if variable.value.isEmpty { return "(empty)" }
        return isShown ? variable.value : "••••••••••"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variable.name)
                    .font(Font.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Text(shownValue)
                    .font(mono)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { vm.editing = EditTarget(id: variable.name) }
            .help("Double-click to edit")

            Button(action: { vm.toggleReveal(variable.name) }) {
                Image(systemName: isShown ? "eye.slash" : "eye").frame(width: 18)
            }
            .help(isShown ? "Hide value" : "Show value")

            Text("Copy:").font(.caption).foregroundColor(.secondary)

            Button("Name") { vm.copyName(variable) }
                .help("Copy just the variable name")

            Button("Value") { vm.copyValue(variable) }
                .help("Copy just the value")

            Button("Export") { vm.copyExport(variable) }
                .help("Copy as export \(variable.name)=\"value\"")

            Button("Message") { vm.copyMessage(variable) }
                .help("Copy your message about this variable (change it with Edit message…)")

            Button(action: { vm.editing = EditTarget(id: variable.name) }) {
                Image(systemName: "pencil").frame(width: 18)
            }
            .help("Edit")

            Button(action: { vm.requestDelete(variable.name) }) {
                Image(systemName: "trash").frame(width: 18)
            }
            .help("Delete")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit sheet

struct EditView: View {
    @EnvironmentObject var vm: EnvViewModel
    @Environment(\.presentationMode) private var presentationMode

    let original: String
    @State private var name: String
    @State private var value: String
    @State private var showValue = true
    @State private var problem: String? = nil

    init(original: String, initialValue: String) {
        self.original = original
        _name = State(initialValue: original)
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit variable")
                .font(.headline)

            TextField("NAME", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(mono)

            HStack(spacing: 8) {
                Group {
                    if showValue {
                        TextField("value", text: $value)
                    } else {
                        SecureField("value", text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(mono)

                Button(action: { showValue.toggle() }) {
                    Image(systemName: showValue ? "eye.slash" : "eye").frame(width: 18)
                }
                .help(showValue ? "Hide the value" : "Show the value")
            }

            if let p = problem {
                Text(p)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        if let failure = vm.saveEdit(original: original, newName: name, value: value) {
            problem = failure
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Edit message sheet

struct MessageEditView: View {
    @EnvironmentObject var vm: EnvViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var text: String
    @State private var problem: String? = nil

    private let exampleName = "MY_API_KEY"

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit message")
                .font(.headline)
            Text("This is what the Message button copies. {{NAME}} is replaced with the variable's name.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $text)
                .font(mono)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))

            if !text.contains(MessageTemplate.placeholder) && !MessageTemplate.isBlank(text) {
                Text("There's no {{NAME}} in this text, so the variable name won't appear in the copied message.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Text("Preview (with \(exampleName))")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView {
                Text(MessageTemplate.render(text, name: exampleName))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 120)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            if let p = problem {
                Text(p)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Button("Reset to default") { text = MessageTemplate.defaultTemplate }
                    .help("Put the built-in message back in the box. Press Save to keep it.")
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() {
        if let failure = vm.saveMessageTemplate(text) {
            problem = failure
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Footer: Terminal loading

struct TerminalFooter: View {
    @EnvironmentObject var vm: EnvViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { vm.terminalEnabled },
                                 set: { vm.requestTerminal($0) })) {
                Text("Load in new Terminal windows")
            }
            Text("Variables are saved in ~/.envvars/env.zsh. Windows that are already open need: source ~/.envvars/env.zsh")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Load your variables in new Terminal windows?",
               isPresented: $vm.showTerminalConfirm,
               actions: {
                   Button("Turn On") { vm.confirmEnableTerminal() }
                   Button("Cancel", role: .cancel) { }
               },
               message: {
                   Text("This adds a small, clearly marked block to your ~/.zshrc (after saving a backup copy) so every new Terminal window loads your saved variables, and you can turn it off here at any time.")
               })
    }
}
