import AVFoundation
import Combine
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Explicit downloads live in Application Support and are never automatically evicted.
enum TTSStorage {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LNReaderAudio", isDirectory: true) }
    static func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func audio(_ id: String) -> URL { directory(id).appendingPathComponent("audio.m4a") }
    static func validID(_ id: String) -> Bool { id.count == 64 && id.allSatisfy(\.isHexDigit) }
    static func voiceDirectory(_ id: String) -> URL {
        // Never use a server-supplied path component directly.
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let backend = SHA256.hash(data: Data(TTSAPIClient().baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("voice-samples").appendingPathComponent(backend).appendingPathComponent(key)
    }
    static func chapterText(bookId: String, chapterId: String) -> URL {
        let id = SHA256.hash(data: Data((bookId + "\u{0}" + chapterId).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("chapters", isDirectory: true).appendingPathComponent(id + ".json")
    }
    static func verify(staged: URL, manifest: TTSManifest) async throws {
        try manifest.validate()
        let valid = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: staged)
            defer { try? handle.close() }
            var hash = SHA256(), size: Int64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data); size += Int64(data.count) }
            return size == manifest.audioBytes && hash.finalize().map { String(format: "%02x", $0) }.joined() == manifest.audioSHA256
        }.value
        guard valid else { throw TTSError.corruptDownload }
        let actual = try await AVURLAsset(url: staged).load(.duration).seconds
        guard actual.isFinite, abs(actual - manifest.duration) < 0.25 else { throw TTSError.corruptDownload }
    }
    static func commit(staged: URL, manifest: TTSManifest) throws {
        let folder = directory(manifest.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var safeManifest = manifest; safeManifest.audioURL = nil
        try JSONEncoder().encode(safeManifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        let textPath = chapterText(bookId: manifest.bookId, chapterId: manifest.chapterId)
        try FileManager.default.createDirectory(at: textPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = TTSChapterText(bookId: manifest.bookId, chapterId: manifest.chapterId, contentRevision: manifest.contentRevision, title: manifest.title, position: manifest.position, blocks: manifest.blocks)
        try JSONEncoder().encode(text).write(to: textPath, options: .atomic)
        let destination = audio(manifest.id)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #endif
    }
    static func streamManifest(_ id: String) -> URL { directory(id).appendingPathComponent("stream.json") }
    static func streamPart(_ id: String, _ part: TTSStreamPart) -> URL {
        directory(id).appendingPathComponent("parts").appendingPathComponent(part.sha256 + "." + part.format)
    }
    static func cacheStream(_ manifest: TTSStreamingManifest) throws {
        var local = manifest
        for i in local.parts.indices { local.parts[i].audioURL = nil }
        try FileManager.default.createDirectory(at: directory(manifest.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(local).write(to: streamManifest(manifest.id), options: .atomic)
    }
    static func loadStreamPart(_ id: String, part: TTSStreamPart, client: TTSAPIClient) async throws -> URL {
        let target = streamPart(id, part)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let path = part.audioURL else { throw TTSError.request("Connect to load the next audio part.") }
        let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: try client.url(path)))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TTSError.request("This audio part is not available. Reconnecting…") }
        let valid = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: temporary)
            return data.count == part.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == part.sha256
        }.value
        guard valid else { throw TTSError.corruptDownload }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: temporary, to: target) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        #endif
        return target
    }

}

private final class TTSInstallEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func begin() { lock.lock(); count += 1; lock.unlock() }
    func finish() { lock.lock(); count -= 1; lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
}

@MainActor
final class TTSOfflineLibrary: NSObject, ObservableObject {
    static let shared = TTSOfflineLibrary()
    @Published private(set) var records: [TTSDownloadRecord] = []
    @Published private(set) var voices = TTSVoice.presets
    @Published private(set) var engineState: TTSEngineState?
    @Published var errorMessage: String?
    @Published private(set) var isRefreshing = false
    var backgroundCompletion: (() -> Void)? { didSet { finishBackgroundEventsIfPossible() } }
    private var backgroundEventsFinished = false
    private nonisolated let installEvents = TTSInstallEvents()
    private var refreshTask: Task<Void, Never>?
    private var lastProgressSave = Date.distantPast
    private var lastVoiceRefresh = Date.distantPast
    private var pendingDeletions: [TTSAudioDeletion] = []
    private var deletionTask: Task<Void, Error>?
    private var deletionURL: URL { TTSStorage.root.appendingPathComponent("pending-deletions.json") }
    private lazy var session: URLSession = {
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: "com.lnreader.audio.downloads.v1")
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.httpCookieStorage = .shared; config.httpMaximumConnectionsPerHost = 3; config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var indexURL: URL { TTSStorage.root.appendingPathComponent("downloads.json") }
    private override init() {
        super.init()
        do {
            try FileManager.default.createDirectory(at: TTSStorage.root, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: deletionURL) { pendingDeletions = try JSONDecoder().decode([TTSAudioDeletion].self, from: data) }
            if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([TTSDownloadRecord].self, from: data) { records = saved }
            records.removeAll { record in pendingDeletions.contains { $0.backendURL == record.backendURL && $0.bookId == record.rendition.bookId && $0.chapterId == record.rendition.chapterId && $0.voiceId == record.rendition.voiceId } }
            if let data = try? Data(contentsOf: TTSStorage.root.appendingPathComponent("voices.json")), let saved = try? JSONDecoder().decode([TTSVoice].self, from: data) {
                let current = saved.filter { !$0.id.hasPrefix("qwen-") }
                voices = current + TTSVoice.presets.filter { preset in !current.contains { $0.id == preset.id } }
            }
            if UserDefaults.standard.string(forKey: "tts.voice")?.hasPrefix("qwen-") == true {
                UserDefaults.standard.set("breeze-warm", forKey: "tts.voice")
            }
            // Recover a completed atomic package if iOS terminated us before the index commit.
            for directory in try FileManager.default.contentsOfDirectory(at: TTSStorage.root, includingPropertiesForKeys: nil) where TTSStorage.validID(directory.lastPathComponent) {
                let id = directory.lastPathComponent
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONDecoder().decode(TTSManifest.self, from: data),
                      manifest.id == id, (try? manifest.validate()) != nil,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: TTSStorage.audio(id).path),
                      (attributes[.size] as? NSNumber)?.int64Value == manifest.audioBytes else { continue }
                if pendingDeletions.contains(where: { $0.bookId == manifest.bookId && $0.chapterId == manifest.chapterId && $0.voiceId == manifest.voiceId }) { try? FileManager.default.removeItem(at: directory); continue }
                let rendition = TTSRendition(id: id, voiceId: manifest.voiceId, status: "ready", bookId: manifest.bookId, chapterId: manifest.chapterId, bookTitle: manifest.bookTitle, title: manifest.title, position: manifest.position, contentRevision: manifest.contentRevision, completedChunks: 0, totalChunks: 0, error: nil, manifestURL: nil)
                if let index = records.firstIndex(where: { $0.id == id }) {
                    records[index].state = "downloaded"; records[index].manifest = manifest; records[index].error = nil
                    records[index].bytesExpected = manifest.audioBytes; records[index].bytesReceived = manifest.audioBytes
                } else {
                    records.append(.init(id: id, rendition: rendition, state: "downloaded", bytesReceived: manifest.audioBytes, bytesExpected: manifest.audioBytes, isPreview: ["breeze-previews", "qwen-previews", "custom-voice-previews"].contains(manifest.bookId), backendURL: TTSAPIClient().baseURL.absoluteString, manifest: manifest))
                }
            }
            for index in records.indices where records[index].isAvailable {
                if !TTSStorage.validID(records[index].id) || !FileManager.default.fileExists(atPath: TTSStorage.audio(records[index].id).path) {
                    records[index].state = "failed"; records[index].error = "Local audio is missing. Download again to repair."
                }
            }
        } catch { errorMessage = error.localizedDescription }
        save()
        Task { await reconcileTransfers(); await refreshVoices(); startRefreshLoop() }
        #if os(iOS)
        // Polling is pointless while suspended; resume only if something is still waiting.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRefreshLoop() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRefreshLoop() }
        }
        #endif
    }
    func reconnectBackgroundSession() { _ = session }
    private func finishBackgroundEventsIfPossible() {
        guard backgroundEventsFinished, installEvents.isEmpty, let completion = backgroundCompletion else { return }
        backgroundEventsFinished = false; backgroundCompletion = nil; completion()
    }
    private func save() {
        do { try JSONEncoder().encode(records).write(to: indexURL, options: .atomic) }
        catch { errorMessage = "Could not save audio downloads: \(error.localizedDescription)" }
    }
    func downloads(bookId: String, chapterId: String? = nil) -> [TTSDownloadRecord] {
        records.filter { !$0.isPreview && $0.rendition.bookId == bookId && (chapterId == nil || $0.rendition.chapterId == chapterId) }
    }
    func downloaded(bookId: String, chapterId: String, voiceId: String? = nil) -> TTSDownloadRecord? {
        downloads(bookId: bookId, chapterId: chapterId).filter { $0.isAvailable && (voiceId == nil || $0.rendition.voiceId == voiceId) }.sorted { $0.updatedAt > $1.updatedAt }.first
    }
    func localManifest(_ id: String) throws -> TTSManifest {
        guard TTSStorage.validID(id), records.contains(where: { $0.id == id && $0.isAvailable }), FileManager.default.fileExists(atPath: TTSStorage.audio(id).path) else { throw TTSError.missingAudio }
        let value = try JSONDecoder().decode(TTSManifest.self, from: Data(contentsOf: TTSStorage.directory(id).appendingPathComponent("manifest.json")))
        try value.validate(); return value
    }
    func localText(bookId: String, chapterId: String) -> TTSChapterText? {
        guard let data = try? Data(contentsOf: TTSStorage.chapterText(bookId: bookId, chapterId: chapterId)) else { return nil }
        return try? JSONDecoder().decode(TTSChapterText.self, from: data)
    }
    var migratedDefaultVoice: String {
        let value = UserDefaults.standard.string(forKey: "tts.voice") ?? "breeze-warm"
        return !value.hasPrefix("qwen-") && voices.contains(where: { $0.id == value }) ? value : "breeze-warm"
    }
    private func selectionKey(_ bookId: String, _ chapterId: String) -> String {
        "tts.selection." + SHA256.hash(data: Data((bookId + "\u{0}" + chapterId).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func selectedVoice(bookId: String, chapterId: String) -> String {
        let selected = UserDefaults.standard.string(forKey: selectionKey(bookId, chapterId)) ?? UserDefaults.standard.string(forKey: selectionKey(bookId, "__book_default__")) ?? migratedDefaultVoice
        if selected.hasPrefix("qwen-"), !records.contains(where: { $0.isAvailable && $0.rendition.bookId == bookId && $0.rendition.chapterId == chapterId && $0.rendition.voiceId == selected }) {
            return migratedDefaultVoice
        }
        return selected
    }
    func selectVoice(_ id: String, bookId: String, chapterId: String) { UserDefaults.standard.set(id, forKey: selectionKey(bookId, chapterId)); objectWillChange.send() }
    func setBookVoice(_ id: String, bookId: String) { selectVoice(id, bookId: bookId, chapterId: "__book_default__") }
    func refreshVoices() async {
        lastVoiceRefresh = Date()
        do {
            let client = TTSAPIClient()
            let catalogue = try await client.voiceCatalogue()
            voices = catalogue.voices
            if let preferred = catalogue.defaultVoice, voices.contains(where: { $0.id == preferred.voiceId }) {
                let key = "tts.appliedServerDefault." + client.baseURL.absoluteString
                if UserDefaults.standard.string(forKey: key) != preferred.revision {
                    UserDefaults.standard.set(preferred.voiceId, forKey: "tts.voice")
                    UserDefaults.standard.set(preferred.revision, forKey: key)
                }
            }
            try JSONEncoder().encode(voices).write(to: TTSStorage.root.appendingPathComponent("voices.json"), options: .atomic)
            for voice in voices {
                if voice.isCustom && voice.status == "ready" {
                    do { try await saveReferenceIfMissing(voice, client: client) }
                    catch { errorMessage = error.localizedDescription }
                }
                if let preview = voice.preview, voice.isCustom || preview.status == "ready", !records.contains(where: { $0.id == preview.id && ($0.isAvailable || $0.state == "downloading") }) { track(preview, client: client, preview: true) }
            }
            errorMessage = nil
            await refresh(includeEngine: false)
        } catch { errorMessage = error.localizedDescription }
    }
    private func saveReferenceIfMissing(_ voice: TTSVoice, client: TTSAPIClient) async throws {
        let folder = TTSStorage.voiceDirectory(voice.id), path = folder.appendingPathComponent("reference.flac")
        if FileManager.default.fileExists(atPath: path.path) { return }
        let data = try await client.voiceReference(voice.id)
        guard data.count == voice.sampleBytes, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == voice.sampleSHA256 else { throw TTSError.corruptDownload }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }
    func addCustomVoice(name: String, sample: URL, transcript: String) async throws -> TTSVoice {
        let data = try Data(contentsOf: sample)
        guard data.count <= 6_000_000 else { throw TTSError.request("Choose an audio sample smaller than 6 MB.") }
        let draft = TTSStorage.root.appendingPathComponent("voice-draft-" + UUID().uuidString)
        try data.write(to: draft, options: .atomic)
        defer { try? FileManager.default.removeItem(at: draft) }
        let client = TTSAPIClient()
        let voice = try await client.createVoice(name: name, audio: data, transcript: transcript)
        let folder = TTSStorage.voiceDirectory(voice.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: draft, to: folder.appendingPathComponent("original.audio"))
            voices.append(voice)
            try JSONEncoder().encode(voices).write(to: TTSStorage.root.appendingPathComponent("voices.json"), options: .atomic)
        } catch {
            voices.removeAll { $0.id == voice.id }
            try? await client.deleteVoice(voice.id)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        if let preview = voice.preview { track(preview, client: client, preview: true) }
        do { try await saveReferenceIfMissing(voice, client: client) }
        catch { errorMessage = error.localizedDescription }
        return voice
    }
    func deleteCustomVoice(_ voice: TTSVoice) async throws {
        try await TTSAPIClient().deleteVoice(voice.id)
        if TTSVoicePreviewPlayer.shared.voiceId == voice.id { TTSVoicePreviewPlayer.shared.stop() }
        // Only the reference and generated preview are removed. Book downloads stay.
        for record in records.filter({ $0.isPreview && $0.rendition.voiceId == voice.id }) { await delete(record.id) }
        voices.removeAll { $0.id == voice.id }
        try JSONEncoder().encode(voices).write(to: TTSStorage.root.appendingPathComponent("voices.json"), options: .atomic)
        try? FileManager.default.removeItem(at: TTSStorage.voiceDirectory(voice.id))
    }
    private func restoreReferences(_ ids: [String], client: TTSAPIClient) async throws {
        guard ids.contains(where: { $0.hasPrefix("custom-") }) else { return }
        let current = try await client.voices()
        for voice in current where ids.contains(voice.id) && voice.isCustom && voice.status == "evicted" {
            let path = TTSStorage.voiceDirectory(voice.id).appendingPathComponent("reference.flac")
            guard let data = try? Data(contentsOf: path) else { throw TTSError.request("The sample for \(voice.name) is missing. Add the voice again to prepare new chapters. Downloaded chapters still play.") }
            try await client.restoreVoice(voice.id, audio: data)
        }
    }
    func prepare(chapter: TTSChapterRequest, voiceIds: [String]) async throws {
        try await flushDeletions()
        let client = TTSAPIClient()
        try await restoreReferences(voiceIds, client: client)
        let renditions = try await client.prepare(chapter: chapter, voices: voiceIds)
        if let revision = renditions.first?.contentRevision {
            let blocks = chapter.blocks.map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let text = TTSChapterText(bookId: chapter.bookId, chapterId: chapter.chapterId, contentRevision: revision, title: chapter.title, position: chapter.position, blocks: blocks)
            let path = TTSStorage.chapterText(bookId: chapter.bookId, chapterId: chapter.chapterId)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(text).write(to: path, options: .atomic)
        }
        for rendition in renditions { track(rendition, client: client) }
        await refresh()
    }
    private func track(_ rendition: TTSRendition, client: TTSAPIClient, preview: Bool = false) {
        if let index = records.firstIndex(where: { $0.id == rendition.id }) {
            guard !records[index].isAvailable && records[index].state != "downloading" else { return }
            records[index].rendition = rendition; records[index].state = "waiting"; records[index].error = nil
        } else { records.append(.init(id: rendition.id, rendition: rendition, state: "waiting", isPreview: preview, backendURL: client.baseURL.absoluteString)) }
        save()
        startRefreshLoop()
    }
    private var hasWaiting: Bool { records.contains { $0.state == "waiting" } }
    private var refreshFailures = 0
    /// Polls only while a preparation is waiting on the server. Idle libraries make no requests.
    private func startRefreshLoop() {
        guard refreshTask == nil, hasWaiting else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = min(12 * pow(2.0, Double(self.refreshFailures)), 300)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self.hasWaiting else { break }
                await self.refresh()
            }
            if !Task.isCancelled { self?.refreshTask = nil }
        }
    }
    private func stopRefreshLoop() { refreshTask?.cancel(); refreshTask = nil }
    func refresh(includeEngine: Bool = true) async {
        guard !isRefreshing else { return }; isRefreshing = true; defer { isRefreshing = false }
        do { try await flushDeletions() }
        catch { errorMessage = "Server deletion is pending. Reconnect and sign in before preparing deleted chapters again." }
        if Date().timeIntervalSince(lastVoiceRefresh) > 30 && voices.contains(where: { $0.preview?.status != "ready" }) { await refreshVoices() }
        if includeEngine || hasWaiting {
            do { engineState = try await TTSAPIClient().engine(); refreshFailures = 0 }
            catch {
                refreshFailures = min(refreshFailures + 1, 5)
                engineState = TTSEngineState(status: "unavailable", message: error.localizedDescription, updatedAt: "", retryAt: nil)
            }
        }
        // A server repair or retry from another device can revive a failed job.
        // Keep user-paused transfers and local file failures under user control.
        let waiting = records.filter { $0.state == "waiting" || ($0.state == "failed" && ["failed", "cancelled", "evicted"].contains($0.rendition.status)) }
        var snapshots: [String: [TTSRendition]] = [:]
        for record in waiting {
            do {
                let client = TTSAPIClient(backendURL: record.backendURL)
                let current: TTSRendition?
                if record.isPreview { current = record.rendition }
                else {
                    let key = record.backendURL + "\u{0}" + record.rendition.bookId
                    if snapshots[key] == nil { snapshots[key] = try await client.renditions(bookId: record.rendition.bookId) }
                    current = snapshots[key]?.first { $0.id == record.id }
                }
                guard let index = records.firstIndex(where: { $0.id == record.id && ["waiting", "failed"].contains($0.state) }) else { continue }
                guard let current else {
                    records[index].state = "failed"
                    records[index].error = "This preparation was removed from the server queue. Retry to prepare it again."
                    continue
                }
                records[index].rendition = current
                records[index].error = current.error
                if ["failed", "cancelled", "evicted"].contains(current.status) { records[index].state = "failed"; records[index].error = current.error ?? "Preparation stopped" }
                else {
                    records[index].state = "waiting"
                    if current.status == "ready" { try await beginDownload(current, client: client) }
                }
            } catch {
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    if records[index].isPreview && records[index].state == "downloading" { records[index].state = "failed" }
                    records[index].error = error.localizedDescription
                }
            }
        }
        save()
    }
    private func beginDownload(_ rendition: TTSRendition, client: TTSAPIClient) async throws {
        let manifest = try await client.manifest(rendition)
        guard let index = records.firstIndex(where: { $0.id == rendition.id && $0.state == "waiting" }) else { return }
        let space = try TTSStorage.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard space > manifest.audioBytes + 20 * 1024 * 1024 else { throw TTSError.request("Free some storage before downloading more audio.") }
        guard let path = manifest.audioURL else { throw TTSError.invalidManifest }
        records[index].manifest = manifest; records[index].state = "downloading"; records[index].bytesExpected = manifest.audioBytes
        let transferID = rendition.id + ":" + UUID().uuidString
        records[index].transferID = transferID
        // Samples are small and should be ready to audition even on cellular.
        // Chapter transfers retain the user's Wi-Fi-only background policy.
        if records[index].isPreview {
            save()
            var request = URLRequest(url: try client.url(path))
            request.allowsCellularAccess = true
            request.timeoutInterval = 60
            let (temporary, response) = try await URLSession.shared.download(for: request)
            let staged = TTSStorage.root.appendingPathComponent("incoming-" + UUID().uuidString + ".m4a")
            try FileManager.default.moveItem(at: temporary, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw TTSError.request("Could not download this voice sample. Try again.")
            }
            try await TTSStorage.verify(staged: staged, manifest: manifest)
            guard let current = records.firstIndex(where: { $0.id == rendition.id && $0.state == "downloading" && $0.transferID == transferID }) else { return }
            try TTSStorage.commit(staged: staged, manifest: manifest)
            records[current].state = "downloaded"
            records[current].bytesReceived = manifest.audioBytes
            records[current].error = nil
            records[current].updatedAt = Date()
            save()
            return
        }
        let resumePath = TTSStorage.root.appendingPathComponent(rendition.id + ".resume")
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumePath) {
            task = session.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: resumePath)
        } else {
            var request = URLRequest(url: try client.url(path))
            request.allowsCellularAccess = !(UserDefaults.standard.object(forKey: "tts.wifiOnly") as? Bool ?? true)
            task = session.downloadTask(with: request)
        }
        task.taskDescription = transferID
        save(); task.resume()
    }
    func retry(_ id: String) async {
        guard let record = records.first(where: { $0.id == id }), record.state != "downloading", !record.isAvailable else { return }
        do {
            try await flushDeletions()
            let client = TTSAPIClient(backendURL: record.backendURL)
            try await restoreReferences([record.rendition.voiceId], client: client)
            let current = try await client.renditions(bookId: record.rendition.bookId, chapterId: record.rendition.chapterId).first { $0.id == id }
            if current == nil {
                guard let text = localText(bookId: record.rendition.bookId, chapterId: record.rendition.chapterId) else { throw TTSError.request("The server queue was reset. Open this chapter's audio downloads and prepare it again.") }
                let input = TTSChapterRequest(bookId: text.bookId, bookTitle: record.rendition.bookTitle, chapterId: text.chapterId, title: text.title, position: text.position, blocks: text.blocks)
                for row in try await client.prepare(chapter: input, voices: [record.rendition.voiceId]) { track(row, client: client) }
            } else if ["failed", "cancelled", "evicted"].contains(current!.status) { try await client.action("retry", renditionId: id) }
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != "downloading" else { return }
            records[index].state = "waiting"; records[index].error = nil; save(); await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    /// Retry every failed rendition of one book.
    ///
    /// Sequential on purpose: each retry re-uploads the voice reference and then
    /// touches the queue, and firing them together is what makes the server
    /// reject half of them. Paused renditions are left alone — the user stopped
    /// those deliberately.
    func retryAllFailed(bookId: String) async {
        let ids = records
            .filter { $0.rendition.bookId == bookId && !$0.isAvailable && $0.state == "failed" }
            .map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { await retry(id) }
    }
    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let transferID = records[index].transferID
        records[index].state = "paused"; save()
        session.getAllTasks { [weak self] tasks in
            for task in tasks where task.taskDescription == transferID {
                if let download = task as? URLSessionDownloadTask {
                    download.cancel { [weak self] data in
                        Task { @MainActor in
                            guard let self, self.records.contains(where: { $0.id == id && $0.state == "paused" && $0.transferID == transferID }), let data else { return }
                            try? data.write(to: TTSStorage.root.appendingPathComponent(id + ".resume"), options: .atomic)
                        }
                    }
                } else { task.cancel() }
            }
        }
    }
    func deleteMany(_ ids: [String]) async {
        for id in ids { await delete(id, deferServer: true) }
        do { try await flushDeletions() }
        catch { errorMessage = "Removed from this phone. Server deletion is pending until you reconnect and sign in." }
    }
    func delete(_ id: String, deferServer: Bool = false) async {
        guard TTSStorage.validID(id), let record = records.first(where: { $0.id == id }) else { return }
        let scope = TTSAudioDeletion(bookId: record.rendition.bookId, chapterId: record.rendition.chapterId, voiceId: record.rendition.voiceId, backendURL: record.backendURL)
        if !["breeze-previews", "qwen-previews"].contains(record.rendition.bookId), !pendingDeletions.contains(scope) {
            pendingDeletions.append(scope)
            do { try JSONEncoder().encode(pendingDeletions).write(to: deletionURL, options: .atomic) }
            catch { pendingDeletions.removeAll { $0 == scope }; errorMessage = "Could not save the deletion. Please try again."; return }
        }
        let removed = records.filter { $0.backendURL == scope.backendURL && $0.rendition.bookId == scope.bookId && $0.rendition.chapterId == scope.chapterId && $0.rendition.voiceId == scope.voiceId }
        let ids = Set(removed.map(\.id)), transfers = Set(removed.compactMap(\.transferID))
        if let playingID = ReaderTTSManager.shared.manifest?.id, ids.contains(playingID) { ReaderTTSManager.shared.stop() }
        records.removeAll { ids.contains($0.id) }; save()
        for id in ids {
            try? FileManager.default.removeItem(at: TTSStorage.root.appendingPathComponent(id + ".resume"))
            do { if FileManager.default.fileExists(atPath: TTSStorage.directory(id).path) { try FileManager.default.removeItem(at: TTSStorage.directory(id)) } }
            catch { errorMessage = error.localizedDescription }
        }
        if !records.contains(where: { $0.rendition.bookId == scope.bookId && $0.rendition.chapterId == scope.chapterId }) { try? FileManager.default.removeItem(at: TTSStorage.chapterText(bookId: scope.bookId, chapterId: scope.chapterId)) }
        if let position = ReaderTTSManager.shared.position(for: scope.bookId), ids.contains(position.renditionId) { UserDefaults.standard.removeObject(forKey: "tts.listeningPosition." + scope.bookId) }
        let tasks = await session.allTasks
        tasks.filter { task in task.taskDescription.map { transfers.contains($0) || ids.contains($0) } ?? false }.forEach { $0.cancel() }
        if !deferServer {
            do { try await flushDeletions() }
            catch { errorMessage = "Removed from this phone. Server deletion is pending until you reconnect and sign in." }
        }
    }
    private func flushDeletions() async throws {
        if let task = deletionTask { return try await task.value }
        guard !pendingDeletions.isEmpty else { return }
        let task = Task { @MainActor in
            while let first = pendingDeletions.first {
                let batch = Array(pendingDeletions.filter { $0.backendURL == first.backendURL }.prefix(100))
                try await TTSAPIClient(backendURL: first.backendURL).deletePreparations(batch)
                let remaining = pendingDeletions.filter { !batch.contains($0) }
                try JSONEncoder().encode(remaining).write(to: deletionURL, options: .atomic)
                pendingDeletions = remaining
            }
        }
        deletionTask = task
        do { try await task.value; deletionTask = nil }
        catch { deletionTask = nil; throw error }
    }
    private func reconcileTransfers() async {
        let tasks = await session.allTasks
        // Migrate previews left waiting on the background session's Wi-Fi policy.
        let previews = Set(records.filter { $0.isPreview && $0.state == "downloading" }.compactMap(\.transferID))
        for index in records.indices where records[index].isPreview && records[index].state == "downloading" {
            records[index].transferID = nil
            records[index].state = "waiting"
        }
        tasks.filter { $0.taskDescription.map(previews.contains) == true }.forEach { $0.cancel() }
        let known = Set(records.compactMap(\.transferID))
        tasks.filter { task in task.taskDescription.map { !known.contains($0) } ?? true }.forEach { $0.cancel() }
        let active = Set(tasks.compactMap(\.taskDescription))
        for index in records.indices where records[index].state == "downloading" && !active.contains(records[index].transferID ?? records[index].id) { records[index].state = "waiting" }
        save()
    }
}

extension TTSOfflineLibrary: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let transferID = downloadTask.taskDescription, let id = transferID.split(separator: ":").first.map(String.init), TTSStorage.validID(id) else { return }
        installEvents.begin()
        let staged = TTSStorage.root.appendingPathComponent("incoming-\(UUID().uuidString).m4a")
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TTSError.request("Download authorization expired. Retry this download.") }
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.installEvents.finish(); self.finishBackgroundEventsIfPossible() }
                guard let record = self.records.first(where: { $0.id == id && $0.state == "downloading" && $0.transferID == transferID }), let manifest = record.manifest else { try? FileManager.default.removeItem(at: staged); return }
                do {
                    try await TTSStorage.verify(staged: staged, manifest: manifest)
                    guard let index = self.records.firstIndex(where: { $0.id == id && $0.state == "downloading" && $0.transferID == transferID }) else { try? FileManager.default.removeItem(at: staged); return }
                    try TTSStorage.commit(staged: staged, manifest: manifest)
                    self.records[index].state = "downloaded"; self.records[index].bytesReceived = manifest.audioBytes; self.records[index].error = nil; self.records[index].updatedAt = Date(); self.save()
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    if let index = self.records.firstIndex(where: { $0.id == id && $0.state == "downloading" && $0.transferID == transferID }) { self.records[index].state = "failed"; self.records[index].error = error.localizedDescription; self.save() }
                }
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.installEvents.finish(); self.finishBackgroundEventsIfPossible() }
                guard let index = self.records.firstIndex(where: { $0.id == id && $0.state == "downloading" && $0.transferID == transferID }) else { return }
                self.records[index].state = "failed"; self.records[index].error = error.localizedDescription; self.save()
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let transferID = downloadTask.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self, let index = self.records.firstIndex(where: { $0.transferID == transferID && $0.state == "downloading" }) else { return }
            self.records[index].bytesReceived = totalBytesWritten
            if Date().timeIntervalSince(self.lastProgressSave) > 2 { self.lastProgressSave = Date(); self.save() }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let transferID = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self, let index = self.records.firstIndex(where: { $0.transferID == transferID && $0.state == "downloading" }) else { return }
            let id = self.records[index].id
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: TTSStorage.root.appendingPathComponent(id + ".resume"), options: .atomic)
            }
            self.records[index].state = "failed"; self.records[index].error = error.localizedDescription; self.save()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in self?.backgroundEventsFinished = true; self?.finishBackgroundEventsIfPossible() }
    }
}
