import Observation
import SwiftUI

@Observable
@MainActor
final class OnboardingSetup {
    enum Step: Hashable {
        case icons, identifier, username, email, password, signedIn
    }

    enum Mode: Hashable {
        case signIn, register
    }

    var step: Step = .icons
    var mode: Mode = .signIn
    var identifier = ""
    var username = ""
    var email = ""
    var password = ""
    var isSubmitting = false
    var error: String?

    // Invalid input is explained on submission, rather than silently disabling Continue.
    var canContinue: Bool { !isSubmitting }

    func advance(sync: SyncManager, reduceMotion: Bool, onComplete: @escaping () -> Void) async {
        guard !isSubmitting else { return }
        error = nil

        switch step {
        case .icons:
            if sync.currentUser != nil {
                changeStep(.signedIn, reduceMotion: reduceMotion)
            } else {
                beginSignIn(reduceMotion: reduceMotion)
            }
        case .identifier:
            identifier = trimmed(identifier)
            guard !identifier.isEmpty else {
                error = "Enter your username or email to continue."
                return
            }
            changeStep(.password, reduceMotion: reduceMotion)
        case .username:
            username = trimmed(username)
            guard username.count >= 3 else {
                error = "Choose a username with at least 3 characters."
                return
            }
            changeStep(.email, reduceMotion: reduceMotion)
        case .email:
            email = trimmed(email)
            guard validEmail(email) else {
                error = "Enter a valid email address to continue."
                return
            }
            changeStep(.password, reduceMotion: reduceMotion)
        case .password:
            guard !password.isEmpty else {
                error = "Enter your password to continue."
                return
            }
            if mode == .signIn {
                identifier = trimmed(identifier)
                guard !identifier.isEmpty else {
                    changeStep(.identifier, reduceMotion: reduceMotion)
                    error = "Enter your username or email to continue."
                    return
                }
            } else {
                username = trimmed(username)
                email = trimmed(email)
                guard username.count >= 3 else {
                    changeStep(.username, reduceMotion: reduceMotion)
                    error = "Choose a username with at least 3 characters."
                    return
                }
                guard validEmail(email) else {
                    changeStep(.email, reduceMotion: reduceMotion)
                    error = "Enter a valid email address to continue."
                    return
                }
            }

            if mode == .register && password.count < 8 {
                error = "Use a password with at least 8 characters."
                return
            }

            isSubmitting = true
            defer { isSubmitting = false }
            if mode == .signIn {
                await sync.signIn(identifier: identifier, password: password)
            } else {
                await sync.register(username: username, email: email, password: password)
            }
            guard sync.currentUser != nil else {
                error = sync.lastError ?? "We couldn’t confirm your session. Please try again."
                return
            }
            changeStep(.signedIn, reduceMotion: reduceMotion)
        case .signedIn:
            guard sync.currentUser != nil else {
                beginSignIn(reduceMotion: reduceMotion)
                error = "Your session has ended. Please sign in again."
                return
            }
            onComplete()
        }
    }

    func back(reduceMotion: Bool) -> Bool {
        guard !isSubmitting else { return true }
        switch step {
        case .icons:
            return false
        case .identifier, .username, .signedIn:
            changeStep(.icons, reduceMotion: reduceMotion)
        case .email:
            changeStep(.username, reduceMotion: reduceMotion)
        case .password:
            changeStep(mode == .signIn ? .identifier : .email, reduceMotion: reduceMotion)
        }
        return true
    }

    func beginRegistration(reduceMotion: Bool) {
        guard !isSubmitting else { return }
        withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
            mode = .register
            step = .username
            error = nil
        }
    }

    func beginSignIn(reduceMotion: Bool) {
        guard !isSubmitting else { return }
        withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
            mode = .signIn
            step = .identifier
            error = nil
        }
    }

    private func changeStep(_ next: Step, reduceMotion: Bool) {
        withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
            step = next
            error = nil
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !value.contains(where: { $0.isWhitespace })
    }
}

struct OnboardingSetupContent: View {
    @Bindable var setup: OnboardingSetup
    var onSubmit: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(IconPack.storageKey) private var packRaw = IconPack.swiftIcons.rawValue
    @ScaledMetric(relativeTo: .largeTitle) private var fieldSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var previewSize: CGFloat = 56
    @FocusState private var focusedField: OnboardingSetup.Step?
    @State private var showsPassword = false


    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch setup.step {
            case .icons:
                iconChoices
            case .signedIn:
                Text("You’re signed in")
                    .font(Typography.largeTitle)
                    .accessibilityAddTraits(.isHeader)
            case .identifier, .username, .email, .password:
                credentialContent
            }

            if let error = setup.error {
                Text(error)
                    .font(Typography.body)
                    .foregroundStyle(AppTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appReveal(trigger: setup.step)
        .onChange(of: setup.step, initial: true) { _, step in
            showsPassword = false
            switch step {
            case .icons, .signedIn:
                focusedField = nil
            case .identifier, .username, .email, .password:
                focusedField = step
            }
        }

        .onChange(of: setup.error) { _, error in
            if let error {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }

    private var iconChoices: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Choose Icons")
                .font(Typography.largeTitle)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 20) {
                ForEach(IconPack.allCases) { pack in
                    Button {
                        Haptics.shared.selection()
                        withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
                            packRaw = pack.rawValue
                        }
                    } label: {
                        VStack(spacing: 18) {
                            previewIcon("books.vertical", pack: pack)
                                .frame(width: min(previewSize, 72), height: min(previewSize, 72))
                            Rectangle()
                                .fill(selectedPack == pack ? Color.primary : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(pack.displayName)
                    .accessibilityAddTraits(selectedPack == pack ? .isSelected : [])
                }
            }
        }
    }

    private var selectedPack: IconPack {
        IconPack(rawValue: packRaw) ?? .swiftIcons
    }

    @ViewBuilder
    private func previewIcon(_ symbol: String, pack: IconPack) -> some View {
        switch pack {
        case .swiftIcons:
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
        case .paperIcons:
            if let asset = IconPackCatalog.paperAsset(for: symbol) {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
            }
        case .modernArt:
            Image(IconPackCatalog.modernArtAsset(for: symbol))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        }
    }

    private var credentialContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    credentialField
                        .font(.system(size: fieldSize, weight: .light, design: .default))
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(setup.step == .password ? .go : .next)
                        .onSubmit(onSubmit)

                    if setup.step == .password {
                        Button {
                            showsPassword.toggle()
                            focusedField = .password
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .font(Typography.headline)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                    }
                }
                Rectangle()
                    .fill(AppTheme.hairline)
                    .frame(height: 1)
            }
            .disabled(setup.isSubmitting)

            accountModePrompt
                .disabled(setup.isSubmitting)
        }
    }

    @ViewBuilder
    private var credentialField: some View {
        switch setup.step {
        case .identifier:
            TextField("Enter your username", text: $setup.identifier)
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .accessibilityLabel("Username or email")
                .focused($focusedField, equals: .identifier)
        case .username:
            TextField("Enter your username", text: $setup.username)
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .focused($focusedField, equals: .username)
        case .email:
            TextField("Enter your email", text: $setup.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .focused($focusedField, equals: .email)
        case .password:
            Group {
                if showsPassword {
                    TextField("Enter your password", text: $setup.password)
                } else {
                    SecureField("Enter your password", text: $setup.password)
                }
            }
            .textContentType(setup.mode == .register ? .newPassword : .password)
            .focused($focusedField, equals: .password)
        case .icons, .signedIn:
            EmptyView()
        }
    }

    private var accountModePrompt: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                accountPromptText
                accountModeButton
            }
            VStack(alignment: .leading, spacing: 6) {
                accountPromptText
                accountModeButton
            }
        }
        .font(Typography.body)
    }

    private var accountPromptText: some View {
        Text(setup.mode == .signIn ? "New to LNReader?" : "Already have an account?")
            .foregroundStyle(.secondary)
    }

    private var accountModeButton: some View {
        Button(setup.mode == .signIn ? "Create a new account" : "Sign in") {
            if setup.mode == .signIn {
                setup.beginRegistration(reduceMotion: reduceMotion)
            } else {
                setup.beginSignIn(reduceMotion: reduceMotion)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .underline()
    }
}
