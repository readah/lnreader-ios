// ReaderView.swift
// Full-screen chapter reader with tap-to-toggle controls.

import SwiftData
import SwiftUI
import WebKit
import GlurBackdrop

struct ReaderView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader.highlightColor") private var highlightColorHex = ""
    @AppStorage("reader.highlightOpacity") private var highlightOpacity = 0.26
    @AppStorage("reader.justifyText") private var justifyText = true

    @StateObject private var ttsBridge = ReaderContentBridge()
    @ObservedObject private var ttsManager = ReaderTTSManager.shared
    @ObservedObject private var audioLibrary = TTSOfflineLibrary.shared
    @State private var showAudioDownloads = false
    @State private var showSleepPicker = false
    @State private var showSpeedPicker = false
    @State private var speechScrubTime: Double?

    @State private var currentChapterPath: String
    @State private var currentChapterName: String
    let sourceKey: String
    let entryURL: String?

    private func fetchEntry() -> Entry? {
        guard let entryURL else { return nil }
        let key = sourceKey
        let predicate = #Predicate<Entry> { $0.url == entryURL && $0.sourceKey == key }
        var descriptor = FetchDescriptor<Entry>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    @State private var htmlContent = ""
    @State private var displayedAudioRevision: String?
    @State private var chapterLoadID = UUID()
    @State private var baseURL: URL? = nil
    @State private var isLoading = true
    @State private var chrome: ReaderChromeState = .control
    @State private var showSettings = false
    @State private var settingsDetent: PresentationDetent = .medium
    @State private var showChapterList = false
    @State private var startTTSWhenReady = false
    @State private var errorMessage: String?
    @State private var isPreparingTTS = false
    @State private var cachedChapters: [Chapter] = []
    
    // NovelFire / NovelPhoenix Comments State (same backend, different host)
    @State private var novelfirePostId = ""
    @State private var novelfireChapterId = ""
    @State private var novelfireCsrfToken = ""
    @State private var commentsHtml = ""
    @State private var nextCursor: String? = nil
    @State private var hasMoreComments = false
    @State private var showLoginSheet = false
    @State private var showCommentsSheet = false
    @State private var commentsTask: Task<Void, Never>?

    /// Comment site for the current source, if chapter comments are supported.
    private var commentSite: CommentSite? { CommentSite.site(for: SourceKey.identifier(from: sourceKey)) }

    // Reader settings persisted across sessions
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineHeight") private var lineHeight: Double = 1.6
    @AppStorage("reader.fontFamily") private var fontFamily = "Georgia"
    @AppStorage("reader.padding") private var horizontalPadding: Double = 16
    @AppStorage("reader.backgroundColor") private var backgroundColorHex: String = ""
    @AppStorage("reader.textColor") private var textColorHex: String = ""
    @AppStorage("reader.bionicReading") private var bionicReading = false
    @AppStorage("reader.characterSpacing") private var characterSpacing: Double = 0.0
    @AppStorage("reader.wordSpacing") private var wordSpacing: Double = 0.0
    @AppStorage("reader.grainIntensity") private var grainIntensity: Double = 10.0
    @AppStorage("reader.lineFocusEnabled") private var lineFocusEnabled = false
    @AppStorage("reader.lineFocusLines") private var lineFocusLines = 1
    @AppStorage("reader.lineFocusDulling") private var lineFocusDulling = "mid"
    @AppStorage("reader.verticalPadding") private var verticalPadding: Double = 20
    @AppStorage("tts.voice") private var ttsVoiceId: String = "breeze-warm"
    @AppStorage("tts.speed") private var ttsSpeed: Double = 1.0

    @ObservedObject private var focusManager = FocusModeManager.shared

    init(chapterPath: String, chapterName: String, sourceKey: String, entryURL: String?) {
        self._currentChapterPath = State(initialValue: chapterPath)
        self._currentChapterName = State(initialValue: chapterName)
        self.sourceKey = sourceKey
        self.entryURL = entryURL
    }

    private func toggleControls() {
        setChrome(chrome.toggled)
    }

    private func openSettings() {
        settingsDetent = .medium
        showSettings = true
    }

    /// Single tap moves between the two states: focus shows the page, control
    /// shows every action.
    private func setChrome(_ state: ReaderChromeState) {
        guard chrome != state else { return }
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) { chrome = state }
        Haptics.shared.impact(.light)
    }

    /// Kept out of the modifier chain: inlining it pushes the body past what the
    /// type checker will infer in reasonable time.
    private var narrationAlert: Binding<Bool> {
        Binding(
            get: { ttsManager.errorMessage != nil },
            set: { presented in if !presented { ttsManager.errorMessage = nil } }
        )
    }

    var body: some View {
        presentation
            .task { await loadChapter() }
            .onChange(of: ttsBridge.isReady) { _, ready in handleBridgeReady(ready) }
            .onChange(of: ttsManager.currentBlockIndex) { _, newIndex in handleBlockIndex(newIndex) }
            .onChange(of: isCurrentSpeech) { _, isSpeaking in handleSpeechChange(isSpeaking) }
            .onChange(of: ttsManager.errorMessage) { _, error in
                if error != nil { isPreparingTTS = false }
            }
            .onChange(of: ttsManager.currentWord) { _, word in
                guard isCurrentSpeech, speechScrubTime == nil else { return }
                ttsBridge.setActiveWord(word)
            }
            .onChange(of: ttsManager.manifest?.id) { _, _ in handleManifestChange() }
            .onAppear { FocusModeManager.shared.updateFocusStatus() }
            .onDisappear {
                commentsTask?.cancel()
                // Reading position is written on a coalescing timer while
                // scrolling; closing the reader is the moment to make sure the
                // last few seconds are not lost.
                libraryManager.flushProgress(context: modelContext)
            }
    }

    // MARK: - View composition
    //
    // Split into three properties on purpose: one flat body with ~25 modifiers
    // is past what the Swift type checker will infer in reasonable time.

    /// Sheets, covers and alerts.
    private var presentation: some View {
        readerStack
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .statusBarHidden(!chrome.isControl)
            .background(EdgeSwipeDismiss(edges: [.left]) {
                guard !showSettings, !showChapterList, !showLoginSheet, !showCommentsSheet, !showAudioDownloads else { return }
                dismiss()
            })
            .onChange(of: chrome) { _, state in ttsBridge.setControlsVisible(state.isControl) }
            .onChange(of: showSettings) { _, visible in
                if visible {
                    settingsDetent = .medium
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .fullScreenCover(isPresented: $showChapterList) { chapterListSheet }
            .sheet(isPresented: $showLoginSheet) { loginSheet }
            .sheet(isPresented: $showCommentsSheet) { commentsSheet }
            .sheet(isPresented: $showAudioDownloads) { audioDownloadsSheet }
            .alert("Narration", isPresented: narrationAlert) {
                Button("OK", role: .cancel) { ttsManager.errorMessage = nil }
            } message: { Text(ttsManager.errorMessage ?? "") }
            .onReceive(ttsBridge.paragraphScrollPublisher) { position in
                // Only update progress when TTS is not active (TTS updates it automatically)
                guard !isCurrentSpeech, let chapter = currentChapter else { return }
                libraryManager.recordReadingPosition(
                    chapter: chapter, paragraphIndex: position.paragraphIndex,
                    percent: position.percent, context: modelContext
                )
            }
            .onReceive(ttsBridge.wordTapPublisher) { position in
                guard isCurrentSpeech else { return }
                ttsManager.seek(paragraph: position.paragraphIndex, offset: position.offset)
                ttsManager.resume()
                ttsBridge.resumeFollowing()
            }
            .confirmationDialog("Playback speed", isPresented: $showSpeedPicker) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2, 2.5], id: \.self) { speed in
                    Button(String(format: "%.2gx", speed)) { updateSpeed(speed) }
                }
            }
            .confirmationDialog("Sleep timer", isPresented: $showSleepPicker) {
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") { ttsManager.setSleep(minutes: minutes) }
                }
                Button("End of chapter") { ttsManager.sleepAfterChapter() }
                Button("Off") { ttsManager.setSleep(minutes: nil) }
            }
    }

    /// The reader itself: background, page content, toolbar, overlays.
    private var readerStack: some View {
        ZStack {
            // Background
            resolvedBackgroundColor.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            // Content
            if isLoading {
                LoadingView(message: "Loading chapter...")
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Couldn't load chapter",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ReaderContent(
                    htmlContent: htmlContent,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    fontFamily: fontFamily,
                    horizontalPadding: horizontalPadding,
                    verticalPadding: verticalPadding,
                    backgroundColorHex: backgroundColorHex,
                    textColorHex: textColorHex,
                    bionicReading: bionicReading,
                    lineFocusEnabled: lineFocusEnabled,
                    lineFocusLines: lineFocusLines,
                    lineFocusDulling: lineFocusDulling,
                    showControls: chrome.isControl,
                    bridge: ttsBridge,
                    baseURL: baseURL,
                    characterSpacing: characterSpacing,
                    wordSpacing: wordSpacing,
                    grainIntensity: grainIntensity,
                    highlightColorHex: highlightColorHex,
                    highlightOpacity: highlightOpacity,
                    justifyText: justifyText,
                    commentsHtml: "",
                    hasMoreComments: false,
                    onTap: { toggleControls() },
                    onParagraphTap: { _ in },
                    onLoadMoreComments: nil,
                    onLikeComment: nil,
                    onDislikeComment: nil
                )
                .ignoresSafeArea(.all)
                .opacity(ttsBridge.isReady ? 1 : 0)
            }

            // The edge blur alone keeps text clear of the toolbar; the old
            // solid gradient band across the top is gone.
            chromeGlur

            // Reading and listening share the same top navigation.
            ReaderToolbar(
                chapterName: currentChapterName,
                hasPrevious: hasPreviousChapter,
                hasNext: hasNextChapter,
                isPreparingTTS: isPreparingTTS,
                onDismiss: { dismiss() },
                onSettings: openSettings,
                onTTSStart: { isCurrentSpeech ? stopTTSPlayback() : startTTSPlayback() },
                onPreviousChapter: navigateToPreviousChapter,
                onNextChapter: navigateToNextChapter,
                onChapterClick: { showChapterList = true },
                onComments: commentSite != nil ? { showCommentsSheet = true } : nil,
                isListening: isCurrentSpeech
            )
            .opacity(chrome.isControl ? 1.0 : 0.0)
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: chrome)
            .allowsHitTesting(chrome.isControl)
            .accessibilityHidden(!chrome.isControl)

            // TTS Controls Overlay (visible when isCurrentSpeech is true)
            ttsControlsOverlay
                .opacity(isCurrentSpeech && chrome.isControl ? 1.0 : 0.0)
                .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: chrome)
                .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isCurrentSpeech)
                .allowsHitTesting(isCurrentSpeech && chrome.isControl)
                .accessibilityHidden(!isCurrentSpeech || !chrome.isControl)

            // Focus Status Indicator Overlay (visible when controls and TTS speaking overlay are hidden, and Line Focus mode is active)
            VStack(spacing: 8) {
                if !chrome.isControl && !isCurrentSpeech {
                    if lineFocusEnabled {
                        ReaderFocusIndicator()
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    IncognitoIndicator()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                Spacer()
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(!chrome.isControl && !isCurrentSpeech)
            .padding(.top, 12)
        }
    }

    /// The manga reader's edge blur, shown with the controls: text melts into
    /// the top and bottom of the screen instead of stopping at a hard line.
    /// Same light radius as the manga reader; it never intercepts taps or
    /// scrolls, and it fades out with the controls.
    private var chromeGlur: some View {
        VStack(spacing: 0) {
            GlurView(radius: 2, direction: .up)
                .frame(height: 140)
            Spacer(minLength: 0)
            GlurView(radius: 2, direction: .down)
                .frame(height: 140)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(chrome.isControl ? 1 : 0)
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: chrome)
    }

    private var settingsSheet: some View {
        ReaderSettings(
            fontSize: $fontSize,
            lineHeight: $lineHeight,
            fontFamily: $fontFamily,
            horizontalPadding: $horizontalPadding,
            verticalPadding: $verticalPadding,
            backgroundColorHex: $backgroundColorHex,
            textColorHex: $textColorHex,
            bionicReading: $bionicReading,
            lineFocusEnabled: $lineFocusEnabled,
            lineFocusLines: $lineFocusLines,
            lineFocusDulling: $lineFocusDulling,
            characterSpacing: $characterSpacing,
            wordSpacing: $wordSpacing,
            grainIntensity: $grainIntensity,
            detent: $settingsDetent
        )
        // Full height by default, so every setting fits without scrolling;
        // half height is one drag down, same as the manga reader's sheet.
        .presentationDetents([.medium, .large], selection: $settingsDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var chapterListSheet: some View {
        ReaderChapterListSheet(
            entry: fetchEntry(),
            currentChapterPath: currentChapterPath,
            onSelectChapter: { chapter in
                showChapterList = false
                navigateToChapter(chapter)
            },
            onDismiss: { showChapterList = false }
        )
    }

    private var loginSheet: some View {
        NovelFireLoginView(onLoginSuccess: {
            loadNovelFireComments()
        }, site: commentSite ?? .novelFire)
    }

    private var commentsSheet: some View {
        NovelFireCommentsView(
            postId: novelfirePostId,
            chapterId: novelfireChapterId,
            csrfToken: novelfireCsrfToken,
            initialCommentsHtml: commentsHtml,
            initialNextCursor: nextCursor,
            initialHasMore: hasMoreComments,
            chapterPath: currentChapterPath,
            backgroundColorHex: backgroundColorHex,
            textColorHex: textColorHex,
            site: commentSite ?? .novelFire
        )
    }

    private var audioDownloadsSheet: some View {
        BookAudioDownloadsView(
            bookId: audioBookId,
            bookTitle: fetchEntry()?.displayTitle ?? currentChapterName,
            sourceKey: sourceKey,
            entryURL: entryURL ?? "",
            chapters: audioChapterChoices,
            coverURL: fetchEntry()?.displayThumbnailURL,
            initialChapter: currentChapterPath
        )
    }

    // MARK: - TTS event handlers

    private func handleBridgeReady(_ ready: Bool) {
        guard ready else { return }
        ttsBridge.setSpeechMode(isCurrentSpeech)
        if isCurrentSpeech { ttsBridge.setActiveWord(displayedSpeechWord) }
        if !isCurrentSpeech, let lastIndex = currentChapter?.paragraphIndex, lastIndex > 0 {
            ttsBridge.scrollToParagraph(lastIndex)
        }
        if startTTSWhenReady {
            startTTSWhenReady = false
            startTTSPlayback()
        }
    }

    private func handleBlockIndex(_ newIndex: Int?) {
        guard isCurrentSpeech, let newIndex else { return }
        if speechScrubTime == nil { ttsBridge.setActiveWord(ttsManager.currentWord) }

        // Save reading progress to database
        let total = ttsManager.totalBlocks
        guard let chapter = currentChapter, total > 0 else { return }
        let percent = Int(Double(newIndex + 1) / Double(total) * 100)
        libraryManager.recordReadingPosition(
            chapter: chapter,
            paragraphIndex: newIndex,
            percent: min(max(percent, 0), 100),
            context: modelContext
        )
    }

    private func handleSpeechChange(_ isSpeaking: Bool) {
        ttsBridge.setSpeechMode(isSpeaking)
        if isSpeaking {
            isPreparingTTS = false
            ttsBridge.setActiveWord(displayedSpeechWord)
        } else {
            speechScrubTime = nil
            ttsBridge.clearActive()
        }
    }

    private func handleManifestChange() {
        guard let manifest = ttsManager.manifest, manifest.bookId == audioBookId else { return }
        if currentChapterPath != manifest.chapterId || displayedAudioRevision != manifest.contentRevision {
            currentChapterPath = manifest.chapterId
            currentChapterName = manifest.title
            isLoading = true
            Task { await loadChapter() }
        }
    }

    private var resolvedBackgroundColor: Color {
        if backgroundColorHex.isEmpty {
            return AppTheme.readerBackground
        }
        return Color(hex: backgroundColorHex) ?? AppTheme.readerBackground
    }

    private var currentChapter: Chapter? {
        cachedChapters.first(where: { $0.url == currentChapterPath })
    }

    // MARK: - Navigation Helpers

    private var sortedChapters: [Chapter] {
        cachedChapters
    }

    private var hasPreviousChapter: Bool {
        guard entryURL != nil,
            let currentIndex = sortedChapters.firstIndex(where: { $0.url == currentChapterPath })
        else { return false }
        return currentIndex > 0
    }

    private var hasNextChapter: Bool {
        guard entryURL != nil,
            let currentIndex = sortedChapters.firstIndex(where: { $0.url == currentChapterPath })
        else { return false }
        return currentIndex < sortedChapters.count - 1
    }

    private func navigateToPreviousChapter() {
        ttsManager.stop()
        guard
            let currentIndex = sortedChapters.firstIndex(where: { $0.url == currentChapterPath }),
            currentIndex > 0
        else { return }
        let prevChapter = sortedChapters[currentIndex - 1]
        currentChapterPath = prevChapter.url
        currentChapterName = prevChapter.name
        isLoading = true
        Task {
            await loadChapter()
        }
    }

    private func navigateToNextChapter() {
        ttsManager.stop()
        guard
            let currentIndex = sortedChapters.firstIndex(where: { $0.url == currentChapterPath }),
            currentIndex < sortedChapters.count - 1
        else { return }
        let nextChapter = sortedChapters[currentIndex + 1]
        currentChapterPath = nextChapter.url
        currentChapterName = nextChapter.name
        isLoading = true
        Task {
            await loadChapter()
        }
    }

    private func navigateToChapter(_ chapter: Chapter) {
        ttsManager.stop()
        currentChapterPath = chapter.url
        currentChapterName = chapter.name
        isLoading = true
        Task {
            await loadChapter()
        }
    }

    // MARK: - Data Loading

    private func loadChapter() async {
        let loadID = UUID(); chapterLoadID = loadID
        let requestedPath = currentChapterPath
        errorMessage = nil
        ttsBridge.contentDidChange()
        displayedAudioRevision = nil
        if cachedChapters.isEmpty, let entryURL {
            let key = sourceKey
            let predicate = #Predicate<Chapter> { $0.entry?.url == entryURL && $0.entry?.sourceKey == key }
            var descriptor = FetchDescriptor<Chapter>(predicate: predicate, sortBy: [SortDescriptor(\.sourceOrder)])
            descriptor.relationshipKeyPathsForPrefetching = []
            if let fetched = try? modelContext.fetch(descriptor) {
                // Reading order, oldest first: previous/next follow the chapter
                // list, not the source's array. Hidden chapters do not exist for
                // previous/next, except the one that is open.
                self.cachedChapters = ChapterOrder.oldestFirst(
                    fetched.filter { !$0.hidden || $0.url == requestedPath }
                )
            }
        }
        if let manifest = ttsManager.manifest, manifest.bookId == audioBookId, manifest.chapterId == currentChapterPath {
            htmlContent = TTSBookIdentity.html(blocks: manifest.blocks)
            displayedAudioRevision = manifest.contentRevision
            baseURL = nil; isLoading = false
            return
        }
        let selected = audioLibrary.selectedVoice(bookId: audioBookId, chapterId: currentChapterPath)
        if let local = audioLibrary.downloaded(bookId: audioBookId, chapterId: currentChapterPath, voiceId: selected) ?? audioLibrary.downloaded(bookId: audioBookId, chapterId: currentChapterPath),
           let manifest = try? audioLibrary.localManifest(local.id) {
            htmlContent = TTSBookIdentity.html(blocks: manifest.blocks)
            displayedAudioRevision = manifest.contentRevision
            baseURL = nil; isLoading = false
            return
        }
        if let local = audioLibrary.localText(bookId: audioBookId, chapterId: currentChapterPath) {
            htmlContent = TTSBookIdentity.html(blocks: local.blocks)
            displayedAudioRevision = local.contentRevision
            baseURL = nil; isLoading = false
            return
        }

        if let entryURL, let downloaded = OfflineChapters.novel(sourceKey: sourceKey, entryURL: entryURL, chapterURL: requestedPath) {
            errorMessage = nil
            ttsBridge.contentDidChange()
            htmlContent = downloaded; baseURL = nil; isLoading = false
            if let entry = fetchEntry(), let chapter = entry.chapters.first(where: { $0.url == requestedPath }) {
                libraryManager.recordHistory(entry: entry, chapter: chapter, context: modelContext)
            }
            return
        }
        if sourceKey == SourceKey.local, let entryURL {
            do {
                let fileManager = FileManager.default
                let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let novelId = entryURL.replacingOccurrences(of: "local://", with: "")
                let bookDir = docDir.appendingPathComponent("LocalNovels").appendingPathComponent(novelId)
                let chapterURL = bookDir.appendingPathComponent(currentChapterPath)

                guard fileManager.fileExists(atPath: chapterURL.path) else {
                    errorMessage = "Chapter file not found: \(currentChapterPath)"
                    isLoading = false
                    return
                }

                let rawHtml = try String(contentsOf: chapterURL, encoding: .utf8)
                htmlContent = rawHtml
                baseURL = chapterURL.deletingLastPathComponent()
                isLoading = false

                // Record reading history
                if let chapter = cachedChapters.first(where: { $0.url == currentChapterPath }),
                   let entry = fetchEntry() {
                    libraryManager.recordHistory(entry: entry, chapter: chapter, context: modelContext)
                }
            } catch {
                errorMessage = "Failed to load local chapter: \(error.localizedDescription)"
                isLoading = false
            }
            return
        }

        guard let source = sourceManager.novelSource(forKey: sourceKey) else {
            errorMessage = "Source not available. Reinstall the extension and try again."
            isLoading = false
            return
        }

        do {
            let parsed = try await source.chapterHTML(
                SourceChapter(url: requestedPath, name: currentChapterName)
            )
            guard chapterLoadID == loadID, currentChapterPath == requestedPath else { return }
            htmlContent = parsed
            baseURL = nil
            isLoading = false

            // Record reading history
            if let entry = fetchEntry(),
               let chapter = cachedChapters.first(where: { $0.url == currentChapterPath }) {
                libraryManager.recordHistory(entry: entry, chapter: chapter, context: modelContext)
            }

            // Fetch NovelFire / NovelPhoenix comments asynchronously
            if commentSite != nil {
                loadNovelFireComments()
            }
        } catch {
            guard chapterLoadID == loadID else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
    
    private func loadNovelFireComments() {
        guard let site = commentSite else { return }
        // Cancel any in-flight fetch from a previous chapter so a slow
        // response can't overwrite the current chapter's comments.
        commentsTask?.cancel()
        self.novelfirePostId = ""
        self.novelfireChapterId = ""
        self.novelfireCsrfToken = ""
        self.commentsHtml = ""
        self.nextCursor = nil
        self.hasMoreComments = false

        commentsTask = Task {
            do {
                let meta = try await NovelFireCommentsService.shared.fetchChapterMetadata(chapterPath: currentChapterPath, site: site)
                guard !Task.isCancelled else { return }
                self.novelfirePostId = meta.postId
                self.novelfireChapterId = meta.chapterId
                self.novelfireCsrfToken = meta.csrfToken

                let response = try await NovelFireCommentsService.shared.fetchComments(postId: meta.postId, chapterId: meta.chapterId, site: site)
                guard !Task.isCancelled else { return }
                self.commentsHtml = response.html
                self.nextCursor = response.next_cursor
                self.hasMoreComments = response.has_more_pages
            } catch is CancellationError {
                // Superseded by a newer chapter — ignore.
            } catch {
                #if DEBUG
                print("⚠️ Failed to load \(site.displayName) comments: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func loadMoreComments() {
        guard let site = commentSite,
              !novelfirePostId.isEmpty && !novelfireChapterId.isEmpty,
              let cursor = nextCursor else { return }
        Task {
            do {
                let response = try await NovelFireCommentsService.shared.fetchComments(
                    postId: novelfirePostId,
                    chapterId: novelfireChapterId,
                    cursor: cursor,
                    site: site
                )
                self.commentsHtml += response.html
                self.nextCursor = response.next_cursor
                self.hasMoreComments = response.has_more_pages

                // Append comments via JS to prevent losing scroll position.
                // JSON-encode the fragment so quotes/newlines/emoji survive.
                let encoded: String = {
                    if let data = try? JSONEncoder().encode(response.html),
                       let s = String(data: data, encoding: .utf8) { return s }
                    return "\"\""
                }()
                let js = "window.appendComments(\(encoded), \(response.has_more_pages ? "true" : "false"));"
                _ = try? await ttsBridge.webView?.evaluateJavaScript(js)
            } catch {
                #if DEBUG
                print("⚠️ Failed to load more comments: \(error)")
                #endif
            }
        }
    }

    private func handleLikeComment(commentId: String) {
        handleCommentAction(commentId: commentId, isLike: true)
    }

    private func handleDislikeComment(commentId: String) {
        handleCommentAction(commentId: commentId, isLike: false)
    }

    private func handleCommentAction(commentId: String, isLike: Bool) {
        guard let site = commentSite else { return }
        if !NovelFireCommentsService.shared.hasSession(for: site) {
            self.showLoginSheet = true
            return
        }

        let csrf = self.novelfireCsrfToken
        let referer = site.referer(chapterPath: currentChapterPath)

        Task {
            do {
                let response: NovelFireCommentsService.ActionResponse
                if isLike {
                    response = try await NovelFireCommentsService.shared.likeComment(commentId: commentId, csrfToken: csrf, referer: referer, site: site)
                } else {
                    response = try await NovelFireCommentsService.shared.dislikeComment(commentId: commentId, csrfToken: csrf, referer: referer, site: site)
                }

                // Success! Update WebView UI
                let js = "window.updateCommentLikes(\"\(commentId)\", \(response.likes), \(response.dislikes), \(isLike ? "true" : "false"));"
                _ = try? await ttsBridge.webView?.evaluateJavaScript(js)
            } catch {
                #if DEBUG
                print("⚠️ Comment action failed: \(error)")
                #endif
                if (error as NSError).code == 419 {
                    do {
                        let meta = try await NovelFireCommentsService.shared.fetchChapterMetadata(chapterPath: currentChapterPath, site: site, forceRefresh: true)
                        self.novelfireCsrfToken = meta.csrfToken
                        let js = "alert('Session refreshed. Please try liking/disliking again.');"
                        _ = try? await ttsBridge.webView?.evaluateJavaScript(js)
                    } catch {
                        #if DEBUG
                        print("⚠️ Failed to refresh CSRF token: \(error)")
                        #endif
                    }
                }
            }
        }
    }

    private var audioBookId: String { TTSBookIdentity.make(pluginId: sourceKey, novelPath: entryURL ?? currentChapterPath) }
    private var isCurrentSpeech: Bool {
        ttsManager.isSpeaking && ttsManager.manifest?.bookId == audioBookId && ttsManager.manifest?.chapterId == currentChapterPath
    }
    private var audioChapterChoices: [TTSChapterChoice] {
        if cachedChapters.isEmpty { return [.init(path: currentChapterPath, title: currentChapterName, position: 0)] }
        return cachedChapters.map { .init(path: $0.url, title: $0.name, position: $0.sourceOrder) }
    }
    private func toggleTTSPlayback() {
        if isCurrentSpeech { ttsManager.togglePause() } else { startTTSPlayback() }
    }
    private func startTTSPlayback(from startIndex: Int? = nil) {
        let voice = audioLibrary.selectedVoice(bookId: audioBookId, chapterId: currentChapterPath)
        guard let record = audioLibrary.downloaded(bookId: audioBookId, chapterId: currentChapterPath, voiceId: voice) ?? audioLibrary.downloads(bookId: audioBookId, chapterId: currentChapterPath).first(where: { $0.rendition.voiceId == voice && $0.rendition.completedChunks > 0 }) else {
            showAudioDownloads = true
            return
        }
        ttsManager.attachCover(url: fetchEntry()?.displayThumbnailURL, bookId: audioBookId)
        if record.isAvailable { ttsManager.play(renditionID: record.id, paragraph: startIndex) }
        else { ttsManager.playAvailable(record) }
        ttsBridge.setSpeechMode(true)
        ttsBridge.resumeFollowing()
        isPreparingTTS = false
    }
    private func stopTTSPlayback() {
        ttsManager.stop(); ttsBridge.setSpeechMode(false); ttsBridge.clearActive()
    }
    private func updateSpeed(_ newSpeed: Double) { ttsSpeed = newSpeed; ttsManager.setRate(newSpeed) }
    private var displayedSpeechWord: TTSWordTiming? {
        if let speechScrubTime { return ttsManager.manifest?.word(at: speechScrubTime) }
        return ttsManager.currentWord
    }
    private var ttsControlsOverlay: some View {
        TTSPlaybackControls(
            isPlaying: !ttsManager.isPaused, isBuffering: ttsManager.isBuffering,
            elapsed: ttsManager.elapsed, duration: ttsManager.duration, rate: ttsManager.rate,
            voiceId: ttsManager.manifest?.voiceId ?? ttsVoiceId,
            voiceName: audioLibrary.voices.first { $0.id == (ttsManager.manifest?.voiceId ?? ttsVoiceId) }?.name ?? ttsManager.manifest?.voiceName ?? "Breeze",
            isFollowing: ttsBridge.isFollowing, sleepTimerLabel: ttsManager.sleepTimerLabel, playbackStatus: ttsManager.playbackStatus,
            onSettings: openSettings,
            onPlayPause: { ttsManager.togglePause() }, onSkipBack: { ttsManager.skip(-15) },
            onSkipForward: { ttsManager.skip(30) }, onRate: { showSpeedPicker = true },
            onVoice: { showAudioDownloads = true },
            onBookmark: { if let chapter = currentChapter { chapter.bookmark.toggle(); try? modelContext.save() } },
            onSleep: { showSleepPicker = true },
            onFollow: { ttsBridge.resumeFollowing() },
            onSeek: { ttsManager.seek(to: $0); ttsBridge.resumeFollowing() },
            onScrub: { time in
                let wasScrubbing = speechScrubTime != nil
                speechScrubTime = time
                if time != nil && !wasScrubbing { ttsBridge.resumeFollowing() }
                ttsBridge.setActiveWord(displayedSpeechWord)
            }
        )
    }

}

// MARK: - Focus Indicator View Overlay
struct ReaderFocusIndicator: View {    @ObservedObject var focusManager = FocusModeManager.shared
    @State private var showLabel = false
    /// The old version held a `Timer` and mutated `@State` from its closure. The
    /// timer outlived the view, so it kept writing to a `@State` that was no
    /// longer installed — a SwiftUI runtime fault, not a compile error. A
    /// cancellable task is torn down with the view instead.
    @State private var hideTask: Task<Void, Never>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activeType = focusManager.currentFocusType

        Group {
            if activeType != .none {
                VStack(spacing: 8) {
                    Button {
                        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                            showLabel = true
                        }
                        hideTask?.cancel()
                        hideTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                                showLabel = false
                            }
                        }
                    } label: {
                        if showLabel {
                            Label(activeType.displayName, systemImage: activeType.iconName)
                        } else {
                            Label(activeType.displayName, systemImage: activeType.iconName)
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.caption2.weight(.bold))
                    .accessibilityLabel("Focus mode: \(activeType.displayName)")

                    // If label is shown, offer a small manual override selector
                    if showLabel {
                        Button("Change Focus") { cycleOverride() }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        }
        .onAppear { focusManager.updateFocusStatus() }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func cycleOverride() {
        let options = ["auto", "dnd", "work", "sleep", "none"]
        if let index = options.firstIndex(of: focusManager.overrideType) {
            let nextIndex = (index + 1) % options.count
            withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                focusManager.overrideType = options[nextIndex]
                focusManager.updateFocusStatus()
            }
        }
    }
}

// MARK: - Incognito Indicator

/// Marks a session that is not being recorded.
///
/// Shown with the chrome hidden, in the same slot as the Focus indicator, so
/// incognito cannot be on without something on screen saying so. The History
/// toolbar carries the same marker while the controls are visible.
struct IncognitoIndicator: View {
    var body: some View {
        if IncognitoMode.shared.isOn {
            Label("Incognito", systemImage: "eye.slash.fill")
                .labelStyle(.iconOnly)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Incognito, nothing is being recorded")
        }
    }
}
