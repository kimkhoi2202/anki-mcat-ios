import SwiftUI
import AnkiKit

/// Sync login screen, a close port of AnkiDroid's `LoginFragment`
/// (`res/layout/fragment_my_account.xml`): a hero logo, a username field with a
/// leading mail icon, a password field with a leading lock icon and a show/hide
/// toggle, a disabled-until-valid "Log In" button, and the AnkiWeb account links
/// (reset password, sign up, privacy, forgot email).
///
/// The sync **server** is chosen on the Settings screen (as in AnkiDroid, whose
/// custom sync server lives in Preferences), not here. Submitting calls
/// `sync_login` against that server; on success the host key is stored in the
/// Keychain and a sync is kicked off (AnkiDroid offers "Sync now?" after login).
struct LoginView: View {
    @ObservedObject var store: AnkiStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var usernameError: String?
    @State private var passwordError: String?
    @State private var usernameTouched = false
    @State private var passwordTouched = false
    @State private var submitting = false
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    // AnkiDroid validation strings (res/values: invalid_email, password_empty).
    private static let invalidEmail = "Enter a valid email"
    private static let passwordRequired = "Password is required"

    // AnkiWeb account links (AnkiDroid res/values/constants.xml).
    private static let resetPasswordURL = URL(string: "https://ankiweb.net/account/resetpw")!
    private static let signUpURL = URL(string: "https://ankiweb.net/account/register")!
    private static let privacyURL = URL(string: "https://ankiweb.net/account/privacy")!
    private static let forgotEmailURL = URL(
        string: "https://github.com/ankidroid/Anki-Android/wiki/FAQ#forgotten-ankiweb-email-instructions"
    )!

    /// Mirrors AnkiDroid's `loginButtonEnabled`: both fields non-empty.
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
                        hero
                        fields
                        if let error = store.loginErrorMessage {
                            errorBanner(error)
                        }
                        submitButton
                        links
                    }
                    .padding(DS.Spacing.l)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("AnkiWeb Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(submitting)
                }
            }
            .onChange(of: focused) { newValue in
                // Validate on blur and clear on focus, like AnkiDroid's
                // onUserNameFocusChange / onPasswordFocusChange. A field is only
                // flagged once it has actually been focused (touched), so we never
                // show an error before the user has had a chance to type.
                if newValue == .username { usernameTouched = true }
                if newValue == .password { passwordTouched = true }
                if newValue == .username {
                    usernameError = nil
                } else if usernameTouched, username.trimmingCharacters(in: .whitespaces).isEmpty {
                    usernameError = Self.invalidEmail
                }
                if newValue == .password {
                    passwordError = nil
                } else if passwordTouched, password.isEmpty {
                    passwordError = Self.passwordRequired
                }
            }
            .onAppear {
                username = store.syncUsername
                #if DEBUG
                if let user = UserDefaults.standard.string(forKey: "syncUser") { username = user }
                #endif
                focused = username.isEmpty ? .username : .password
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        // AnkiDroid's real login banner (res/drawable/login_logo): the sync
        // illustration — this device's collection (filled star) linked to AnkiWeb
        // (outlined star). Converted from AnkiDroid's source art.
        Image("AnkiLoginLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.m)
            .accessibilityLabel("AnkiDroid sync")
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: DS.Spacing.m) {
            LabeledField(title: "Username", error: usernameError) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "envelope")
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 20)
                    TextField("you@example.com", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .onChange(of: username) { _ in
                            if !username.trimmingCharacters(in: .whitespaces).isEmpty {
                                usernameError = nil
                            }
                        }
                }
            }
            LabeledField(title: "Password", error: passwordError) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "lock")
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 20)
                    passwordInput
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(DS.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
            }
        }
    }

    /// The password entry, switching between a masked `SecureField` and a plain
    /// `TextField` for the show/hide toggle (AnkiDroid's `password_toggle`).
    @ViewBuilder
    private var passwordInput: some View {
        Group {
            if showPassword {
                TextField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField("Password", text: $password)
            }
        }
        .textContentType(.password)
        .focused($focused, equals: .password)
        .submitLabel(.go)
        .onSubmit { submit() }
        .onChange(of: password) { _ in
            if !password.isEmpty { passwordError = nil }
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

    // MARK: - Links (AnkiDroid's AnkiWeb account links)

    private var links: some View {
        VStack(spacing: DS.Spacing.m) {
            Link("Reset password", destination: Self.resetPasswordURL)

            VStack(spacing: 2) {
                Text("Don’t have an AnkiWeb account? It’s free!")
                    .font(DS.Typography.caption.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                Text("Note: AnkiWeb is a separate service.")
                    .font(DS.Typography.caption)
                    .italic()
                    .foregroundStyle(DS.textSecondary)
            }
            .multilineTextAlignment(.center)

            Link("Sign up", destination: Self.signUpURL)

            HStack(spacing: DS.Spacing.l) {
                Link("Privacy", destination: Self.privacyURL)
                Link("Forgot Email?", destination: Self.forgotEmailURL)
            }
        }
        .font(DS.Typography.caption.weight(.medium))
        .tint(DS.accent)
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.s)
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
        usernameError = username.trimmingCharacters(in: .whitespaces).isEmpty ? Self.invalidEmail : nil
        passwordError = password.isEmpty ? Self.passwordRequired : nil
        guard canSubmit else { return }
        focused = nil
        submitting = true
        Task {
            let success = await store.login(username: username, password: password)
            submitting = false
            if success {
                dismiss()
                // Came here by pressing Sync, so sync right after logging in.
                store.startSync()
            }
        }
    }
}

/// A titled input row: a small caption label above a DesignSystem-styled field,
/// with an optional inline error message (and red border) below it.
private struct LabeledField<Content: View>: View {
    let title: String
    var error: String?
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
                        .strokeBorder(error == nil ? DS.separator : DS.again, lineWidth: 1)
                )
            if let error {
                Text(error)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.again)
                    .accessibilityLabel("Error: \(error)")
            }
        }
    }
}
