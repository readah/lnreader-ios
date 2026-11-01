import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct OfflineLibraryView: View {
    @Query(sort: \DownloadItem.order) private var queue: [DownloadItem]
    @State private var downloads = ChapterDownloadManager.shared
    @AppStorage("downloads.wifiOnly") private var wifiOnly = true
    @AppStorage("downloads.aheadCount") private var aheadCount = 0
    @AppStorage("downloads.deleteAfterRead") private var deleteAfterRead = 0
    @AppStorage("downloads.keepBookmarked") private var keepBookmarked = true
    @AppStorage("downloads.deleteOnMarkRead") private var deleteOnMarkRead = false
    @State private var storageBytes: Int64?
    @State private var confirmCancelAll = false
    @State private var confirmClearAll = false
    @State private var editMode: EditMode = .inactive

    /// Still to do, in the order they will run.
    private var pending: [DownloadItem] { queue.filter { $0.state != .completed } }
    private var completed: [DownloadItem] { queue.filter { $0.state == .completed } }
    private var isEmpty: Bool { queue.isEmpty }
    private var hasRunning: Bool { pending.contains { $0.state == .queued || $0.state == .downloading } }

    var body: some View {
        List {
            if isEmpty {
                ContentUnavailableView(
                    "No downloads yet", systemImage: "arrow.down.circle",
                    description: Text("Download chapters from a title’s chapter list. They show up here while they download and stay readable offline."))
                    .listRowBackground(Color.clear)
            } else {
                overviewSection
            }
            automationSection
            if !isEmpty {
                if !pending.isEmpty { queueSection }
                if !completed.isEmpty { downloadedSection }
            }
        }
        .settingsScreen("Downloads")
        .environment(\.editMode, $editMode)
        .toolbar { toolbarItems }
        .task(id: completed.count) {
            storageBytes = await Task.detached(priority: .utility) { ChapterDownloadManager.storageBytes() }.value
        }
        .confirmationDialog("Cancel every pending download?", isPresented: $confirmCancelAll, titleVisibility: .visible) {
            Button("Cancel \(pending.count) downloads", role: .destructive) { downloads.cancelAll() }
        }
        .confirmationDialog("Delete every downloaded chapter?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Delete all downloads", role: .destructive) { downloads.clearAll() }
        } message: {
            Text("Chapters stay in your library and can be downloaded again.")
        }
    }

    // MARK: Sections

    private var overviewSection: some View {
        Section {
            LabeledContent("Downloaded", value: "\(completed.count) chapters")
            LabeledContent("Storage used", value: storageBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
            Toggle("Wi-Fi only", isOn: $wifiOnly).onChange(of: wifiOnly) { _, _ in downloads.resume() }
            if !pending.isEmpty {
                Button(hasRunning ? "Pause all" : "Resume all", systemImage: hasRunning ? "pause.fill" : "play.fill") {
                    if hasRunning { downloads.pauseAll() } else { downloads.resumeAll() }
                    LibraryMaintenance.scheduleDownloads()
                }
            }
        } footer: {
            if let message = downloads.message { Text(message) }
        }
    }

    private var automationSection: some View {
        Section {
            Picker("Download ahead", selection: $aheadCount) {
                Text("Off").tag(0)
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) chapters").tag($0) }
            }
            Picker("Delete after reading", selection: $deleteAfterRead) {
                Text("Never").tag(0)
                Text("Chapter just read").tag(1)
                Text("Second to last read").tag(2)
                Text("Third to last read").tag(3)
                Text("Fourth to last read").tag(4)
                Text("Fifth to last read").tag(5)
            }
            Toggle("Remove when marked as read", isOn: $deleteOnMarkRead)
            Toggle("Keep bookmarked chapters", isOn: $keepBookmarked)
        } header: {
            Text("While reading")
        } footer: {
            Text("Download ahead queues the next chapters when you open one, using your Wi-Fi setting. Delete after reading removes a chapter’s download once you finish the chapter that many places after it. Remove when marked as read does the same when you mark chapters read from the chapter list.")
        }
    }

    private var queueSection: some View {
        Section {
            ForEach(pending) { item in
                DownloadQueueRow(item: item)
            }
            .onMove { source, destination in downloads.move(pending, from: source, to: destination) }
        } header: {
            Text("Queue · \(pending.count)")
        } footer: {
            Text("Swipe a download to cancel it or run it next. Tap Edit to reorder.")
        }
    }

    private var downloadedSection: some View {
        let groups = Dictionary(grouping: completed) { $0.chapter?.entry?.persistentModelID }
        let rows = groups.compactMap { _, items -> (entry: Entry, items: [DownloadItem])? in
            guard let entry = items.first?.chapter?.entry else { return nil }
            return (entry, items)
        }.sorted { $0.entry.displayTitle.localizedStandardCompare($1.entry.displayTitle) == .orderedAscending }
        return Section("Downloaded") {
            ForEach(rows, id: \.entry.persistentModelID) { row in
                NavigationLink {
                    NovelDetailView(entry: row.entry)
                } label: {
                    LabeledContent(row.entry.displayTitle, value: "\(row.items.count)")
                }
                    .swipeActions {
                        Button("Delete", role: .destructive) { for item in row.items { downloads.remove(item) } }
                    }
            }
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if !isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if pending.count > 1 {
                        Button(editMode.isEditing ? "Done reordering" : "Reorder queue", systemImage: "arrow.up.arrow.down") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                    }
                    if !pending.isEmpty {
                        Button("Cancel all pending", systemImage: "xmark", role: .destructive) { confirmCancelAll = true }
                    }
                    if !completed.isEmpty {
                        Button("Delete all downloads", systemImage: "trash", role: .destructive) { confirmClearAll = true }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }
}

/// One pending download: a state button on the left that pauses or resumes it,
/// the title and chapter, and a plain-language status line.
private struct DownloadQueueRow: View {
    let item: DownloadItem
    private let downloads = ChapterDownloadManager.shared

    private var isActive: Bool { item.state == .queued || item.state == .downloading }
    private var progress: Double { downloads.progress(of: item) }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isActive { downloads.pause(item) } else { downloads.retry(item) }
            } label: { stateIcon.frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(isActive ? "Pause download" : "Resume download")
            if let entry = item.chapter?.entry {
                NavigationLink { NovelDetailView(entry: entry) } label: { details }
            } else {
                details
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Cancel", role: .destructive) { downloads.remove(item) }
        }
        .swipeActions(edge: .leading) {
            Button("Run next", systemImage: "arrow.up.to.line") { downloads.moveToTop(item) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.chapter?.entry?.displayTitle ?? "Removed title")
                .font(Typography.small).foregroundStyle(.secondary).lineLimit(1)
            Text(item.chapter?.name ?? "Removed chapter").font(Typography.body).lineLimit(2)
            Text(status).font(Typography.small).foregroundStyle(item.state == .failed ? AppTheme.warning : .secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch item.state {
        case .downloading:
            DownloadProgressRing(progress: progress).frame(width: 25, height: 25)
        case .paused:
            Image(systemName: "pause.circle").font(.system(size: 25, weight: .light)).foregroundStyle(.primary)
        case .failed:
            Image(systemName: "arrow.clockwise.circle").font(.system(size: 25, weight: .light)).foregroundStyle(AppTheme.warning)
        default:
            Image(systemName: "ellipsis.circle").font(.system(size: 25, weight: .light)).foregroundStyle(.primary)
        }
    }

    private var status: String {
        switch item.state {
        case .queued: "Waiting"
        case .downloading: progress > 0 ? "Downloading · \(Int(progress * 100))%" : "Downloading"
        case .paused: "Paused"
        case .failed: item.error ?? "Failed"
        case .completed: "Downloaded"
        }
    }
}

struct LibraryUpdateSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Entry> { $0.inLibrary }) private var entries: [Entry]
    @AppStorage("general.autoUpdateOnLaunch") private var autoUpdateOnLaunch = false
    @AppStorage("updates.backgroundEnabled") private var enabled = false
    @AppStorage("updates.intervalHours") private var hours = 6.0
    @AppStorage("general.updateOnWifiOnly") private var wifiOnly = true
    @AppStorage("updates.notify") private var notify = false
    @AppStorage("updates.autoDownloadNew") private var autoDownload = false
    @AppStorage("updates.skipUnread") private var skipUnread = false
    @AppStorage("updates.skipCompleted") private var skipCompleted = false
    @AppStorage("updates.schedulingError") private var schedulingError = ""
    var body: some View {
        Form {
            Section("On launch") {
                Toggle("Update library on launch", isOn: $autoUpdateOnLaunch)
            }
            Section {
                Toggle("Check for new chapters", isOn: $enabled)
                Stepper("Requested interval: \(Int(hours)) hours", value: $hours, in: 1...72, step: 1)
                Toggle("Wi-Fi only", isOn: $wifiOnly)
                Toggle("Only titles without unread chapters", isOn: $skipUnread)
                Toggle("Skip completed titles", isOn: $skipCompleted)
                Toggle("Download new chapters", isOn: $autoDownload)
                Toggle("Notify about new chapters", isOn: $notify)
            } header: {
                Text("Refresh")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS chooses when background work runs. Low Power Mode and Background App Refresh settings can delay it.")
                    if !schedulingError.isEmpty { Text(schedulingError) }
                }
            }
            Section("Per-title updates") {
                ForEach(entries.filter { !$0.isLocal }) { entry in
                    Picker(entry.displayTitle, selection: Binding(get: { entry.updateStrategy }, set: { entry.updateStrategy = $0; try? context.save() })) {
                        ForEach(UpdateStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
        }
        .settingsScreen("Library updates")
        .onChange(of: enabled) { _, _ in LibraryMaintenance.schedule() }
        .onChange(of: hours) { _, _ in LibraryMaintenance.schedule() }
        .onChange(of: notify) { _, value in
            if value { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) } }
        }
    }
}

extension UTType {
    static var lnreaderBackup: UTType { UTType(exportedAs: "com.lnreader.backup", conformingTo: .data) }
}
struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lnreaderBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct LibraryBackupView: View {
    @Environment(\.modelContext) private var context
    @State private var recoveryKey = ""
    @State private var importKey = ""
    @State private var document: LibraryBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var pending: LibraryBackup.Snapshot?
    @State private var pendingMihon: MihonBackup.Backup?
    @AppStorage("backup.includeLocalBooks") private var includeLocalBooks = false
    /// Which kind of file the file picker is currently choosing.
    @State private var importsMihon = false
    var body: some View {
        Form {
            Section {
                SecureField("Recovery key", text: $recoveryKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Copy recovery key") { UIPasteboard.general.string = recoveryKey }
                    .disabled(recoveryKey.isEmpty)
                Toggle("Include imported books", isOn: $includeLocalBooks)
                Button("Export .lnbk backup") { export() }.disabled(busy || recoveryKey.isEmpty)
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("Includes your library, categories, chapter reading state, history and settings. Turn off Include imported books to leave out their files, which are large and do not compress; their reading progress is still saved, but you would import the files again after a restore. Downloaded chapter media and audio can be downloaded again. Keep the recovery key separately from your backup. You need it to restore on another device.")
            }
            Section {
                SecureField("Recovery key from the backup device", text: $importKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Choose .lnbk backup") { importsMihon = false; importing = true }.disabled(busy)
            } header: {
                Text("Restore and merge")
            } footer: {
                Text("Leave blank to use this device’s key. Existing title details and newer reading progress are kept.")
            }
            Section {
                Button("Choose .tachibk backup") { importsMihon = true; importing = true }.disabled(busy)
            } header: {
                Text("Import from another app")
            } footer: {
                Text("Restores the manga library, categories, read chapters, history and trackers from a .tachibk backup made by Mihon, Tachiyomi, Yokai or Tachimanga. Titles already here keep their details and the further reading progress.")
            }
            if busy { ProgressView("Working…") }
            if let message { Section { Text(message) } }
        }
        .settingsScreen("Backup & restore")
        .task { do { recoveryKey = try LibraryBackup.key() } catch { message = error.localizedDescription } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .lnreaderBackup,
                      defaultFilename: "lnreader_\(Date().formatted(.iso8601.year().month().day())).lnbk") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.lnreaderBackup, .data], allowsMultipleSelection: false) { result in
            Task { await read(result) }
        }
        .confirmationDialog(mihonPrompt, isPresented: Binding(get: { pendingMihon != nil }, set: { if !$0 { pendingMihon = nil } }), titleVisibility: .visible) {
            Button("Import backup") {
                guard let backup = pendingMihon else { return }
                pendingMihon = nil
                restoreMihon(backup)
            }
        } message: {
            Text(mihonDetail)
        }
        .confirmationDialog("Merge \(pending?.entries.count ?? 0) titles into your library?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Restore backup") {
                guard let snapshot = pending else { return }
                pending = nil
                do { let count = try LibraryBackup.restore(snapshot, container: context.container); message = "Restored \(count) titles." }
                catch { message = "Restore failed: \(error.localizedDescription)" }
            }
        }
    }
    private var mihonPrompt: String { "Import \(pendingMihon?.manga.count ?? 0) titles?" }

    /// Which sources the file uses and whether they are installed.
    private var mihonDetail: String {
        guard let backup = pendingMihon else { return "" }
        let preview = MihonBackup.preview(backup)
        var lines = ["\(preview.matched) titles are from sources built into the app."]
        if !preview.unmatched.isEmpty {
            let names = preview.unmatched.sorted { $0.value > $1.value }
                .map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            lines.append("These sources are not installed, so their titles will be listed but cannot be opened until you add them: \(names).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func restoreMihon(_ backup: MihonBackup.Backup) {
        busy = true
        let container = context.container
        Task {
            defer { busy = false }
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try MihonBackup.restore(backup, into: container)
                }.value
                LibraryChapterCounts.shared.invalidate()
                var text = "Imported \(summary.added) new titles with \(summary.chapters) chapters"
                if summary.merged > 0 { text += ", merged \(summary.merged) that were already here" }
                if summary.categories > 0 { text += ", added \(summary.categories) categories" }
                message = text + "."
                if !summary.unmatchedSources.isEmpty {
                    let total = summary.unmatchedSources.values.reduce(0, +)
                    message? += " \(total) titles come from sources that are not installed."
                }
            } catch { message = "Import failed: \(error.localizedDescription)" }
        }
    }

    private func export() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let snapshot = try LibraryBackup.snapshot(context: context, includeLocalFiles: includeLocalBooks)
                let key = recoveryKey
                let data = try await Task.detached {
                    try LibraryBackup.seal(JSONEncoder().encode(snapshot), recoveryKey: key)
                }.value
                document = LibraryBackupDocument(data: data); exporting = true
            } catch { message = "Export failed: \(error.localizedDescription)" }
        }
    }
    private func read(_ result: Result<[URL], Error>) async {
        busy = true; defer { busy = false }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if importsMihon {
                pendingMihon = try await Task.detached {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    return try MihonBackup.decode(Data(contentsOf: url))
                }.value
                return
            }
            let key = importKey.isEmpty ? recoveryKey : importKey
            pending = try await Task.detached {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= LibraryBackup.limit + 64 else { throw CocoaError(.fileReadTooLarge) }
                return try LibraryBackup.open(Data(contentsOf: url), recoveryKey: key)
            }.value
        } catch {
            message = importsMihon
                ? "Could not read that backup. \(error.localizedDescription)"
                : "Could not open backup. Check the recovery key and file. \(error.localizedDescription)"
        }
    }
}
