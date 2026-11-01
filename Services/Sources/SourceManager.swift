// SourceManager.swift - The registry of installed sources.
//
// Every source is compiled into the app (`NativeSources`), so there is nothing to install:
// the registry is filled once at launch and the UI reads it.

import Foundation
import Observation

/// Registry of every source the app can browse, of both kinds.
@Observable
@MainActor
final class SourceManager {

    /// Installed sources keyed by `sourceKey`.
    private(set) var sources: [String: any CatalogSource] = [:]

    /// Last failure from a registry or install operation.
    private(set) var lastError: Error?

    /// Set while sources are being (re)loaded from disk.
    private(set) var isLoading = false

    static let hideAdultSourcesKey = "browse.hideAdultSources"

    /// Drops adult sources from every listing: Browse, global search and the
    /// pickers. Lookups (`source(forKey:)`, `novelSource(forKey:)`) still resolve
    /// them, so a library entry that already points at one keeps working.
    var hidesAdultSources: Bool {
        didSet {
            UserDefaults.standard.set(hidesAdultSources, forKey: Self.hideAdultSourcesKey)
        }
    }

    init() {
        hidesAdultSources = UserDefaults.standard.bool(forKey: Self.hideAdultSourcesKey)
        // Not from the launch task: a link can open an entry before that task
        // (which awaits the sync pull) has run.
        registerNativeSources()
    }

    // MARK: Registration

    func register(_ source: any CatalogSource) {
        sources[source.key] = source
    }

    func unregister(key: String) {
        sources.removeValue(forKey: key)
    }

    func replaceAll(with newSources: [any CatalogSource]) {
        sources = Dictionary(uniqueKeysWithValues: newSources.map { ($0.key, $0) })
    }

    // MARK: Lookup

    func source(forKey key: String) -> (any CatalogSource)? {
        sources[key]
    }

    func source(for entry: Entry) -> (any CatalogSource)? {
        sources[entry.sourceKey]
    }

    /// All sources, novels first, then alphabetically inside each kind.
    var allSources: [any CatalogSource] {
        let visible = hidesAdultSources
            ? sources.values.filter { !$0.isAdult }
            : Array(sources.values)

        return visible.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .novel }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func sources(of kind: ContentKind) -> [any CatalogSource] {
        allSources.filter { $0.kind == kind }
    }

    var novelSources: [any CatalogSource] { sources(of: .novel) }
    var mangaSources: [any CatalogSource] { sources(of: .manga) }

    /// Languages present across installed sources, for the browse filter.
    var availableLanguages: [String] {
        Array(Set(sources.values.map(\.lang))).sorted()
    }

    func novelSource(forKey key: String) -> (any NovelSource)? {
        sources[key] as? any NovelSource
    }

    func mangaSource(forKey key: String) -> (any MangaSource)? {
        sources[key] as? any MangaSource
    }

    // MARK: Native sources

    /// Register every source compiled into the app. Idempotent.
    func registerNativeSources() {
        for source in NativeSources.all() where sources[source.key] == nil {
            register(source)
        }
    }
}
