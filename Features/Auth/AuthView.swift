import SwiftUI

enum AuthPresentation {
    case settings
    case onboarding
}

struct AuthView: View {
    var presentation: AuthPresentation = .settings
    var onComplete: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var isRestoringSession = false

    @Environment(SyncManager.self) private var syncManager
    @Environment(\.appDismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Field?

    @State private var mode: AuthMode = .login
    @State private var username = ""
    @State private var email = ""
    @State private var identifier = ""
    @State private var password = ""
    @State private var resetToken = ""
    @State private var backendURL = ""
    @State private var showsPassword = false
    @State private var showsServerSettings = false
    @State private var serverSettingsExpanded = true

    @State private var requestedReset = false
    @State private var isSubmitting = false
    @State private var didComplete = false
    @State private var error: String?
    @State private var message: String?

    private enum Field: Hashable {
        case username, email, identifier, password, resetToken, server
    }

    var body: some View {
        Group {
            if presentation == .settings {
                AppNavigationStack {
                    settingsContent
                        .toolbar(.hidden, for: .navigationBar)
                }
            } else {
                formContent
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            backendURL = syncManager.backendURL
            if presentation == .settings, syncManager.currentUser != nil {
                complete()
            }
        }
        .onChange(of: syncManager.currentUser?.id) { _, id in
            if presentation == .settings, id != nil, !isSubmitting {
                complete()
            }
        }
        .onChange(of: error) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
        .onChange(of: message) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
        .appInteractiveDismissDisabled(isSubmitting)
        .background {
            if presentation == .onboarding {
                EdgeSwipeDismiss(edges: [.left]) {
                    guard !busy, !showsServerSettings else { return }
                    focused = nil
                    onBack?()
                }
            }
        }
        .appSheet(isPresented: $showsServerSettings) { serverSettingsSheet }
    }

    private var settingsContent: some View {
        ZStack {

            ScrollView {
                formContent
                    .padding(.horizontal, 24)
                    .padding(.vertical, 60)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .appBackdrop()
        .overlay(alignment: .topTrailing) {
            Button("Close") { dismiss() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(AppPlainButtonStyle())
                .padding(24)
                .disabled(busy)
        }
        .background(EdgeSwipeDismiss(edges: [.left]) {
            guard !busy, !showsServerSettings else { return }
            dismiss()
        })
    }

    private var formContent: some View {
        VStack(spacing: 28) {
            header
            if syncManager.currentUser != nil {
                signedInCard
            } else {
                formCard
            }
            footer
        }
        .foregroundStyle(.white)
        .buttonStyle(AppPlainButtonStyle())
    }

    private var header: some View {
        VStack(spacing: 8) {
            AppIcon(systemName: "sparkles", size: 44, relativeTo: .body)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(syncManager.currentUser != nil ? "You're signed in" : mode.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(syncManager.currentUser != nil ? "Ready to continue" : mode.subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }

    private var formCard: some View {
        VStack(spacing: 16) {
            credentials
            if mode == .login {
                Button("Forgot password?") { switchMode(.forgot) }
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            status
            submitButton
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .disabled(busy)
        .animation(AppMotion.glassMorph(reduceMotion: reduceMotion), value: mode)
    }

    @ViewBuilder
    private var credentials: some View {
        if mode == .register {
            field(icon: "person") {
                TextField("Username", text: $username)
                    .accessibilityLabel("Username")
                    .accessibilityHint("At least 3 characters")
                    .textContentType(.username)
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .email }
            }
        }
        if mode == .login {
            field(icon: "envelope") {
                TextField("Email or username", text: $identifier)
                    .accessibilityLabel("Email or username")
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .focused($focused, equals: .identifier)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
        } else if mode == .register || mode == .forgot {
            field(icon: "envelope") {
                TextField("Email", text: $email)
                    .accessibilityLabel("Email")
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .focused($focused, equals: .email)
                    .submitLabel(mode == .forgot ? .send : .next)
                    .onSubmit {
                        if mode == .forgot { startSubmit() }
                        else { focused = .password }
                    }
            }
        }
        if mode == .reset {
            field(icon: "key") {
                TextField("Reset token", text: $resetToken)
                    .accessibilityLabel("Reset token")
                    .accessibilityHint("Paste the token value from the reset link in your email")
                    .privacySensitive()
                    .focused($focused, equals: .resetToken)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
        }
        if mode != .forgot {
            passwordField
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(icon: "lock") {
                Group {
                    if showsPassword {
                        TextField(mode == .reset ? "New password" : "Password", text: $password)
                    } else {
                        SecureField(mode == .reset ? "New password" : "Password", text: $password)
                    }
                }
                .accessibilityLabel(mode == .reset ? "New password" : "Password")
                .textContentType(mode == .login ? .password : .newPassword)
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit(startSubmit)
                .privacySensitive()

                Button {
                    showsPassword.toggle()
                    focused = .password
                } label: {
                    AppIcon(systemName: showsPassword ? "eye.slash" : "eye", size: 17)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                .accessibilityValue(showsPassword ? "Visible" : "Hidden")
            }
            if mode == .register || mode == .reset {
                Text("At least 8 characters")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func field<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            AppIcon(systemName: icon, size: 17)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
                .foregroundStyle(.white)
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        if isRestoringSession {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking your account…")
                    .font(.footnote)
            }
            .accessibilityElement(children: .combine)
        }
        if let error {
            AppLabel(error, systemName: "exclamationmark.circle", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(AppTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message {
            AppLabel(message, systemName: "checkmark.circle", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var submitButton: some View {
        Button(action: startSubmit) {
            ZStack {
                if isSubmitting {
                    ProgressView()
                        .tint(.black)
                } else {
                    Text(mode.actionTitle)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
        }
        .accessibilityLabel(isSubmitting ? mode.progressTitle : mode.actionTitle)
        .disabled(busy || !hasRequiredFields)
        .opacity(hasRequiredFields ? 1 : 0.6)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            if syncManager.currentUser == nil {
                modeLinks
                Button("Server settings") {
                    focused = nil
                    showsServerSettings = true
                }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityHint("Advanced settings for a custom sync server")
            }
            if presentation == .onboarding {
                HStack(spacing: 24) {
                    if onBack != nil {
                        Button("Back") {
                            focused = nil
                            Haptics.shared.impact(.light)
                            onBack?()
                        }
                        .accessibilityHint("Returns to the introduction")
                    }
                    if syncManager.currentUser == nil {
                        Button("Not now", action: complete)
                            .accessibilityHint("Continue without an account. Cloud sync is optional.")
                    }
                }
                .font(.footnote)
                .frame(minHeight: 44)
            }
        }
        .foregroundStyle(.white)
        .disabled(isSubmitting || syncManager.isWorking)
    }

    @ViewBuilder
    private var modeLinks: some View {
        if mode == .login || mode == .register {
            HStack(spacing: 4) {
                Text(mode == .login ? "Don't have an account?" : "Already have an account?")
                    .foregroundStyle(.white.opacity(0.7))
                Button(mode == .login ? "Sign up" : "Sign in") {
                    switchMode(mode == .login ? .register : .login)
                }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            }
            .font(.footnote)
        } else {
            VStack(spacing: 16) {
                if mode == .forgot && requestedReset {
                    Button("I have a reset token") { switchMode(.reset) }
                        .fontWeight(.semibold)
                }
                Button("Back to sign in") { switchMode(.login) }
            }
            .font(.footnote)
        }
    }

    private var signedInCard: some View {
        VStack(spacing: 16) {
            AppLabel("Signed in as \(syncManager.currentUser?.displayUsername ?? syncManager.currentUser?.username ?? syncManager.currentUser?.email ?? "Reader")", systemName: "checkmark.circle", size: 15, relativeTo: .subheadline)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button(action: complete) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(busy)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var serverSettingsSheet: some View {
        AppNavigationStack {
            AppForm {
                DisclosureGroup(isExpanded: $serverSettingsExpanded) {
                    TextField("Server URL", text: $backendURL)
                        .accessibilityLabel("Server URL")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .server)
                        .submitLabel(.done)
                        .onSubmit { focused = nil }
                    if let serverValidationError {
                       AppLabel(serverValidationError, systemName: "exclamationmark.circle", size: 13, relativeTo: .footnote)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.destructive)
                    }
                    if backendURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http:") {
                       AppLabel("HTTP is not encrypted. Use HTTPS for a remote server.", systemName: "exclamationmark.shield", size: 13, relativeTo: .footnote)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.warning)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Server settings")
                        InfoButton(text: "Use the default server unless you host your own. Your credentials are sent to this server.")
                    }
                }
            }
            .appNavigationTitle("Server settings")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        focused = nil
                        showsServerSettings = false
                    }
                }
            }
        }
        .appPresentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var busy: Bool { isSubmitting || syncManager.isWorking || isRestoringSession }

    private var hasRequiredFields: Bool {
        switch mode {
        case .login: !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .register: !username.isEmpty && !email.isEmpty && !password.isEmpty
        case .forgot: !email.isEmpty
        case .reset: !resetToken.isEmpty && !password.isEmpty
        }
    }

    private var serverValidationError: String? {
        let server = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: server),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return "Enter a valid HTTP or HTTPS server URL in Server settings, without credentials, a query, or a fragment."
        }
        return nil
    }

    private var validationError: String? {
        if let serverValidationError { return serverValidationError }
        if mode == .register, username.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
            return "Choose a username with at least 3 characters."
        }
        if mode == .register || mode == .forgot {
            let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
            if parts.count != 2 || parts.contains(where: { $0.isEmpty }) || email.contains(where: { $0.isWhitespace }) {
                return "Enter a valid email address."
            }
        }
        if (mode == .register || mode == .reset) && password.count < 8 {
            return "Use a password with at least 8 characters."
        }
        if mode == .reset, resetToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Paste the reset token from your email."
        }
        return nil
    }

    private func switchMode(_ newMode: AuthMode) {
        guard !busy else { return }
        focused = nil
        error = nil
        message = nil
        showsPassword = false
        Haptics.shared.impact(.light)
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            mode = newMode
        }
    }

    private func startSubmit() {
        guard !busy, hasRequiredFields else { return }
        error = nil
        message = nil
        if let validationError {
            error = validationError
            return
        }
        focused = nil
        isSubmitting = true
        AccessibilityNotification.Announcement(mode.progressTitle).post()
        Task { await submit() }
    }

    private func submit() async {
        defer { isSubmitting = false }
        syncManager.updateBackendURL(backendURL.trimmingCharacters(in: .whitespacesAndNewlines))
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
        error = syncManager.lastError
        guard error == nil else { return }

        switch mode {
        case .login, .register:
            if syncManager.currentUser != nil {
                complete()
            } else {
                message = "Your request completed, but no signed-in session was returned. Try signing in again."
            }
        case .forgot:
            requestedReset = true
            message = "If an account uses this email, you'll receive a password reset link. You can enter its reset token below."
        case .reset:
            mode = .login
            password = ""
            resetToken = ""
            showsPassword = false
            message = "Password updated. Sign in with your new password."
        }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        focused = nil
        if let onComplete { onComplete() }
        else { dismiss() }
    }
}

private enum AuthMode {
    case login, register, forgot, reset

    var title: String {
        switch self {
        case .login: "Welcome back"
        case .register: "Create account"
        case .forgot: "Forgot your password?"
        case .reset: "Reset password"
        }
    }

    var subtitle: String {
        switch self {
        case .login: "Sign in to continue"
        case .register: "Sign up for optional cloud sync"
        case .forgot: "We'll email you a link to reset it."
        case .reset: "Enter your reset token and choose a new password."
        }
    }

    var actionTitle: String {
        switch self {
        case .login: "Sign in"
        case .register: "Create account"
        case .forgot: "Send reset link"
        case .reset: "Update password"
        }
    }

    var progressTitle: String {
        switch self {
        case .login: "Signing in…"
        case .register: "Creating your account…"
        case .forgot: "Requesting reset link…"
        case .reset: "Updating password…"
        }
    }
}
