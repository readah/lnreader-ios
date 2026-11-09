// Haptics.swift - Every vibration in the app goes through here.
//
// One place, so one switch turns them all off (Settings › General › Haptics)
// and one strength scales them all. The reader's cues are composed with Core
// Haptics: real transients and continuous events with intensity envelopes,
// tuned per cue, rather than the five stock impact styles. A device without a
// Taptic Engine that Core Haptics can drive gets the nearest stock feedback.
//
// When to fire is decided elsewhere (ScrollHaptics.swift for scrolling,
// MangaReaderControls.swift for hold to scroll); this file only decides how
// each cue feels.

import CoreHaptics
import SwiftUI
import UIKit

@MainActor
final class Haptics {
    static let shared = Haptics()

    nonisolated static let enabledKey = "general.haptics"
    nonisolated static let strengthKey = "general.hapticStrength"
    nonisolated static let scrollEnabledKey = "general.scrollHaptics"
    nonisolated static let strengthRange = 0.25...1.0

    /// Read on every cue, so flipping the setting takes effect at once.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The ticks, chapter knocks and end thuds of scrolling. Under the main
    /// switch: off there silences these too.
    nonisolated static var isScrollEnabled: Bool {
        isEnabled && (UserDefaults.standard.object(forKey: scrollEnabledKey) as? Bool ?? true)
    }

    nonisolated static var strength: Double {
        let stored = UserDefaults.standard.object(forKey: strengthKey) as? Double ?? 1
        return min(max(stored, strengthRange.lowerBound), strengthRange.upperBound)
    }

    enum Weight {
        case soft, light, medium, heavy, rigid

        var style: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .soft: .soft
            case .light: .light
            case .medium: .medium
            case .heavy: .heavy
            case .rigid: .rigid
            }
        }

        /// One notch softer, as taps are played.
        var gentled: Weight {
            switch self {
            case .soft, .light: .soft
            case .medium: .light
            case .heavy, .rigid: .medium
            }
        }
    }

    private let supportsEngine = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var engineNeedsStart = true
    private var isStartingEngine = false
    private var lastStartFailure: Date?
    /// The scroll swell's players, one per direction, built once and restarted
    /// for every tick: a tick can fire seventy times a second, and a new pattern
    /// and player each time is allocation and latency on the scroll's hot path.
    private var tickPlayers: [ScrollDirection: CHHapticPatternPlayer] = [:]
    private var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private lazy var selectionGenerator = UISelectionFeedbackGenerator()
    private lazy var notificationGenerator = UINotificationFeedbackGenerator()

    private init() {}

    // MARK: - Everyday feedback

    /// A tap of the given weight, for buttons, long presses and toggles.
    ///
    /// Deliberately gentler than stock UIKit feedback: one weight softer and
    /// well under full intensity, so reading controls never thump.
    func impact(_ weight: Weight, intensity: Double = 1) {
        guard Self.isEnabled else { return }
        let scaled = intensity * Self.strength * Self.tapIntensityScale
        generator(weight.gentled.style).impactOccurred(intensity: CGFloat(scaled))
    }

    /// How much of a tap's requested intensity actually reaches the device.
    private static let tapIntensityScale = 0.6

    /// The light tick of a value changing, as a picker wheel gives.
    func selection() {
        guard Self.isEnabled else { return }
        selectionGenerator.selectionChanged()
    }

    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard Self.isEnabled else { return }
        notificationGenerator.notificationOccurred(type)
    }

    /// Spin the engine up ahead of a burst of cues (a reader opening), so the
    /// first click is not late.
    func prepare() {
        guard Self.isEnabled else { return }
        if supportsEngine { _ = readyEngine() } else { generator(.light).prepare() }
    }

    // MARK: - Scrolling

    func scroll(_ cue: ScrollCue) {
        guard Self.isScrollEnabled else { return }
        let i = cue.intensity, s = cue.sharpness
        switch cue.kind {
        case .detent:
            tick(intensity: i, sharpness: s, direction: cue.direction)
        case .edge:
            // The hit, then a faint rebound as the content springs back.
            play([
                tap(0, i, s),
                hum(0, 0.09, i * 0.45, s * 0.5, fading: true),
                tap(0.075, i * 0.32, s * 0.7),
            ]) { impact(.soft, intensity: i) }
        case .chapter:
            chapterBreak(intensity: i, sharpness: s)
        }
    }

    /// A chapter boundary: a low knock, a brighter one, and a short swell
    /// under both that dies away. Distinct from any page click.
    func chapterBreak(intensity: Double = 0.85, sharpness: Double = 0.55) {
        guard Self.isEnabled else { return }
        play([
            tap(0, intensity * 0.6, sharpness * 0.5),
            tap(0.1, intensity, min(sharpness + 0.25, 1)),
            hum(0, 0.32, intensity * 0.35, 0.1, attack: 0.1, fading: true),
        ]) {
            impact(.medium, intensity: intensity)
        }
    }

    /// A page turn in the paged reader: a brief swish that settles into a click.
    func pageTurn() {
        guard Self.isEnabled else { return }
        play([
            hum(0, 0.06, 0.28, 0.6, attack: 0.06),
            tap(0.055, 0.6, 0.7),
        ]) { impact(.light, intensity: 0.7) }
    }

    // MARK: - Hold and auto scroll

    /// The hold caught: a quick spool-up that ends in a firm catch.
    func scrollEngaged() {
        guard Self.isEnabled else { return }
        play([
            hum(0, 0.13, 0.55, 0.25, attack: 0.13),
            tap(0.12, 0.8, 0.55),
        ]) { impact(.medium) }
    }

    /// The hold let go, or auto scroll stopped: the spool winding down.
    func scrollReleased() {
        guard Self.isEnabled else { return }
        play([
            tap(0, 0.45, 0.35),
            hum(0, 0.16, 0.35, 0.15, fading: true),
        ]) { impact(.soft, intensity: 0.6) }
    }

    /// The hold speed crossed a step. `level` is 0 at the slowest and 1 at
    /// the fastest: the clicks brighten as the speed climbs, like gears.
    func scrollSpeedStep(level: Double) {
        guard Self.isEnabled else { return }
        let t = min(max(level, 0), 1)
        play([tap(0, 0.32 + 0.3 * t, 0.2 + 0.7 * t)]) { selection() }
    }

    /// The hold speed hit its slowest or fastest: two hard knocks.
    func scrollSpeedLimit() {
        guard Self.isEnabled else { return }
        play([
            tap(0, 0.95, 0.85),
            tap(0.055, 0.7, 0.4),
        ]) { impact(.rigid) }
    }

    // MARK: - Playing

    /// One soft swell on the player cached for that direction. The pattern is a
    /// short continuous event with an intensity envelope rather than a hard
    /// transient — the same round, rising feel as Traverse's login button,
    /// compressed into a tick. Each tick's intensity and sharpness are set on
    /// the player as dynamic parameters just before it restarts.
    private func tick(intensity: Double, sharpness: Double, direction: ScrollDirection) {
        // .medium gentles to .light, keeping the fallback directions distinct.
        let fallbackWeight: Weight = direction == .forward ? .soft : .medium
        guard supportsEngine else {
            return impact(fallbackWeight, intensity: intensity)
        }
        guard let engine = readyEngine() else {
            // Engine is starting or backing off: skip the high-frequency scroll tick
            // rather than stalling the main thread or spamming stock impact generators.
            return
        }
        let parameters = [
            // A multiplier on the pattern's intensity envelope.
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: scaled(intensity), relativeTime: 0),
            // An offset, -1...1, added to the pattern's sharpness.
            CHHapticDynamicParameter(
                parameterID: .hapticSharpnessControl,
                value: clamp(sharpness) - direction.baseSharpness,
                relativeTime: 0
            ),
        ]
        func fire(on engine: CHHapticEngine) throws {
            if tickPlayers[direction] == nil {
                tickPlayers[direction] = try engine.makePlayer(with: Self.scrollSwellPattern(direction))
            }
            try tickPlayers[direction]?.sendParameters(parameters, atTime: CHHapticTimeImmediate)
            try tickPlayers[direction]?.start(atTime: CHHapticTimeImmediate)
        }
        do {
            try fire(on: engine)
        } catch {
            // The engine stopped or reset under the player. Invalidate and request restart.
            tickPlayers[direction] = nil
            engineNeedsStart = true
            _ = readyEngine()
        }
    }

    /// The scroll tick, 55 ms long. Reading on swells up and lets go at the
    /// peak; scrolling back is the same softness released downwards, so the two
    /// directions are told apart without either being louder than the other.
    private static func scrollSwellPattern(_ direction: ScrollDirection) throws -> CHHapticPattern {
        let duration: TimeInterval = 0.055
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: direction.baseSharpness),
            ],
            relativeTime: 0,
            duration: duration
        )
        let points: [CHHapticParameterCurve.ControlPoint] = switch direction {
        case .forward:
            [.init(relativeTime: 0, value: 0.05), .init(relativeTime: duration, value: 1)]
        case .backward:
            [.init(relativeTime: 0, value: 1), .init(relativeTime: duration, value: 0.05)]
        }
        let envelope = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: points,
            relativeTime: 0
        )
        return try CHHapticPattern(events: [event], parameterCurves: [envelope])
    }

    private func play(_ events: [CHHapticEvent], fallback: () -> Void) {
        guard supportsEngine else { return fallback() }
        guard let engine = readyEngine() else { return fallback() }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            do {
                try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            } catch {
                // The engine stopped without telling us (it was idle, or the
                // app was in the background). Mark for restart and use fallback.
                engineNeedsStart = true
                tickPlayers.removeAll()
                _ = readyEngine()
                fallback()
            }
        } catch {
            fallback()
        }
    }

    private func readyEngine() -> CHHapticEngine? {
        if engine == nil {
            guard let made = try? CHHapticEngine() else { return nil }
            made.playsHapticsOnly = true
            // Powers the Taptic Engine down between bursts instead of holding it on.
            made.isAutoShutdownEnabled = true
            // Called off the main thread. A reset invalidates every player
            // made on the engine, so the cached tick player goes with it.
            made.stoppedHandler = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.engineNeedsStart = true
                    self?.tickPlayers.removeAll()
                }
            }
            made.resetHandler = { @Sendable [weak self] in
                Task { @MainActor in
                    self?.engineNeedsStart = true
                    self?.tickPlayers.removeAll()
                }
            }
            engine = made
        }
        guard let engine else { return nil }
        if engineNeedsStart {
            if !isStartingEngine {
                if let last = lastStartFailure, Date().timeIntervalSince(last) < 2.0 {
                    return nil
                }
                isStartingEngine = true
                engine.start { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.isStartingEngine = false
                        if error == nil {
                            self.engineNeedsStart = false
                            self.lastStartFailure = nil
                        } else {
                            self.lastStartFailure = Date()
                        }
                    }
                }
            }
            return nil
        }
        return engine
    }

    private func generator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let existing = impactGenerators[style] { return existing }
        let made = UIImpactFeedbackGenerator(style: style)
        made.prepare()
        impactGenerators[style] = made
        return made
    }

    // MARK: - Building blocks

    /// A transient: a single click. Scaled by the strength setting.
    private func tap(_ time: TimeInterval, _ intensity: Double, _ sharpness: Double) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: scaled(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: clamp(sharpness)),
            ],
            relativeTime: time
        )
    }

    /// A continuous event: a sustained texture under the clicks. `attack`
    /// swells it in over that many seconds; `fading` lets it die away over its
    /// duration instead of holding level. The envelope is the event's own, so
    /// the clicks around it keep their full strength.
    private func hum(
        _ time: TimeInterval,
        _ duration: TimeInterval,
        _ intensity: Double,
        _ sharpness: Double,
        attack: TimeInterval = 0,
        fading: Bool = false
    ) -> CHHapticEvent {
        var parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: scaled(intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: clamp(sharpness)),
        ]
        if attack > 0 {
            parameters.append(CHHapticEventParameter(parameterID: .attackTime, value: Float(attack)))
        }
        if fading {
            parameters.append(CHHapticEventParameter(parameterID: .sustained, value: 0))
            parameters.append(CHHapticEventParameter(parameterID: .decayTime, value: Float(duration)))
        }
        return CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: parameters,
            relativeTime: time,
            duration: duration
        )
    }

    private func scaled(_ intensity: Double) -> Float { clamp(intensity * Self.strength) }
    private func clamp(_ value: Double) -> Float { Float(min(max(value, 0), 1)) }
}

extension ScrollDirection {
    /// Sharpness the swell pattern is built at; each tick shifts it from here.
    /// Scrolling back is the duller of the two.
    var baseSharpness: Float { self == .forward ? 0.30 : 0.18 }
}

extension View {
    /// `sensoryFeedback` that respects the app's haptics switch.
    func hapticFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in Haptics.isEnabled }
    }
}
