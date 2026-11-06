import Observation
import SwiftData
import SwiftUI
import UIKit
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
                    EntryDetailView(entry: row.entry)
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
                NavigationLink { EntryDetailView(entry: entry) } label: { details }
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
                    Text("iOS decides when this runs; Low Power Mode can delay it.")
                    if !schedulingError.isEmpty { Text(schedulingError) }
                }
            }
            Section {
                NavigationLink {
                    PerTitleUpdatesView(entries: entries)
                } label: {
                    LabeledContent("Per-title updates", value: perTitleSummary)
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

    /// "All titles" when nothing is overridden, otherwise how many are not checked every time.
    private var perTitleSummary: String {
        let overridden = entries.lazy.filter { !$0.isLocal && $0.updateStrategy != .always }.count
        return overridden == 0 ? "All titles" : "\(overridden) limited"
    }
}

/// Every library title with its update strategy. Searchable, and filterable by strategy
/// so the handful of titles that are skipped are easy to find again. The library query
/// lives in `LibraryUpdateSettingsView`, which passes its results down.
private struct PerTitleUpdatesView: View {
    let entries: [Entry]
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var scope: UpdateStrategy?

    var body: some View {
        let rows = visibleRows
        List {
            if rows.isEmpty {
                Group {
                    if search.isEmpty && scope == nil {
                        ContentUnavailableView("No titles", systemImage: "books.vertical",
                                               description: Text("Titles you add to your library show up here."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { entry in
                        PerTitleUpdateRow(entry: entry) { strategy in
                            entry.updateStrategy = strategy
                            try? context.save()
                        }
                    }
                } footer: {
                    Text("“Only once” fetches the chapter list once, for finished series. “Never” skips the title in every update, manual or automatic.")
                }
            }
        }
        .settingsScreen("Per-title updates")
        .searchable(text: $search, prompt: "Search titles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $scope) {
                Text("All titles").tag(UpdateStrategy?.none)
                ForEach(UpdateStrategy.allCases, id: \.self) { Text($0.displayName).tag(UpdateStrategy?.some($0)) }
            }
        } label: {
            Label("Filter", systemImage: scope == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var visibleRows: [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return entries
            .filter { entry in
                !entry.isLocal
                    && (scope == nil || entry.updateStrategy == scope)
                    && (query.isEmpty || entry.displayTitle.localizedStandardContains(query))
            }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
}

/// Title on the left, wrapping up to two lines; the strategy menu on the right at a fixed
/// width so it never drops to its own line when the title is long.
private struct PerTitleUpdateRow: View {
    let entry: Entry
    let onChange: (UpdateStrategy) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.displayTitle)
                .font(Typography.body)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Picker("Update", selection: Binding(get: { entry.updateStrategy }, set: onChange)) {
                    ForEach(UpdateStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(entry.updateStrategy.displayName)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(Typography.body)
            }
            .fixedSize()
            .accessibilityLabel("Updates for \(entry.displayTitle)")
            .accessibilityValue(entry.updateStrategy.displayName)
        }
    }
}

extension UTType {
    static var lnreaderBackup: UTType { UTType(exportedAs: "com.lnreader.backup", conformingTo: .data) }
    static var tachibkBackup: UTType { UTType(exportedAs: "org.tachiyomi.tachibk", conformingTo: .data) }
}
struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lnreaderBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct TachibkBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.tachibkBackup, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// The system document picker, asked for a **copy** of the file.
///
/// SwiftUI's `fileImporter` opens in place when the app declares
/// `LSSupportsOpeningDocumentsInPlace` — which this app does. A backup that cannot be
/// opened in place (one still in iCloud, or in another app's container) then never
/// resolves: the picker sits there and the tap does nothing, and the completion never
/// runs, so the screen cannot even report why. `asCopy` always hands back a local URL.
struct BackupDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
enum BackupOperationKind: Equatable {
    case export
    case exportTachibk
    case restoreLN
    case restoreMihon

    var title: String {
        switch self {
        case .export: "Backup export"
        case .exportTachibk: "Tachibk export"
        case .restoreLN: "LNReader restore"
        case .restoreMihon: "Mihon import"
        }
    }
}

struct BackupProgress: Equatable {
    let kind: BackupOperationKind
    var total: Int
    var completed = 0
    var inFlight: [String] = []
    var isCancelling = false
    var wasCancelled = false
    let startedAt = Date()
    var finishedAt: Date?
    var error: String?

    var added = 0
    var merged = 0
    var chapters = 0
    var categories = 0
    var localFiles = 0
    var unmatchedSources: [String: Int] = [:]

    var isFinished: Bool { finishedAt != nil || error != nil }
    var fraction: Double { total <= 0 ? 0 : min(1.0, Double(completed) / Double(total)) }

    var headline: String {
        if error != nil { return "Operation failed" }
        if wasCancelled { return "\(kind.title) stopped" }
        if isCancelling { return "Stopping…" }
        if isFinished {
            switch kind {
            case .export, .exportTachibk: return "Backup created"
            case .restoreLN: return "Restore complete"
            case .restoreMihon: return "Import complete"
            }
        }
        switch kind {
        case .export: return "Exporting backup · \(completed) of \(total)"
        case .exportTachibk: return "Exporting .tachibk · \(completed) of \(total)"
        case .restoreLN: return "Restoring backup · \(completed) of \(total)"
        case .restoreMihon: return "Importing backup · \(completed) of \(total)"
        }
    }

    var subtitle: String {
        if let error { return error }
        if isFinished {
            var parts: [String] = []
            switch kind {
            case .export, .exportTachibk:
                parts.append("\(completed) titles")
                if localFiles > 0 { parts.append("\(localFiles) local files") }
            case .restoreLN, .restoreMihon:
                let totalRestored = added + merged
                if totalRestored > 0 {
                    parts.append("\(totalRestored) titles (\(added) new, \(merged) merged)")
                }
                if chapters > 0 { parts.append("\(chapters) chapters") }
                if categories > 0 { parts.append("\(categories) categories") }
                if !unmatchedSources.isEmpty {
                    let missing = unmatchedSources.values.reduce(0, +)
                    parts.append("\(missing) from missing sources")
                }
            }
            return parts.isEmpty ? "Completed" : parts.joined(separator: " · ")
        }
        return inFlight.first.map { "Now: \($0)" } ?? "Processing…"
    }

    var icon: String {
        if error != nil { return "xmark.circle.fill" }
        if wasCancelled { return "stop.circle.fill" }
        if !isFinished { return "arrow.triangle.2.circlepath" }
        return unmatchedSources.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

@Observable
@MainActor
final class BackupManager {
    static let shared = BackupManager()

    var progress: BackupProgress?
    private var activeTask: Task<Void, Never>?

    var isRunning: Bool {
        guard let progress else { return false }
        return !progress.isFinished
    }

    func cancel() {
        guard isRunning else { return }
        progress?.isCancelling = true
        activeTask?.cancel()
    }

    func dismiss() {
        if !isRunning {
            progress = nil
        }
    }

    func reportProgress(completed: Int, total: Int, current: String) {
        guard isRunning else { return }
        progress?.total = max(1, total)
        progress?.completed = completed
        progress?.inFlight = [current]
    }

    func export(
        container: ModelContainer,
        includeLocalBooks: Bool,
        recoveryKey: String,
        onExportReady: @escaping (LibraryBackupDocument) -> Void
    ) {
        guard !isRunning else { return }
        let trimmedKey = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        progress = BackupProgress(kind: .export, total: 1)
        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let context = ModelContext(container)
                let entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
                await MainActor.run {
                    BackupManager.shared.progress?.total = max(1, entryCount)
                }

                let snapshot = try LibraryBackup.snapshot(context: context, includeLocalFiles: includeLocalBooks) { completed, total, current in
                    Task { @MainActor in
                        BackupManager.shared.reportProgress(completed: completed, total: total, current: current)
                    }
                }

                if Task.isCancelled {
                    await MainActor.run {
                        BackupManager.shared.progress?.wasCancelled = true
                        BackupManager.shared.progress?.finishedAt = Date()
                        BackupManager.shared.progress?.inFlight = []
                    }
                    return
                }

                await MainActor.run {
                    BackupManager.shared.progress?.inFlight = ["Encrypting backup…"]
                }

                let encoded = try JSONEncoder().encode(snapshot)
                let sealed = try LibraryBackup.seal(encoded, recoveryKey: trimmedKey)

                if Task.isCancelled {
                    await MainActor.run {
                        BackupManager.shared.progress?.wasCancelled = true
                        BackupManager.shared.progress?.finishedAt = Date()
                        BackupManager.shared.progress?.inFlight = []
                    }
                    return
                }

                await MainActor.run {
                    let mgr = BackupManager.shared
                    mgr.progress?.completed = mgr.progress?.total ?? 1
                    mgr.progress?.localFiles = snapshot.localFiles.count
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                    Haptics.shared.notify(.success)
                    let doc = LibraryBackupDocument(data: sealed)
                    onExportReady(doc)
                }
            } catch {
                await MainActor.run {
                    let mgr = BackupManager.shared
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.error = error.localizedDescription
                        Haptics.shared.notify(.error)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            }
        }
    }

    func exportTachibk(
        container: ModelContainer,
        onExportReady: @escaping (TachibkBackupDocument) -> Void
    ) {
        guard !isRunning else { return }

        progress = BackupProgress(kind: .exportTachibk, total: 1)
        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let context = ModelContext(container)
                let mangaCount = (try? context.fetch(FetchDescriptor<Entry>()).filter { $0.kind == .manga }.count) ?? 0
                await MainActor.run {
                    BackupManager.shared.progress?.total = max(1, mangaCount)
                }

                let data = try MihonBackup.export(context: context) { completed, total, current in
                    Task { @MainActor in
                        BackupManager.shared.reportProgress(completed: completed, total: total, current: current)
                    }
                }

                if Task.isCancelled {
                    await MainActor.run {
                        BackupManager.shared.progress?.wasCancelled = true
                        BackupManager.shared.progress?.finishedAt = Date()
                        BackupManager.shared.progress?.inFlight = []
                    }
                    return
                }

                await MainActor.run {
                    let mgr = BackupManager.shared
                    mgr.progress?.completed = mgr.progress?.total ?? 1
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                    Haptics.shared.notify(.success)
                    let doc = TachibkBackupDocument(data: data)
                    onExportReady(doc)
                }
            } catch {
                await MainActor.run {
                    let mgr = BackupManager.shared
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.error = error.localizedDescription
                        Haptics.shared.notify(.error)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            }
        }
    }

    func restoreLN(
        _ snapshot: LibraryBackup.Snapshot,
        container: ModelContainer
    ) {
        guard !isRunning else { return }
        progress = BackupProgress(kind: .restoreLN, total: max(1, snapshot.entries.count))

        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let summary = try LibraryBackup.restore(snapshot, container: container) { completed, total, current in
                    Task { @MainActor in
                        BackupManager.shared.reportProgress(completed: completed, total: total, current: current)
                    }
                }

                await MainActor.run {
                    let mgr = BackupManager.shared
                    LibraryChapterCounts.shared.invalidate()
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.completed = mgr.progress?.total ?? snapshot.entries.count
                        mgr.progress?.added = summary.added
                        mgr.progress?.merged = summary.merged
                        mgr.progress?.chapters = summary.chapters
                        mgr.progress?.categories = summary.categories
                        mgr.progress?.localFiles = summary.localFiles
                        Haptics.shared.notify(.success)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            } catch {
                await MainActor.run {
                    let mgr = BackupManager.shared
                    LibraryChapterCounts.shared.invalidate()
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.error = error.localizedDescription
                        Haptics.shared.notify(.error)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            }
        }
    }

    func restoreMihon(
        _ backup: MihonBackup.Backup,
        container: ModelContainer
    ) {
        guard !isRunning else { return }
        progress = BackupProgress(kind: .restoreMihon, total: max(1, backup.manga.count))

        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let summary = try MihonBackup.restore(backup, into: container) { completed, total, current in
                    Task { @MainActor in
                        BackupManager.shared.reportProgress(completed: completed, total: total, current: current)
                    }
                }

                await MainActor.run {
                    let mgr = BackupManager.shared
                    LibraryChapterCounts.shared.invalidate()
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.completed = mgr.progress?.total ?? backup.manga.count
                        mgr.progress?.added = summary.added
                        mgr.progress?.merged = summary.merged
                        mgr.progress?.chapters = summary.chapters
                        mgr.progress?.categories = summary.categories
                        mgr.progress?.unmatchedSources = summary.unmatchedSources
                        Haptics.shared.notify(.success)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            } catch {
                await MainActor.run {
                    let mgr = BackupManager.shared
                    LibraryChapterCounts.shared.invalidate()
                    if Task.isCancelled {
                        mgr.progress?.wasCancelled = true
                    } else {
                        mgr.progress?.error = error.localizedDescription
                        Haptics.shared.notify(.error)
                    }
                    mgr.progress?.finishedAt = Date()
                    mgr.progress?.inFlight = []
                }
            }
        }
    }
}

private struct SnapshotWrapper: Identifiable {
    let id = UUID()
    let snapshot: LibraryBackup.Snapshot
}

private struct MihonWrapper: Identifiable {
    let id = UUID()
    let backup: MihonBackup.Backup
}

struct LNReaderBackupPreviewSheet: View {
    let snapshot: LibraryBackup.Snapshot
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore LNReader Backup")
                                .font(Typography.headline)
                            Text("Created \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Contents") {
                    LabeledContent("Titles", value: "\(snapshot.entries.count)")
                    LabeledContent("Categories", value: "\(snapshot.categories.count)")
                    let totalChapters = snapshot.entries.reduce(0) { $0 + $1.chapters.count }
                    LabeledContent("Chapters", value: "\(totalChapters)")
                    if !snapshot.localFiles.isEmpty {
                        let totalBytes = snapshot.localFiles.values.reduce(0) { $0 + $1.count }
                        LabeledContent("Imported book files", value: "\(snapshot.localFiles.count) (\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)))")
                    }
                    LabeledContent("Reading progress & settings", value: "Included")
                }

                Section {
                    Text("Existing titles and reading progress will be merged non-destructively. Downloaded chapter files and newer reading history on this device will not be lost.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        dismiss()
                        onConfirm()
                    }
                    .bold()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Restore Backup")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MihonBackupPreviewSheet: View {
    let backup: MihonBackup.Backup
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Mihon Backup")
                                .font(Typography.headline)
                            Text("From Mihon, Tachiyomi, Yokai, or Tachimanga")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Contents") {
                    LabeledContent("Manga titles", value: "\(backup.manga.count)")
                    LabeledContent("Categories", value: "\(backup.categories.count)")
                    let totalChapters = backup.manga.reduce(0) { $0 + $1.chapters.count }
                    LabeledContent("Chapters", value: "\(totalChapters)")
                    let totalTracks = backup.manga.reduce(0) { $0 + $1.tracks.count }
                    if totalTracks > 0 {
                        LabeledContent("Tracking entries", value: "\(totalTracks)")
                    }
                }

                let preview = MihonBackup.preview(backup)
                Section("Sources") {
                    if preview.matched > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("\(preview.matched) titles from built-in sources")
                                .font(Typography.body)
                        }
                    }
                    if !preview.unmatched.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(AppTheme.warning)
                                let missingCount = preview.unmatched.values.reduce(0, +)
                                Text("\(missingCount) titles from uninstalled sources")
                                    .font(Typography.body.weight(.medium))
                            }
                            let sourceList = preview.unmatched.sorted { $0.value > $1.value }
                                .map { "\($0.key) (\($0.value))" }
                                .joined(separator: ", ")
                            Text("These titles will be added to your library, but cannot fetch new chapters until their source is available: \(sourceList).")
                                .font(Typography.small)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Text("Existing library titles and reading progress will be merged non-destructively.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        dismiss()
                        onConfirm()
                    }
                    .bold()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Import Backup")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct BackupProgressCard: View {
    let progress: BackupProgress
    let onStop: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if progress.isFinished {
                        Image(systemName: progress.icon)
                            .font(.title2)
                            .foregroundStyle(iconColor)
                    } else {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.circular)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.headline)
                            .font(Typography.headline)
                        Text(progress.subtitle)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                if !progress.isFinished {
                    ProgressView(value: progress.fraction)
                    HStack {
                        if let current = progress.inFlight.first {
                            Text(current)
                                .font(Typography.small)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        elapsedText
                            .font(Typography.small)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    if progress.isFinished {
                        Button("Dismiss") { onDismiss() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Stop", role: .destructive) { onStop() }
                            .buttonStyle(.bordered)
                            .disabled(progress.isCancelling)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var iconColor: Color {
        if progress.error != nil { return AppTheme.destructive }
        if progress.wasCancelled { return AppTheme.warning }
        return progress.unmatchedSources.isEmpty ? Color.green : AppTheme.warning
    }

    private var elapsedText: some View {
        if let end = progress.finishedAt {
            Text(Duration.seconds(end.timeIntervalSince(progress.startedAt)), format: .time(pattern: .minuteSecond))
        } else {
            Text(progress.startedAt, style: .timer)
        }
    }
}

struct BackupProgressSheet: View {
    @Bindable var manager: BackupManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress = manager.progress {
                    Section {
                        if progress.isFinished {
                            HStack(spacing: 12) {
                                Image(systemName: progress.icon)
                                    .font(.title2)
                                    .foregroundStyle(iconColor(progress))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(progress.headline).font(Typography.headline)
                                    Text(progress.subtitle).font(Typography.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        } else {
                            ProgressView(value: progress.fraction) {
                                Text("\(progress.completed) of \(progress.total) titles")
                            }
                        }

                        if progress.added > 0 || progress.merged > 0 {
                            LabeledContent("New titles added", value: "\(progress.added)")
                            LabeledContent("Existing titles merged", value: "\(progress.merged)")
                        }
                        if progress.chapters > 0 {
                            LabeledContent("Chapters restored", value: "\(progress.chapters)")
                        }
                        if progress.categories > 0 {
                            LabeledContent("Categories", value: "\(progress.categories)")
                        }
                        if progress.localFiles > 0 {
                            LabeledContent("Local book files", value: "\(progress.localFiles)")
                        }
                        LabeledContent(progress.isFinished ? "Took" : "Running for") {
                            elapsed(progress)
                        }
                    }

                    if !progress.isFinished, !progress.inFlight.isEmpty {
                        Section("Processing now") {
                            ForEach(progress.inFlight, id: \.self) { Text($0).lineLimit(1) }
                        }
                    }

                    if !progress.unmatchedSources.isEmpty {
                        Section("Uninstalled sources (\(progress.unmatchedSources.values.reduce(0, +)) titles)") {
                            ForEach(progress.unmatchedSources.sorted(by: { $0.value > $1.value }), id: \.key) { name, count in
                                LabeledContent(name, value: "\(count)")
                            }
                        }
                    }

                    if let error = progress.error {
                        Section("Error") {
                            Text(error)
                                .font(Typography.caption)
                                .foregroundStyle(AppTheme.destructive)
                        }
                    }
                }
            }
            .navigationTitle("Backup & restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if manager.isRunning {
                        Button("Stop", role: .destructive) { manager.cancel() }
                            .disabled(manager.progress?.isCancelling == true)
                    } else {
                        Button("Dismiss") {
                            manager.dismiss()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func iconColor(_ progress: BackupProgress) -> Color {
        if progress.error != nil { return AppTheme.destructive }
        if progress.wasCancelled { return AppTheme.warning }
        return progress.unmatchedSources.isEmpty ? Color.green : AppTheme.warning
    }

    @ViewBuilder
    private func elapsed(_ progress: BackupProgress) -> some View {
        if let end = progress.finishedAt {
            Text(Duration.seconds(end.timeIntervalSince(progress.startedAt)),
                 format: .time(pattern: .minuteSecond))
        } else {
            Text(progress.startedAt, style: .timer)
        }
    }
}

struct LibraryBackupView: View {
    @Environment(\.modelContext) private var context
    @State private var backupManager = BackupManager.shared
    @State private var recoveryKey = ""
    @State private var importKey = ""
    @State private var document: LibraryBackupDocument?
    @State private var tachibkDocument: TachibkBackupDocument?
    @State private var exporting = false
    @State private var exportingTachibk = false
    @State private var importing = false
    @State private var picked: URL?
    @State private var readingFile = false
    @State private var readErrorMessage: String?
    @State private var pendingSnapshot: LibraryBackup.Snapshot?
    @State private var pendingMihon: MihonBackup.Backup?
    @AppStorage("backup.includeLocalBooks") private var includeLocalBooks = false
    @State private var importsMihon = false

    var body: some View {
        Form {
            if let progress = backupManager.progress {
                BackupProgressCard(progress: progress, onStop: { backupManager.cancel() }, onDismiss: { backupManager.dismiss() })
            }
            if readingFile {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading backup file…")
                            .font(Typography.body)
                    }
                }
            }

            Section {
                SecureField("Recovery key", text: $recoveryKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Copy recovery key") {
                    UIPasteboard.general.string = recoveryKey
                    Haptics.shared.notify(.success)
                }
                .disabled(recoveryKey.isEmpty)
                Toggle("Include imported books", isOn: $includeLocalBooks)
                Button("Export .lnbk backup") { export() }
                    .disabled(backupManager.isRunning || readingFile || recoveryKey.isEmpty)
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("Keep the recovery key apart from the backup; restoring on another device needs it. Imported book files are large, so leaving them out means importing them again after a restore.")
            }

            Section {
                SecureField("Recovery key from the backup device", text: $importKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Choose .lnbk backup") {
                    importsMihon = false
                    importing = true
                }
                .disabled(backupManager.isRunning || readingFile)
            } header: {
                Text("Restore and merge")
            } footer: {
                Text("Leave blank to use this device’s key.")
            }

            Section {
                Button("Export .tachibk backup") { exportTachibk() }
                    .disabled(backupManager.isRunning || readingFile)
                Button("Choose .tachibk backup") {
                    importsMihon = true
                    importing = true
                }
                .disabled(backupManager.isRunning || readingFile)
            } header: {
                Text("Mihon / Tachiyomi (.tachibk)")
            } footer: {
                Text("Export or import backups compatible with Mihon, Tachiyomi, Yokai or Tachimanga.")
            }
        }
        .settingsScreen("Backup & restore")
        .task {
            do {
                recoveryKey = try LibraryBackup.key()
            } catch {
                readErrorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .lnreaderBackup,
            defaultFilename: "lnreader_\(Date().formatted(.iso8601.year().month().day())).lnbk"
        ) { result in
            if case .failure(let error) = result {
                readErrorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $exportingTachibk,
            document: tachibkDocument,
            contentType: .tachibkBackup,
            defaultFilename: "mihon_\(Date().formatted(.iso8601.year().month().day())).tachibk"
        ) { result in
            if case .failure(let error) = result {
                readErrorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $importing, onDismiss: openPicked) {
            BackupDocumentPicker(types: [.lnreaderBackup, .tachibkBackup, .data]) { url in
                picked = url
                importing = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: {
            pendingSnapshot.map { SnapshotWrapper(snapshot: $0) }
        }, set: {
            pendingSnapshot = $0?.snapshot
        })) { wrapper in
            LNReaderBackupPreviewSheet(snapshot: wrapper.snapshot) {
                let container = context.container
                backupManager.restoreLN(wrapper.snapshot, container: container)
            }
        }
        .sheet(item: Binding(get: {
            pendingMihon.map { MihonWrapper(backup: $0) }
        }, set: {
            pendingMihon = $0?.backup
        })) { wrapper in
            MihonBackupPreviewSheet(backup: wrapper.backup) {
                let container = context.container
                backupManager.restoreMihon(wrapper.backup, container: container)
            }
        }
        .alert("Could Not Open Backup", isPresented: Binding(get: { readErrorMessage != nil }, set: { if !$0 { readErrorMessage = nil } })) {
            Button("OK") { readErrorMessage = nil }
        } message: {
            if let readErrorMessage { Text(readErrorMessage) }
        }
    }

    private func export() {
        let container = context.container
        let key = recoveryKey
        let includeLocal = includeLocalBooks
        backupManager.export(container: container, includeLocalBooks: includeLocal, recoveryKey: key) { doc in
            document = doc
            exporting = true
        }
    }

    private func exportTachibk() {
        let container = context.container
        backupManager.exportTachibk(container: container) { doc in
            tachibkDocument = doc
            exportingTachibk = true
        }
    }

    private func openPicked() {
        guard let url = picked else { return }
        picked = nil
        Task { await read(url) }
    }

    private func read(_ url: URL) async {
        readingFile = true
        defer { readingFile = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if importsMihon {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    return try MihonBackup.decode(Data(contentsOf: url))
                }.value
                Haptics.shared.notify(.success)
                pendingMihon = decoded
                return
            }
            let key = importKey.isEmpty ? recoveryKey : importKey
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= LibraryBackup.limit + 64 else { throw CocoaError(.fileReadTooLarge) }
                return try LibraryBackup.open(Data(contentsOf: url), recoveryKey: key)
            }.value
            Haptics.shared.notify(.success)
            pendingSnapshot = snapshot
        } catch {
            Haptics.shared.notify(.error)
            readErrorMessage = importsMihon
                ? "Could not read that backup. \(error.localizedDescription)"
                : "Could not open backup. Check the recovery key and verify the file is a valid LNReader backup. (\(error.localizedDescription))"
        }
    }
}
