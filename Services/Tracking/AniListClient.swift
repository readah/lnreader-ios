// AniListClient.swift
// AniList login (OAuth implicit grant) and the GraphQL calls tracking needs.

import AuthenticationServices
import Foundation
import Security

/// Tachiyomi's tracker ids and status numbers, kept so `.tachibk` backups line up.
enum TrackerID {
    static let aniList = 2
}

enum TrackStatus: Int, CaseIterable, Identifiable {
    case reading = 1, completed, onHold, dropped, planning, rereading
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reading: "Reading"
        case .completed: "Completed"
        case .onHold: "On hold"
        case .dropped: "Dropped"
        case .planning: "Plan to read"
        case .rereading: "Rereading"
        }
    }

    var aniList: String {
        switch self {
        case .reading: "CURRENT"
        case .completed: "COMPLETED"
        case .onHold: "PAUSED"
        case .dropped: "DROPPED"
        case .planning: "PLANNING"
        case .rereading: "REPEATING"
        }
    }

    init?(aniList: String) {
        guard let match = Self.allCases.first(where: { $0.aniList == aniList }) else { return nil }
        self = match
    }
}

struct TrackSearchResult: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let cover: URL?
    let format: String
    let totalChapters: Int
    let year: Int?
    let url: String
}

/// A user's list entry on AniList.
struct RemoteTrack: Sendable {
    var listId: Int64
    var mediaId: Int64
    var title: String
    var progress: Int
    var total: Int
    var status: TrackStatus
    /// 0–100, whatever the user's score format is.
    var score: Double
    var start: Date?
    var finish: Date?
    var isPrivate: Bool
    var url: String
}

enum AniListError: LocalizedError {
    case notLoggedIn, unauthorized, cancelled
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Log in to AniList first."
        case .unauthorized: "Your AniList login expired. Log in again."
        case .cancelled: "Login cancelled."
        case .server(let message): message
        }
    }
}

enum AniListConfig {
    /// A public identifier, not a secret: the implicit flow has no client secret.
    static let clientID = "54859"
    /// Must match the redirect URL registered for the client at anilist.co/settings/developer.
    static let callbackScheme = "lnreader"
    static let redirect = "lnreader://anilist-auth"
}

/// The token lives in the Keychain, never in UserDefaults or a backup.
///
/// Reads are cached: `SecItemCopyMatching` is a synchronous IPC to `securityd`,
/// and every AniList request reads the token.
enum AniListTokenStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.lnreader.anilist",
        kSecAttrAccount as String: "token",
    ]

    private static let lock = NSLock()
    /// `nil`: the Keychain has not been asked yet. `.some(nil)`: it has no token.
    private static var cached: String??

    static func load() -> String? {
        lock.withLock {
            if let cached { return cached }

            var result: CFTypeRef?
            let query = base.merging([kSecReturnData as String: true]) { _, new in new }
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            // A locked device (before the first unlock after a reboot) is not an
            // answer; caching it would keep the app logged out until relaunch.
            guard status == errSecSuccess || status == errSecItemNotFound else { return nil }

            let token = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            cached = .some(token)
            return token
        }
    }

    static func save(_ token: String) {
        lock.withLock {
            SecItemDelete(base as CFDictionary)
            let add = base.merging([
                kSecValueData as String: Data(token.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new }
            // Cache only a token that reached the Keychain, or the login is gone at launch.
            cached = SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? .some(token) : nil
        }
    }

    static func clear() {
        lock.withLock {
            SecItemDelete(base as CFDictionary)
            cached = .some(nil)
        }
    }
}

final class AniListClient: @unchecked Sendable {
    static let shared = AniListClient()
    private let endpoint = URL(string: "https://graphql.anilist.co")!

    var token: String? { AniListTokenStore.load() }

    // MARK: Login

    @MainActor
    func login() async throws -> String {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: AniListConfig.clientID),
            .init(name: "response_type", value: "token"),
        ]
        let anchor = WebAuthAnchor()
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!, callbackURLScheme: AniListConfig.callbackScheme
            ) { url, error in
                if let url { continuation.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: AniListError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AniListError.cancelled)
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            anchorHolder = (session, anchor)
            session.start()
        }
        anchorHolder = nil
        // The token comes back in the fragment: lnreader://anilist-auth#access_token=…
        let fragment = URLComponents(string: "?" + (url.fragment ?? ""))
        guard let token = fragment?.queryItems?.first(where: { $0.name == "access_token" })?.value else {
            throw AniListError.server("AniList did not return a token.")
        }
        AniListTokenStore.save(token)
        return token
    }

    @MainActor private var anchorHolder: (ASWebAuthenticationSession, WebAuthAnchor)?

    func logout() { AniListTokenStore.clear() }

    // MARK: Requests

    private func send(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let token else { throw AniListError.notLoggedIn }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AniListError.unauthorized }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            if (first["status"] as? Int) == 401 { throw AniListError.unauthorized }
            // "Not Found." on MediaList means the title is simply not on the list.
            throw AniListError.server(first["message"] as? String ?? "AniList error")
        }
        guard status == 200, let payload = json["data"] as? [String: Any] else {
            throw AniListError.server("AniList returned HTTP \(status).")
        }
        return payload
    }

    func viewer() async throws -> (id: Int, name: String) {
        let data = try await send("query { Viewer { id name } }")
        guard let viewer = data["Viewer"] as? [String: Any], let id = viewer["id"] as? Int else {
            throw AniListError.server("Could not read your AniList profile.")
        }
        return (id, viewer["name"] as? String ?? "")
    }

    func search(_ text: String, novel: Bool) async throws -> [TrackSearchResult] {
        let formats = novel ? ["NOVEL"] : ["MANGA", "ONE_SHOT"]
        let query = """
        query($search: String, $formats: [MediaFormat]) {
          Page(perPage: 25) {
            media(search: $search, type: MANGA, format_in: $formats) {
              id siteUrl format chapters
              title { romaji english }
              coverImage { medium }
              startDate { year }
            }
          }
        }
        """
        let data = try await send(query, variables: ["search": text, "formats": formats])
        let media = ((data["Page"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        return media.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            let title = item["title"] as? [String: Any]
            let name = (title?["english"] as? String) ?? (title?["romaji"] as? String) ?? "Untitled"
            return TrackSearchResult(
                id: Int64(id), title: name,
                cover: ((item["coverImage"] as? [String: Any])?["medium"] as? String).flatMap(URL.init(string:)),
                format: (item["format"] as? String ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
                totalChapters: item["chapters"] as? Int ?? 0,
                year: (item["startDate"] as? [String: Any])?["year"] as? Int,
                url: item["siteUrl"] as? String ?? "https://anilist.co/manga/\(id)"
            )
        }
    }

    private static let entryFields = """
    id progress status private scoreRaw: score(format: POINT_100)
    startedAt { year month day } completedAt { year month day }
    media { id siteUrl chapters title { romaji english } }
    """

    /// The signed-in user's entry for a title, or nil when it is not on their list.
    func entry(mediaId: Int64, userId: Int) async throws -> RemoteTrack? {
        let query = "query($m: Int, $u: Int) { MediaList(mediaId: $m, userId: $u) { \(Self.entryFields) } }"
        do {
            let data = try await send(query, variables: ["m": Int(mediaId), "u": userId])
            return (data["MediaList"] as? [String: Any]).flatMap(Self.remote)
        } catch AniListError.server(let message) where message.lowercased().contains("not found") {
            return nil
        }
    }

    /// Create or update an entry. Only the fields given are sent.
    func save(
        mediaId: Int64, progress: Int? = nil, status: TrackStatus? = nil, score: Double? = nil,
        start: Date? = nil, finish: Date? = nil, clearStart: Bool = false, clearFinish: Bool = false,
        isPrivate: Bool? = nil
    ) async throws -> RemoteTrack {
        var variables: [String: Any] = ["mediaId": Int(mediaId)]
        var declared = ["$mediaId: Int"], passed = ["mediaId: $mediaId"]
        func add(_ name: String, _ type: String, _ value: Any) {
            variables[name] = value
            declared.append("$\(name): \(type)")
            passed.append("\(name): $\(name)")
        }
        if let progress { add("progress", "Int", progress) }
        if let status { add("status", "MediaListStatus", status.aniList) }
        if let isPrivate { add("private", "Boolean", isPrivate) }
        if let score { add("score", "Int", Int(score.rounded())) }
        if let start { add("startedAt", "FuzzyDateInput", Self.fuzzy(start)) }
        else if clearStart { add("startedAt", "FuzzyDateInput", ["year": NSNull(), "month": NSNull(), "day": NSNull()]) }
        if let finish { add("completedAt", "FuzzyDateInput", Self.fuzzy(finish)) }
        else if clearFinish { add("completedAt", "FuzzyDateInput", ["year": NSNull(), "month": NSNull(), "day": NSNull()]) }
        // `scoreRaw` is the 0–100 field regardless of the user's display format.
        let arguments = passed.map { $0.hasPrefix("score:") ? "scoreRaw: $score" : $0 }.joined(separator: ", ")
        let query = "mutation(\(declared.joined(separator: ", "))) { SaveMediaListEntry(\(arguments)) { \(Self.entryFields) } }"
        let data = try await send(query, variables: variables)
        guard let saved = (data["SaveMediaListEntry"] as? [String: Any]).flatMap(Self.remote) else {
            throw AniListError.server("AniList did not confirm the update.")
        }
        return saved
    }

    func delete(listId: Int64) async throws {
        _ = try await send(
            "mutation($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }",
            variables: ["id": Int(listId)])
    }

    // MARK: Mapping

    private static func fuzzy(_ date: Date) -> [String: Int] {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return ["year": parts.year ?? 0, "month": parts.month ?? 0, "day": parts.day ?? 0]
    }

    private static func date(_ value: Any?) -> Date? {
        guard let dict = value as? [String: Any], let year = dict["year"] as? Int else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: year, month: dict["month"] as? Int ?? 1, day: dict["day"] as? Int ?? 1))
    }

    private static func remote(_ item: [String: Any]) -> RemoteTrack? {
        guard let id = item["id"] as? Int, let media = item["media"] as? [String: Any],
              let mediaId = media["id"] as? Int else { return nil }
        let title = media["title"] as? [String: Any]
        return RemoteTrack(
            listId: Int64(id), mediaId: Int64(mediaId),
            title: (title?["english"] as? String) ?? (title?["romaji"] as? String) ?? "",
            progress: item["progress"] as? Int ?? 0,
            total: media["chapters"] as? Int ?? 0,
            status: TrackStatus(aniList: item["status"] as? String ?? "") ?? .planning,
            score: (item["scoreRaw"] as? NSNumber)?.doubleValue ?? 0,
            start: date(item["startedAt"]), finish: date(item["completedAt"]),
            isPrivate: item["private"] as? Bool ?? false,
            url: media["siteUrl"] as? String ?? "")
    }
}

private final class WebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
