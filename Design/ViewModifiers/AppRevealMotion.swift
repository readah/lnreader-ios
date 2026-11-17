import SwiftUI

/// Independent of the material preference, and inherited by onboarding too.
enum RevealMotion {
    static let enabledKey = "appearance.springUnblurMotion"
}

private struct SpringUnblurMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var springUnblurMotion: Bool {
        get { self[SpringUnblurMotionKey.self] }
        set { self[SpringUnblurMotionKey.self] = newValue }
    }
}

extension AppMotion {
    static func reveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.88)
    }
}

private struct SpringUnblurTransition: ViewModifier {
    var hidden: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 9 : 0)
            .scaleEffect(hidden ? 0.96 : 1)
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 14 : 0)
    }
}

extension AnyTransition {
    static var appSpringUnblur: AnyTransition {
        .modifier(active: SpringUnblurTransition(hidden: true), identity: SpringUnblurTransition(hidden: false))
    }
}

extension View {
    /// Animate an arrival, not scrolling or model updates. A new trigger replays
    /// the reveal without changing identity, focus, navigation, or form state.
    func appReveal<Trigger: Hashable>(trigger: Trigger, edge: Edge = .bottom) -> some View {
        modifier(AppRevealModifier(trigger: trigger, edge: edge))
    }

    func appReveal(edge: Edge = .bottom) -> some View {
        appReveal(trigger: false, edge: edge)
    }

    /// For reader chrome kept mounted while hidden. Does not affect its hit
    /// testing or visibility; those remain the caller's responsibility.
    func appUnblurVisibility(_ visible: Bool, edge: Edge = .bottom) -> some View {
        modifier(UnblurVisibilityModifier(visible: visible, edge: edge))
    }
}

private struct RevealIdentity<Trigger: Hashable>: Hashable {
    let trigger: Trigger
    let enabled: Bool
    let reduceMotion: Bool
}

private struct AppRevealModifier<Trigger: Hashable>: ViewModifier {
    @Environment(\.springUnblurMotion) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    let trigger: Trigger
    let edge: Edge

    private var active: Bool { enabled && !reduceMotion && !settled }

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 9 : 0)
            .opacity(active ? 0.55 : 1)
            .offset(x: active ? displacement.width : 0, y: active ? displacement.height : 0)
            .task(id: RevealIdentity(trigger: trigger, enabled: enabled, reduceMotion: reduceMotion)) {
                guard enabled, !reduceMotion else { settled = true; return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { settled = false }
                // Let the arriving layout paint once; no timers, per-frame state
                // updates or tasks survive a dismissed screen / changed trigger.
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) { settled = true }
            }
    }

    private var displacement: CGSize {
        switch edge {
        case .top: CGSize(width: 0, height: -12)
        case .bottom: CGSize(width: 0, height: 14)
        case .leading: CGSize(width: -14, height: 0)
        case .trailing: CGSize(width: 14, height: 0)
        }
    }
}

struct AppearanceMotionPreview: View {
    @Environment(\.springUnblurMotion) private var enabled
    @State private var replay = 0
    var body: some View {
        Button { replay += 1 } label: {
            HStack(spacing: 12) {
                AppIcon(systemName: "sparkles", size: 22)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("A softer arrival").font(Typography.headline)
                    Text("Tap to replay").font(Typography.caption)
                }
                Spacer()
                AppIcon(systemName: "arrow.clockwise", size: 16)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .appReveal(trigger: replay)
            .environment(\.springUnblurMotion, enabled && replay > 0)
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Replay spring and unblur preview")
    }
}

private struct UnblurVisibilityModifier: ViewModifier {
    @Environment(\.springUnblurMotion) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visible: Bool
    let edge: Edge

    private var active: Bool { enabled && !reduceMotion && !visible }
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .offset(y: active ? (edge == .top ? -12 : 12) : 0)
            .animation(enabled ? AppMotion.reveal(reduceMotion: reduceMotion) : nil, value: visible)
    }
}
