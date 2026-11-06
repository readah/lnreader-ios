// LibraryUpdateBanner.swift - Where a library update can be watched.
//
// A compact bar above the tab bar while an update runs, and a summary after it
// ends. Tapping it opens the detail sheet: what is being fetched, what failed
// and why, and a way to stop.

import SwiftUI

struct LibraryUpdateBanner: View {
    @Environment(LibraryManager.self) private var libraryManager
    @State private var backupManager = BackupManager.shared
    @State private var showDetail = false
    @State private var showBackupDetail = false

    var body: some View {
        if let progress = libraryManager.updateProgress {
            Button { showDetail = true } label: { bannerLabel(progress) }
                .buttonStyle(.plain)
                .sheet(isPresented: $showDetail) {
                    LibraryUpdateSheet().presentationDetents([.medium, .large])
                }
        } else if let progress = backupManager.progress {
            Button { showBackupDetail = true } label: { backupBannerLabel(progress) }
                .buttonStyle(.plain)
                .sheet(isPresented: $showBackupDetail) {
                    BackupProgressSheet(manager: backupManager).presentationDetents([.medium, .large])
                }
        }
    }

    private func backupBannerLabel(_ progress: BackupProgress) -> some View {
        HStack(spacing: 12) {
            if progress.isFinished {
                Image(systemName: progress.icon)
                    .foregroundStyle(backupIconColor(progress))
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.circular)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.headline).font(.subheadline.weight(.semibold))
                Text(progress.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private func backupIconColor(_ progress: BackupProgress) -> Color {
        if progress.error != nil { return AppTheme.destructive }
        if progress.wasCancelled { return AppTheme.warning }
        return progress.unmatchedSources.isEmpty ? Color.green : AppTheme.warning
    }

    private func bannerLabel(_ progress: LibraryUpdateProgress) -> some View {
        HStack(spacing: 12) {
            if progress.isFinished {
                Image(systemName: icon(for: progress))
                    .foregroundStyle(progress.failures.isEmpty ? Color.green : AppTheme.warning)
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.circular)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headline(progress)).font(.subheadline.weight(.semibold))
                Text(subtitle(progress)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private func icon(for progress: LibraryUpdateProgress) -> String {
        if progress.wasCancelled { return "stop.circle.fill" }
        return progress.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func headline(_ progress: LibraryUpdateProgress) -> String {
        if let note = progress.note { return note }
        if progress.isFinished {
            return progress.wasCancelled ? "Update stopped" : "Library updated"
        }
        if progress.isCancelling { return "Stopping…" }
        return "Updating library · \(progress.completed) of \(progress.total)"
    }

    private func subtitle(_ progress: LibraryUpdateProgress) -> String {
        if progress.note != nil { return "Tap for details" }
        if progress.isFinished {
            var parts = ["\(progress.newChapters) new chapters"]
            if !progress.failures.isEmpty { parts.append("\(progress.failures.count) failed") }
            return parts.joined(separator: " · ")
        }
        return progress.inFlight.first.map { "Now: \($0)" } ?? "Starting…"
    }
}

struct LibraryUpdateSheet: View {
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress = libraryManager.updateProgress {
                    Section {
                        if let note = progress.note {
                            Text(note)
                        } else {
                            ProgressView(value: progress.fraction) {
                                Text("\(progress.completed) of \(progress.total) titles")
                            }
                            LabeledContent("New chapters", value: "\(progress.newChapters)")
                            LabeledContent("Titles with new chapters", value: "\(progress.titlesWithNewChapters)")
                            LabeledContent(progress.isFinished ? "Took" : "Running for") {
                                Text(progress.startedAt, style: .timer).monospacedDigit()
                                    .hidden().overlay(alignment: .trailing) { elapsed(progress) }
                            }
                            if progress.notInstalled > 0 {
                                LabeledContent("Skipped (source not installed)", value: "\(progress.notInstalled)")
                            }
                            LabeledContent("Started", value: progress.automatic ? "Automatically" : "By you")
                        }
                    }

                    if !progress.isFinished, !progress.inFlight.isEmpty {
                        Section("Fetching now") {
                            ForEach(progress.inFlight, id: \.self) { Text($0).lineLimit(1) }
                        }
                    }

                    if !progress.failures.isEmpty {
                        Section("Failed (\(progress.failures.count))") {
                            ForEach(progress.failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.title).lineLimit(1)
                                    Text("\(failure.source): \(failure.message)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if libraryManager.isUpdating {
                        Button("Stop", role: .destructive) { libraryManager.cancelUpdate() }
                            .disabled(libraryManager.updateProgress?.isCancelling == true)
                    } else {
                        Button("Dismiss", role: .destructive) {
                            libraryManager.dismissUpdateSummary()
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

    @ViewBuilder
    private func elapsed(_ progress: LibraryUpdateProgress) -> some View {
        if let end = progress.finishedAt {
            Text(Duration.seconds(end.timeIntervalSince(progress.startedAt)),
                 format: .time(pattern: .minuteSecond))
        } else {
            Text(progress.startedAt, style: .timer)
        }
    }
}
