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

    private var selectedChapters: [TTSChapterChoice] {
        guard !chapters.isEmpty else { return [] }
        let start = min(max(fromChapter - 1, 0), chapters.count - 1)
        let end = min(max(throughChapter - 1, start), chapters.count - 1)
        return Array(chapters[start...end])
    }
    /// Chapters this book actually has audio records for.
    ///
    /// This screen manages downloads, it does not browse chapters: a chapter
    /// nobody has asked for has nothing to show here. Anything with a record —
    /// ready, preparing or failed — stays, so progress and retries remain
    /// reachable.
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
    private var currentChoice: TTSChapterChoice? { chapters.first { $0.path == initialChapter } ?? chapters.first }
    private var bookRecords: [TTSDownloadRecord] { library.downloads(bookId: bookId) }
    private var byteCount: Int64 { bookRecords.filter(\.isAvailable).reduce(0) { $0 + $1.bytesExpected } }
    private var groups: [String: [TTSDownloadRecord]] {
        Dictionary(grouping: bookRecords.filter { voiceFilter == "all" || $0.rendition.voiceId == voiceFilter }, by: { $0.rendition.chapterId })
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
    var body: some View {
        AppNavigationStack {
            List {
                Section {
                    dashboard
                        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if preparing || error != nil || library.errorMessage != nil || library.engineState?.needsAttention == true {
                    Section {
                        if preparing {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(preparationProgress)
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop") { preparationTask?.cancel() }
                                    .font(Typography.caption.weight(.semibold))
                                    .buttonStyle(AppBorderlessButtonStyle())
                            }
                        }
                        if let message = error ?? library.errorMessage ?? (library.engineState?.needsAttention == true ? library.engineState?.message : nil) {
                            AppLabel(message, systemName: "exclamationmark.circle", size: 13, relativeTo: .footnote)
                                .font(Typography.caption)
                                .foregroundStyle(AppTheme.warning)
                        }
                    }
                }
                Section {
                    let indexed = groups
                    let visible = visibleAll
                    let page = min(chapterPage, pageCount - 1)
                    ForEach(Array(visible.dropFirst(page * 100).prefix(100))) { chapter in
                        chapterRow(chapter, records: indexed[chapter.path] ?? [])
                    }
                    if visible.isEmpty {
                        compactEmptyState
                            .listRowBackground(Rectangle().fill(.regularMaterial))
                    }
                } header: {
                    HStack {
                        Text("Downloaded · \(visibleAll.count)")
                            .font(Typography.caption.weight(.semibold))
                            .textCase(nil)
                            .foregroundStyle(.secondary)
                        Spacer()
                        AppMenu {
                            AppPicker("Status", selection: $stateFilter) {
                                ForEach(["All", "Downloaded", "Preparing", "Issues"], id: \.self) { Text($0).tag($0) }
                            }
                            AppPicker("Voice", selection: $voiceFilter) {
                                Text("All voices").tag("all")
                                ForEach(library.voices) { Text($0.name).tag($0.id) }
                            }
                        } label: {
                            AppLabel(stateFilter, systemName: "line.3.horizontal.decrease", size: 13, relativeTo: .footnote)
                                .font(Typography.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                } footer: {
                    Text(offlineSummary).font(Typography.caption)
                }
            }
            .listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background { CoverBackdrop(url: coverURL, tint: coverTint) }
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
                        Button("Delete selected range…", role: .destructive) {
                            let paths = Set(selectedChapters.map(\.path))
                            deleteIDs = bookRecords.filter { paths.contains($0.rendition.chapterId) && (voiceFilter == "all" || $0.rendition.voiceId == voiceFilter) }.map(\.id)
                        }.disabled(bookRecords.isEmpty)
                    } label: { AppLabel("Audio download options", systemName: "ellipsis.circle", size: 17, relativeTo: .body) }
                }
                AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if pageCount > 1 {
                    AppToolbarItemGroup(placement: .bottomBar) {
                        Button { chapterPage = max(0, currentPage - 1) } label: { AppLabel("Previous chapters", systemName: "chevron.left", size: 12, relativeTo: .caption).labelStyle(.iconOnly) }
                            .disabled(currentPage == 0)
                        Spacer()
                        Text(pageLabel).font(.caption.monospacedDigit())
                        Spacer()
                        Button { chapterPage = min(pageCount - 1, currentPage + 1) } label: { AppLabel("Next chapters", systemName: "chevron.right", size: 17, relativeTo: .body).labelStyle(.iconOnly) }
                            .disabled(currentPage + 1 >= pageCount)
                    }
                }
            }
            .toolbar(pageCount > 1 ? .visible : .hidden, for: .bottomBar)
            // Pinned exactly like Browse: the drawer sits under the title and
            // stays while the list scrolls.
            .appSearchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Chapter number or title"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .appSheet(isPresented: $showVoices) {
                AppNavigationStack {
                    AppForm { Section { NarrationComputePicker() }; Section("Narrator") { NarrationVoicePicker(selected: $selectedVoices) } }
                        .appNavigationTitle("Choose voices").navigationBarTitleDisplayMode(.large)
                        .appToolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") {
                            if let voice = selectedVoices.sorted().first { library.setBookVoice(voice, bookId: bookId) }
                            showVoices = false
                        } } }
                }
            }
            .appSheet(isPresented: $showRange) { rangePicker }
            .task {
                if !initialized {
                    let index = chapters.firstIndex { $0.path == initialChapter } ?? 0
                    fromChapter = index + 1; throughChapter = fromChapter; chapterPage = index / 100
                    selectedVoices = [library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? chapters.first?.path ?? "")]
                    initialized = true
                }
                await library.refreshVoices()
                while !Task.isCancelled {
                    await library.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            .appRefreshable { await library.refreshVoices(); await library.refresh() }
            .onChange(of: search) { _, _ in chapterPage = 0 }
            .onChange(of: stateFilter) { _, _ in chapterPage = 0 }
            .onChange(of: voiceFilter) { _, _ in chapterPage = 0 }
            .appConfirmationDialog("Delete this chapter audio everywhere?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                if let record = deleteTarget { Button("Delete \(voiceName(record))", role: .destructive) { Task { await library.delete(record.id) }; deleteTarget = nil } }
            } message: { Text("Other voices and chapter text remain available.") }
            .appConfirmationDialog("Delete \(deleteIDs.count) chapter voice downloads everywhere?", isPresented: Binding(get: { !deleteIDs.isEmpty }, set: { if !$0 { deleteIDs = [] } })) {
                Button("Delete selected audio everywhere", role: .destructive) {
                    let ids = deleteIDs; deleteIDs = []
                    Task { await library.deleteMany(ids) }
                }
            } message: { Text("Chapter text stays on this phone. You can prepare the voices again later.") }
        }
    }
    private var activeVoice: String {
        let preferred = library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? "")
        return selectedVoices.contains(preferred) ? preferred : selectedVoices.sorted().first ?? preferred
    }
    /// The header already counts downloaded chapters; the footer only adds how
    /// much room they take on this phone.
    private var offlineSummary: String {
        "\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) stored on this phone"
    }

    /// A quiet empty row. `ContentUnavailableView` is sized for a whole screen;
    /// inside this sheet its heading outran the book title above it.
    private var compactEmptyState: some View {
        VStack(spacing: 8) {
            AppIcon(systemName: "headphones", size: 28, relativeTo: .body)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Nothing downloaded")
                .font(Typography.headline)
            Text(search.isEmpty && stateFilter == "All"
                 ? "Use the buttons above to download this chapter, the next ten, or a range."
                 : "Try another search or filter.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Cover, chapter and narrator on the blurred artwork, then the actions.
    /// The artwork is the only large graphic on the sheet, so the cover is the
    /// thing that names the book rather than another competing card.
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                EntryCoverView(url: coverURL, cornerRadius: 10)
                    .frame(width: 96)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

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

            downloadControls

            if !failedRecords.isEmpty {
                retryAllButton
            }
        }
    }

    /// The narrator as a compact control under the chapter, in the same glass
    /// as the voice chips: the voice's own light marks it, its name is the
    /// value, and the chevron opens the picker. A card here used to compete
    /// with the cover for the first glance.
    private var narratorButton: some View {
        let name = library.voices.first { $0.id == activeVoice }?.name ?? "Narrator"
        return Button { showVoices = true } label: {
            HStack(spacing: 7) {
                AppIcon(systemName: "waveform", size: 12, relativeTo: .body)
                    .font(.system(size: 12, weight: .semibold))
                Text(name)
                    .font(Typography.body.weight(.semibold))
                    .lineLimit(1)
                Text("Narrator")
                    .font(Typography.caption)
                    .opacity(0.7)
                AppIcon(systemName: "chevron.right", size: 10, relativeTo: .body)
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background { VoiceGlowSurface(voiceId: activeVoice, halo: 9) }
            .contentShape(Capsule())
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Narrator: \(name)")
        .accessibilityHint("Choose a narrator voice")
    }

    /// Three direct actions. The set is short and fixed, so hiding it behind a
    /// dropdown only cost a tap.
    private var downloadControls: some View {
        VStack(spacing: 10) {
            Button(action: downloadCurrent) {
                AppLabel(downloadCurrentTitle, systemName: "arrow.down.circle.fill", size: 17, relativeTo: .body)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(downloadBlocked)

            HStack(spacing: 10) {
                Button { downloadNext(10) } label: {
                    AppLabel("Next 10", systemName: "arrow.down.circle", size: 17, relativeTo: .body)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .appGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(downloadBlocked)

                Button { showRange = true } label: {
                    AppLabel("Range…", systemName: "slider.horizontal.3", size: 17, relativeTo: .body)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .appGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(chapters.isEmpty)
            }
        }
    }

    /// The chapter number in the button says which chapter it will download,
    /// so the header no longer repeats it.
    private var downloadCurrentTitle: String {
        guard let currentChoice else { return "Download chapter" }
        return "Download chapter \(currentChoice.position + 1)"
    }

    /// Only failed renditions for this book. Paused ones are excluded: the user
    /// stopped those on purpose, so retrying them is not what "retry all" means.
    private var failedRecords: [TTSDownloadRecord] {
        groups.values
            .flatMap { $0 }
            .filter { !$0.isAvailable && $0.state == "failed" }
    }

    /// Appears only when this book has something to retry, so the sheet does not
    /// carry a permanently dead button.
    private var retryAllButton: some View {
        Button {
            Haptics.shared.impact(.light, intensity: 0.8)
            Task { await library.retryAllFailed(bookId: bookId) }
        } label: {
            AppLabel(failedRecords.count == 1 ? "Retry 1 failed chapter" : "Retry \(failedRecords.count) failed chapters", systemName: "arrow.clockwise", size: 17, relativeTo: .body)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .appGlassButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(preparing)
        .accessibilityHint("Queues every failed narration for this book again")
    }

    private var downloadBlocked: Bool {
        preparing || selectedVoices.isEmpty || currentChapterIndex == nil
    }

    /// The chapter the sheet was opened from, or the first one when it was not
    /// opened from a chapter at all.
    private var currentChapterIndex: Int? {
        if let initialChapter,
           let index = chapters.firstIndex(where: { $0.path == initialChapter }) {
            return index
        }
        return chapters.isEmpty ? nil : 0
    }

    private func downloadCurrent() {
        guard let index = currentChapterIndex else { return }
        fromChapter = index + 1
        throughChapter = fromChapter
        prepareSelected()
    }

    /// `count` chapters starting at the current one, matching the old "Next 10".
    private func downloadNext(_ count: Int) {
        guard let index = currentChapterIndex else { return }
        fromChapter = index + 1
        throughChapter = min(chapters.count, fromChapter + count - 1)
        prepareSelected()
    }
    /// The third of the three direct actions: a two-handle slider for picking a
    /// span quickly, with a stepper per edge for landing on an exact chapter.
    ///
    /// The steppers never dead-end. Moving one edge past the other takes the
    /// other with it, so a collapsed range at chapter 1 still grows whichever
    /// way the user pushes; the old version disabled the button they reached for.
    private var rangePicker: some View {
        AppNavigationStack {
            AppForm {
                Section {
                    VStack(spacing: 12) {
                        ChapterRangeSlider(lower: $fromChapter, upper: $throughChapter, count: chapters.count)
                        HStack {
                            Text("1")
                            Spacer()
                            Text(max(chapters.count, 1).formatted())
                        }
                        .font(Typography.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    }
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
                    rangeStepperRow("From", value: fromChapterBinding)
                    rangeStepperRow("Through", value: throughChapterBinding)
                } header: {
                    Text("Chapters")
                } footer: {
                    Text(rangeSummary)
                }
            }
            .appNavigationTitle("Range")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRange = false } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { commitRange() } label: {
                    Text(rangeDownloadTitle).frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .disabled(selectedChapters.isEmpty || selectedVoices.isEmpty || preparing)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .appPresentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func rangeStepperRow(_ title: String, value: Binding<Int>) -> some View {
        AppStepper(value: value, in: 1...max(chapters.count, 1)) {
            HStack {
                Text(title)
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
        return count == 1 ? "Download 1 chapter" : "Download \(count) chapters"
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
        return "\(count) chapter\(count == 1 ? "" : "s") in \(voices) voice\(voices == 1 ? "" : "s"), prepared in the background and kept on this phone."
    }

    private func commitRange() {
        setRangeStart(fromChapter)
        setRangeEnd(throughChapter)
        showRange = false
        prepareSelected()
    }
    private func chapterSummary(_ records: [TTSDownloadRecord]) -> String {
        if records.isEmpty { return "No audio downloaded" }
        let ready = records.filter(\.isAvailable).count
        let pending = records.filter { ["waiting", "downloading"].contains($0.state) }.count
        let issues = records.filter { $0.error != nil || ["failed", "paused"].contains($0.state) }.count
        return [ready > 0 ? "\(ready) voices offline" : nil, pending > 0 ? "\(pending) preparing" : nil, issues > 0 ? "\(issues) need attention" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private func primaryRecord(_ records: [TTSDownloadRecord]) -> TTSDownloadRecord? { records.first { $0.rendition.voiceId == activeVoice } }
    private func canPlay(_ record: TTSDownloadRecord) -> Bool { record.isAvailable || record.rendition.completedChunks > 0 }
    private func playAudio(_ record: TTSDownloadRecord) {
        library.selectVoice(record.rendition.voiceId, bookId: bookId, chapterId: record.rendition.chapterId)
        ReaderTTSManager.shared.attachCover(url: coverURL, bookId: bookId)
        ReaderTTSManager.shared.playAvailable(record)
        dismiss()
    }
    private func downloadChapter(_ chapter: TTSChapterChoice) {
        fromChapter = (chapters.firstIndex { $0.path == chapter.path } ?? 0) + 1
        throughChapter = fromChapter; prepareSelected()
    }
    private func chapterRow(_ chapter: TTSChapterChoice, records: [TTSDownloadRecord]) -> some View {
        let primary = primaryRecord(records)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.surface)
                    Text("\(chapter.position + 1)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                }.frame(width: 36, height: 36)
                AppNavigationLink {
                    TTSChapterAudioDetailView(chapter: chapter, bookId: bookId, bookTitle: bookTitle, coverURL: coverURL,
                                              onPlay: { playAudio($0) }, onAddVoice: { showVoices = true })
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chapter.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                        Text(primary.map { $0.isAvailable ? "\(voiceName($0)) · Offline" : $0.rendition.completedChunks > 0 ? "\(voiceName($0)) · \($0.rendition.completedChunks)/\($0.rendition.totalChunks) parts ready" : status($0) } ?? (records.isEmpty ? "Tap to see details" : "\(records.count) voices saved"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(AppPlainButtonStyle())
                if let primary, canPlay(primary) {
                    Button { playAudio(primary) } label: { AppLabel("Play \(chapter.title)", systemName: "play.circle.fill", size: 28, relativeTo: .title).labelStyle(.iconOnly).font(.title) }
                } else if let primary, ["failed", "paused"].contains(primary.state) {
                    Button { Task { await library.retry(primary.id) } } label: { AppLabel("Retry \(chapter.title)", systemName: "arrow.clockwise.circle", size: 22, relativeTo: .title2).labelStyle(.iconOnly).font(.title2) }
                } else if primary != nil {
                    ProgressView()
                } else {
                    Button { downloadChapter(chapter) } label: { AppLabel("Download \(chapter.title)", systemName: "arrow.down.circle", size: 22, relativeTo: .title2).labelStyle(.iconOnly).font(.title2) }.disabled(preparing)
                }
            }.buttonStyle(AppBorderlessButtonStyle())
            if let primary, ["waiting", "downloading"].contains(primary.state) { ProgressView(value: primary.progress) }
            if let primary, primary.state == "failed" || primary.state == "paused" {
                HStack(alignment: .top) {
                    Text(primary.error ?? "Preparation is paused.").font(.caption).foregroundStyle(AppTheme.warning).lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await library.retry(primary.id) } }.font(.caption.weight(.semibold)).buttonStyle(AppBorderlessButtonStyle())
                }
            }
        }.padding(.vertical, 4)
        .listRowBackground(Rectangle().fill(.regularMaterial))
        .swipeActions {
            if let primary {
                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = primary }
                if ["failed", "paused"].contains(primary.state) { Button("Retry", systemImage: "arrow.clockwise") { Task { await library.retry(primary.id) } }.tint(Color(.systemGray)) }
            }
        }
    }
    private func voiceName(_ record: TTSDownloadRecord) -> String { library.voices.first { $0.id == record.rendition.voiceId }?.name ?? record.manifest?.voiceName ?? record.rendition.voiceId }
    private func status(_ record: TTSDownloadRecord) -> String {
        switch record.state {
        case "downloaded": return "Available offline · " + ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file)
        case "waiting":
            if record.rendition.status == "ready" { return "Ready on server · waiting for transfer" }
            let label = record.rendition.status == "loading" ? "Loading Breeze models" : record.rendition.status == "generating" ? "Generating speech" : record.rendition.status == "assembling" ? "Assembling audio" : record.rendition.status.capitalized
            return "\(label) · \(record.rendition.completedChunks)/\(record.rendition.totalChunks) parts"
        case "downloading": return "Downloading to this phone"
        default: return record.state.capitalized
        }
    }
    private func prepareSelected() {
        guard !preparing else { return }
        let choices = selectedChapters
        let preferred = library.selectedVoice(bookId: bookId, chapterId: initialChapter ?? choices.first?.path ?? "")
        let voices = selectedVoices.sorted { a, b in a == preferred ? true : b == preferred ? false : a < b }
        preparing = true; error = nil
        preparationTask = Task { @MainActor in
            defer { preparing = false }
            do {
                for (index, chapter) in choices.enumerated() {
                    try Task.checkCancellation()
                    preparationProgress = "Adding \(index + 1) of \(choices.count)…"
                    if let cached = library.localText(bookId: bookId, chapterId: chapter.path) {
                        try await library.prepare(chapter: .init(bookId: bookId, bookTitle: bookTitle, chapterId: chapter.path, title: chapter.title, position: chapter.position, blocks: cached.blocks), voiceIds: voices)
                        continue
                    }
                    let html: String
                    if sourceKey == SourceKey.local {
                        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalNovels").appendingPathComponent(entryURL.replacingOccurrences(of: "local://", with: ""))
                        let file = folder.appendingPathComponent(chapter.path).standardizedFileURL
                        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw TTSError.request("Invalid local chapter path") }
                        html = try String(contentsOf: file, encoding: .utf8)
                    } else {
                        guard let source = sourceManager.novelSource(forKey: sourceKey) else { throw TTSError.request("Source is unavailable") }
                        html = try await source.chapterHTML(SourceChapter(url: chapter.path, name: chapter.title))
                    }
                    let blocks = try await TTSChapterTextExtractor().extract(html)
                    try await library.prepare(chapter: .init(bookId: bookId, bookTitle: bookTitle, chapterId: chapter.path, title: chapter.title, position: chapter.position, blocks: blocks), voiceIds: voices)
                }
            } catch is CancellationError { }
            catch { self.error = "\(preparationProgress) \(error.localizedDescription) Chapters already added remain queued." }
        }
    }
}

/// The book's cover, blurred and darkened, behind the whole sheet — the way
/// Apple Music lays an album page over its own artwork. The scrim keeps labels
/// legible and stays dark, which the app's dark-only appearance makes safe.
private struct CoverBackdrop: View {
    let url: String?
    var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemBackground)
                if let urlString = url, let imageURL = URL(string: urlString) {
                    CustomAsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    // The blur eats its own edges; grow the artwork past the
                    // sheet so no dark rim shows through.
                    .scaleEffect(1.3)
                    .blur(radius: 55, opaque: true)
                    .saturation(1.15)
                    .opacity(0.7)
                }
                if let tint { tint.opacity(0.18) }
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.25), location: 0),
                        .init(color: .black.opacity(0.45), location: 0.4),
                        .init(color: .black.opacity(0.75), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Two handles over the chapter numbers, dragged as one 44-point-tall control.
/// With the handles apart the gesture takes the nearer one. With both on the
/// same chapter it waits for the drag direction, so pulling left grows the range
/// backwards and pulling right grows it forwards instead of both handles
/// fighting over the finger; dragging back to the start lets it switch sides.
private struct ChapterRangeSlider: View {
    @Binding var lower: Int
    @Binding var upper: Int
    let count: Int
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
                    .fill(.quaternary)
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

    private func knobView(active: Bool) -> some View {
        Circle()
            .fill(Color(.systemBackground))
            .overlay(Circle().strokeBorder(AppTheme.primaryFill, lineWidth: 3))
            .frame(width: knob, height: knob)
            .scaleEffect(active ? 1.12 : 1)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
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
                            startedCollapsed: true)
                    } else {
                        let lowerX = knob / 2 + span * position(of: lower)
                        let upperX = knob / 2 + span * position(of: upper)
                        drag = DragState(
                            handle: abs(value.startLocation.x - lowerX) <= abs(value.startLocation.x - upperX) ? .lower : .upper,
                            startedCollapsed: false)
                    }
                }
                // A range that started collapsed can be dragged back through the
                // start and out the other side, so the same gesture works both ways.
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
