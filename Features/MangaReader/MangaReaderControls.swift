// MangaReaderControls.swift - The decisions behind the manga reader's inputs.
//
// Pure on purpose: where a tap lands, how fast a hold scrolls, whether a volume
// change was a button press. The UIKit pieces (`WebtoonScrollController`,
// `VolumeKeyHost`) only feed these functions and act on the answer, so the
// rules can be checked headless.

import CoreGraphics
import Foundation

// MARK: - Tap zones

/// What a tap should do.
enum MangaTapAction: Equatable {
    case previous
    case next
    case menu

    /// The same tap with the sides swapped. The menu never moves.
    var reversed: MangaTapAction {
        switch self {
        case .previous: .next
        case .next: .previous
        case .menu: .menu
        }
    }
}

/// One region of the reader screen, and what a tap inside it does.
///
/// These rectangles are the layout: `action(at:)` looks a tap up in them and the
/// settings sheet draws them, so the picture a reader is shown cannot disagree
/// with the tap they make.
struct MangaTapZone: Equatable {
    let action: MangaTapAction
    let rect: CGRect
}

/// How the screen is divided into tap targets in paged mode.
///
/// Layouts are described for left-to-right reading. A right-to-left series (or
/// the invert toggle) swaps previous and next; the menu zone never moves.
enum MangaTapZoneLayout: String, Codable, CaseIterable, Identifiable {
    /// Left third previous, right third next, middle opens the menu.
    case standard
    /// The whole bottom row and right column next, the rest of the top row and
    /// left column previous, centre opens the menu.
    case lShaped
    /// Left third previous, everything else next, a strip along the top opens the menu.
    case kindlish
    /// Narrow strips on the left and right edges turn pages, the rest is the menu.
    case edge
    /// Taps never turn pages; any tap toggles the menu.
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Default"
        case .lShaped: "L-shaped"
        case .kindlish: "Kindle-style"
        case .edge: "Edges"
        case .disabled: "Disabled"
        }
    }

    /// Short enough for a segmented control.
    var shortName: String {
        switch self {
        case .standard: "Default"
        case .lShaped: "L-shape"
        case .kindlish: "Kindle"
        case .edge: "Edges"
        case .disabled: "Off"
        }
    }

    var summary: String {
        switch self {
        case .standard: "Left and right thirds turn the page"
        case .lShaped: "Top and left go back, bottom and right go forward"
        case .kindlish: "Left third goes back, the rest goes forward"
        case .edge: "Only the screen edges turn the page"
        case .disabled: "Taps only show or hide the controls"
        }
    }

    /// The Kindle layout's menu strip, as a share of the screen height.
    static let kindleMenuHeight: CGFloat = 0.12
    /// The Edges layout's page-turn strips, as a share of the screen width.
    static let edgeStripWidth: CGFloat = 0.2

    /// The screen cut into tap targets for a reader of `size`: disjoint
    /// rectangles that cover all of it.
    ///
    /// `inverted` and `rightToLeft` are applied here, so each zone's action is
    /// what a tap on it does right now. Two reversals cancel: an inverted layout
    /// on a right-to-left series is the left-to-right layout again.
    func zones(
        in size: CGSize,
        inverted: Bool = false,
        rightToLeft: Bool = false
    ) -> [MangaTapZone] {
        guard size.width > 0, size.height > 0 else { return [] }
        let w = size.width
        let h = size.height
        let thirdW = w / 3
        let thirdH = h / 3

        let base: [MangaTapZone]
        switch self {
        case .standard:
            base = [
                MangaTapZone(action: .previous, rect: CGRect(x: 0, y: 0, width: thirdW, height: h)),
                MangaTapZone(action: .menu, rect: CGRect(x: thirdW, y: 0, width: thirdW, height: h)),
                MangaTapZone(action: .next, rect: CGRect(x: 2 * thirdW, y: 0, width: thirdW, height: h)),
            ]
        case .lShaped:
            // Two Ls around a centre square. Forward owns the whole bottom row
            // and the whole right column — the easy sweep for a right thumb —
            // so back gets what is left of the top row and left column. A
            // corner belongs to the band that runs through it: bottom-left
            // goes forward.
            base = [
                MangaTapZone(action: .previous, rect: CGRect(x: 0, y: 0, width: 2 * thirdW, height: thirdH)),
                MangaTapZone(action: .previous, rect: CGRect(x: 0, y: thirdH, width: thirdW, height: thirdH)),
                MangaTapZone(action: .menu, rect: CGRect(x: thirdW, y: thirdH, width: thirdW, height: thirdH)),
                MangaTapZone(action: .next, rect: CGRect(x: 2 * thirdW, y: 0, width: thirdW, height: 2 * thirdH)),
                MangaTapZone(action: .next, rect: CGRect(x: 0, y: 2 * thirdH, width: w, height: thirdH)),
            ]
        case .kindlish:
            let top = h * Self.kindleMenuHeight
            base = [
                MangaTapZone(action: .menu, rect: CGRect(x: 0, y: 0, width: w, height: top)),
                MangaTapZone(action: .previous, rect: CGRect(x: 0, y: top, width: thirdW, height: h - top)),
                MangaTapZone(action: .next, rect: CGRect(x: thirdW, y: top, width: w - thirdW, height: h - top)),
            ]
        case .edge:
            let strip = w * Self.edgeStripWidth
            base = [
                MangaTapZone(action: .previous, rect: CGRect(x: 0, y: 0, width: strip, height: h)),
                MangaTapZone(action: .menu, rect: CGRect(x: strip, y: 0, width: w - 2 * strip, height: h)),
                MangaTapZone(action: .next, rect: CGRect(x: w - strip, y: 0, width: strip, height: h)),
            ]
        case .disabled:
            base = [MangaTapZone(action: .menu, rect: CGRect(origin: .zero, size: size))]
        }

        guard inverted != rightToLeft else { return base }
        return base.map { MangaTapZone(action: $0.action.reversed, rect: $0.rect) }
    }

    /// The action for a tap at `point` in a reader of `size`.
    func action(
        at point: CGPoint,
        in size: CGSize,
        inverted: Bool = false,
        rightToLeft: Bool = false
    ) -> MangaTapAction {
        zones(in: size, inverted: inverted, rightToLeft: rightToLeft)
            .first { $0.rect.contains(point) }?.action ?? .menu
    }
}

// MARK: - Scrolling

/// Hold-to-scroll: the press speed, and how a vertical drag while holding
/// changes it.
struct HoldScrollConfig: Codable, Equatable {
    /// Points per second when the hold starts.
    var baseSpeed: Double = 180
    /// Points per second gained for each point the finger moves.
    var speedPerPoint: Double = 2
    var minSpeed: Double = 40
    var maxSpeed: Double = 1500
    /// `true`: dragging up speeds the scroll up and dragging down slows it.
    /// `false`: the other way round.
    var upIncreases: Bool = true

    init() {}

    /// Missing keys keep their defaults, so adding a setting later does not
    /// discard what was saved before it existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HoldScrollConfig()
        baseSpeed = try c.decodeIfPresent(Double.self, forKey: .baseSpeed) ?? d.baseSpeed
        speedPerPoint = try c.decodeIfPresent(Double.self, forKey: .speedPerPoint) ?? d.speedPerPoint
        minSpeed = try c.decodeIfPresent(Double.self, forKey: .minSpeed) ?? d.minSpeed
        maxSpeed = try c.decodeIfPresent(Double.self, forKey: .maxSpeed) ?? d.maxSpeed
        upIncreases = try c.decodeIfPresent(Bool.self, forKey: .upIncreases) ?? d.upIncreases
    }

    static let baseRange = 20.0...1200.0
    static let stepRange = 0.5...6.0

    /// Speed after the finger has moved `dragY` points from where the hold began.
    /// Positive `dragY` is downwards, as in screen coordinates.
    func speed(forDrag dragY: Double) -> Double {
        let toward = upIncreases ? -dragY : dragY
        return min(max(baseSpeed + toward * speedPerPoint, lower), upper)
    }

    /// Bounds with a sane order even if the saved values were not.
    var lower: Double { max(1, min(minSpeed, maxSpeed)) }
    var upper: Double { max(lower, maxSpeed) }

    /// Where `speed` sits between the slowest and fastest, 0...1. The haptic
    /// ticks brighten along it.
    func level(of speed: Double) -> Double {
        guard upper > lower else { return 1 }
        return min(max((speed - lower) / (upper - lower), 0), 1)
    }
}

/// What the hold-to-scroll haptics should do for a speed change.
enum HoldHaptic: Equatable {
    /// The speed crossed a step: a light selection tick.
    case tick
    /// The speed hit its minimum or maximum: a firmer tap.
    case limit
}

/// Decides when a changing hold speed deserves a haptic: one tick per
/// `step` points per second crossed, and one firmer tap on arriving at either
/// limit. Not every frame — a drag changes the speed continuously, and a
/// buzz per frame is noise.
struct HoldHapticTracker {
    static let step = 40.0

    private var bucket: Int
    private var atLimit: Bool

    init(startSpeed: Double, config: HoldScrollConfig) {
        bucket = Int((startSpeed / Self.step).rounded(.down))
        atLimit = startSpeed <= config.lower || startSpeed >= config.upper
    }

    mutating func update(speed: Double, config: HoldScrollConfig) -> HoldHaptic? {
        let limited = speed <= config.lower || speed >= config.upper
        defer { atLimit = limited }
        let next = Int((speed / Self.step).rounded(.down))
        if limited, !atLimit {
            bucket = next
            return .limit
        }
        guard next != bucket else { return nil }
        bucket = next
        // Sliding along a limit crosses no new step worth a tick.
        return limited ? nil : .tick
    }
}

/// How auto scroll moves the strip.
enum AutoScrollStyle: String, Codable, CaseIterable, Identifiable {
    /// A steady crawl at the set speed. The eyes chase moving art the whole time.
    case continuous
    /// The strip rests while you read, then moves a screenful at once, at the
    /// same average pace as the crawl.
    case stepped

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continuous: "Continuous"
        case .stepped: "A screen at a time"
        }
    }
}

/// How long the strip keeps gliding after a flick.
enum WebtoonMomentum: String, Codable, CaseIterable, Identifiable {
    /// UIKit's default: a flick glides a long way.
    case long
    case medium
    /// UIKit's fast rate: the strip settles almost as the finger lifts.
    case short

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .long: "Long"
        case .medium: "Medium"
        case .short: "Short"
        }
    }

    /// `UIScrollView.decelerationRate`: the share of velocity kept per
    /// millisecond. A glide's length goes with `1 / (1 - rate)`, so medium
    /// travels a third as far as long.
    var decelerationRate: Double {
        switch self {
        case .long: 0.998
        case .medium: 0.994
        case .short: 0.99
        }
    }
}

enum ScrollStep {

    /// Longest frame gap that counts as continuous motion. After a stall (the
    /// app was suspended, a sheet was up) a raw gap would jump the page.
    static let maxFrameGap = 0.1

    /// How far one stepped auto scroll, a tap or a volume key moves, as a share
    /// of the screen. The rest stays on screen so the eye keeps its place.
    static let screenful = 0.85

    /// Seconds stepped auto scroll rests before moving `distance` points, so it
    /// keeps the average pace of a crawl at `speed` points per second.
    static func restInterval(distance: Double, speed: Double) -> Double {
        distance / max(speed, 1)
    }

    /// `offset` rounded to whole device pixels. A strip resting between pixels
    /// is resampled every frame, which shimmers as it crawls.
    static func pixelAligned(_ offset: Double, scale: Double) -> Double {
        let scale = max(scale, 1)
        return (offset * scale).rounded() / scale
    }

    /// Advance `offset` by `speed` points per second over `dt` seconds, never
    /// past `maxOffset`. A negative `speed` moves back, never past `minOffset`.
    /// `reachedEnd` is true on the step that arrives at the limit it moves toward.
    static func advance(
        offset: Double,
        speed: Double,
        dt: Double,
        maxOffset: Double,
        minOffset: Double = 0
    ) -> (offset: Double, reachedEnd: Bool) {
        if speed < 0, dt > 0 {
            let back = offset + speed * min(dt, maxFrameGap)
            if back <= minOffset { return (min(minOffset, max(offset, minOffset)), true) }
            return (back, false)
        }
        guard speed > 0, dt > 0 else { return (offset, offset >= maxOffset) }
        let next = offset + speed * min(dt, maxFrameGap)
        if next >= maxOffset { return (max(maxOffset, min(offset, maxOffset)), true) }
        return (next, false)
    }
}

// MARK: - Volume keys

enum VolumeKey: Equatable {
    case up
    case down
}

/// Tells a volume button press from the app resetting the volume itself.
///
/// iOS reports a button press only as a new `outputVolume`. To keep a press
/// observable at the ends of the range the reader parks the volume at `target`
/// and sets it back after every press; that reset is reported too, and must not
/// be read as another press.
struct VolumeKeyDetector {
    let target: Float
    private(set) var last: Float
    private let tolerance: Float = 0.001

    init(target: Float = 0.5, last: Float? = nil) {
        self.target = target
        self.last = last ?? target
    }

    /// Feed each reported volume; returns the button pressed, if any.
    mutating func consume(_ volume: Float) -> VolumeKey? {
        defer { last = volume }
        if abs(volume - target) < tolerance { return nil }
        if volume > last + tolerance { return .up }
        if volume < last - tolerance { return .down }
        return nil
    }
}

// MARK: - Stored control settings

/// Reader input settings that follow the user rather than the series.
///
/// One JSON value under one `@AppStorage` key, so the reader observes a single
/// property instead of one per knob.
struct MangaControlSettings: Equatable {
    var volumeKeys = false
    /// `false`: volume up goes back, volume down goes forward.
    var volumeKeysInverted = false
    /// Points per second for auto scroll.
    var autoScrollSpeed: Double = 60
    var autoScrollStyle: AutoScrollStyle = .stepped
    var hold = HoldScrollConfig()
    var holdScrollEnabled = true
    /// Webtoon page width as a share of the screen. Below 1 the strip is framed
    /// by still margins, so less of the field of view moves.
    var stripWidth: Double = 1
    var momentum: WebtoonMomentum = .medium

    static let autoSpeedRange = 10.0...600.0
    static let stripWidthRange = 0.6...1.0

    static let storageKey = "manga.controls"

    init() {}

    /// Volume up goes back unless inverted.
    func isForward(_ key: VolumeKey) -> Bool {
        (key == .down) != volumeKeysInverted
    }

    /// The stored shape. Every field optional, so a value saved before a
    /// setting existed still loads and the new setting keeps its default.
    ///
    /// Deliberately not `MangaControlSettings: Codable`: a `RawRepresentable`
    /// that is also `Codable` encodes through `rawValue`, which encodes the
    /// value, which calls `rawValue`...
    private struct Payload: Codable {
        var volumeKeys: Bool?
        var volumeKeysInverted: Bool?
        var autoScrollSpeed: Double?
        var autoScrollStyle: AutoScrollStyle?
        var hold: HoldScrollConfig?
        var holdScrollEnabled: Bool?
        var stripWidth: Double?
        var momentum: WebtoonMomentum?
    }
}

extension MangaControlSettings: RawRepresentable {
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        let defaults = MangaControlSettings()
        volumeKeys = payload.volumeKeys ?? defaults.volumeKeys
        volumeKeysInverted = payload.volumeKeysInverted ?? defaults.volumeKeysInverted
        autoScrollSpeed = payload.autoScrollSpeed ?? defaults.autoScrollSpeed
        autoScrollStyle = payload.autoScrollStyle ?? defaults.autoScrollStyle
        hold = payload.hold ?? defaults.hold
        holdScrollEnabled = payload.holdScrollEnabled ?? defaults.holdScrollEnabled
        stripWidth = payload.stripWidth.map {
            min(max($0, Self.stripWidthRange.lowerBound), Self.stripWidthRange.upperBound)
        } ?? defaults.stripWidth
        momentum = payload.momentum ?? defaults.momentum
    }

    var rawValue: String {
        let payload = Payload(
            volumeKeys: volumeKeys,
            volumeKeysInverted: volumeKeysInverted,
            autoScrollSpeed: autoScrollSpeed,
            autoScrollStyle: autoScrollStyle,
            hold: hold,
            holdScrollEnabled: holdScrollEnabled,
            stripWidth: stripWidth,
            momentum: momentum
        )
        // Sorted, so the same settings are always the same string: `==` on a
        // `RawRepresentable` can compare raw values, and unsorted keys come
        // out in a different order each time.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
