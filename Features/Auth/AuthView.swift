import SwiftUI

struct AuthView: View {
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AuthMode = .login
    @State private var username = ""
    @State private var email = ""
    @State private var identifier = ""
    @State private var password = ""
    @State private var resetToken = ""
    @State private var backendURL = ""

    var body: some View {
        @Bindable var syncManager = syncManager

        NavigationStack {
            Form {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(AuthMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                credentialsSection
                statusSection
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { submitBar }
            .onAppear {
                backendURL = syncManager.backendURL
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppIcon(systemName: "person.crop.circle.badge.checkmark", size: 22, relativeTo: .title2)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text("Sync your reader")
                .font(Typography.title)

            Text("Use one account for profile, sources, and non-local library entries.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var credentialsSection: some View {
        Section {
            if mode == .register {
                TextField("Username", text: $username)
                    .textContentType(.username)
            }

            if mode == .login {
                TextField("Email or username", text: $identifier)
                    .textContentType(.username)
            } else if mode == .register || mode == .forgot {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
            }

            if mode == .reset {
                TextField("Reset token", text: $resetToken)
            }

            if mode != .forgot {
                SecureField("Password", text: $password)
                    .textContentType(mode == .login ? .password : .newPassword)
            }

            TextField("Backend URL", text: $backendURL)
                .keyboardType(.URL)
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    @ViewBuilder
    private var statusSection: some View {
        if let error = syncManager.lastError {
            Section {
                AppLabel(error, systemName: "exclamationmark.circle", size: 13, relativeTo: .footnote)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.destructive)
            }
        } else if let message = syncManager.lastMessage {
            Section {
                AppLabel(message, systemName: "checkmark.circle", size: 13, relativeTo: .footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var submitBar: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 12) {
                if syncManager.isWorking {
                    ProgressView()
                }
                Text(mode.actionTitle)
                    .frame(maxWidth: .infinity)
            }
        }
        .primaryActionStyle()
        .controlSize(.large)
        .disabled(syncManager.isWorking || !canSubmit)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var canSubmit: Bool {
        switch mode {
        case .login:
            !identifier.isEmpty && password.count >= 8 && !backendURL.isEmpty
        case .register:
            username.count >= 3 && email.contains("@") && password.count >= 8 && !backendURL.isEmpty
        case .forgot:
            email.contains("@") && !backendURL.isEmpty
        case .reset:
            !resetToken.isEmpty && password.count >= 8 && !backendURL.isEmpty
        }
    }

    private func submit() async {
        syncManager.updateBackendURL(backendURL)
        switch mode {
        case .login:
            await syncManager.signIn(identifier: identifier, password: password)
        case .register:
            await syncManager.register(username: username, email: email, password: password)
        case .forgot:
            await syncManager.requestPasswordReset(email: email)
        case .reset:
            await syncManager.resetPassword(token: resetToken, newPassword: password)
        }

        if syncManager.currentUser != nil {
            dismiss()
        }
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case login
    case register
    case forgot
    case reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login: "Login"
        case .register: "Register"
        case .forgot: "Forgot"
        case .reset: "Reset"
        }
    }

    var actionTitle: String {
        switch self {
        case .login: "Login"
        case .register: "Create Account"
        case .forgot: "Send Reset Link"
        case .reset: "Reset Password"
        }
    }
}
