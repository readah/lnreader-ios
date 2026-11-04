// MangaReaderSettings.swift - Per-series manga reader settings, persisted.
//
// A series may override any reader setting; a setting it does not override
// follows the global default. `MangaReaderOverrides` holds only what the series
// changed, so a new global default reaches every series that never opted out.
//
// Stored in UserDefaults rather than the model, like scanlator rules: these are
// view preferences, and keeping them out of `Entry` avoids a schema migration
// for every setting added here. Later reader settings (tap zones, volume keys,
// auto scroll) are new optional fields on `MangaReaderOverrides` — optionals
// decode as absent, so older saved data keeps loading.

import Foundation

/// What one series changed. `nil` means "use the default".
struct MangaReaderOverrides: Codable, Equatable {
    var readingMode: MangaReadingMode?
    var direction: MangaPagingDirection?
    var tapZones: MangaTapZoneLayout?
    var invertTapZones: Bool?

    var isEmpty: Bool { self == MangaReaderOverrides() }
}

/// Fully resolved settings, every field concrete.
struct MangaReaderPreferences: Equatable {
    var readingMode: MangaReadingMode
    var direction: MangaPagingDirection
    var tapZones: MangaTapZoneLayout
    var invertTapZones: Bool

    /// The app-wide defaults, read from the same keys the settings UI writes.
    static func defaults(_ store: UserDefaults = .standard) -> MangaReaderPreferences {
        MangaReaderPreferences(
            readingMode: store.string(forKey: MangaReaderSettingsKey.readingMode)
                .flatMap(MangaReadingMode.init(rawValue:)) ?? .pager,
            direction: store.string(forKey: MangaReaderSettingsKey.direction)
                .flatMap(MangaPagingDirection.init(rawValue:)) ?? .leftToRight,
            tapZones: store.string(forKey: MangaReaderSettingsKey.tapZones)
                .flatMap(MangaTapZoneLayout.init(rawValue:)) ?? .standard,
            invertTapZones: store.bool(forKey: MangaReaderSettingsKey.invertTapZones)
        )
    }

    /// Reset the app-wide manga reader defaults back to built-ins.
    static func resetDefaults(_ store: UserDefaults = .standard) {
        store.removeObject(forKey: MangaReaderSettingsKey.readingMode)
        store.removeObject(forKey: MangaReaderSettingsKey.direction)
        store.removeObject(forKey: MangaReaderSettingsKey.tapZones)
        store.removeObject(forKey: MangaReaderSettingsKey.invertTapZones)
        store.removeObject(forKey: MangaControlSettings.storageKey)
    }

    /// Overrides win; anything not overridden comes from `defaults`.
    func applying(_ overrides: MangaReaderOverrides) -> MangaReaderPreferences {
        MangaReaderPreferences(
            readingMode: overrides.readingMode ?? readingMode,
            direction: overrides.direction ?? direction,
            tapZones: overrides.tapZones ?? tapZones,
            invertTapZones: overrides.invertTapZones ?? invertTapZones
        )
    }
}

/// `@AppStorage` keys for the global defaults.
enum MangaReaderSettingsKey {
    static let readingMode = "manga.readingMode"
    static let direction = "manga.pagingDirection"
    static let tapZones = "manga.tapZones"
    static let invertTapZones = "manga.tapZonesInverted"
}

@Observable
@MainActor
final class MangaSeriesSettings {

    /// Series this belongs to (`sourceKey::url`).
    let key: String

    private(set) var overrides: MangaReaderOverrides
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.overrides = Self.load(key: key, defaults: defaults)
    }

    /// The settings in effect for this series right now.
    var resolved: MangaReaderPreferences {
        MangaReaderPreferences.defaults(defaults).applying(overrides)
    }

    var hasOverrides: Bool { !overrides.isEmpty }

    func setReadingMode(_ mode: MangaReadingMode?) {
        mutate { $0.readingMode = mode }
    }

    func setDirection(_ direction: MangaPagingDirection?) {
        mutate { $0.direction = direction }
    }

    func setTapZones(_ layout: MangaTapZoneLayout?) {
        mutate { $0.tapZones = layout }
    }

    func setInvertTapZones(_ inverted: Bool?) {
        mutate { $0.invertTapZones = inverted }
    }

    /// Forget every override; the series follows the defaults again.
    func reset() {
        mutate { $0 = MangaReaderOverrides() }
    }

    /// Promote this series' effective settings to the global defaults and drop
    /// the overrides that made them differ, so every series that has not opted
    /// out follows suit.
    func makeDefault() {
        let current = resolved
        defaults.set(current.readingMode.rawValue, forKey: MangaReaderSettingsKey.readingMode)
        defaults.set(current.direction.rawValue, forKey: MangaReaderSettingsKey.direction)
        defaults.set(current.tapZones.rawValue, forKey: MangaReaderSettingsKey.tapZones)
        defaults.set(current.invertTapZones, forKey: MangaReaderSettingsKey.invertTapZones)
        reset()
    }

    // MARK: - Persistence

    private func mutate(_ body: (inout MangaReaderOverrides) -> Void) {
        var updated = overrides
        body(&updated)
        guard updated != overrides else { return }
        overrides = updated
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey(key))
        } else if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey(key))
        }
    }

    private static func defaultsKey(_ key: String) -> String {
        "mangareader.\(key)"
    }

    private static func load(key: String, defaults: UserDefaults) -> MangaReaderOverrides {
        guard let data = defaults.data(forKey: defaultsKey(key)),
              let decoded = try? JSONDecoder().decode(MangaReaderOverrides.self, from: data)
        else { return MangaReaderOverrides() }
        return decoded
    }
}
