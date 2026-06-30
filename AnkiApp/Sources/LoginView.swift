import SwiftUI
import AnkiKit

/// Sync login screen, cloning AnkiDroid's `LoginFragment`: an email/username
/// field, a password field, and — adapted for self-hosted servers — a sync-server
/// dropdown (our self-hosted MCAT server, AnkiWeb, or "Other…", which reveals a
/// custom URL field).
///
/// Submitting calls `sync_login`; on success the host key is stored in the
/// Keychain and a sync is kicked off (AnkiDroid offers "Sync now?" after login).
struct LoginView: View {
    @ObservedObject var store: AnkiStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    /// Which sync server to use; `.other` reveals the custom URL field.
    @State private var serverChoice: ServerChoice = .mcat
    /// Custom server URL, used only when `serverChoice == .other`.
    @State private var customServerURL = ""
    @State private var submitting = false
    @FocusState private var focused: Field?

    private enum Field { case username, password, server }

    /// The group's self-hosted sync server (deployed on Fly.io).
    static let mcatServerURL = "https://anki-mcat-sync.fly.dev/"

    /// Sync server presets offered in the dropdown.
    private enum ServerChoice: Hashable, CaseIterable {
        case mcat
        case ankiweb
        case other

        var label: String {
            switch self {
            case .mcat: return "MCAT Sync (our server)"
            case .ankiweb: return "AnkiWeb (default)"
            case .other: return "Other…"
            }
        }
    }

    /// The endpoint string passed to `login` ("" means AnkiWeb / default).
    private var resolvedEndpoint: String {
        switch serverChoice {
        case .mcat: return Self.mcatServerURL
        case .ankiweb: return ""
        case .other: return customServerURL
        }
    }

    private var canSubmit: Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty,
              !submitting
        else { return false }
        if serverChoice == .other {
            return !customServerURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Maps a stored/launch-arg endpoint to the matching dropdown selection.
    private func selectServer(for endpoint: String?) {
        let value = (endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            serverChoice = .ankiweb
        } else if value.normalizedURL == Self.mcatServerURL.normalizedURL {
            serverChoice = .mcat
            customServerURL = ""
        } else {
            serverChoice = .other
            customServerURL = value
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        header
                        fields
                        if let error = store.loginErrorMessage {
                            errorBanner(error)
                        }
                        submitButton
                        footnote
                    }
                    .padding(DS.Spacing.l)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Sync Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(submitting)
                }
            }
            .onAppear {
                // Prefill from the stored account.
                username = store.syncUsername
                // Prefill the server dropdown from the last-used endpoint, if any.
                if let saved = store.customSyncServer {
                    selectServer(for: saved)
                }
                #if DEBUG
                // Launch-argument overrides for automated screenshots (debug-only).
                let defaults = UserDefaults.standard
                if let user = defaults.string(forKey: "syncUser") { username = user }
                if let server = defaults.string(forKey: "syncServer") { selectServer(for: server) }
                #endif
                focused = username.isEmpty ? .username : .password
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(DS.accent)
            Text("Log in to sync")
                .font(DS.Typography.title)
                .foregroundStyle(DS.textPrimary)
            Text("Sign in to your AnkiWeb account, or point at a self-hosted sync server below.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .padding(.bottom, DS.Spacing.s)
    }

    private var fields: some View {
        VStack(spacing: DS.Spacing.m) {
            LabeledField(title: "Email / Username") {
                TextField("you@example.com", text: $username)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
            LabeledField(title: "Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(serverChoice == .other ? .next : .go)
                    .onSubmit {
                        if serverChoice == .other { focused = .server } else { submit() }
                    }
            }
            serverField
            if serverChoice == .other {
                LabeledField(title: "Server URL") {
                    TextField("https://my-sync-server.example.com/", text: $customServerURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .server)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: serverChoice)
    }

    /// A dropdown picking the sync server: our self-hosted server, AnkiWeb, or a
    /// custom URL ("Other…", which reveals the URL field below).
    private var serverField: some View {
        LabeledField(title: "Sync server") {
            Menu {
                Picker("Sync server", selection: $serverChoice) {
                    ForEach(ServerChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } label: {
                HStack(spacing: DS.Spacing.s) {
                    Text(serverChoice.label)
                        .foregroundStyle(DS.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Sync server")
            .accessibilityValue(serverChoice.label)
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: DS.Spacing.s) {
                if submitting {
                    ProgressView().tint(.white)
                }
                Text(submitting ? "Signing in…" : "Log In")
            }
        }
        .buttonStyle(.dsPrimary)
        .disabled(!canSubmit)
    }

    private var footnote: some View {
        Text("Your password is exchanged for a sync key, which is stored securely in the Keychain.")
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
            .padding(.top, DS.Spacing.xs)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.again)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .background(
            DS.again.opacity(0.12),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        submitting = true
        Task {
            let success = await store.login(
                username: username,
                password: password,
                endpoint: resolvedEndpoint
            )
            submitting = false
            if success {
                dismiss()
                // Came here by pressing Sync, so sync right after logging in.
                store.startSync()
            }
        }
    }
}

/// A titled input row: a small caption label above a DesignSystem-styled field.
private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
            content
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .padding(.horizontal, DS.Spacing.m)
                .frame(minHeight: DS.minTapTarget)
                .background(
                    DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .strokeBorder(DS.separator, lineWidth: 1)
                )
        }
    }
}

private extension String {
    /// Lowercased, trailing-slash-stripped form for comparing server URLs so
    /// that e.g. `https://host/` and `https://host` match the same preset.
    var normalizedURL: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
