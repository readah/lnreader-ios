// TrackingManager.swift
// Keeps AniList in step with reading: bind a title, push progress when a
// chapter is finished, and queue the push when the network is not there.

import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
@Observable
final class TrackingManager {

    private(set) var userName: String?
    private(set) var userId: Int?
    /// Stored so views observe it. Set from the Keychain at launch and when
    /// protected data becomes available (a launch before the first unlock reads
    /// nothing), then only by `login` and `logout`.
    private(set) var isLoggedIn = false

    /// "Update AniList when a chapter is finished". On by default.
    var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateKey) }
    }
    private static let autoUpdateKey = "tracking.autoUpdate"
    private static let nameKey = "tracking.anilist.name"
    private static let idKey = "tracking.anilist.id"

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var debounce: [PersistentIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Manual "mark as read" bursts (a dozen taps, a bulk select) collapse into one update.
    private static let debounceInterval: Duration = .seconds(3)

    init() {
        userName = UserDefaults.standard.string(forKey: Self.nameKey)
        let stored = UserDefaults.standard.integer(forKey: Self.idKey)
        userId = stored == 0 ? nil : stored
        isLoggedIn = AniListClient.shared.token != nil
    }

    func configure(container: ModelContainer) {
        self.container = container
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: Notification.Name("LNReaderNetworkChanged"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.flushPending() }
            },
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isLoggedIn else { return }
                    self.isLoggedIn = AniListClient.shared.token != nil
                    await self.flushPending()
                }
            },
        ]
    }

    // MARK: - Account

    func login() async throws {
        _ = try await AniListClient.shared.login()
        // Before `viewer()`, which can fail: the token is saved either way.
        isLoggedIn = AniListClient.shared.token != nil
        let viewer = try await AniListClient.shared.viewer()
        userId = viewer.id
        userName = viewer.name
        UserDefaults.standard.set(viewer.id, forKey: Self.idKey)
        UserDefaults.standard.set(viewer.name, forKey: Self.nameKey)
        await flushPending()
    }

    func logout() {
        AniListClient.shared.logout()
        isLoggedIn = false
        userId = nil
        userName = nil
        UserDefaults.standard.removeObject(forKey: Self.idKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
    }

    private func requireUser() async throws -> Int {
        guard isLoggedIn else { throw AniListError.notLoggedIn }
        if let userId { return userId }
        let viewer = try await AniListClient.shared.viewer()
        userId = viewer.id
        UserDefaults.standard.set(viewer.id, forKey: Self.idKey)
        return viewer.id
    }

    /// A rejected token means the login is gone; say so instead of failing forever.
    private func handle(_ error: Error) -> Error {
        if case AniListError.unauthorized = error { logout() }
        return error
    }

    // MARK: - Lookup

    func aniListTrack(for entry: Entry) -> Track? {
        entry.tracks.first { $0.syncId == TrackerID.aniList }
    }

    func search(_ text: String, kind: ContentKind) async throws -> [TrackSearchResult] {
        do { return try await AniListClient.shared.search(text, novel: kind == .novel) }
        catch { throw handle(error) }
    }

    // MARK: - Bind, edit, remove

    /// Start tracking `entry` as `result`. Progress is the larger of what is read
    /// here and what AniList already has, so binding never rolls anything back.
    @discardableResult
    func bind(
        _ result: TrackSearchResult, to entry: Entry, isPrivate: Bool = false, context: ModelContext
    ) async throws -> Track {
        do {
            let user = try await requireUser()
            let existing = try await AniListClient.shared.entry(mediaId: result.id, userId: user)
            let local = Int(highestRead(in: entry))
            let progress = max(local, existing?.progress ?? 0)
            let total = existing?.total ?? result.totalChapters

            var status = existing?.status ?? (progress > 0 ? .reading : .planning)
            if existing == nil || existing?.status == .planning, progress > 0 { status = .reading }
            if total > 0, progress >= total { status = .completed }

            let now = Date.now
            let start = existing?.start ?? (progress > 0 ? (earliestRead(in: entry) ?? now) : nil)
            let finish = status == .completed ? (existing?.finish ?? now) : existing?.finish

            let saved = try await AniListClient.shared.save(
                mediaId: result.id, progress: progress, status: status, start: start, finish: finish,
                isPrivate: isPrivate)

            if let old = aniListTrack(for: entry) { context.delete(old) }
            let track = Track(syncId: TrackerID.aniList, remoteId: result.id, title: saved.title)
            context.insert(track)
            track.entry = entry
            apply(saved, to: track, fallbackTotal: result.totalChapters)
            if track.remoteURL.isEmpty { track.remoteURL = result.url }
            try? context.save()
            LibraryChapterCounts.shared.invalidate()
            return track
        } catch { throw handle(error) }
    }

    /// A manual edit from the tracker sheet. Only the fields given are changed.
    func update(
        _ track: Track, status: TrackStatus? = nil, progress: Int? = nil, score: Double? = nil,
        start: Date?? = nil, finish: Date?? = nil, isPrivate: Bool? = nil, context: ModelContext
    ) async throws {
        do {
            _ = try await requireUser()
            let saved = try await AniListClient.shared.save(
                mediaId: track.remoteId, progress: progress, status: status, score: score,
                start: start.flatMap { $0 }, finish: finish.flatMap { $0 },
                clearStart: start != nil && start! == nil, clearFinish: finish != nil && finish! == nil,
                isPrivate: isPrivate)
            apply(saved, to: track, fallbackTotal: track.totalChapters)
            try? context.save()
        } catch { throw handle(error) }
    }

    func remove(_ track: Track, fromAniList: Bool, context: ModelContext) async throws {
        do {
            if fromAniList, let listId = track.libraryId, listId != 0 {
                try await AniListClient.shared.delete(listId: listId)
            }
        } catch { throw handle(error) }
        if let entry = track.entry {
            for pending in entry.pendingTrackUpdates where pending.syncId == track.syncId { context.delete(pending) }
        }
        context.delete(track)
        try? context.save()
        LibraryChapterCounts.shared.invalidate()
    }

    private func apply(_ remote: RemoteTrack, to track: Track, fallbackTotal: Int) {
        track.remoteId = remote.mediaId
        track.libraryId = remote.listId
        track.title = remote.title.isEmpty ? track.title : remote.title
        track.lastChapterRead = Double(remote.progress)
        track.totalChapters = remote.total > 0 ? remote.total : fallbackTotal
        track.status = remote.status.rawValue
        track.score = remote.score
        track.startDate = remote.start
        track.finishDate = remote.finish
        track.isPrivate = remote.isPrivate
        if !remote.url.isEmpty { track.remoteURL = remote.url }
    }

    // MARK: - Reading progress

    /// A chapter was finished or marked read. Cheap to call: it returns at once
    /// for a title that is not tracked, and coalesces bursts.
    func readStateChanged(entry: Entry) {
        guard autoUpdate, isLoggedIn, aniListTrack(for: entry) != nil else { return }
        let id = entry.persistentModelID
        debounce[id]?.cancel()
        debounce[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.debounce[id] = nil
            self.queueProgress(for: entry)
            await self.flushPending()
        }
    }

    /// Record the highest read chapter on the track and queue it for AniList.
    private func queueProgress(for entry: Entry) {
        guard let track = aniListTrack(for: entry), let context = entry.modelContext else { return }
        let read = highestRead(in: entry)
        guard read > track.lastChapterRead else { return }

        track.lastChapterRead = read
        let current = TrackStatus(rawValue: track.status)
        if current == nil || current == .planning || current == .onHold || current == .dropped { track.status = TrackStatus.reading.rawValue }
        if track.startDate == nil { track.startDate = .now }
        if track.totalChapters > 0, Int(read) >= track.totalChapters {
            track.status = TrackStatus.completed.rawValue
            if track.finishDate == nil { track.finishDate = .now }
        }

        if let pending = entry.pendingTrackUpdates.first(where: { $0.syncId == track.syncId }) {
            pending.chapterNumber = max(pending.chapterNumber, read)
        } else {
            let pending = PendingTrackUpdate(syncId: track.syncId, chapterNumber: read)
            context.insert(pending)
            pending.entry = entry
        }
        try? context.save()
    }

    /// Send every queued update. Failures stay queued; the next foreground,
    /// network change or finished chapter tries again.
    func flushPending() async {
        guard isLoggedIn, !isFlushing, let container else { return }
        isFlushing = true
        defer { isFlushing = false }

        let context = container.mainContext
        let pending = (try? context.fetch(FetchDescriptor<PendingTrackUpdate>())) ?? []
        for item in pending {
            guard let entry = item.entry, let track = aniListTrack(for: entry) else {
                context.delete(item)
                continue
            }
            do {
                let saved = try await AniListClient.shared.save(
                    mediaId: track.remoteId,
                    progress: Int(item.chapterNumber.rounded(.down)),
                    status: TrackStatus(rawValue: track.status),
                    start: track.startDate, finish: track.finishDate)
                // Keep a higher local figure if more was read while this was in flight.
                let localProgress = track.lastChapterRead
                apply(saved, to: track, fallbackTotal: track.totalChapters)
                track.lastChapterRead = max(track.lastChapterRead, localProgress)
                context.delete(item)
            } catch AniListError.unauthorized {
                _ = handle(AniListError.unauthorized)
                break
            } catch {
                continue
            }
        }
        try? context.save()
    }

    // MARK: - Local facts

    private func highestRead(in entry: Entry) -> Double {
        guard let context = entry.modelContext else { return 0 }
        let id = entry.persistentModelID
        var descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate { $0.entry?.persistentModelID == id && $0.read && $0.chapterNumber > 0 },
            sortBy: [SortDescriptor(\Chapter.chapterNumber, order: .reverse)])
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first?.chapterNumber) ?? 0
    }

    private func earliestRead(in entry: Entry) -> Date? {
        guard let context = entry.modelContext else { return nil }
        let id = entry.persistentModelID
        var descriptor = FetchDescriptor<SchemaV2.History>(
            predicate: #Predicate { $0.chapter?.entry?.persistentModelID == id },
            sortBy: [SortDescriptor(\SchemaV2.History.lastRead)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.lastRead
    }
}
