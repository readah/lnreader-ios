import AVFoundation
import Combine
import Foundation
import MediaPlayer

#if os(iOS)
import UIKit
private typealias CoverImage = UIImage
#elseif os(macOS)
import AppKit
private typealias CoverImage = NSImage
#endif

/// Plays verified local chapters or verified cached parts of a preparing chapter.
/// Model inference always stays on the selected remote Breeze worker.
@MainActor
final class ReaderTTSManager: ObservableObject {
    static let shared = ReaderTTSManager()
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentBlockIndex: Int?
    @Published private(set) var currentWord: TTSWordTiming?
    @Published private(set) var manifest: (any TTSPlaybackManifest)?
    @Published private(set) var playbackStatus: String?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isBuffering = false
    @Published private(set) var rate = 1.0
    @Published private(set) var sleepTimerLabel = "Off"
    @Published var errorMessage: String?
    var totalBlocks: Int { manifest?.blocks.count ?? 0 }

    private let player = AVPlayer()
    private var observer: Any?
    private var itemObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var sleepDeadline: Date?
    private var sleepAtChapterEnd = false
    private var wasPlayingBeforeInterruption = false
    private var epoch = UUID()
    private var seekID: UUID?
    private var streamRecord: TTSDownloadRecord?
    private var streamSnapshot: TTSStreamingManifest?
    private var streamIndex: Int?
    private var streamWaitingIndex: Int?
    private var streamPollTask: Task<Void, Never>?
    private var streamLoadTask: Task<Void, Never>?
    private var streamPrefetch: Task<URL, Error>?
    private var streamPrefetchIndex: Int?
    private var streamOffset: Double { streamIndex.flatMap { streamSnapshot?.parts.indices.contains($0) == true ? streamSnapshot?.parts[$0].start : nil } ?? 0 }
    private var lastPositionSave = Date.distantPast
    private var lastNowPlaying = Date.distantPast
    private var artworkBookId: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.double(forKey: "tts.speed")
        rate = saved > 0 ? min(max(saved, 0.5), 3) : 1
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBuffering, self.seekID == nil else { return }
                // Read the current clock after queued seeks, not an old callback's time.
                self.update(self.streamOffset + self.player.currentTime().seconds)
            }
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.finishChapter()
            }
        })
        #if os(iOS)
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        #endif
        configureRemoteCommands()
    }

    func play(renditionID: String, paragraph: Int? = nil, offset: Int = 0, resume: Bool = true) {
        do {
            let next = try TTSOfflineLibrary.shared.localManifest(renditionID)
            cancelStream()
            TTSVoicePreviewPlayer.shared.stop()
            let saved = position(for: next.bookId)
            let start: Double
            if let paragraph { start = next.time(paragraph: paragraph, offset: offset) ?? 0 }
            else if resume, let saved, saved.renditionId == next.id { start = saved.time }
            else { start = 0 }
            epoch = UUID(); seekID = nil
            player.pause()
            persistPosition()
            manifest = next; duration = next.duration; elapsed = start
            currentWord = next.word(at: start); currentBlockIndex = currentWord?.paragraphIndex
            errorMessage = nil; isSpeaking = true; isPaused = false; isBuffering = true
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: TTSStorage.audio(next.id))
            itemObservation?.invalidate()
            player.replaceCurrentItem(with: item)
            let activeEpoch = epoch
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.epoch == activeEpoch else { return }
                    if item.status == .readyToPlay {
                        self.itemObservation?.invalidate(); self.itemObservation = nil
                        self.performSeek(to: min(self.elapsed, max(0, next.duration - 0.02)))
                    } else if item.status == .failed {
                        self.errorMessage = item.error?.localizedDescription ?? "This local audio could not be opened."
                        self.isBuffering = false; self.isPaused = true
                    }
                }
            }
            updateNowPlaying()
        } catch { errorMessage = error.localizedDescription; isBuffering = false }
    }

    private func cancelStream() {
        streamPollTask?.cancel(); streamLoadTask?.cancel(); streamPrefetch?.cancel()
        streamPollTask = nil; streamLoadTask = nil; streamPrefetch = nil; streamPrefetchIndex = nil
        streamRecord = nil; streamSnapshot = nil; streamIndex = nil; streamWaitingIndex = nil; playbackStatus = nil
    }
    func playAvailable(_ record: TTSDownloadRecord) {
        if record.isAvailable { play(renditionID: record.id); return }
        // The caller attached the cover just before this; keep it through the stop.
        stop(clearingArtwork: false); TTSVoicePreviewPlayer.shared.stop()
        streamRecord = record; isBuffering = true; isPaused = false
        playbackStatus = "Loading ready audio…"
        if let text = TTSOfflineLibrary.shared.localText(bookId: record.rendition.bookId, chapterId: record.rendition.chapterId), text.contentRevision == record.rendition.contentRevision {
            let row = record.rendition
            manifest = TTSStreamingManifest(schema: 1, id: row.id, bookId: row.bookId, chapterId: row.chapterId, bookTitle: row.bookTitle, title: row.title, position: row.position, contentRevision: row.contentRevision, voiceId: row.voiceId, voiceName: TTSOfflineLibrary.shared.voices.first { $0.id == row.voiceId }?.name ?? "Narrator", blocks: text.blocks, words: [], duration: 0, parts: [], totalChunks: row.totalChunks, completedChunks: row.completedChunks, complete: false, status: row.status, error: nil)
            isSpeaking = true
        }
        let session = epoch
        streamPollTask = Task { [weak self] in
            guard let self else { return }
            let client = TTSAPIClient(backendURL: record.backendURL)
            while !Task.isCancelled && self.epoch == session {
                do {
                    let next = try await client.stream(record.rendition)
                    try Task.checkCancellation()
                    guard self.epoch == session else { return }
                    try TTSStorage.cacheStream(next)
                    self.applyStream(next, session: session)
                } catch {
                    guard !Task.isCancelled, self.epoch == session else { return }
                    if self.streamSnapshot == nil, let data = try? Data(contentsOf: TTSStorage.streamManifest(record.id)), let cached = try? JSONDecoder().decode(TTSStreamingManifest.self, from: data) {
                        if (try? cached.validate()) != nil { self.applyStream(cached, session: session) }
                    }
                    self.playbackStatus = error.localizedDescription
                    if self.manifest == nil { self.errorMessage = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func applyStream(_ next: TTSStreamingManifest, session: UUID) {
        guard epoch == session else { return }
        let first = streamSnapshot == nil
        streamSnapshot = next; manifest = next; duration = next.duration; isSpeaking = true
        playbackStatus = next.error ?? (next.complete ? nil : "\(next.completedChunks)/\(next.totalChunks) parts ready · listening as prepared")
        if first {
            let saved = position(for: next.bookId)
            let target = saved?.renditionId == next.id ? min(saved?.time ?? 0, max(0, next.duration - 0.01)) : 0
            let index = next.parts.last(where: { $0.start <= target })?.index ?? 0
            streamWaitingIndex = index
            if next.parts.indices.contains(index) { loadStreamPart(index, target: target); return }
        }
        if let index = streamWaitingIndex, next.parts.indices.contains(index), streamLoadTask == nil { loadStreamPart(index) }
        prefetchNextStreamPart()
    }
    private func prefetchNextStreamPart() {
        guard let index = streamIndex.map({ $0 + 1 }), let snapshot = streamSnapshot,
              snapshot.parts.indices.contains(index), let record = streamRecord, streamPrefetchIndex != index else { return }
        streamPrefetch?.cancel(); streamPrefetchIndex = index
        let part = snapshot.parts[index]
        streamPrefetch = Task { try await TTSStorage.loadStreamPart(snapshot.id, part: part, client: TTSAPIClient(backendURL: record.backendURL)) }
    }
    private func loadStreamPart(_ index: Int, target: Double? = nil, delay: Double = 0) {
        guard let snapshot = streamSnapshot, snapshot.parts.indices.contains(index), let record = streamRecord else { return }
        streamLoadTask?.cancel(); streamWaitingIndex = index
        let part = snapshot.parts[index], session = epoch
        isBuffering = true; player.pause(); seekID = nil
        currentWord = nil; currentBlockIndex = nil
        streamLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let file: URL
                if self.streamPrefetchIndex == index, let prefetch = self.streamPrefetch { file = try await prefetch.value }
                else { file = try await TTSStorage.loadStreamPart(snapshot.id, part: part, client: TTSAPIClient(backendURL: record.backendURL)) }
                try Task.checkCancellation()
                guard self.epoch == session else { return }
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                self.streamIndex = index; self.streamWaitingIndex = nil
                if self.streamPrefetchIndex == index { self.streamPrefetch = nil; self.streamPrefetchIndex = nil }
                self.prefetchNextStreamPart()
                self.elapsed = min(target ?? part.start, part.start + part.audioDuration)
                self.currentWord = snapshot.word(at: self.elapsed)
                self.currentBlockIndex = self.currentWord?.paragraphIndex
                let item = AVPlayerItem(url: file)
                self.itemObservation?.invalidate()
                self.player.replaceCurrentItem(with: item)
                self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.epoch == session, self.player.currentItem === item else { return }
                        if item.status == .readyToPlay {
                            self.itemObservation?.invalidate(); self.itemObservation = nil
                            self.performSeek(to: self.elapsed)
                        } else if item.status == .failed {
                            self.playbackStatus = item.error?.localizedDescription ?? "This part could not be opened."
                            self.isBuffering = false; self.isPaused = true
                        }
                    }
                }
                self.streamLoadTask = nil
            } catch {
                guard !Task.isCancelled, self.epoch == session else { return }
                self.playbackStatus = error.localizedDescription
                if self.streamPrefetchIndex == index { self.streamPrefetch = nil; self.streamPrefetchIndex = nil }
                self.streamLoadTask = nil
            }
        }
    }
    func switchVoice(to record: TTSDownloadRecord) {
        guard let source = currentWord, manifest?.bookId == record.rendition.bookId, manifest?.chapterId == record.rendition.chapterId else {
            play(renditionID: record.id); return
        }
        let wasPaused = isPaused
        play(renditionID: record.id, paragraph: source.paragraphIndex, offset: source.sourceStart, resume: false)
        if wasPaused { pause() }
    }
    func seek(paragraph: Int, offset: Int) {
        guard let time = manifest?.time(paragraph: paragraph, offset: offset) else {
            if streamSnapshot != nil { playbackStatus = "That part is still being prepared." }
            return
        }
        seek(to: time)
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, manifest != nil else { return }
        let target = min(max(0, seconds), max(0, duration - 0.01))
        update(target); persistPosition(); updateNowPlaying()
        if let snapshot = streamSnapshot {
            guard let part = snapshot.parts.last(where: { $0.start <= target }) else { return }
            loadStreamPart(part.index, target: target)
        } else if player.currentItem?.status == .readyToPlay { performSeek(to: target) }
    }
    private func performSeek(to target: Double) {
        let request = UUID(), activeEpoch = epoch
        seekID = request; isBuffering = true
        player.pause()
        player.seek(to: CMTime(seconds: max(0, target - streamOffset), preferredTimescale: 24000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.epoch == activeEpoch, self.seekID == request else { return }
                self.seekID = nil; self.isBuffering = false
                self.update(self.streamOffset + self.player.currentTime().seconds)
                if finished && !self.isPaused { self.player.playImmediately(atRate: Float(self.rate)) }
                self.persistPosition(); self.updateNowPlaying()
            }
        }
    }
    func skip(_ seconds: Double) { seek(to: elapsed + seconds) }
    func togglePause() { isPaused ? resume() : pause() }
    func pause() { guard isSpeaking || streamRecord != nil else { return }; player.pause(); isPaused = true; persistPosition(); updateNowPlaying() }
    func resume() { guard isSpeaking else { return }; isPaused = false; if !isBuffering { player.playImmediately(atRate: Float(rate)) }; updateNowPlaying() }
    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        rate = min(max(value, 0.5), 3); UserDefaults.standard.set(rate, forKey: "tts.speed")
        if isSpeaking && !isPaused && !isBuffering { player.rate = Float(rate) }
        updateNowPlaying()
    }
    func setSleep(minutes: Int?) {
        sleepAtChapterEnd = false
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0 * 60)) }
        sleepTimerLabel = minutes.map { "\($0)m" } ?? "Off"
    }
    func sleepAfterChapter() { sleepDeadline = nil; sleepAtChapterEnd = true; sleepTimerLabel = "Chapter" }
    func stop(clearingArtwork: Bool = true) {
        persistPosition(); cancelStream(); epoch = UUID(); seekID = nil; itemObservation?.invalidate(); itemObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        isSpeaking = false; isPaused = false; isBuffering = false; currentWord = nil; currentBlockIndex = nil
        manifest = nil; elapsed = 0; duration = 0
        if clearingArtwork { artworkTask?.cancel(); artworkTask = nil; artwork = nil; artworkBookId = nil }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    private func update(_ time: Double) {
        guard isSpeaking, time.isFinite else { return }
        elapsed = min(max(0, time), duration)
        let word = manifest?.word(at: elapsed)
        if word != currentWord { currentWord = word; currentBlockIndex = word?.paragraphIndex }
        if let deadline = sleepDeadline, Date() >= deadline { setSleep(minutes: nil); pause() }
        if Date().timeIntervalSince(lastPositionSave) > 3 { persistPosition() }
        if Date().timeIntervalSince(lastNowPlaying) > 1 { updateNowPlaying() }
    }
    private func positionKey(_ bookId: String) -> String { "tts.listeningPosition." + bookId }
    func position(for bookId: String) -> TTSListeningPosition? {
        guard let data = UserDefaults.standard.data(forKey: positionKey(bookId)) else { return nil }
        return try? JSONDecoder().decode(TTSListeningPosition.self, from: data)
    }
    private func persistPosition() {
        guard let manifest, let word = currentWord ?? manifest.words.last(where: { $0.start <= elapsed }) ?? manifest.words.first else { return }
        let value = TTSListeningPosition(renditionId: manifest.id, paragraph: word.paragraphIndex, offset: word.sourceStart, time: elapsed)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: positionKey(manifest.bookId)) }
        lastPositionSave = Date()
    }
    private func finishChapter() {
        persistPosition()
        if let snapshot = streamSnapshot, let index = streamIndex {
            let part = snapshot.parts[index]
            elapsed = part.end; currentWord = nil; currentBlockIndex = nil
            if index + 1 < snapshot.parts.count || !snapshot.complete {
                streamWaitingIndex = index + 1; isBuffering = true
                playbackStatus = "Waiting for the next part · \(snapshot.completedChunks)/\(snapshot.totalChunks) ready"
                if index + 1 < snapshot.parts.count { loadStreamPart(index + 1, delay: part.pauseAfter / rate) }
                return
            }
        }
        update(duration)
        if sleepAtChapterEnd { sleepAtChapterEnd = false; sleepTimerLabel = "Off"; pause(); return }
        guard let current = manifest else { return }
        let library = TTSOfflineLibrary.shared
        let following = library.downloads(bookId: current.bookId).filter { $0.isAvailable && $0.rendition.position > current.position }.sorted { $0.rendition.position < $1.rendition.position }
        guard let first = following.first else { pause(); return }
        let selected = library.selectedVoice(bookId: current.bookId, chapterId: first.rendition.chapterId)
        guard let next = following.first(where: { $0.rendition.chapterId == first.rendition.chapterId && $0.rendition.voiceId == selected }),
              next.rendition.position == current.position + 1 else {
            pause(); errorMessage = "The next chapter is not downloaded in its selected voice."; return
        }
        play(renditionID: next.id, resume: false)
    }
    private func updateNowPlaying() {
        guard let manifest else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: manifest.title,
            MPMediaItemPropertyAlbumTitle: manifest.bookTitle,
            MPMediaItemPropertyArtist: TTSOfflineLibrary.shared.voices.first { $0.id == manifest.voiceId }?.name ?? manifest.voiceName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0 : rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1
        ]
        // The system now-playing card (lock screen, Dynamic Island, Control Center)
        // is rendered outside the app and cannot read SwiftData, so the cover has to
        // be handed over explicitly.
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlaying = Date()
    }

    /// Attach the book cover to the system now-playing card for the playing book.
    /// Safe to call on every playback start; the image is fetched once per book.
    func attachCover(url: String?, bookId: String) {
        guard artworkBookId != bookId else { return }
        artworkBookId = bookId
        artwork = nil
        artworkTask?.cancel()
        guard let url, !url.isEmpty else { return }
        artworkTask = Task { [weak self] in
            guard let image = await Self.loadCoverImage(url) else { return }
            guard let self, !Task.isCancelled, self.artworkBookId == bookId else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }

    private static func loadCoverImage(_ value: String) async -> CoverImage? {
        let url: URL?
        if let parsed = URL(string: value), parsed.scheme != nil { url = parsed }
        else { url = URL(fileURLWithPath: value) }
        guard let url else { return nil }
        #if os(iOS)
        if !url.isFileURL, let cached = ImageCache.cached(url) { return cached }
        if url.isFileURL { return UIImage(contentsOfFile: url.path) }
        #elseif os(macOS)
        if url.isFileURL { return NSImage(contentsOf: url) }
        #else
        return nil
        #endif
        // Same browser User-Agent the library covers use; CDNs block the default one.
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePause() }; return .success }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [30]
        commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(30) }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let value = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: value.positionTime) }; return .success
        }
    }
    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue { wasPlayingBeforeInterruption = isSpeaking && !isPaused; pause() }
        else if let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume), wasPlayingBeforeInterruption { resume() }
    }
    #endif
}
