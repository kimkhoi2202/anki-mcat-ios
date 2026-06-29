import SwiftUI
import AnkiKit

/// Sync login screen, cloning AnkiDroid's `LoginFragment`: an email/username
/// field, a password field, and — adapted for self-hosted servers — an optional
/// custom server URL whose placeholder makes clear that the default is AnkiWeb.
///
/// Submitting calls `sync_login`; on success the host key is stored in the
/// Keychain and a sync is kicked off (AnkiDroid offers "Sync now?" after login).
struct LoginView: View {
    @ObservedObject var store: AnkiStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var serverURL = ""
    @State private var submitting = false
    @FocusState private var focused: Field?

    private enum Field { case username, password, server }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !submitting
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
                // Prefill from the stored account, or from launch arguments when
                // driving the login screen for automated screenshots.
                let defaults = UserDefaults.standard
                username = defaults.string(forKey: "syncUser") ?? store.syncUsername
                serverURL = defaults.string(forKey: "syncServer") ?? serverURL
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
                    .submitLabel(.next)
                    .onSubmit { focused = .server }
            }
            LabeledField(title: "Custom sync server (optional)") {
                TextField("https://sync.ankiweb.net (default)", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .server)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            }
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
                endpoint: serverURL
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
