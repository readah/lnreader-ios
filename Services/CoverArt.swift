// CoverArt.swift
// Cover lookup against AniList, and when it is allowed to replace a source cover.

import Foundation

/// One cover AniList offers for a search.
struct CoverCandidate: Identifiable, Hashable, Sendable {
    let id: Int64
    /// The name shown in the picker.
    let title: String
    /// Every name AniList holds for the work, for automatic matching.
    let titles: [String]
    let format: String
    let year: Int?
    let coverURL: String
}

enum CoverArtError: LocalizedError {
    case anilist(String)

    var errorDescription: String? {
        switch self {
        case .anilist(let message): message
        }
    }
}

/// The free AniList GraphQL API: 460×722 `extraLarge` covers for manga and
/// light novels, no key and no login.
enum CoverArt {

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private static let autoOffPrefix = "cover.auto-off."

    // MARK: - Search

    /// AniList's search results, in its own relevance order.
    ///
    /// - Parameter isNovel: novels ask for `NOVEL` only, manga for
    ///   `MANGA`/`ONE_SHOT`. An adaptation's cover is a different work's art.
    static func candidates(for query: String, isNovel: Bool) async throws -> [CoverCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let formats = isNovel ? ["NOVEL"] : ["MANGA", "ONE_SHOT"]
        let query = """
        query($search: String, $formats: [MediaFormat]) {
          Page(perPage: 20) {
            media(search: $search, type: MANGA, format_in: $formats) {
              id format startDate { year }
              title { romaji english native }
              coverImage { extraLarge large }
            }
          }
        }
        """
        let payload: SearchPayload = try await send(query, variables: ["search": text, "formats": formats])
        return payload.Page.media.compactMap(CoverCandidate.init)
    }

    /// The cover for a tracker binding, without a title search.
    static func cover(mediaID: Int64) async -> String? {
        let query = """
        query($id: Int) {
          Media(id: $id) { coverImage { extraLarge large } }
        }
        """
        guard let payload: MediaPayload = try? await send(query, variables: ["id": Int(mediaID)]) else {
            return nil
        }
        return payload.Media.coverImage?.best
    }

    // MARK: - Automatic choice

    /// A cover AniList is confident is this book's, or nil.
    ///
    /// A bound tracker entry is trusted by id. Otherwise the first search hit
    /// whose title passes `CoverMatching.isSameBook` wins; a near miss returns
    /// nil so the source's own cover stays until the user picks one.
    static func bestCover(title: String, isNovel: Bool, mediaID: Int64?) async -> String? {
        // `remoteId` is 0 until a bind writes one; asking for media 0 would spend
        // a request to learn nothing.
        if let mediaID, mediaID > 0, let direct = await cover(mediaID: mediaID) { return direct }
        guard let results = try? await candidates(for: title, isNovel: isNovel) else { return nil }
        return results
            .first { candidate in
                candidate.titles.contains { CoverMatching.isSameBook(title, $0) }
            }?
            .coverURL
    }

    // MARK: - Opting out

    private static func autoOffKey(sourceKey: String, url: String) -> String {
        autoOffPrefix + sourceKey + "::" + url
    }

    /// The user chose the source's cover; automatic lookup must not undo that
    /// on the next visit.
    static func isAutoDisabled(sourceKey: String, url: String) -> Bool {
        UserDefaults.standard.bool(forKey: autoOffKey(sourceKey: sourceKey, url: url))
    }

    static func disableAuto(sourceKey: String, url: String) {
        UserDefaults.standard.set(true, forKey: autoOffKey(sourceKey: sourceKey, url: url))
    }

    // MARK: - GraphQL

    private static func send<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let request = HTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: body)
        let response = try await HTTPClient.covers.send(request)
        let envelope = try response.decoded(Envelope<T>.self)
        if let failure = envelope.errors?.first?.message, !failure.isEmpty {
            throw CoverArtError.anilist(failure)
        }
        guard let payload = envelope.data else {
            throw CoverArtError.anilist("AniList returned no data.")
        }
        return payload
    }

    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let message: String? }
        let data: T?
        let errors: [Failure]?
    }

    private struct SearchPayload: Decodable {
        let Page: Page
        struct Page: Decodable { let media: [Media] }
    }

    private struct MediaPayload: Decodable {
        let Media: Media
    }

    fileprivate struct Media: Decodable {
        struct Titles: Decodable {
            let romaji: String?
            let english: String?
            let native: String?
        }
        struct Cover: Decodable {
            let extraLarge: String?
            let large: String?
            var best: String? { extraLarge ?? large }
        }
        struct StartDate: Decodable { let year: Int? }

        let id: Int
        let format: String?
        let startDate: StartDate?
        let title: Titles?
        let coverImage: Cover?
    }
}

fileprivate extension CoverCandidate {
    init?(media: CoverArt.Media) {
        let names = [media.title?.english, media.title?.romaji, media.title?.native]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard let cover = media.coverImage?.best, !cover.isEmpty else { return nil }
        self.init(
            id: Int64(media.id),
            title: names.first ?? "Untitled",
            titles: names,
            format: (media.format ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
            year: media.startDate?.year,
            coverURL: cover)
    }
}
