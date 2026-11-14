import SwiftUI

private enum OnboardingPalette {
    static let background = Color.black
    static let ink = Color.white
}

enum OnboardingStorage {
    static let completionKey = "onboarding.glassIntroCompleted"
}

/// Mount the real app before fading out the introduction, so its first frame
/// resolves behind the glass rather than appearing as an abrupt navigation cut.
struct OnboardingHost<Content: View>: View {
    @AppStorage(OnboardingStorage.completionKey) private var completed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                LiquidGlassOnboardingView {
                    guard !opening else { return }
                    if reduceMotion {
                        completed = true
                    } else {
                        opening = true
                    }
                }
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
}

/// A reversible, finger-driven lens, not a timed approximation of the swipe.
struct LiquidGlassOnboardingView: View {
    var onComplete: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lens = OnboardingGeometry.dome(width: 390, height: 844)
    @State private var progress = 0.0
    @State private var docked = false
    @State private var dragging = false
    @State private var gestureAccepted = false
    @State private var fountainStart: Date?
    @State private var fountainPushedUp = false
    @State private var launchID = 0
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 36

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // One sampled scene: covers and lettering cannot accidentally
                // render above the lens or drift between two separate timelines.
                RefractingOnboardingLens(
                    metrics: lens, size: size, reduceTransparency: reduceTransparency,
                    canvas: background(in: size)
                )
                .allowsHitTesting(false)

                Text("SWIPE UP TO ENTER")
                    .font(Typography.small)
                    .tracking(2.2)
                    .position(x: size.width / 2, y: size.height * 0.92)
                    .opacity(introVisibility)
                    .blur(radius: reduceMotion ? 0 : (1 - introVisibility) * 8)
                    .allowsHitTesting(false)

                controls(safeArea: geometry.safeAreaInsets)
            }
            .foregroundStyle(OnboardingPalette.ink)
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(.rect)
            .simultaneousGesture(dragGesture(in: size))
            .onAppear { reset(in: size) }
            .onChange(of: size) { _, newSize in
                guard !dragging else { return }
                lens = docked ? dock(in: newSize) : dome(in: newSize)
            }
            .task(id: launchID) {
                guard docked, !dragging, fountainStart == nil else { return }
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 450)) }
                catch { return }
                guard !Task.isCancelled, docked, !dragging else { return }
                fountainStart = .now
            }
            .accessibilityAction(named: Text("Lift glass and reveal")) { settle(dock: true, in: size) }
            .accessibilityAction(named: Text("Reset glass")) { reset(in: size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .accessibilityLabel("LNReader introduction")
    }

    private var introVisibility: Double { max(0, 1 - progress / 0.18) }
    private var titleVisibility: Double { OnboardingGeometry.titleVisibility(progress: progress) }

    private func background(in size: CGSize) -> some View {
        ZStack {
            OnboardingPalette.background
            Text("A new chapter\nstarts here.")
                .font(Typography.title)
                .fontDesign(.serif)
                .multilineTextAlignment(.center)
                .position(x: size.width / 2, y: size.height * 0.48)
                .opacity(introVisibility)
                .blur(radius: reduceMotion ? 0 : (1 - introVisibility) * 16)

            OnboardingFountain(start: fountainStart, size: size,
                               pushedUp: fountainPushedUp, reduceMotion: reduceMotion)

            // Appears before the rising lens crosses it, so the real fixed title
            // is bent by the glass rather than a separate copy following a finger.
            OnboardingTitle(size: titleSize)
                .position(x: size.width / 2, y: size.height * 0.52)
                .opacity(titleVisibility)
                .blur(radius: reduceMotion ? 0 : (1 - titleVisibility) * 8)

            Text("Your next story awaits.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .position(x: size.width / 2, y: size.height * 0.575)
                .opacity(docked && !dragging ? 1 : 0)
                .blur(radius: reduceMotion || (docked && !dragging) ? 0 : 10)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func controls(safeArea: EdgeInsets) -> some View {
        VStack {
            HStack {
                Spacer()
                Button("Skip", action: onComplete)
                    .font(Typography.caption)
                    .padding(12)
                    .contentShape(.rect)
            }
            .padding(.top, max(safeArea.top, 44))
            Spacer()
            if docked && !dragging {
                Button("Continue", action: onComplete)
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .primaryActionStyle()
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(safeArea.bottom, 24) + 12)
                    .transition(.opacity)
            }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !dragging {
                    let dx = (value.startLocation.x - lens.x) / max(lens.rx + 24, 1)
                    let dy = (value.startLocation.y - lens.y) / max(lens.ry + 24, 1)
                    gestureAccepted = dx * dx + dy * dy <= 1
                    guard gestureAccepted else { return }
                    dragging = true
                    launchID += 1
                    Haptics.shared.impact(.soft)
                    withAnimation(AppMotion.onboardingSettle(reduceMotion: reduceMotion)) {
                        fountainPushedUp = fountainStart != nil
                    }
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
                guard gestureAccepted else { return }
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
            // Once emitted, the canopy stays at the ceiling when scrubbing back.
        }
        launchID += 1
    }

    private func reset(in size: CGSize) {
        dragging = false
        gestureAccepted = false
        docked = false
        progress = 0
        fountainStart = nil
        fountainPushedUp = false
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
        (Text("Meet ") + Text("LNReader.").italic())
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
    let canvas: Canvas

    var animatableData: OnboardingLensMetrics {
        get { metrics }
        set { metrics = newValue }
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
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
                        .float(metrics.power), .float(metrics.dispersion)
                    ), maxSampleOffset: CGSize(width: 160, height: 160))
            }
            Ellipse()
                .stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.08), .white.opacity(0.36)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .frame(width: max(metrics.rx * 2, 1), height: max(metrics.ry * 2, 1))
                .position(x: metrics.x, y: metrics.y)
        }
        .frame(width: size.width, height: size.height)
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
