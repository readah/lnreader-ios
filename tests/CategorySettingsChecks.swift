// CategorySettingsChecks.swift - Per-category display, update flags and scope, headless.

import Foundation

@main
struct CategorySettingsChecks {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        var flags = 0
        check(!CategoryFlags.isExcluded(flags), "flags start included")
        flags = CategoryFlags.setting(flags, excluded: true)
        check(CategoryFlags.isExcluded(flags), "excluded flag set")
        check(CategoryFlags.setting(flags | 0b100, excluded: false) == 0b100, "clearing keeps other bits")
        check(CategoryFlags.setting(flags, excluded: true) == flags, "setting twice is a no-op")

        let paused: Set<String> = ["Hiatus"]
        check(LibraryUpdateScope.includes(categories: [], excluded: paused, only: nil), "uncategorised titles update")
        check(LibraryUpdateScope.includes(categories: ["Reading"], excluded: paused, only: nil), "included category updates")
        check(!LibraryUpdateScope.includes(categories: ["Hiatus"], excluded: paused, only: nil), "excluded category is skipped")
        check(!LibraryUpdateScope.includes(categories: ["Reading", "Hiatus"], excluded: paused, only: nil), "exclusion wins in a shared title")
        check(LibraryUpdateScope.includes(categories: ["Hiatus"], excluded: paused, only: "Hiatus"), "refreshing a category ignores its exclusion")
        check(!LibraryUpdateScope.includes(categories: ["Reading"], excluded: paused, only: "Hiatus"), "category refresh leaves other titles alone")
        check(!LibraryUpdateScope.includes(categories: [], excluded: [], only: "Hiatus"), "uncategorised is outside a category refresh")

        let fallback = DisplayMode.comfortable
        var store = LibraryDisplayStore()
        check(store.mode(for: "Manga", default: fallback) == fallback, "no override follows the default")
        store.set(.list, for: "Manga")
        check(store.mode(for: "Manga", default: fallback) == .list, "category override wins")
        check(store.mode(for: nil, default: fallback) == fallback && store.mode(for: "Other", default: fallback) == fallback, "categories independent")
        store.set(.coverOnly, for: nil)
        check(store.mode(for: nil, default: fallback) == .coverOnly && store.hasOverride(for: nil), "All has its own override")
        let reloaded = LibraryDisplayStore(json: store.json)
        check(reloaded.mode(for: "Manga", default: fallback) == .list, "round trips through JSON")
        store.reset("Manga")
        check(!store.hasOverride(for: "Manga") && store.hasOverride(for: nil), "reset removes one override")
        check(LibraryDisplayStore(json: "garbage").mode(for: nil, default: fallback) == fallback, "bad JSON falls back to default")
        let stale = LibraryDisplayStore(json: #"{"Manga":"Hologram","Novels":"List"}"#)
        check(stale.mode(for: "Manga", default: fallback) == fallback && stale.mode(for: "Novels", default: fallback) == .list, "unknown mode drops only itself")

        // The category editor keys every override by name. A rename has to
        // carry it across, and a delete has to drop only that key.
        var renamed = LibraryDisplayStore()
        renamed.set(.list, for: "Manga")
        renamed.set(.coverOnly, for: "Novels")
        renamed.rename(from: "Manga", to: "Comics")
        check(renamed.mode(for: "Comics", default: fallback) == .list, "rename moves the display override")
        check(!renamed.hasOverride(for: "Manga"), "rename drops the old display key")
        check(renamed.mode(for: "Novels", default: fallback) == .coverOnly, "rename leaves other categories alone")
        renamed.rename(from: "Missing", to: "Ghost")
        check(!renamed.hasOverride(for: "Ghost"), "renaming a category with no override is a no-op")
        renamed.remove("Comics")
        check(!renamed.hasOverride(for: "Comics") && renamed.hasOverride(for: "Novels"), "delete drops one display override")

        var filters = LibraryFilterStore()
        var active = LibraryFilter()
        active.unread = .include
        filters.set(active, for: "Manga")
        filters.set(active, for: nil)
        filters.rename(from: "Manga", to: "Comics")
        check(filters.filter(for: "Comics").unread == .include, "rename moves the filter override")
        check(filters.filter(for: "Manga").unread == .off, "rename drops the old filter key")
        check(filters.filter(for: nil).unread == .include, "renaming a category leaves All alone")
        filters.remove("Comics")
        check(filters.filter(for: "Comics").unread == .off && filters.filter(for: nil).unread == .include, "delete drops one filter override")

        print("PASS: category settings — update flag, update scope, per-category display/filter stores, name migration")
    }
}
