// IconPack.swift
// Selectable icon sets. `AppIcon` replaces `Image(systemName:)` in views; menus
// keep SF Symbols because UIKit builds those rows from a `UIImage`.

import SwiftUI

enum IconPack: String, CaseIterable, Identifiable {
    case swiftIcons = "Swift Icons"
    case paperIcons = "Paper Icons"
    case modernArt = "Modern Art"

    var id: String { rawValue }
    var displayName: String { rawValue }

    static let storageKey = "appearance.iconPack"
}

enum IconPackCatalog {
    static func paperAsset(for symbol: String) -> String? {
        if let exact = paperMap[symbol] { return "paper_\(exact)" }
        let stripped = symbol
            .replacingOccurrences(of: ".fill", with: "")
            .replacingOccurrences(of: ".circle", with: "")
        if let fallback = paperMap[stripped] { return "paper_\(fallback)" }
        return nil
    }

    static func modernArtAsset(for symbol: String) -> String {
        if let exact = modernArtMap[symbol] { return "art_shape_\(exact)" }
        var hash: Int = 0
        for byte in symbol.utf8 { hash = (hash &* 31 &+ Int(byte)) & 0x7FFFFFFF }
        return "art_shape_\((hash % 72) + 1)"
    }

    // Paper Icons (@weihuasongguo/variable-width-svg), curated for the SF Symbols
    // this app draws. Anything absent falls back to its SF Symbol.
    private static let paperMap: [String: String] = [
        // Navigation and reading
        "books.vertical": "book_open",
        "book": "book_open",
        "book.fill": "book_open",
        "book.closed.fill": "book_close",
        "book.pages": "book_open",
        "scroll": "note",
        "bookmark": "bookmark",
        "bookmark.fill": "bookmark",
        "highlighter": "pen_tool",
        "text.quote": "text_quote",
        "textformat.size": "align_left",
        "safari": "compass",
        "globe": "earth",
        "clock": "calendar_clock",
        "clock.fill": "calendar_clock",
        "clock.arrow.circlepath": "calendar_clock",
        "calendar": "calendar",
        "bell": "bell_jingle",
        "bell.fill": "bell_jingle",
        "ellipsis": "list",
        "ellipsis.circle": "list",
        "square.grid.2x2": "widget",
        "square.grid.2x2.fill": "widget",
        "rectangle.grid.2x2": "widget",
        "list.number": "list_ordered",
        "list.bullet": "list",
        "text.badge.checkmark": "checklist",
        "textformat.abc": "align_left",
        "bubble.left.and.bubble.right": "messages",
        "photo": "image_exposure",
        "line.3.horizontal.decrease": "filter",
        "line.3.horizontal.decrease.circle": "filter",
        "line.3.horizontal.decrease.circle.fill": "filter",
        "text.magnifyingglass": "search",
        "magnifyingglass": "search",
        "link": "link",

        // Actions
        "trash": "delete",
        "trash.fill": "delete",
        "arrow.down.circle": "download",
        "arrow.down.circle.fill": "download",
        "arrow.down.doc.fill": "download",
        "square.and.arrow.down": "import",
        "square.and.arrow.up": "share",
        "arrow.clockwise": "refresh",
        "arrow.clockwise.circle": "refresh",
        "arrow.clockwise.circle.fill": "refresh",
        "arrow.counterclockwise": "undo",
        "arrow.uturn.backward.circle.fill": "undo",
        "arrow.triangle.2.circlepath": "refresh",
        "arrow.triangle.swap": "exchange",
        "arrow.up.arrow.down": "switch",
        "arrow.up.and.down.and.arrow.left.and.right": "move",
        "rectangle.split.3x1": "distribute_horizontal",
        "lock.fill": "package",
        "lock": "package",
        "arrow.up.arrow.down.circle": "sort",
        "dice": "sort",
        "dice.fill": "sort",
        "hand.thumbsdown": "feedback",
        "rectangle.portrait.and.arrow.right": "logout",
        "rectangle.portrait.and.arrow.right.fill": "logout",
        "arrow.up": "arrow_up",
        "arrow.up.to.line": "arrow_up",
        "arrow.up.right.square": "arrow_up_right",
        "arrow.down": "arrow_down",
        "arrow.right": "arrow_right",
        "chevron.right": "caret_right",
        "chevron.forward": "caret_right",
        "chevron.left": "caret_left",
        "chevron.backward": "caret_left",
        "chevron.up": "chevron_up",
        "chevron.down": "chevron_down",
        "chevron.up.chevron.down": "chevron_down",
        "checkmark": "check",
        "checkmark.circle": "check",
        "checkmark.circle.fill": "check",
        "xmark": "close",
        "xmark.circle.fill": "close_circle",
        "plus.circle": "add_circle",
        "minus": "clear",
        "pencil": "edit",
        "slider.horizontal.3": "sliders",
        "externaldrive": "save",
        "externaldrive.badge.checkmark": "save",
        "paintbrush": "pen_tool",
        "location.fill": "location_pin",
        "hyphen": "clear",

        // Status and info
        "exclamationmark.circle": "warning",
        "exclamationmark.circle.fill": "warning",
        "exclamationmark.triangle": "warning",
        "exclamationmark.triangle.fill": "warning",
        "exclamationmark.shield": "warning",
        "info.circle": "help_circle",
        "info.circle.fill": "help_circle",
        "questionmark.circle": "help_circle",
        "stop.fill": "stop",
        "stop.circle.fill": "stop",
        "hand.thumbsup": "approval",
        "hand.thumbsup.fill": "approval",

        // TTS and media
        "waveform": "activity",
        "waveform.badge.plus": "microphone",
        "headphones": "microphone",
        "mic.fill": "microphone",
        "pause.circle": "pause",
        "pause.circle.fill": "pause",
        "pause.fill": "pause",
        "play": "play",
        "play.fill": "play",
        "play.circle": "play_circle",
        "play.circle.fill": "play_circle",
        "circle": "circle",
        "circle.fill": "circle",
        "moon.zzz": "moon",
        "moon.zzz.fill": "moon",
        "moon.fill": "moon",
        "sun.min": "sun",
        "sun.max": "sun",
        "sparkles": "sparkle",

        // People
        "person.crop.circle": "user",
        "person.crop.circle.fill": "user",
        "person.crop.circle.badge.plus": "user",
        "person.crop.circle.badge.questionmark": "user",
        "person.badge.key": "user",
        "person.2": "users",
        "person.2.fill": "users",
        "hand.point.up.left": "approval",

        // Metrics and storage
        "chart.bar": "activity",
        "chart.bar.fill": "activity",
        "chart.pie": "image_mosaic",
        "percent": "calculator",
        "number": "calculator",
        "icloud.fill": "cloud",
        "cloud": "cloud",
        "iphone": "widget",
        "eye": "eye",
        "eye.slash": "eye_off",
        "eye.slash.fill": "eye_off",
        "briefcase.fill": "backpack",
        "bed.double.fill": "bed",
        "wand.and.rays": "sparkle",
        "doc.on.doc": "copy",
        "doc.on.clipboard": "copy"
    ]

    // A fixed shape per symbol, so the same action always looks the same.
    private static let modernArtMap: [String: Int] = [
        "books.vertical": 1,
        "book.fill": 1,
        "book.closed.fill": 1,
        "book.pages": 1,
        "clock": 2,
        "clock.fill": 2,
        "arrow.clockwise": 3,
        "arrow.clockwise.circle": 3,
        "arrow.clockwise.circle.fill": 3,
        "arrow.triangle.2.circlepath": 3,
        "arrow.counterclockwise": 4,
        "arrow.uturn.backward.circle.fill": 4,
        "person.2": 5,
        "person.2.fill": 5,
        "person.crop.circle": 6,
        "person.crop.circle.fill": 6,
        "person.crop.circle.badge.plus": 6,
        "person.badge.key": 6,
        "trash": 7,
        "trash.fill": 7,
        "arrow.down.circle": 8,
        "arrow.down.circle.fill": 8,
        "arrow.down.doc.fill": 8,
        "bookmark": 9,
        "bookmark.fill": 9,
        "square.and.arrow.down": 10,
        "square.and.arrow.up": 11,
        "bell": 12,
        "bell.fill": 12,
        "safari": 13,
        "globe": 13,
        "magnifyingglass": 14,
        "text.magnifyingglass": 14,
        "checkmark": 15,
        "checkmark.circle": 15,
        "checkmark.circle.fill": 15,
        "xmark": 16,
        "xmark.circle.fill": 16,
        "plus.circle": 17,
        "minus": 17,
        "exclamationmark.triangle": 18,
        "exclamationmark.triangle.fill": 18,
        "exclamationmark.circle": 18,
        "info.circle": 19,
        "info.circle.fill": 19,
        "waveform": 20,
        "waveform.badge.plus": 20,
        "headphones": 20,
        "pause.circle": 21,
        "pause.fill": 21,
        "stop.fill": 22,
        "stop.circle.fill": 22,
        "chart.bar.fill": 23,
        "chart.pie": 24,
        "pencil": 25,
        "slider.horizontal.3": 26,
        "line.3.horizontal.decrease": 27,
        "chevron.right": 28,
        "chevron.left": 29,
        "chevron.up": 30,
        "chevron.down": 31,
        "square.grid.2x2": 32,
        "rectangle.grid.2x2": 32,
        "list.number": 33,
        "highlighter": 34,
        "text.quote": 35,
        "sparkles": 36,
        "moon.zzz": 37,
        "sun.max": 38,
        "eye.slash": 39,
        "icloud.fill": 40,
        "externaldrive": 41,
        "location.fill": 42,
        "arrow.up": 43,
        "arrow.down": 44,
        "arrow.right": 45,
        "arrow.up.arrow.down": 46,
        "paintbrush": 47,
        "hand.thumbsup": 48,
        "ellipsis": 49,
        "ellipsis.circle": 49
    ]
}

/// An SF Symbol name drawn from the selected icon pack.
struct AppIcon: View {
    let systemName: String
    var size: CGFloat = 17
    var renderingMode: Image.TemplateRenderingMode = .template

    @AppStorage(IconPack.storageKey) private var packRaw = IconPack.swiftIcons.rawValue
    @ScaledMetric private var scaledSize: CGFloat

    init(
        systemName: String,
        size: CGFloat = 17,
        relativeTo style: Font.TextStyle = .body,
        renderingMode: Image.TemplateRenderingMode = .template
    ) {
        self.systemName = systemName
        self.size = size
        self.renderingMode = renderingMode
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    var body: some View {
        switch IconPack(rawValue: packRaw) ?? .swiftIcons {
        case .swiftIcons:
            Image(systemName: systemName)
        case .paperIcons:
            if let asset = IconPackCatalog.paperAsset(for: systemName) {
                assetImage(asset)
            } else {
                Image(systemName: systemName)
            }
        case .modernArt:
            assetImage(IconPackCatalog.modernArtAsset(for: systemName))
        }
    }

    private func assetImage(_ name: String) -> some View {
        Image(name)
            .renderingMode(renderingMode)
            .resizable()
            .scaledToFit()
            .frame(width: scaledSize, height: scaledSize)
    }
}

/// A `Label` whose icon follows the selected pack. Menu and context-menu rows
/// keep `Label(_:systemImage:)`: UIKit renders those from a `UIImage`.
struct AppLabel: View {
    let title: String
    let systemName: String
    var size: CGFloat
    var relativeTo: Font.TextStyle

    init(
        _ title: String,
        systemName: String,
        size: CGFloat = 17,
        relativeTo style: Font.TextStyle = .body
    ) {
        self.title = title
        self.systemName = systemName
        self.size = size
        self.relativeTo = style
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            AppIcon(systemName: systemName, size: size, relativeTo: relativeTo)
        }
    }
}

/// The tab bar only accepts a `Label` for its icon and title, so this returns
/// one directly instead of wrapping `AppIcon` in another view.
struct AppTabLabel: View {
    let title: String
    let systemName: String

    @AppStorage(IconPack.storageKey) private var packRaw = IconPack.swiftIcons.rawValue

    var body: some View {
        switch IconPack(rawValue: packRaw) ?? .swiftIcons {
        case .swiftIcons:
            Label(title, systemImage: systemName)
        case .paperIcons:
            if let asset = IconPackCatalog.paperAsset(for: systemName) {
                Label {
                    Text(title)
                } icon: {
                    Image(asset).renderingMode(.template)
                }
            } else {
                Label(title, systemImage: systemName)
            }
        case .modernArt:
            Label {
                Text(title)
            } icon: {
                Image(IconPackCatalog.modernArtAsset(for: systemName)).renderingMode(.template)
            }
        }
    }
}
