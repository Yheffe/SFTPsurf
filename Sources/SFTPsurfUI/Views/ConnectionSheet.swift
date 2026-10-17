import AppKit
import SwiftUI
import SFTPsurfCore

/// Create or edit a connection, and optionally connect straight away.
public struct ConnectionSheet: View {
    @ObservedObject var model: BrowserModel
    let mode: BrowserModel.ConnectionSheetMode

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfile
    @State private var password: String = ""
    @State private var savePassword: Bool
    @State private var isNew: Bool
    @State private var validationMessage: String?

    public init(model: BrowserModel, mode: BrowserModel.ConnectionSheetMode) {
        self.model = model
        self.mode = mode
        _draft = State(initialValue: mode.profile)
        _isNew = State(initialValue: mode.isNew)
        _savePassword = State(initialValue: model.preferences.savePasswordsInKeychain)
        _password = State(initialValue: "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 470)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: draft.kind == .sftp ? "lock.shield" : "network")
                .foregroundStyle(Color.accentColor)
            Text(isNew ? "New Connection" : "Edit Connection")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var form: some View {
        Form {
            TextField("Nickname", text: $draft.nickname, prompt: Text("Optional, e.g. “Production”"))
            TextField("Server", text: $draft.host, prompt: Text("example.com"))
            TextField(
                "Port",
                value: Binding(
                    get: { draft.port ?? draft.kind.defaultPort },
                    set: { draft.port = $0 }
                ),
                format: .number
            )
            TextField("Username", text: $draft.username)
            TextField("Initial folder", text: $draft.initialPath, prompt: Text("Optional"))

            Picker("Protocol", selection: $draft.kind) {
                ForEach(RemoteProtocolKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: draft.kind) { _, newValue in
                // FTP cannot use keys, so keep the auth choice valid.
                draft.authMethod = AuthMethod.sanitized(draft.authMethod, for: newValue)
            }

            if draft.kind == .sftp {
                sftpFields
            } else {
                ftpFields
            }

            if isPasswordAuth {
                SecureField("Password", text: $password, prompt: Text("Stored in the Keychain"))
                Toggle("Save password in Keychain", isOn: $savePassword)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var sftpFields: some View {
        Picker("Sign in with", selection: $draft.authMethod) {
            Text(AuthMethod.password.displayName).tag(AuthMethod.password)
            Text(AuthMethod.agentAndDefaults.displayName).tag(AuthMethod.agentAndDefaults)
            if case .privateKey(let path) = draft.authMethod {
                Text(AuthMethod.privateKey(path: path).displayName)
                    .tag(AuthMethod.privateKey(path: path))
            } else {
                Text("Private Key File").tag(AuthMethod.privateKey(path: "~/.ssh/id_ed25519"))
            }
        }

        if case .privateKey(let path) = draft.authMethod {
            HStack {
                TextField("Key file", text: Binding(
                    get: { path },
                    set: { draft.authMethod = .privateKey(path: $0) }
                ))
                Button("Choose…") { chooseKeyFile() }
            }
        }

        TextField(
            "Jump host",
            text: Binding(
                get: { draft.proxyJump ?? "" },
                set: { draft.proxyJump = $0.isEmpty ? nil : $0 }
            ),
            prompt: Text("Optional, e.g. user@bastion")
        )
    }

    @ViewBuilder
    private var ftpFields: some View {
        Toggle("Use passive mode", isOn: $draft.ftpPassive)
        Toggle("Use UTF-8 filenames", isOn: $draft.ftpUTF8)
    }

    private var footer: some View {
        HStack {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if !isNew {
                Button("Delete", role: .destructive) {
                    model.bookmarkStore.remove(id: draft.id)
                    model.keychain.deletePassword(for: draft.id)
                    model.reloadBookmarks()
                    dismiss()
                }
            }

            Button("Cancel", role: .cancel) { dismiss() }

            Button(isNew ? "Save" : "Save Changes") {
                guard validate() else { return }
                persistPasswordIfNeeded()
                model.bookmarkStore.upsert(draft)
                model.reloadBookmarks()
                dismiss()
            }

            Button("Connect") {
                guard validate() else { return }
                persistPasswordIfNeeded()
                model.bookmarkStore.upsert(draft)
                model.reloadBookmarks()
                dismiss()

                if isPasswordAuth && password.isEmpty {
                    // Nothing typed, so fall back to whatever the Keychain holds.
                    model.beginConnect(to: draft)
                } else if isPasswordAuth {
                    Task { await model.connect(profile: draft, password: password) }
                } else {
                    Task { await model.connect(profile: draft, password: nil) }
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var isPasswordAuth: Bool {
        draft.authMethod == .password
    }

    private func validate() -> Bool {
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = "Enter a server address."
            return false
        }
        if let port = draft.port, !(1...65535).contains(port) {
            validationMessage = "Port must be between 1 and 65535."
            return false
        }
        validationMessage = nil
        return true
    }

    private func persistPasswordIfNeeded() {
        guard isPasswordAuth else { return }
        if savePassword, !password.isEmpty {
            model.keychain.setPassword(password, for: draft.id)
        } else if !savePassword {
            model.keychain.deletePassword(for: draft.id)
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SSH private key"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.authMethod = .privateKey(path: url.path)
        }
    }
}

/// Prompts for a password when the Keychain has nothing stored.
struct PasswordPromptSheet: View {
    @ObservedObject var model: BrowserModel
    let prompt: BrowserModel.PasswordPrompt

    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""
    @State private var savePassword: Bool

    init(model: BrowserModel, prompt: BrowserModel.PasswordPrompt) {
        self.model = model
        self.prompt = prompt
        _savePassword = State(initialValue: prompt.saveInKeychain)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Password for \(prompt.profile.displayName)")
                    .font(.headline)
            }

            if let message = prompt.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Toggle("Save password in Keychain", isOn: $savePassword)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if savePassword {
            model.keychain.setPassword(password, for: prompt.profile.id)
        }
        let profile = prompt.profile
        dismiss()
        Task { await model.connect(profile: profile, password: password) }
    }
}

/// Renames an item in either pane.
struct RenameSheet: View {
    @ObservedObject var model: BrowserModel
    let prompt: BrowserModel.RenamePrompt

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(model: BrowserModel, prompt: BrowserModel.RenamePrompt) {
        self.model = model
        self.prompt = prompt
        _name = State(initialValue: prompt.originalName)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(prompt.originalName)”")
                .font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func commit() {
        model.pendingRename?.newName = name
        dismiss()
        model.confirmPendingRename()
    }
}

/// Names a new folder.
struct NewFolderSheet: View {
    @ObservedObject var model: BrowserModel
    let prompt: BrowserModel.NewFolderPrompt

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(model: BrowserModel, prompt: BrowserModel.NewFolderPrompt) {
        self.model = model
        self.prompt = prompt
        _name = State(initialValue: prompt.name)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.target == .local ? "New Local Folder" : "New Remote Folder")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func commit() {
        model.pendingNewFolder?.name = name
        dismiss()
        model.confirmPendingNewFolder()
    }
}

/// Preferences window.
public struct PreferencesView: View {
    @ObservedObject var model: BrowserModel

    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Show hidden files", isOn: Binding(
                    get: { model.preferences.showHiddenFiles },
                    set: { model.setShowHiddenFiles($0) }
                ))
                Toggle("Confirm before deleting", isOn: Binding(
                    get: { model.preferences.confirmBeforeDelete },
                    set: {
                        model.preferences.confirmBeforeDelete = $0
                        model.savePreferences()
                    }
                ))
            }

            Section("Transfers") {
                Stepper(
                    "Simultaneous transfers: \(model.preferences.maxConcurrentTransfers)",
                    value: Binding(
                        get: { model.preferences.maxConcurrentTransfers },
                        set: {
                            model.preferences.maxConcurrentTransfers = max(1, min(8, $0))
                            model.savePreferences()
                        }
                    ),
                    in: 1...8
                )
            }

            Section("Security") {
                Toggle("Save passwords in the Keychain by default", isOn: Binding(
                    get: { model.preferences.savePasswordsInKeychain },
                    set: {
                        model.preferences.savePasswordsInKeychain = $0
                        model.savePreferences()
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
    }
}
