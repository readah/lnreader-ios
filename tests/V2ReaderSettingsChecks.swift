// V2ReaderSettingsChecks.swift - Per-series reader settings, headless.

import CoreGraphics
import Foundation

@main
@MainActor
struct V2ReaderSettingsChecks {

    static func main() {
        checkDefaultsWhenNothingStored()
        checkOverrideBeatsDefault()
        checkOverrideIsPerField()
        checkNewDefaultReachesUnoverriddenSeries()
        checkPersistsAcrossInstances()
        checkSeriesAreIndependent()
        checkResetClearsStorage()
        checkMakeDefault()
        checkResetGlobalDefaults()
        checkForwardCompatibleDecoding()
        checkTapZoneOverrides()
        checkTapZones()
        checkTapZoneReversal()
        checkHoldSpeed()
        checkScrollStep()
        checkHoldHaptics()
        checkVolumeDetector()
        checkControlSettingsDecoding()
        print("PASS: reader settings — defaults, per-field override, default propagation, "
            + "persistence, series isolation, reset, make default, decoding old data; "
            + "tap zones, reversal, hold speed, scroll step, volume detection, control settings")
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "lnreader-reader-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func checkDefaultsWhenNothingStored() {
        let settings = MangaSeriesSettings(key: "s::a", defaults: freshDefaults())
        precondition(settings.resolved == MangaReaderPreferences(readingMode: .pager, direction: .leftToRight,
                                                                  tapZones: .standard, invertTapZones: false),
                     "built-in defaults")
        precondition(!settings.hasOverrides, "nothing overridden")
    }

    private static func checkOverrideBeatsDefault() {
        let defaults = freshDefaults()
        defaults.set("pager", forKey: MangaReaderSettingsKey.readingMode)
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        settings.setReadingMode(.webtoon)
        precondition(settings.resolved.readingMode == .webtoon, "override wins over the default")
    }

    private static func checkOverrideIsPerField() {
        let defaults = freshDefaults()
        defaults.set("rightToLeft", forKey: MangaReaderSettingsKey.direction)
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        settings.setReadingMode(.webtoon)
        precondition(settings.resolved.direction == .rightToLeft,
                     "overriding the mode must not freeze the direction")
    }

    private static func checkNewDefaultReachesUnoverriddenSeries() {
        let defaults = freshDefaults()
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        defaults.set("webtoon", forKey: MangaReaderSettingsKey.readingMode)
        precondition(settings.resolved.readingMode == .webtoon,
                     "a series that never overrode follows a changed default")
    }

    private static func checkPersistsAcrossInstances() {
        let defaults = freshDefaults()
        MangaSeriesSettings(key: "s::a", defaults: defaults).setDirection(.rightToLeft)
        let reloaded = MangaSeriesSettings(key: "s::a", defaults: defaults)
        precondition(reloaded.resolved.direction == .rightToLeft, "override survives a reload")
    }

    private static func checkSeriesAreIndependent() {
        let defaults = freshDefaults()
        MangaSeriesSettings(key: "s::a", defaults: defaults).setReadingMode(.webtoon)
        let other = MangaSeriesSettings(key: "s::b", defaults: defaults)
        precondition(other.resolved.readingMode == .pager, "another series is unaffected")
    }

    private static func checkResetClearsStorage() {
        let defaults = freshDefaults()
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        settings.setReadingMode(.webtoon)
        settings.reset()
        precondition(!settings.hasOverrides, "reset clears overrides")
        precondition(defaults.data(forKey: "mangareader.s::a") == nil,
                     "an empty override set is removed, not stored as {}")
    }

    private static func checkMakeDefault() {
        let defaults = freshDefaults()
        let a = MangaSeriesSettings(key: "s::a", defaults: defaults)
        a.setReadingMode(.webtoon)
        a.makeDefault()
        precondition(!a.hasOverrides, "promoting to default drops the override")
        let b = MangaSeriesSettings(key: "s::b", defaults: defaults)
        precondition(b.resolved.readingMode == .webtoon, "other series follow the new default")
    }

    private static func checkResetGlobalDefaults() {
        let defaults = freshDefaults()
        defaults.set("webtoon", forKey: MangaReaderSettingsKey.readingMode)
        defaults.set("rightToLeft", forKey: MangaReaderSettingsKey.direction)
        defaults.set("edge", forKey: MangaReaderSettingsKey.tapZones)
        defaults.set(true, forKey: MangaReaderSettingsKey.invertTapZones)
        var controls = MangaControlSettings()
        controls.volumeKeys = true
        defaults.set(controls.rawValue, forKey: MangaControlSettings.storageKey)

        precondition(MangaReaderPreferences.defaults(defaults) == MangaReaderPreferences(
            readingMode: .webtoon,
            direction: .rightToLeft,
            tapZones: .edge,
            invertTapZones: true
        ), "custom global defaults applied")

        MangaReaderPreferences.resetDefaults(defaults)

        precondition(MangaReaderPreferences.defaults(defaults) == MangaReaderPreferences(
            readingMode: .pager,
            direction: .leftToRight,
            tapZones: .standard,
            invertTapZones: false
        ), "defaults reset to built-ins")
        precondition(defaults.string(forKey: MangaControlSettings.storageKey) == nil,
                     "controls reset")
    }

    private static func checkForwardCompatibleDecoding() {
        // Fields added later are optional, so data written before them loads,
        // and data with fields this build does not know does not break it.
        let defaults = freshDefaults()
        defaults.set(Data(#"{"readingMode":"webtoon","futureSetting":"x"}"#.utf8), forKey: "mangareader.s::a")
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        precondition(settings.resolved.readingMode == .webtoon, "known field decoded despite an unknown one")
        defaults.set(Data("{}".utf8), forKey: "mangareader.s::b")
        precondition(!MangaSeriesSettings(key: "s::b", defaults: defaults).hasOverrides, "empty object loads")
    }

    // MARK: - Tap zones

    private static let screen = CGSize(width: 300, height: 600)

    private static func tap(_ layout: MangaTapZoneLayout, _ x: CGFloat, _ y: CGFloat,
                            inverted: Bool = false, rtl: Bool = false) -> MangaTapAction {
        layout.action(at: CGPoint(x: x, y: y), in: screen, inverted: inverted, rightToLeft: rtl)
    }

    private static func checkTapZoneOverrides() {
        let defaults = freshDefaults()
        defaults.set("kindlish", forKey: MangaReaderSettingsKey.tapZones)
        let settings = MangaSeriesSettings(key: "s::a", defaults: defaults)
        precondition(settings.resolved.tapZones == .kindlish, "default layout comes from the global key")
        settings.setTapZones(.edge)
        settings.setInvertTapZones(true)
        let reloaded = MangaSeriesSettings(key: "s::a", defaults: defaults)
        precondition(reloaded.resolved.tapZones == .edge && reloaded.resolved.invertTapZones,
                     "layout and invert persist per series")
        precondition(MangaSeriesSettings(key: "s::b", defaults: defaults).resolved.tapZones == .kindlish,
                     "another series keeps the default")
    }

    private static func checkTapZones() {
        precondition(tap(.standard, 50, 300) == .previous, "standard: left third")
        precondition(tap(.standard, 150, 300) == .menu, "standard: middle")
        precondition(tap(.standard, 250, 300) == .next, "standard: right third")

        precondition(tap(.lShaped, 150, 50) == .previous, "L: top band goes back")
        precondition(tap(.lShaped, 50, 300) == .previous, "L: left band goes back")
        precondition(tap(.lShaped, 250, 300) == .next, "L: right band goes forward")
        precondition(tap(.lShaped, 150, 550) == .next, "L: bottom band goes forward")
        precondition(tap(.lShaped, 150, 300) == .menu, "L: centre is the menu")

        precondition(tap(.kindlish, 150, 20) == .menu, "kindle: top strip is the menu")
        precondition(tap(.kindlish, 50, 300) == .previous, "kindle: left third goes back")
        precondition(tap(.kindlish, 150, 300) == .next, "kindle: the rest goes forward")

        precondition(tap(.edge, 20, 300) == .previous, "edge: left strip")
        precondition(tap(.edge, 280, 300) == .next, "edge: right strip")
        precondition(tap(.edge, 150, 300) == .menu, "edge: the rest is the menu")

        for x in [10, 150, 290] as [CGFloat] {
            precondition(tap(.disabled, x, 300) == .menu, "disabled: every tap is the menu")
        }
        precondition(MangaTapZoneLayout.standard.action(at: .zero, in: .zero) == .menu,
                     "an unmeasured reader never turns a page")
    }

    private static func checkTapZoneReversal() {
        precondition(tap(.standard, 50, 300, rtl: true) == .next, "right-to-left swaps the sides")
        precondition(tap(.standard, 50, 300, inverted: true) == .next, "invert swaps the sides")
        precondition(tap(.standard, 50, 300, inverted: true, rtl: true) == .previous,
                     "invert on a right-to-left series cancels out")
        precondition(tap(.standard, 150, 300, inverted: true, rtl: true) == .menu, "the menu zone never moves")
        precondition(tap(.disabled, 50, 300, inverted: true) == .menu, "disabled stays disabled")
    }

    // MARK: - Scrolling

    private static func checkHoldSpeed() {
        var hold = HoldScrollConfig()
        hold.baseSpeed = 200
        hold.speedPerPoint = 2
        hold.minSpeed = 50
        hold.maxSpeed = 600
        precondition(hold.speed(forDrag: 0) == 200, "no drag keeps the base speed")
        precondition(hold.speed(forDrag: -50) == 300, "up increases by default")
        precondition(hold.speed(forDrag: 50) == 100, "down decreases by default")
        precondition(hold.speed(forDrag: -1000) == 600, "capped at the maximum")
        precondition(hold.speed(forDrag: 1000) == 50, "floored at the minimum")
        hold.upIncreases = false
        precondition(hold.speed(forDrag: 50) == 300, "direction can be inverted: down increases")
        precondition(hold.speed(forDrag: -50) == 100, "direction can be inverted: up decreases")
        hold.minSpeed = 900
        precondition(hold.speed(forDrag: 0) == 600 && hold.lower == 600,
                     "an inverted min/max pair collapses instead of trapping the speed")
    }

    private static func checkScrollStep() {
        let step = ScrollStep.advance(offset: 100, speed: 60, dt: 0.5, maxOffset: 1000)
        precondition(abs(step.offset - 106) < 0.0001 && !step.reachedEnd,
                     "dt is clamped to one frame gap so a stall cannot jump")
        let steady = ScrollStep.advance(offset: 100, speed: 120, dt: 1.0 / 60, maxOffset: 1000)
        precondition(abs(steady.offset - 102) < 0.0001, "120 pt/s over a 60 Hz frame is 2 pt")
        let end = ScrollStep.advance(offset: 999, speed: 300, dt: 0.05, maxOffset: 1000)
        precondition(end.offset == 1000 && end.reachedEnd, "stops exactly at the end")
        let already = ScrollStep.advance(offset: 1000, speed: 100, dt: 0.016, maxOffset: 1000)
        precondition(already.offset == 1000 && already.reachedEnd, "already at the end")
        let short = ScrollStep.advance(offset: 40, speed: 100, dt: 0.016, maxOffset: 0)
        precondition(short.offset == 0 && short.reachedEnd, "content shorter than the screen never scrolls")
        let idle = ScrollStep.advance(offset: 10, speed: 0, dt: 0.016, maxOffset: 100)
        precondition(idle.offset == 10 && !idle.reachedEnd, "zero speed does not move")

        precondition(ScrollStep.restInterval(distance: 600, speed: 60) == 10,
                     "stepped auto scroll rests as long as a crawl would take to cover the screenful")
        precondition(ScrollStep.restInterval(distance: 600, speed: 0) == 600, "zero speed does not divide by zero")
        precondition(ScrollStep.pixelAligned(10.2, scale: 3) == 31.0 / 3, "rounds to the nearest of three pixels a point")
        precondition(ScrollStep.pixelAligned(10.2, scale: 0) == 10, "a missing scale counts as one")
        precondition(WebtoonMomentum.long.decelerationRate > WebtoonMomentum.medium.decelerationRate
                     && WebtoonMomentum.medium.decelerationRate > WebtoonMomentum.short.decelerationRate,
                     "longer momentum keeps more velocity")
    }

    private static func checkHoldHaptics() {
        var hold = HoldScrollConfig()
        hold.baseSpeed = 200
        hold.speedPerPoint = 1
        hold.minSpeed = 100
        hold.maxSpeed = 400
        var tracker = HoldHapticTracker(startSpeed: 200, config: hold)
        precondition(tracker.update(speed: 205, config: hold) == nil, "within a step: silent")
        precondition(tracker.update(speed: 245, config: hold) == .tick, "crossing a step ticks")
        precondition(tracker.update(speed: 250, config: hold) == nil, "no second tick inside a step")
        precondition(tracker.update(speed: 190, config: hold) == .tick, "slowing down ticks too")
        precondition(tracker.update(speed: 100, config: hold) == .limit, "arriving at the minimum is firmer")
        precondition(tracker.update(speed: 100, config: hold) == nil, "staying at the limit is silent")
        precondition(tracker.update(speed: 130, config: hold) == .tick, "leaving the limit resumes ticks")
        precondition(tracker.update(speed: 400, config: hold) == .limit, "arriving at the maximum is firmer")
        var atLimit = HoldHapticTracker(startSpeed: 100, config: hold)
        precondition(atLimit.update(speed: 100, config: hold) == nil, "starting on a limit does not fire it")
        precondition(hold.level(of: 100) == 0 && hold.level(of: 400) == 1 && hold.level(of: 250) == 0.5,
                     "tick brightness runs from the slowest to the fastest speed")
        precondition(MangaControlSettings(rawValue: #"{"hold":{"baseSpeed":90,"haptics":false}}"#)?.hold.baseSpeed == 90,
                     "settings saved with the old per-hold haptics switch still load")
    }

    // MARK: - Volume keys

    private static func checkVolumeDetector() {
        var detector = VolumeKeyDetector(target: 0.5)
        precondition(detector.consume(0.5625) == .up, "a higher volume is volume up")
        precondition(detector.consume(0.5) == nil, "the reset to the target is not a press")
        precondition(detector.consume(0.4375) == .down, "a lower volume is volume down")
        precondition(detector.consume(0.5) == nil, "reset again")
        precondition(detector.consume(0.5625) == .up && detector.consume(0.5) == nil,
                     "repeated presses each count once")
        precondition(detector.consume(0.5) == nil, "no change is no press")

        let settings = MangaControlSettings()
        precondition(!settings.isForward(.up) && settings.isForward(.down), "up goes back, down goes forward")
        var inverted = settings
        inverted.volumeKeysInverted = true
        precondition(inverted.isForward(.up) && !inverted.isForward(.down), "invert swaps the buttons")
    }

    // MARK: - Stored control settings

    private static func checkControlSettingsDecoding() {
        var settings = MangaControlSettings()
        settings.volumeKeys = true
        settings.hold.baseSpeed = 333
        settings.hold.upIncreases = false
        precondition(MangaControlSettings(rawValue: settings.rawValue) == settings, "round trip")

        let old = MangaControlSettings(rawValue: #"{"volumeKeys":true}"#)
        precondition(old?.volumeKeys == true && old?.autoScrollSpeed == 60 && old?.hold == HoldScrollConfig(),
                     "a missing field keeps its default instead of discarding what was saved")
        precondition(MangaControlSettings(rawValue: "not json") == nil, "garbage falls back to the default")
        let partialHold = MangaControlSettings(rawValue: #"{"hold":{"baseSpeed":90}}"#)
        precondition(partialHold?.hold.baseSpeed == 90 && partialHold?.hold.maxSpeed == 1500,
                     "a partial hold block keeps defaults for the rest")

        var webtoon = MangaControlSettings()
        webtoon.autoScrollStyle = .continuous
        webtoon.stripWidth = 0.75
        webtoon.momentum = .short
        precondition(MangaControlSettings(rawValue: webtoon.rawValue) == webtoon, "webtoon settings round trip")
        precondition(old?.autoScrollStyle == .stepped && old?.stripWidth == 1 && old?.momentum == .medium,
                     "settings saved before the webtoon options get their defaults")
        precondition(MangaControlSettings(rawValue: #"{"stripWidth":0.1}"#)?.stripWidth == 0.6,
                     "a stored strip width is clamped to the slider's range")
    }
}
