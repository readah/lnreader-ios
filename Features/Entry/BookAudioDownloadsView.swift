import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TTSVoicePreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = TTSVoicePreviewPlayer()
    @Published private(set) var voiceId: String?
    private var player: AVAudioPlayer?
    func play(_ record: TTSDownloadRecord) {
        if voiceId == record.rendition.voiceId { stop(); return }
        do {
            if ReaderTTSManager.shared.isSpeaking && !ReaderTTSManager.shared.isPaused { ReaderTTSManager.shared.pause() }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try AVAudioPlayer(contentsOf: TTSStorage.audio(record.id)); player?.delegate = self
            guard player?.play() == true else { return }
            voiceId = record.rendition.voiceId
        } catch { TTSOfflineLibrary.shared.errorMessage = error.localizedDescription }
    }
    func stop() { player?.stop(); player = nil; voiceId = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.stop() } }
}

struct NarrationVoicePicker: View {
    @ObservedObject private var library = TTSOfflineLibrary.shared
    @ObservedObject private var preview = TTSVoicePreviewPlayer.shared
    @Binding var selected: Set<String>
    @State private var showCreateVoice = false
    @State private var deletingVoice: TTSVoice?
    var body: some View {
        ForEach(library.voices) { voice in
            HStack(spacing: 12) {
                Button {
                    if selected.contains(voice.id) { selected.remove(voice.id) } else { selected.insert(voice.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(voice.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading, spacing: 3) {
                            // One motion on screen at a time: the chosen voice
                            // moves, the rest sit still so the list stays calm.
                            TTSVoiceChip(voiceId: voice.id, name: voice.name,
                                         animated: selected.contains(voice.id))
                            Text(voice.description).font(.caption).foregroundStyle(.secondary)
                            Text(voice.isCustom ? "Your voice · English narration" : "LNReader voice design · English narration").font(.caption2).foregroundStyle(.secondary)
                            if let error = voice.preview?.error { Text(error).font(.caption2).foregroundStyle(AppTheme.warning) }
                        }
                        Spacer()
                    }
                }.buttonStyle(AppPlainButtonStyle())
                if let sample = library.records.first(where: { $0.isPreview && $0.isAvailable && $0.rendition.voiceId == voice.id }) {
                    Button { preview.play(sample) } label: {
                        AppLabel("\(preview.voiceId == voice.id ? "Stop" : "Play") downloaded \(voice.name) preview", systemName: preview.voiceId == voice.id ? "stop.fill" : "play.fill", size: 17, relativeTo: .body)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(AppBorderlessButtonStyle())
                } else if let sample = voice.preview, sample.status == "failed" {
                    Button {
                        Task {
                            do { try await TTSAPIClient().action("retry", renditionId: sample.id); await library.refreshVoices() }
                            catch { library.errorMessage = error.localizedDescription }
                        }
                    } label: { AppLabel("Retry \(voice.name) preview", systemName: "arrow.clockwise", size: 17, relativeTo: .body).labelStyle(.iconOnly) }
                    .buttonStyle(AppBorderlessButtonStyle())
                } else {
                    ProgressView().accessibilityLabel("Preview is being prepared")
                }
            }
            .appContextMenu {
                if voice.isCustom {
                    Button("Delete voice", systemImage: "trash", role: .destructive) { deletingVoice = voice }
                }
            }
        }
        Button { showCreateVoice = true } label: { AppLabel("Add your own voice", systemName: "waveform.badge.plus", size: 17, relativeTo: .body) }
            .appSheet(isPresented: $showCreateVoice) {
                CustomVoiceCreationView { voice in selected = [voice.id] }
            }
            .appConfirmationDialog("Delete \(deletingVoice?.name ?? "voice")?", isPresented: Binding(get: { deletingVoice != nil }, set: { if !$0 { deletingVoice = nil } }), titleVisibility: .visible) {
                Button("Delete voice", role: .destructive) {
                    guard let voice = deletingVoice else { return }
                    Task {
                        do { try await library.deleteCustomVoice(voice); selected.remove(voice.id) }
                        catch { library.errorMessage = error.localizedDescription }
                    }
                    deletingVoice = nil
                }
            } message: { Text("This removes the reference and cancels unfinished preparations in this voice. Downloaded book chapters stay on your phone.") }
        AppNavigationLink {
            VoiceReferencePassageView()
        } label: {
            AppLabel("Voice recording passage", systemName: "text.quote", size: 17, relativeTo: .body)
        }
    }
}

struct NarrationComputePicker: View {
    @AppStorage("tts.provider") private var provider = "kaggle"
    @State private var providers: [TTSComputeProvider] = []
    @State private var error: String?
    var body: some View {
        AppPicker("Prepare audio with", selection: $provider) {
            Text("Kaggle").tag("kaggle")
            Text(providers.first(where: { $0.id == "colab" })?.available == true ? "Google Colab" : "Google Colab · not connected").tag("colab")
        }
        .task {
            while !Task.isCancelled {
                do { providers = try await TTSAPIClient().providers(); error = nil }
                catch { self.error = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: provider) { _, _ in Task { await TTSOfflineLibrary.shared.refresh() } }
        if provider == "colab", providers.first(where: { $0.id == "colab" })?.available != true {
            Text(error ?? "Connect Colab on the server before preparing new audio. Downloaded chapters play with either selection.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VoiceReferencePassageView: View {
    // Public-domain opening paragraph of Grant Fairbanks' Rainbow Passage.
    // Source: https://www.dialectsarchive.com/the-rainbow-passage
    static let passage = """
    When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. The rainbow is a division of white light into many beautiful colors. These take the shape of a long round arch, with its path high above, and its two ends apparently beyond the horizon. There is, according to legend, a boiling pot of gold at one end. People look, but no one ever finds it. When a man looks for something beyond his reach, his friends say he is looking for the pot of gold at the end of the rainbow.
    """

    @State private var copied = false

    var body: some View {
        AppForm {
            Section {
                Text(Self.passage)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                Button {
                    UIPasteboard.general.string = Self.passage
                    copied = true
                } label: {
                    AppLabel(copied ? "Passage copied" : "Copy passage", systemName: copied ? "checkmark" : "doc.on.doc", size: 17, relativeTo: .body)
                        }
                .accessibilityHint("Copies only the passage text")
            } header: {
                SettingsSectionHeader(
                    title: "The Rainbow Passage",
                    info: "Read at your usual pace, with natural pauses and a mostly neutral tone. Use gentle expression without acting out emotions. A public-domain passage for sampling English speech sounds, by Grant Fairbanks."
                )
            }
            Section {
                Link(destination: URL(string: "https://www.dialectsarchive.com/the-rainbow-passage")!) { AppLabel("Read the original at IDEA", systemName: "arrow.up.right.square", size: 17, relativeTo: .body) }
            }
        }
        .appNavigationTitle("Recording passage")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct BookAudioDownloadsView: View {
    private enum Layout {
        /// Match this to BookView's horizontal margin (16 or 20) so every card,
        /// button, and sheet control shares one vertical edge rail.
        static let horizontalPadding: CGFloat = 16
        static let cardRadius: CGFloat = 22
        static let sectionSpacing: CGFloat = 20
    }

    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.appDismiss) private var dismiss
    @Environment(\.coverTint) private var coverTint
    @ObservedObject private var library = TTSOfflineLibrary.shared

    let bookId: String
    let bookTitle: String
    let sourceKey: String
    let entryURL: String
    let chapters: [TTSChapterChoice]
    var coverURL: String? = nil
    var initialChapter: String? = nil

    @State private var selectedVoices: Set<String> = []
    @State private var fromChapter = 1
    @State private var throughChapter = 1
    @State private var preparing = false
    @State private var preparationProgress = ""
    @State private var preparationTask: Task<Void, Never>?
    @State private var error: String?
    @State private var dismissedToastID: String?
    @State private var search = ""
    @State private var stateFilter = "All"
    @State private var showVoices = false
    @State private var showRange = false
    @State private var initialized = false
    @State private var deleteTarget: TTSDownloadRecord?
    @State private var deleteIDs: [String] = []
    @State private var voiceFilter = "all"
    @State private var chapterPage = 0

    @AppStorage("tts.provider") private var computeProvider = "kaggle"
    @AppStorage("tts.wifiOnly") private var wifiOnly = true
    @AppStorage(AppearanceTint.strengthKey) private var tintStrength = AppearanceTint.defaultStrength

    // MARK: - Derived State

    private var selectedChapters: [TTSChapterChoice] {
        guard !chapters.isEmpty else { return [] }
        let start = min(max(fromChapter - 1, 0), chapters.count - 1)
        let end = min(max(throughChapter - 1, start), chapters.count - 1)
        return Array(chapters[start...end])
    }

    private var visibleAll: [TTSChapterChoice] {
        let indexed = groups
        return chapters.filter { chapter in
            let records = indexed[chapter.path] ?? []
            guard !records.isEmpty else { return false }
            return matches(chapter, records: records)
        }
    }

    private var pageCount: Int { max(1, (visibleAll.count + 99) / 100) }
    private var currentPage: Int { min(chapterPage, pageCount - 1) }
    private var pageLabel: String {
        let first = currentPage * 100 + 1
        let last = min((currentPage + 1) * 100, visibleAll.count)
        return "\(first)–\(last) of \(visibleAll.count)"
    }

    private var currentChoice: TTSChapterChoice? {
        chapters.first { $0.path == initialChapter } ?? chapters.first
    }

    private var bookRecords: [TTSDownloadRecord] { library.downloads(bookId: bookId) }
    private var byteCount: Int64 { bookRecords.filter(\.isAvailable).reduce(0) { $0 + $1.bytesExpected } }

    private var groups: [String: [TTSDownloadRecord]] {
        Dictionary(
            grouping: bookRecords.filter { voiceFilter == "all" || $0.rendition.voiceId == voiceFilter },
            by: { $0.rendition.chapterId }
        )
    }

    private var activeVoice: String {
        let preferred = library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? "")
        return selectedVoices.contains(preferred) ? preferred : selectedVoices.sorted().first ?? preferred
    }

    private var activeFilterCount: Int {
        (stateFilter == "All" ? 0 : 1) + (voiceFilter == "all" ? 0 : 1)
    }

    private var offlineSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private var failedRecords: [TTSDownloadRecord] {
        groups.values
            .flatMap { $0 }
            .filter { !$0.isAvailable && $0.state == "failed" }
    }

    private var downloadBlocked: Bool {
        preparing || selectedVoices.isEmpty || currentChapterIndex == nil
    }

    private var currentChapterIndex: Int? {
        if let initialChapter,
           let index = chapters.firstIndex(where: { $0.path == initialChapter }) {
            return index
        }
        return chapters.isEmpty ? nil : 0
    }

    private var downloadCurrentTitle: String {
        guard let currentChoice else { return "Download chapter" }
        return "Download chapter \(currentChoice.position + 1)"
    }

    /// Single source of truth for all status / progress / warning messages.
    /// Dismiss tracking keeps the 3-second refresh loop from re-popping a
    /// warning the user already cleared, until the message actually changes.
    private var activeToast: AudioToastMessage? {
        if preparing {
            let text = preparationProgress.isEmpty ? "Preparing audio…" : preparationProgress
            return AudioToastMessage(id: "preparing", kind: .progress, message: text)
        }
        if let message = error ?? library.errorMessage ?? (library.engineState?.needsAttention == true ? library.engineState?.message : nil) {
            let id = "warn:\(message)"
            guard dismissedToastID != id else { return nil }
            return AudioToastMessage(id: id, kind: .warning, message: message)
        }
        return nil
    }

    private func matches(_ chapter: TTSChapterChoice, records: [TTSDownloadRecord]) -> Bool {
        let searchable = "\(chapter.position + 1) \(chapter.title)"
        guard search.isEmpty || searchable.localizedCaseInsensitiveContains(search) else { return false }
        switch stateFilter {
        case "Downloaded": return records.contains { $0.isAvailable }
        case "Preparing": return records.contains { ["waiting", "downloading"].contains($0.state) }
        case "Issues": return records.contains { $0.error != nil || ["failed", "paused"].contains($0.state) }
        default: return true
        }
    }

    // MARK: - Body

    var body: some View {
        AppNavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    heroHeader
                    actionControls
                    downloadsSection
                }
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, activeToast == nil ? 28 : 96)
            }
            .scrollIndicators(.hidden)
            .background {
                EntryAtmosphericBackdrop(
                    coverURL: coverURL,
                    tint: coverTint,
                    strength: tintStrength,
                    scrimDepth: 0.72
                )
            }
            .overlay(alignment: .bottom) {
                if let toast = activeToast {
                    AudioStatusToast(
                        toast: toast,
                        onStop: toast.kind == .progress ? { preparationTask?.cancel() } : nil,
                        onDismiss: { dismissToast(toast) }
                    )
                    .padding(.horizontal, Layout.horizontalPadding)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: activeToast?.id)
            .appNavigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    AppMenu {
                        Toggle("Wi-Fi downloads only", isOn: $wifiOnly)
                        AppPicker("Prepare with", selection: $computeProvider) {
                            Text("Kaggle").tag("kaggle")
                            Text("Colab").tag("colab")
                        }
                        if !bookRecords.isEmpty {
                            Divider()
                            Button("Delete selected range…", role: .destructive) {
                                let paths = Set(selectedChapters.map(\.path))
                                deleteIDs = bookRecords
                                    .filter { paths.contains($0.rendition.chapterId) && (voiceFilter == "all" || $0.rendition.voiceId == voiceFilter) }
                                    .map(\.id)
                            }
                            Button("Delete all downloaded…", role: .destructive) {
                                deleteIDs = bookRecords
                                    .filter { voiceFilter == "all" || $0.rendition.voiceId == voiceFilter }
                                    .map(\.id)
                            }
                        }
                    } label: {
                        AppLabel("Audio download options", systemName: "ellipsis.circle", size: 17, relativeTo: .body)
                    }
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if pageCount > 1 {
                    AppToolbarItemGroup(placement: .bottomBar) {
                        Button { chapterPage = max(0, currentPage - 1) } label: {
                            AppLabel("Previous chapters", systemName: "chevron.left", size: 12, relativeTo: .caption).labelStyle(.iconOnly)
                        }
                        .disabled(currentPage == 0)
                        Spacer()
                        Text(pageLabel).font(.caption.monospacedDigit())
                        Spacer()
                        Button { chapterPage = min(pageCount - 1, currentPage + 1) } label: {
                            AppLabel("Next chapters", systemName: "chevron.right", size: 17, relativeTo: .body).labelStyle(.iconOnly)
                        }
                        .disabled(currentPage + 1 >= pageCount)
                    }
                }
            }
            .toolbar(pageCount > 1 ? .visible : .hidden, for: .bottomBar)
            .appSheet(isPresented: $showVoices) {
                AppNavigationStack {
                    AppForm {
                        Section { NarrationComputePicker() }
                        Section("Narrator") { NarrationVoicePicker(selected: $selectedVoices) }
                    }
                    .appNavigationTitle("Choose voices")
                    .navigationBarTitleDisplayMode(.large)
                    .appToolbar {
                        AppToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                if let voice = selectedVoices.sorted().first {
                                    library.setBookVoice(voice, bookId: bookId)
                                }
                                showVoices = false
                            }
                        }
                    }
                }
            }
            .appSheet(isPresented: $showRange) { rangePicker }
            .task {
                if !initialized {
                    let index = chapters.firstIndex { $0.path == initialChapter } ?? 0
                    fromChapter = index + 1
                    throughChapter = fromChapter
                    chapterPage = index / 100
                    selectedVoices = [library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? chapters.first?.path ?? "")]
                    initialized = true
                }
                await library.refreshVoices()
                while !Task.isCancelled {
                    await library.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            .appRefreshable {
                await library.refreshVoices()
                await library.refresh()
            }
            .onChange(of: search) { _, _ in chapterPage = 0 }
            .onChange(of: stateFilter) { _, _ in chapterPage = 0 }
            .onChange(of: voiceFilter) { _, _ in chapterPage = 0 }
            .appConfirmationDialog(
                "Delete this chapter audio everywhere?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
            ) {
                if let record = deleteTarget {
                    Button("Delete \(voiceName(record))", role: .destructive) {
                        Task { await library.delete(record.id) }
                        deleteTarget = nil
                    }
                }
            } message: {
                Text("Other voices and chapter text remain available.")
            }
            .appConfirmationDialog(
                "Delete \(deleteIDs.count) chapter voice downloads everywhere?",
                isPresented: Binding(get: { !deleteIDs.isEmpty }, set: { if !$0 { deleteIDs = [] } })
            ) {
                Button("Delete selected audio everywhere", role: .destructive) {
                    let ids = deleteIDs
                    deleteIDs = []
                    Task { await library.deleteMany(ids) }
                }
            } message: {
                Text("Chapter text stays on this phone. You can prepare the voices again later.")
            }
        }
    }

    // MARK: - Hero

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            EntryCoverView(url: coverURL, cornerRadius: 12)
                .frame(width: 88)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(bookTitle)
                    .font(Typography.title)
                    .lineLimit(2)

                if let currentChoice {
                    Text("Chapter \(currentChoice.position + 1) · \(currentChoice.title)")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                narratorButton
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var narratorButton: some View {
        let name = library.voices.first { $0.id == activeVoice }?.name ?? "Narrator"
        let extraCount = max(selectedVoices.count - 1, 0)

        return Button { showVoices = true } label: {
            HStack(spacing: 7) {
                AppIcon(systemName: "waveform", size: 12, relativeTo: .body)
                    .font(.system(size: 12, weight: .semibold))
                Text(extraCount > 0 ? "\(name) +\(extraCount)" : name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                Text("Narrator")
                    .font(Typography.caption)
                    .opacity(0.75)
                AppIcon(systemName: "chevron.right", size: 10, relativeTo: .body)
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.65)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { VoiceGlowSurface(voiceId: activeVoice, halo: 8) }
            .contentShape(Capsule())
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Narrator: \(name)")
        .accessibilityHint("Choose a narrator voice")
    }

    // MARK: - Actions

    private var actionControls: some View {
        VStack(spacing: 10) {
            Button(action: downloadCurrent) {
                AppLabel(downloadCurrentTitle, systemName: "arrow.down.circle.fill", size: 17, relativeTo: .body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(downloadBlocked)

            AudioGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { downloadNext(10) } label: {
                        AppLabel("Next 10", systemName: "arrow.down.circle", size: 16, relativeTo: .body)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .appGlassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(downloadBlocked)

                    Button { showRange = true } label: {
                        AppLabel("Range…", systemName: "slider.horizontal.3", size: 16, relativeTo: .body)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .appGlassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(chapters.isEmpty)
                }
            }

            if !failedRecords.isEmpty {
                retryAllButton
            }
        }
    }

    private var retryAllButton: some View {
        Button {
            Haptics.shared.impact(.light, intensity: 0.8)
            Task { await library.retryAllFailed(bookId: bookId) }
        } label: {
            AppLabel(
                failedRecords.count == 1 ? "Retry 1 failed chapter" : "Retry \(failedRecords.count) failed chapters",
                systemName: "arrow.clockwise",
                size: 16,
                relativeTo: .body
            )
            .foregroundStyle(AppTheme.warning)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .appGlassButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(preparing)
        .accessibilityHint("Queues every failed narration for this book again")
    }

    // MARK: - Downloads Section

    private var downloadsSection: some View {
        let indexed = groups
        let visible = visibleAll
        let page = min(chapterPage, pageCount - 1)
        let pagedChapters = Array(visible.dropFirst(page * 100).prefix(100))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text("Downloaded")
                        .font(Typography.headline)
                    Text("· \(visibleAll.count)")
                        .font(Typography.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if byteCount > 0 {
                        Text("· \(offlineSizeLabel)")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                AppMenu {
                    AppPicker("Status", selection: $stateFilter) {
                        ForEach(["All", "Downloaded", "Preparing", "Issues"], id: \.self) { Text($0).tag($0) }
                    }
                    AppPicker("Voice", selection: $voiceFilter) {
                        Text("All voices").tag("all")
                        ForEach(library.voices) { Text($0.name).tag($0.id) }
                    }
                    if activeFilterCount > 0 {
                        Divider()
                        Button("Reset filters") {
                            stateFilter = "All"
                            voiceFilter = "all"
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        AppIcon(systemName: "line.3.horizontal.decrease", size: 12, relativeTo: .caption)
                        Text(activeFilterCount > 0 ? "\(stateFilter) (\(activeFilterCount))" : "Filter")
                            .font(Typography.caption.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .audioGlassCapsule(interactive: true)
                }
            }

            if !bookRecords.isEmpty {
                inlineSearchBar
            }

            if pagedChapters.isEmpty {
                compactEmptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pagedChapters.enumerated()), id: \.element.id) { idx, chapter in
                        chapterRow(chapter, records: indexed[chapter.path] ?? [])
                        if idx < pagedChapters.count - 1 {
                            Divider()
                                .overlay(.white.opacity(0.08))
                                .padding(.leading, 62)
                        }
                    }
                }
                .audioGlassCard(cornerRadius: Layout.cardRadius)
            }
        }
    }

    private var inlineSearchBar: some View {
        HStack(spacing: 8) {
            AppIcon(systemName: "magnifyingglass", size: 14, relativeTo: .body)
                .foregroundStyle(.secondary)
            TextField("Chapter number or title", text: $search)
                .font(Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    AppIcon(systemName: "xmark.circle.fill", size: 15, relativeTo: .body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(AppPlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .audioGlassCapsule(interactive: true)
    }

    private var compactEmptyState: some View {
        VStack(spacing: 8) {
            AppIcon(systemName: "headphones", size: 28, relativeTo: .body)
                .foregroundStyle(.secondary)
            Text(bookRecords.isEmpty ? "Nothing downloaded" : "No matching chapters")
                .font(Typography.headline)
            Text(
                bookRecords.isEmpty
                    ? "Download this chapter, the next ten, or pick a custom range above."
                    : "Try clearing your search or changing the filter."
            )
            .font(Typography.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .audioGlassCard(cornerRadius: Layout.cardRadius)
    }

    private func chapterRow(_ chapter: TTSChapterChoice, records: [TTSDownloadRecord]) -> some View {
        let primary = primaryRecord(records)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.09))
                    Text("\(chapter.position + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 36, height: 36)

                AppNavigationLink {
                    TTSChapterAudioDetailView(
                        chapter: chapter,
                        bookId: bookId,
                        bookTitle: bookTitle,
                        coverURL: coverURL,
                        onPlay: { playAudio($0) },
                        onAddVoice: { showVoices = true }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chapter.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(
                            primary.map {
                                $0.isAvailable
                                    ? "\(voiceName($0)) · Offline"
                                    : $0.rendition.completedChunks > 0
                                        ? "\(voiceName($0)) · \($0.rendition.completedChunks)/\($0.rendition.totalChunks) parts ready"
                                        : status($0)
                            } ?? (records.isEmpty ? "Tap to see details" : "\(records.count) voices saved")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AppPlainButtonStyle())

                if let primary, canPlay(primary) {
                    Button { playAudio(primary) } label: {
                        AppLabel("Play \(chapter.title)", systemName: "play.circle.fill", size: 28, relativeTo: .title)
                            .labelStyle(.iconOnly)
                    }
                } else if let primary, ["failed", "paused"].contains(primary.state) {
                    Button { Task { await library.retry(primary.id) } } label: {
                        AppLabel("Retry \(chapter.title)", systemName: "arrow.clockwise.circle", size: 22, relativeTo: .title2)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(AppTheme.warning)
                    }
                } else if primary != nil {
                    ProgressView()
                } else {
                    Button { downloadChapter(chapter) } label: {
                        AppLabel("Download \(chapter.title)", systemName: "arrow.down.circle", size: 22, relativeTo: .title2)
                            .labelStyle(.iconOnly)
                    }
                    .disabled(preparing)
                }
            }
            .buttonStyle(AppBorderlessButtonStyle())

            if let primary, ["waiting", "downloading"].contains(primary.state) {
                ProgressView(value: primary.progress)
                    .tint(AppTheme.primaryFill)
                    .padding(.leading, 48)
            }

            if let primary, primary.state == "failed" || primary.state == "paused" {
                HStack(alignment: .center, spacing: 8) {
                    Text(primary.error ?? "Preparation is paused.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await library.retry(primary.id) } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(AppBorderlessButtonStyle())
                }
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contextMenu {
            if let primary, canPlay(primary) {
                Button("Play", systemImage: "play.fill") { playAudio(primary) }
            }
            if let primary, ["failed", "paused"].contains(primary.state) {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await library.retry(primary.id) }
                }
            }
            if let primary {
                Button("Delete \(voiceName(primary))", systemImage: "trash", role: .destructive) {
                    deleteTarget = primary
                }
            }
        }
    }

    // MARK: - Range Sheet

    private var rangePicker: some View {
        AppNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Live range summary header
                    HStack(alignment: .firstTextBaseline) {
                        Text("Chapters \(fromChapter.formatted())–\(throughChapter.formatted())")
                            .font(Typography.headline.monospacedDigit())
                        Spacer()
                        Text("\(selectedChapters.count.formatted()) selected")
                            .font(Typography.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    // Quick preset chips
                    AudioGlassContainer(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                rangePresetChip("+10") { applyPreset(span: 10) }
                                rangePresetChip("+25") { applyPreset(span: 25) }
                                rangePresetChip("+50") { applyPreset(span: 50) }
                                rangePresetChip("To End") {
                                    setRangeStart(fromChapter)
                                    setRangeEnd(chapters.count)
                                }
                                rangePresetChip("All") {
                                    setRangeStart(1)
                                    setRangeEnd(chapters.count)
                                }
                            }
                        }
                    }

                    // Unified slider + steppers Liquid Glass card
                    VStack(spacing: 0) {
                        VStack(spacing: 8) {
                            ChapterRangeSlider(lower: $fromChapter, upper: $throughChapter, count: chapters.count)
                            HStack {
                                Text("1")
                                Spacer()
                                Text(max(chapters.count, 1).formatted())
                            }
                            .font(Typography.small.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 14)

                        Divider().overlay(.white.opacity(0.08))

                        rangeStepperRow("From", value: fromChapterBinding)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                        Divider()
                            .overlay(.white.opacity(0.08))
                            .padding(.leading, 16)

                        rangeStepperRow("Through", value: throughChapterBinding)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .audioGlassCard(cornerRadius: Layout.cardRadius)

                    Text(rangeSummary)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background {
                EntryAtmosphericBackdrop(
                    coverURL: coverURL,
                    tint: coverTint,
                    strength: tintStrength * 0.65,
                    scrimDepth: 0.84
                )
            }
            .appNavigationTitle("Range")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRange = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { commitRange() } label: {
                    Text(rangeDownloadTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(selectedChapters.isEmpty || selectedVoices.isEmpty || preparing)
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .appPresentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func rangePresetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.selection()
            action()
        } label: {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .audioGlassCapsule(interactive: true)
        }
        .buttonStyle(AppPlainButtonStyle())
    }

    private func applyPreset(span: Int) {
        let start = max(1, min(fromChapter, max(chapters.count, 1)))
        setRangeStart(start)
        setRangeEnd(min(chapters.count, start + span - 1))
    }

    private func rangeStepperRow(_ title: String, value: Binding<Int>) -> some View {
        AppStepper(value: value, in: 1...max(chapters.count, 1)) {
            HStack {
                Text(title)
                    .font(Typography.body)
                Spacer()
                Text(value.wrappedValue.formatted())
                    .font(Typography.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue("Chapter \(value.wrappedValue)")
    }

    private var rangeDownloadTitle: String {
        let count = selectedChapters.count
        return count == 1 ? "Download 1 chapter" : "Download \(count.formatted()) chapters"
    }

    private var fromChapterBinding: Binding<Int> {
        Binding(get: { fromChapter }, set: { setRangeStart($0) })
    }

    private var throughChapterBinding: Binding<Int> {
        Binding(get: { throughChapter }, set: { setRangeEnd($0) })
    }

    private func setRangeStart(_ value: Int) {
        let next = min(max(value, 1), max(chapters.count, 1))
        fromChapter = next
        if throughChapter < next { throughChapter = next }
    }

    private func setRangeEnd(_ value: Int) {
        let next = min(max(value, 1), max(chapters.count, 1))
        throughChapter = next
        if fromChapter > next { fromChapter = next }
    }

    private var rangeSummary: String {
        let count = selectedChapters.count
        let voices = selectedVoices.count
        guard voices > 0 else { return "Choose a narrator before preparing this range." }
        return "\(count.formatted()) chapter\(count == 1 ? "" : "s") in \(voices) voice\(voices == 1 ? "" : "s"), prepared in the background and kept on this phone."
    }

    // MARK: - Actions & Helpers

    private func dismissToast(_ toast: AudioToastMessage) {
        if toast.kind == .progress {
            preparationTask?.cancel()
        } else {
            dismissedToastID = toast.id
            if error != nil { error = nil }
        }
    }

    private func downloadCurrent() {
        guard let index = currentChapterIndex else { return }
        fromChapter = index + 1
        throughChapter = fromChapter
        prepareSelected()
    }

    private func downloadNext(_ count: Int) {
        guard let index = currentChapterIndex else { return }
        fromChapter = index + 1
        throughChapter = min(chapters.count, fromChapter + count - 1)
        prepareSelected()
    }

    private func commitRange() {
        setRangeStart(fromChapter)
        setRangeEnd(throughChapter)
        showRange = false
        prepareSelected()
    }

    private func primaryRecord(_ records: [TTSDownloadRecord]) -> TTSDownloadRecord? {
        records.first { $0.rendition.voiceId == activeVoice }
    }

    private func canPlay(_ record: TTSDownloadRecord) -> Bool {
        record.isAvailable || record.rendition.completedChunks > 0
    }

    private func playAudio(_ record: TTSDownloadRecord) {
        library.selectVoice(record.rendition.voiceId, bookId: bookId, chapterId: record.rendition.chapterId)
        ReaderTTSManager.shared.attachCover(url: coverURL, bookId: bookId)
        ReaderTTSManager.shared.playAvailable(record)
        dismiss()
    }

    private func downloadChapter(_ chapter: TTSChapterChoice) {
        fromChapter = (chapters.firstIndex { $0.path == chapter.path } ?? 0) + 1
        throughChapter = fromChapter
        prepareSelected()
    }

    private func voiceName(_ record: TTSDownloadRecord) -> String {
        library.voices.first { $0.id == record.rendition.voiceId }?.name
            ?? record.manifest?.voiceName
            ?? record.rendition.voiceId
    }

    private func status(_ record: TTSDownloadRecord) -> String {
        switch record.state {
        case "downloaded":
            return "Available offline · " + ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file)
        case "waiting":
            if record.rendition.status == "ready" { return "Ready on server · waiting for transfer" }
            let label = record.rendition.status == "loading"
                ? "Loading Breeze models"
                : record.rendition.status == "generating"
                    ? "Generating speech"
                    : record.rendition.status == "assembling"
                        ? "Assembling audio"
                        : record.rendition.status.capitalized
            return "\(label) · \(record.rendition.completedChunks)/\(record.rendition.totalChunks) parts"
        case "downloading":
            return "Downloading to this phone"
        default:
            return record.state.capitalized
        }
    }

    private func prepareSelected() {
        guard !preparing else { return }
        let choices = selectedChapters
        let preferred = library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? choices.first?.path ?? "")
        let voices = selectedVoices.sorted { a, b in a == preferred ? true : b == preferred ? false : a < b }
        preparing = true
        error = nil
        dismissedToastID = nil
        preparationTask = Task { @MainActor in
            defer { preparing = false }
            do {
                for (index, chapter) in choices.enumerated() {
                    try Task.checkCancellation()
                    preparationProgress = "Adding \(index + 1) of \(choices.count)…"
                    if let cached = library.localText(bookId: bookId, chapterId: chapter.path) {
                        try await library.prepare(
                            chapter: .init(bookId: bookId, bookTitle: bookTitle, chapterId: chapter.path, title: chapter.title, position: chapter.position, blocks: cached.blocks),
                            voiceIds: voices
                        )
                        continue
                    }
                    let html: String
                    if sourceKey == SourceKey.local {
                        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("LocalNovels")
                            .appendingPathComponent(entryURL.replacingOccurrences(of: "local://", with: ""))
                        let file = folder.appendingPathComponent(chapter.path).standardizedFileURL
                        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                            throw TTSError.request("Invalid local chapter path")
                        }
                        html = try String(contentsOf: file, encoding: .utf8)
                    } else {
                        guard let source = sourceManager.novelSource(forKey: sourceKey) else {
                            throw TTSError.request("Source is unavailable")
                        }
                        html = try await source.chapterHTML(SourceChapter(url: chapter.path, name: chapter.title))
                    }
                    let blocks = try await TTSChapterTextExtractor().extract(html)
                    try await library.prepare(
                        chapter: .init(bookId: bookId, bookTitle: bookTitle, chapterId: chapter.path, title: chapter.title, position: chapter.position, blocks: blocks),
                        voiceIds: voices
                    )
                }
            } catch is CancellationError { }
            catch {
                self.error = "\(preparationProgress) \(error.localizedDescription) Chapters already added remain queued."
            }
        }
    }
}

/// Upgraded Liquid Glass range slider (preserves the collapsed-range bidirectional drag behavior).
private struct ChapterRangeSlider: View {
    @Binding var lower: Int
    @Binding var upper: Int
    let count: Int

    @Environment(\.noLiquidGlass) private var classic
    private let knob: CGFloat = 28
    private let hitHeight: CGFloat = 44
    @State private var drag: DragState?

    private struct DragState {
        var handle: Handle
        let startedCollapsed: Bool
    }

    private enum Handle { case lower, upper }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(width - knob, 1)
            let lowerX = knob / 2 + span * position(of: lower)
            let upperX = knob / 2 + span * position(of: upper)

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(width: span, height: 6)
                    .position(x: width / 2, y: hitHeight / 2)

                Capsule()
                    .fill(AppTheme.primaryFill)
                    .frame(width: max(upperX - lowerX, 0), height: 6)
                    .position(x: (lowerX + upperX) / 2, y: hitHeight / 2)

                knobView(active: drag?.handle == .lower)
                    .position(x: lowerX, y: hitHeight / 2)

                knobView(active: drag?.handle == .upper)
                    .position(x: upperX, y: hitHeight / 2)
            }
            .frame(width: width, height: hitHeight)
            .contentShape(Rectangle())
            .gesture(dragGesture(span: span))
        }
        .frame(height: hitHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chapter range")
        .accessibilityValue("Chapters \(lower) through \(upper) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: upper = min(max(upper, lower) + 1, count)
            case .decrement: upper = max(lower, upper - 1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func knobView(active: Bool) -> some View {
        let base = Circle()
            .fill(.white.opacity(active ? 0.96 : 0.88))
            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
            .frame(width: knob, height: knob)
            .scaleEffect(active ? 1.14 : 1)
            .shadow(color: .black.opacity(0.28), radius: active ? 8 : 4, y: 2)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: active)

        if #available(iOS 26.0, *), !classic {
            base.glassEffect(.regular.interactive(), in: Circle())
        } else {
            base
        }
    }

    private func dragGesture(span: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard count > 1 else { return }
                let chapter = chapter(at: value.location.x, span: span)
                if drag == nil {
                    if lower == upper {
                        guard abs(value.translation.width) > 2 else { return }
                        drag = DragState(
                            handle: value.translation.width < 0 ? .lower : .upper,
                            startedCollapsed: true
                        )
                    } else {
                        let lowerX = knob / 2 + span * position(of: lower)
                        let upperX = knob / 2 + span * position(of: upper)
                        drag = DragState(
                            handle: abs(value.startLocation.x - lowerX) <= abs(value.startLocation.x - upperX) ? .lower : .upper,
                            startedCollapsed: false
                        )
                    }
                }
                if var state = drag, state.startedCollapsed, lower == upper,
                   abs(value.translation.width) > 2 {
                    state.handle = value.translation.width < 0 ? .lower : .upper
                    drag = state
                }
                switch drag?.handle {
                case .lower:
                    let next = min(chapter, upper)
                    if next != lower { lower = next; Haptics.shared.selection() }
                case .upper:
                    let next = max(chapter, lower)
                    if next != upper { upper = next; Haptics.shared.selection() }
                case nil:
                    break
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func chapter(at x: CGFloat, span: CGFloat) -> Int {
        guard count > 1 else { return 1 }
        let clamped = min(max(x - knob / 2, 0), span)
        let raw = Int(((clamped / span) * CGFloat(count - 1)).rounded()) + 1
        return min(max(raw, 1), count)
    }

    private func position(of value: Int) -> CGFloat {
        guard count > 1 else { return 0.5 }
        return CGFloat(min(max(value, 1), count) - 1) / CGFloat(count - 1)
    }
}

// MARK: - Toast Model & Placeholder (swap for app's existing Liquid Glass toast)

private struct AudioToastMessage: Equatable {
    enum Kind: Equatable { case progress, warning }
    let id: String
    let kind: Kind
    let message: String
}

private struct AudioStatusToast: View {
    let toast: AudioToastMessage
    var onStop: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if toast.kind == .progress {
                ProgressView()
                    .controlSize(.small)
            } else {
                AppIcon(systemName: "exclamationmark.circle.fill", size: 16, relativeTo: .body)
                    .foregroundStyle(AppTheme.warning)
            }

            Text(toast.message)
                .font(Typography.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onStop {
                Button("Stop", action: onStop)
                    .font(Typography.caption.weight(.semibold))
                    .buttonStyle(AppBorderlessButtonStyle())
            }

            Button(action: onDismiss) {
                AppIcon(systemName: "xmark", size: 11, relativeTo: .caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(AppPlainButtonStyle())
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .audioGlassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    if value.translation.height > 20 { onDismiss() }
                }
        )
    }
}

// MARK: - Dual-Mode Liquid Glass Helpers

/// Groups interactive glass controls on iOS 26, and falls back to plain
/// content in classic mode (the app's `noLiquidGlass` runtime gate) as well as
/// on older OS versions.
private struct AudioGlassContainer<Content: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *), !classic {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

private struct AudioGlassCard: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(iOS 26.0, *), !classic {
                content
                    .background(shape.fill(.white.opacity(0.04)))
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .background(shape.fill(.ultraThinMaterial))
                    .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
                    .clipShape(shape)
            }
        }
    }
}

private struct AudioGlassCapsule: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let interactive: Bool

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *), !classic {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
            } else {
                content
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            }
        }
    }
}

private extension View {
    func audioGlassCard(cornerRadius: CGFloat) -> some View {
        modifier(AudioGlassCard(cornerRadius: cornerRadius))
    }

    func audioGlassCapsule(interactive: Bool = false) -> some View {
        modifier(AudioGlassCapsule(interactive: interactive))
    }
}


@MainActor
private final class VoiceSampleRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    @Published var file: URL?
    @Published var duration = 0.0
    @Published var recording = false
    @Published var requestingPermission = false
    @Published var playing = false
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var disposed = false
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-draft-" + UUID().uuidString)

    func record() async {
        guard !disposed && !recording && !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Allow microphone access in iPhone Settings to record a voice sample. You can also import an audio file."
            return
        }
        guard !disposed else { return }
        stopPlayback()
        if ReaderTTSManager.shared.isSpeaking { ReaderTTSManager.shared.pause() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent(UUID().uuidString + ".m4a")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let next = try AVAudioRecorder(url: path, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            next.delegate = self
            guard next.record(forDuration: 60) else { throw TTSError.request("Could not start recording.") }
            recorder = next; file = path; duration = 0; recording = true; error = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.duration = self?.recorder?.currentTime ?? self?.duration ?? 0 }
            }
        } catch { self.error = error.localizedDescription; stopRecording() }
    }
    func stopRecording() {
        if let recorder, recorder.isRecording { duration = recorder.currentTime }
        recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func importSample(_ url: URL) async {
        stopRecording(); stopPlayback()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 6_000_000 else { throw TTSError.request("Choose an audio file smaller than 6 MB.") }
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            guard !disposed else { return }
            guard seconds.isFinite, seconds >= 3, seconds <= 60 else { throw TTSError.request("Choose between 3 and 60 seconds of speech.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            try FileManager.default.copyItem(at: url, to: copy)
            file = copy; duration = seconds; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func togglePlayback() {
        if playing { stopPlayback(); return }
        guard let file else { return }
        do {
            if ReaderTTSManager.shared.isSpeaking { ReaderTTSManager.shared.pause() }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: file); player?.delegate = self
            playing = player?.play() == true
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); player = nil; playing = false }
    func cleanUp() { disposed = true; stopRecording(); stopPlayback(); try? FileManager.default.removeItem(at: folder) }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.stopPlayback() } }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recording, self.recorder === recorder else { return }
            self.stopRecording()
            if flag, let file = self.file { self.duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? self.duration }
            else if !flag { self.error = "Recording was interrupted. Record a new sample."; self.file = nil }
        }
    }
}

private struct CustomVoiceCreationView: View {
    @Environment(\.appDismiss) private var dismiss
    @StateObject private var sample = VoiceSampleRecorder()
    @State private var name = ""
    @State private var transcript = ""
    @State private var importing = false
    @State private var saving = false
    @State private var error: String?
    let onCreated: (TTSVoice) -> Void

    var body: some View {
        AppNavigationStack {
            AppForm {
                Section { NarrationComputePicker() }
                Section {
                    TextField("Voice name", text: $name).textInputAutocapitalization(.words)
                }
                Section {
                    HStack {
                        Button {
                            if sample.recording { sample.stopRecording() } else { Task { await sample.record() } }
                        } label: { AppLabel(sample.recording ? "Stop recording" : "Record sample", systemName: sample.recording ? "stop.circle.fill" : "mic.fill", size: 17, relativeTo: .body) }
                        .buttonStyle(AppBorderlessButtonStyle())
                        .disabled(sample.requestingPermission)
                        Spacer()
                        Text("\(Int(sample.duration))s / 60s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button { importing = true } label: { AppLabel("Import audio", systemName: "square.and.arrow.down", size: 17, relativeTo: .body) }.disabled(sample.recording)
                    if sample.file != nil && !sample.recording {
                        Button { sample.togglePlayback() } label: { AppLabel(sample.playing ? "Stop sample" : "Listen to sample", systemName: sample.playing ? "stop.fill" : "play.fill", size: 17, relativeTo: .body) }
                    }
                } header: {
                    SettingsSectionHeader(
                        title: "Voice sample",
                        info: "Record 3–60 seconds of clear speech without music or other speakers. Speak naturally with a mostly neutral tone. Longer recordings do not guarantee a better clone."
                    )
                }
                Section {
                    AppNavigationLink { VoiceReferencePassageView() } label: { AppLabel("Read or copy the sample passage", systemName: "text.quote", size: 17, relativeTo: .body) }
                    Button("I read the full passage exactly") { transcript = VoiceReferencePassageView.passage }
                        .disabled(sample.recording || sample.file == nil)
                }
                Section {
                    TextEditor(text: $transcript).frame(minHeight: 100).accessibilityLabel("Recording transcript, optional")
                } header: {
                    SettingsSectionHeader(
                        title: "Transcript · optional",
                        info: "Enter exactly what was spoken. Leave blank to transcribe the sample automatically during preparation."
                    )
                }
                if let message = error ?? sample.error { Section { Text(message).foregroundStyle(AppTheme.destructive).textSelection(.enabled) } }
                Section {
                    Button {
                        guard let file = sample.file else { return }
                        sample.stopPlayback(); saving = true; error = nil
                        Task {
                            do {
                                let voice = try await TTSOfflineLibrary.shared.addCustomVoice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), sample: file, transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
                                onCreated(voice); dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    } label: {
                        HStack { if saving { ProgressView() }; Text(saving ? "Saving voice…" : "Add voice and prepare preview") }
                    }
                    .disabled(saving || sample.recording || sample.file == nil || sample.duration < 3 || sample.duration > 60 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60 || transcript.count > 6000)
                } header: {
                    SettingsSectionHeader(
                        title: "Preparation",
                        info: "Your sample stays on this phone. Chapter audio and the voice preview are prepared remotely, then downloaded for offline listening."
                    )
                }
            }
            .disabled(saving)
            .appNavigationTitle("Your voice")
            .navigationBarTitleDisplayMode(.large)
            .appToolbar { AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): Task { await sample.importSample(url) }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .onChange(of: sample.file) { _, _ in transcript = "" }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in if sample.recording { sample.stopRecording() } }
        }
        .appInteractiveDismissDisabled(saving || sample.recording || sample.requestingPermission)
        .onDisappear { sample.cleanUp() }
    }
}


// MARK: - Chapter audio detail

/// Full detail for one chapter's audio, pushed from the audio list instead of
/// expanding rows in place. Uses the ambient aurora backdrop behind frosted cards.
struct TTSChapterAudioDetailView: View {
    @ObservedObject private var library = TTSOfflineLibrary.shared
    let chapter: TTSChapterChoice
    let bookId: String
    let bookTitle: String
    var coverURL: String? = nil
    var onPlay: ((TTSDownloadRecord) -> Void)? = nil
    var onAddVoice: (() -> Void)? = nil

    @State private var deleteTarget: TTSDownloadRecord?

    private var records: [TTSDownloadRecord] { library.downloads(bookId: bookId, chapterId: chapter.path) }
    private var primary: TTSDownloadRecord? {
        let selected = library.selectedVoice(bookId: bookId, chapterId: chapter.path)
        return records.first { $0.rendition.voiceId == selected } ?? records.first
    }

    var body: some View {
        List {
            Section { header }
            if let primary { statusSection(primary) }
            if let preview { previewSection(preview) }
            if records.isEmpty { emptySection }
            if !records.isEmpty { voicesSection }
            if let onAddVoice {
                Section {
                    Button(action: onAddVoice) { AppLabel("Download another voice", systemName: "waveform.badge.plus", size: 17, relativeTo: .body) }
                }
            }
        }
        .appNavigationTitle("Chapter \(chapter.position + 1)")
        .navigationBarTitleDisplayMode(.large)
        .appConfirmationDialog("Delete this voice's audio everywhere?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            if let record = deleteTarget {
                Button("Delete \(voiceName(record))", role: .destructive) {
                    Task { await library.delete(record.id) }
                    deleteTarget = nil
                }
            }
        } message: { Text("Chapter text stays on this phone. You can prepare the voice again later.") }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            EntryCoverView(url: coverURL, cornerRadius: 10).frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.title)
                    .font(.title3.bold())
                    .lineLimit(3)
                Text(bookTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(summaryLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func statusSection(_ record: TTSDownloadRecord) -> some View {
        let progress = min(max(record.progress, 0), 1)
        return Section("Status") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(statusText(record)) {
                    Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
                }
                ProgressView(value: progress)
            }
            LabeledContent("Parts", value: "\(record.rendition.completedChunks)/\(record.rendition.totalChunks)")
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file))
            if let provider = record.rendition.computeProvider { LabeledContent("Prepared on", value: provider.capitalized) }
            if let message = record.error {
                AppLabel(message, systemName: record.state == "waiting" ? "arrow.clockwise" : "exclamationmark.circle", size: 12, relativeTo: .caption)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// First few lines of the chapter itself, so the screen shows what the audio
    /// will actually read.
    private var preview: String? {
        guard let blocks = library.localText(bookId: bookId, chapterId: chapter.path)?.blocks, !blocks.isEmpty else { return nil }
        let text = blocks.prefix(3).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func previewSection(_ text: String) -> some View {
        Section("From the chapter") {
            Text(text)
                .font(.subheadline)
                .lineSpacing(4)
                .lineLimit(6)
        }
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView("No audio yet", systemImage: "headphones", description: Text("Prepare this chapter in a voice to listen offline."))
        }
    }

    private var voicesSection: some View {
        Section("Voices") {
            ForEach(records) { record in voiceRow(record) }
        }
    }

    private func voiceRow(_ record: TTSDownloadRecord) -> some View {
        let selected = library.selectedVoice(bookId: bookId, chapterId: chapter.path) == record.rendition.voiceId
        return VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file))
                    .monospacedDigit()
            } label: {
                HStack(spacing: 8) {
                    VoiceGlowDot(voiceId: record.rendition.voiceId)
                    Text(voiceName(record))
                    if selected { AppIcon(systemName: "checkmark.circle.fill", size: 12, relativeTo: .caption).accessibilityLabel("Selected") }
                }
            }
            Text(statusText(record)).font(.caption).foregroundStyle(.secondary)
            if !record.isAvailable, record.state != "failed", record.state != "paused" {
                ProgressView(value: min(max(record.progress, 0), 1))
            }
            if let message = record.error, record.state != "waiting" {
                Text(message).font(.caption).foregroundStyle(AppTheme.warning).lineLimit(3)
            }
            HStack(spacing: 8) {
                if canPlay(record) {
                    action("Play", "play.fill", prominent: true) { play(record) }
                    if !selected { action("Use voice", "checkmark.circle", prominent: false) { library.selectVoice(record.rendition.voiceId, bookId: bookId, chapterId: chapter.path) } }
                } else if record.state == "failed" || record.state == "paused" {
                    action("Retry", "arrow.clockwise", prominent: true) { Task { await library.retry(record.id) } }
                } else {
                    action("Pause", "pause.fill", prominent: false) { library.pause(record.id) }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { deleteTarget = record } label: {
                    AppLabel("Delete \(voiceName(record))", systemName: "trash", size: 17, relativeTo: .body).labelStyle(.iconOnly)
                }
                .appBorderedButtonStyle()
                .buttonBorderShape(.circle)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = record }
        }
    }

    private func action(_ title: String, _ symbol: String, prominent: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) { AppLabel(title, systemName: symbol, size: 17, relativeTo: .body) }
            .modifier(RowActionStyle(prominent: prominent))
    }

    // MARK: Helpers

    private var summaryLine: String {
        let ready = records.filter(\.isAvailable).count
        let pending = records.filter { ["waiting", "downloading"].contains($0.state) }.count
        let issues = records.filter { $0.error != nil || ["failed", "paused"].contains($0.state) }.count
        let parts = [ready > 0 ? "\(ready) offline" : nil, pending > 0 ? "\(pending) preparing" : nil, issues > 0 ? "\(issues) need attention" : nil].compactMap { $0 }
        return parts.isEmpty ? "No audio downloaded" : parts.joined(separator: " · ")
    }
    private func voiceName(_ record: TTSDownloadRecord) -> String {
        library.voices.first { $0.id == record.rendition.voiceId }?.name ?? record.manifest?.voiceName ?? record.rendition.voiceId
    }
    private func canPlay(_ record: TTSDownloadRecord) -> Bool { record.isAvailable || record.rendition.completedChunks > 0 }
    private func play(_ record: TTSDownloadRecord) {
        library.selectVoice(record.rendition.voiceId, bookId: bookId, chapterId: chapter.path)
        if let onPlay { onPlay(record) }
        else {
            ReaderTTSManager.shared.attachCover(url: coverURL, bookId: bookId)
            ReaderTTSManager.shared.playAvailable(record)
        }
    }
    private func statusText(_ record: TTSDownloadRecord) -> String {
        switch record.state {
        case "downloaded": return "Available offline"
        case "waiting":
            if record.rendition.status == "ready" { return "Ready on server · waiting for transfer" }
            let label = record.rendition.status == "loading" ? "Loading Breeze models" : record.rendition.status == "generating" ? "Generating speech" : record.rendition.status == "assembling" ? "Assembling audio" : record.rendition.status.capitalized
            return "\(label) · \(record.rendition.completedChunks)/\(record.rendition.totalChunks) parts"
        case "downloading": return "Downloading to this phone"
        default: return record.state.capitalized
        }
    }
}

/// Capsule action inside a list row: filled for the main action, tinted-off for the rest.
private struct RowActionStyle: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            // Same pairing as `primaryActionStyle`, for the non-glass bordered
            // style: a bare prominent fill is white-on-white in dark mode.
            content
                .appBorderedButtonStyle(prominent: true)
                .tint(AppTheme.primaryFill)
                .foregroundStyle(AppTheme.onPrimaryFill)
                .buttonBorderShape(.capsule)
        } else {
            content.appBorderedButtonStyle().buttonBorderShape(.capsule)
        }
    }
}
