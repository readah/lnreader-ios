import SwiftUI
import UIKit

private enum OnboardingPalette {
    static let background = Color.black
    static let ink = Color.white
}

enum OnboardingStorage {
    static let completionKey = "onboarding.glassIntroCompleted"
}

enum OnboardingEntryPoint {
    case intro
    case signIn
}

/// Mount the real app before fading out the introduction, so its first frame
/// resolves behind the glass rather than appearing as an abrupt navigation cut.
struct OnboardingHost<Content: View>: View {
    @AppStorage(OnboardingStorage.completionKey) private var completed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SyncManager.self) private var syncManager
    @State private var sessionChecked = false
    @State private var opening = false
    @State private var revealed = false
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            if completed || opening {
                content
                    .blur(radius: completed || revealed ? 0 : 8)
                    .opacity(completed || revealed ? 1 : 0)
                    .allowsHitTesting(completed)
                    .accessibilityHidden(!completed)
            }
            if !completed {
                LiquidGlassOnboardingView(onComplete: finish, isRestoringSession: !sessionChecked)
                    .blur(radius: revealed ? 5 : 0)
                    .opacity(revealed ? 0 : 1)
                    .allowsHitTesting(!opening)
                    .accessibilityHidden(opening)
            }
        }
        .background(.black)
        .onChange(of: completed) { _, isComplete in
            // Restarting the intro clears the flag while this host is still
            // mounted. Put the exit animation back at its start, or the
            // overlay returns fully transparent and swallows every touch.
            guard !isComplete else { return }
            opening = false
            revealed = false
        }
        .task(id: completed) {
            guard !completed else { return }
            sessionChecked = false
            await syncManager.loadSession()
            guard !Task.isCancelled else { return }
            sessionChecked = true
        }
        .task(id: opening) {
            guard opening else { return }
            // Give the inserted app a layout pass at its initial blur/opacity.
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch { return }
            withAnimation(AppMotion.onboardingExit(reduceMotion: reduceMotion)) {
                revealed = true
            }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            completed = true
            opening = false
        }
    }


    private func finish() {
        guard !opening else { return }
        if reduceMotion { completed = true }
        else { opening = true }
    }
}


/// A reversible, finger-driven lens, not a timed approximation of the swipe.
struct LiquidGlassOnboardingView: View {
    var onComplete: () -> Void = {}
    var isRestoringSession = false
    let entryPoint: OnboardingEntryPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(SyncManager.self) private var syncManager
    @State private var lens = OnboardingGeometry.dome(width: 390, height: 844)
    @State private var progress = 0.0
    @State private var docked = false
    @State private var dragging = false
    @State private var gestureAccepted = false
    @State private var fountainStart: Date?

    @State private var launchID = 0
    @State private var showingSetup = false
    @State private var setup = OnboardingSetup()
    @State private var sceneSize = CGSize(width: 390, height: 844)
    @State private var sceneFrame = CGRect.zero
    @State private var keyboardLift: CGFloat = 0
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 36

    init(onComplete: @escaping () -> Void = {}, isRestoringSession: Bool = false,
         entryPoint: OnboardingEntryPoint = .intro) {
        self.onComplete = onComplete
        self.isRestoringSession = isRestoringSession
        self.entryPoint = entryPoint
        let setup = OnboardingSetup()
        let signingIn = entryPoint == .signIn
        if signingIn { setup.step = .identifier }
        _setup = State(initialValue: setup)
        _showingSetup = State(initialValue: signingIn)
        _docked = State(initialValue: signingIn)
        _progress = State(initialValue: signingIn ? 1 : 0)
        // A Settings entry resumes the settled canopy instead of replaying the intro.
        _fountainStart = State(initialValue: signingIn ? Date().addingTimeInterval(-4) : nil)
    }

    var body: some View {
        ZStack {
            // Keyboard avoidance belongs to the controls, not the scene. Keeping
            // this geometry fixed prevents the floating covers from jumping.
            GeometryReader { geometry in
                scene(in: geometry.size)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        sceneFrame = frame
                    }
                    .contentShape(.rect)
                    .simultaneousGesture(dragGesture(in: geometry.size))
                    .onAppear {
                        sceneSize = geometry.size
                        if entryPoint == .signIn {
                            lens = dock(in: geometry.size)
                        } else {
                            reset(in: geometry.size)
                        }
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        sceneSize = newSize
                        guard !dragging else { return }
                        lens = docked ? dock(in: newSize) : dome(in: newSize)
                    }
            }
            .ignoresSafeArea()

            GeometryReader { geometry in
                controls(availableHeight: geometry.size.height)
            }
        }
        .foregroundStyle(OnboardingPalette.ink)
        .environment(\.noLiquidGlass, false)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let overlap = sceneFrame.intersection(frame)
            let height = overlap.isNull ? 0 : overlap.height
            withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
                keyboardLift = min(height * 0.5, 164)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(AppMotion.onboardingControl(reduceMotion: reduceMotion)) {
                keyboardLift = 0
            }
        }
        .task(id: launchID) {
            guard docked, !dragging, fountainStart == nil else { return }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 450)) }
            catch { return }
            guard !Task.isCancelled, docked, !dragging else { return }
            fountainStart = .now
        }
        .accessibilityAction(named: Text("Lift glass and reveal")) {
            guard !showingSetup else { return }
            settle(dock: true, in: sceneSize)
        }
    }

    private func scene(in size: CGSize) -> some View {
        ZStack {
            RefractingOnboardingLens(
                metrics: lens, size: size, reduceTransparency: reduceTransparency,
                titleSize: titleSize,
                lensTitleOpacity: dragging ? (1 - titleVisibility) * OnboardingGeometry.smooth(0.04, 0.18, progress) : 0,
                isEnabled: !showingSetup,
                canvas: background(in: size)
            )
            .allowsHitTesting(false)

            Text("SWIPE UP TO ENTER")
                .font(Typography.small)
                .tracking(2.2)
                .position(x: size.width / 2, y: size.height * 0.92)
                .opacity(showingSetup ? 0 : introVisibility)
                .blur(radius: reduceMotion ? 0 : (1 - introVisibility) * 8)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var introVisibility: Double { max(0, 1 - progress / 0.18) }
    private var titleVisibility: Double { OnboardingGeometry.titleVisibility(progress: progress) }

    private func background(in size: CGSize) -> some View {
        ZStack {
            OnboardingBackdrop()
            Text("A new chapter\nstarts here.")
                .font(Typography.title)
                .fontDesign(.serif)
                .multilineTextAlignment(.center)
                .position(x: size.width / 2, y: size.height * 0.48)
                .opacity(showingSetup ? 0 : introVisibility)
                .blur(radius: reduceMotion ? 0 : (1 - introVisibility) * 16)

            OnboardingFountain(start: fountainStart, size: size, reduceMotion: reduceMotion)
                // Animate a view transform, not a Boolean inside Canvas drawing.
                // The fountain keeps its clock, textures and gentle floating motion.
                .offset(y: showingSetup ? -min(size.height * 0.075, 64) - keyboardLift : 0)

            // The lens-only lettering crossfades into this fixed destination
            // title before the rising sphere reaches the middle of the page.
            OnboardingTitle(size: titleSize)
                .position(x: size.width / 2, y: size.height * 0.52)
                .opacity(showingSetup ? 0 : titleVisibility)
                .blur(radius: reduceMotion ? 0 : (1 - titleVisibility) * 8)

            Text("Your next story awaits.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .position(x: size.width / 2, y: size.height * 0.575)
                .opacity(!showingSetup && docked && !dragging ? 1 : 0)
                .blur(radius: reduceMotion || (docked && !dragging) ? 0 : 10)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var continueVisible: Bool { showingSetup || (docked && !dragging) }
    private var waitingForSession: Bool {
        showingSetup && setup.step == .password && isRestoringSession
    }

    private func controls(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            navigationControls
            if showingSetup {
                ScrollView {
                    OnboardingSetupContent(setup: setup, onSubmit: advance)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 28)
                        .padding(.top, min(sceneSize.height * 0.22, availableHeight * 0.24))
                        .padding(.bottom, 28)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .transition(.opacity)
                .disabled(setup.isSubmitting)
            } else {
                Spacer()
            }
            continueButton
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background {
            if showingSetup {
                EdgeSwipeDismiss(edges: [.left]) {
                    guard !setup.isSubmitting, !syncManager.isWorking else { return }
                    goBack()
                }
            }
        }
    }

    private var navigationControls: some View {
        HStack {
            if showingSetup {
                Button(action: goBack) {
                    AppIcon(systemName: "chevron.left", size: 18)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            Button(entryPoint == .signIn ? "Close" : (showingSetup ? "Not now" : "Skip")) {
                if showingSetup { onComplete() }
                else { revealSetup() }
            }
            .font(Typography.caption)
            .frame(minHeight: 44)
        }
        .buttonStyle(AppPlainButtonStyle())
        .padding(.horizontal, 20)
        .disabled(setup.isSubmitting || syncManager.isWorking)
    }

    private var continueButton: some View {
        Button(action: advance) {
            HStack {
                Text("Continue")
                Spacer()
                if setup.isSubmitting || waitingForSession {
                    ProgressView()
                } else {
                    AppIcon(systemName: "arrow.right", size: 22, relativeTo: .title2)
                }
            }
            .font(Typography.title)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .primaryActionStyle()
        .appUnblurVisibility(continueVisible)
        .padding(.horizontal, 16)
        .blur(radius: reduceMotion || continueVisible ? 0 : 12)
        .opacity(continueVisible ? 1 : 0)
        .offset(y: reduceMotion || continueVisible ? 0 : 14)
        .disabled(showingSetup && (!setup.canContinue || syncManager.isWorking || waitingForSession))
        .allowsHitTesting(continueVisible)
        .accessibilityHidden(!continueVisible)
        .animation(AppMotion.onboardingControl(reduceMotion: reduceMotion), value: continueVisible)
    }

    private func advance() {
        guard !setup.isSubmitting, !syncManager.isWorking, !waitingForSession else { return }
        Haptics.shared.impact(.light)
        guard showingSetup else {
            revealSetup()
            return
        }
        Task {
            await setup.advance(sync: syncManager, reduceMotion: reduceMotion, onComplete: onComplete)
        }
    }

    private func revealSetup() {
        withAnimation(AppMotion.onboardingSettle(reduceMotion: reduceMotion)) {
            showingSetup = true
            dragging = false
            docked = true
            progress = 1
            lens = dock(in: sceneSize)
        }
        if fountainStart == nil { fountainStart = .now }
    }

    private func goBack() {
        guard !setup.isSubmitting, !syncManager.isWorking else { return }
        Haptics.shared.impact(.light)
        if entryPoint == .signIn {
            switch setup.step {
            case .identifier, .signedIn, .icons:
                onComplete()
                return
            case .username:
                setup.beginSignIn(reduceMotion: reduceMotion)
                return
            case .email, .password:
                break
            }
        }
        guard !setup.back(reduceMotion: reduceMotion) else { return }
        withAnimation(AppMotion.onboardingSettle(reduceMotion: reduceMotion)) {
            showingSetup = false
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !showingSetup else { return }
                if !dragging {
                    let dx = (value.startLocation.x - lens.x) / max(lens.rx + 24, 1)
                    let dy = (value.startLocation.y - lens.y) / max(lens.ry + 24, 1)
                    gestureAccepted = dx * dx + dy * dy <= 1
                    guard gestureAccepted else { return }
                    dragging = true
                    launchID += 1
                    Haptics.shared.impact(.soft)

                }
                guard gestureAccepted else { return }
                progress = OnboardingGeometry.progress(y: value.location.y, height: size.height)
                let target = OnboardingGeometry.drag(x: value.location.x, y: value.location.y,
                                                     width: size.width, height: size.height)
                withAnimation(AppMotion.onboardingTracking(reduceMotion: reduceMotion)) {
                    lens = target
                }
            }
            .onEnded { value in
                guard !showingSetup, gestureAccepted else { return }
                gestureAccepted = false
                let shouldDock = OnboardingGeometry.shouldDock(
                    y: value.location.y, predictedY: value.predictedEndLocation.y, height: size.height)
                settle(dock: shouldDock, in: size)
            }
    }

    private func settle(dock shouldDock: Bool, in size: CGSize) {
        Haptics.shared.impact(.light)
        withAnimation(AppMotion.onboardingSettle(reduceMotion: reduceMotion)) {
            dragging = false
            docked = shouldDock
            progress = shouldDock ? 1 : 0
            lens = shouldDock ? dock(in: size) : dome(in: size)

        }
        launchID += 1
    }

    private func reset(in size: CGSize) {
        dragging = false
        gestureAccepted = false
        docked = false
        progress = 0
        fountainStart = nil

        launchID += 1
        lens = dome(in: size)
    }

    private func dome(in size: CGSize) -> OnboardingLensMetrics {
        OnboardingGeometry.dome(width: size.width, height: size.height)
    }

    private func dock(in size: CGSize) -> OnboardingLensMetrics {
        OnboardingGeometry.dock(width: size.width, height: size.height)
    }
}

private struct OnboardingTitle: View {
    let size: CGFloat

    var body: some View {
        Text("Meet \(Text("LNReader.").italic())")
            .font(.system(size: size, weight: .light, design: .serif))
            .foregroundStyle(OnboardingPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 12)
    }
}

/// Interpolate the shader uniforms themselves, not just the SwiftUI frame.
private struct RefractingOnboardingLens<Canvas: View>: View, Animatable {
    var metrics: OnboardingLensMetrics
    let size: CGSize
    let reduceTransparency: Bool
    let titleSize: CGFloat
    let lensTitleOpacity: Double
    var isEnabled = true
    let canvas: Canvas

    var animatableData: OnboardingLensMetrics {
        get { metrics }
        set { metrics = newValue }
    }

    var body: some View {
        ZStack {
            if reduceTransparency && isEnabled {
                canvas
                Ellipse()
                    .fill(AppTheme.surface)
                    .frame(width: max(metrics.rx * 2, 1), height: max(metrics.ry * 2, 1))
                    .position(x: metrics.x, y: metrics.y)
            } else {
                canvas
                    .compositingGroup()
                    .layerEffect(ShaderLibrary.liquidGlassLens(
                        .float2(metrics.x, metrics.y),
                        .float2(metrics.rx, metrics.ry),
                        .float(metrics.power), .float(metrics.dispersion), .float(0)
                    ), maxSampleOffset: CGSize(width: 160, height: 160), isEnabled: isEnabled)
                if isEnabled && lensTitleOpacity > 0 {
                    hiddenLensTitle
                        .opacity(lensTitleOpacity)
                        .accessibilityHidden(true)
                }
            }
            Ellipse()
                .stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.08), .white.opacity(0.36)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .frame(width: max(metrics.rx * 2, 1), height: max(metrics.ry * 2, 1))
                .position(x: metrics.x, y: metrics.y)
                .opacity(isEnabled ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
    }

    private var hiddenLensTitle: some View {
        // The padded sampling region contains the full lettering. The shader
        // clips AFTER refraction and preserves alpha, leaving covers underneath.
        OnboardingTitle(size: titleSize)
            .frame(width: max(metrics.rx * 2, 1) + 320,
                   height: max(metrics.ry * 2, 1) + 320)
            .compositingGroup()
            .layerEffect(ShaderLibrary.liquidGlassLens(
                .float2(metrics.rx + 160, metrics.ry + 160),
                .float2(metrics.rx, metrics.ry),
                .float(metrics.power), .float(metrics.dispersion), .float(1)
            ), maxSampleOffset: CGSize(width: 160, height: 160))
            .position(x: metrics.x, y: metrics.y)
    }
}

extension OnboardingLensMetrics: VectorArithmetic {
    static var zero: Self { Self(x: 0, y: 0, rx: 0, ry: 0, power: 0, dispersion: 0) }
    static func + (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        result.values += rhs.values
        return result
    }
    static func - (lhs: Self, rhs: Self) -> Self {
        var result = lhs
        result.values -= rhs.values
        return result
    }
    mutating func scale(by rhs: Double) { values *= SIMD8(repeating: rhs) }
    var magnitudeSquared: Double { (0..<8).reduce(0) { $0 + values[$1] * values[$1] } }
}

#Preview {
    LiquidGlassOnboardingView()
}
