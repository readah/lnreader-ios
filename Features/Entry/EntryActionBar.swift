// EntryActionBar.swift
// The detail screen's compact secondary dock: tracking, downloads, audio.
//
// Library moved into the hero beside Continue Reading. The remaining actions
// share one glass capsule, divided by hairlines, so the row reads as a single
// control instead of three competing buttons. Only actions that carry state
// belong here. Refresh is a toolbar button; occasional actions (migrate, edit)
// go in a toolbar menu; see docs/DETAIL_SCREEN.md.

import SwiftUI

struct EntryActionBar: View {
    let entry: Entry?
    let isManga: Bool
    /// The bound AniList entry, when there is one.
    let track: Track?
    let onTracking: () -> Void
    let onAudio: () -> Void

    @State private var confirmDeleteDownloads = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coverTint) private var coverTint

    private var inLibrary: Bool { entry?.inLibrary ?? false }
    private var showsAnyAction: Bool { (entry != nil && inLibrary) || !isManga }

    var body: some View {
        if showsAnyAction {
            HStack(spacing: 0) {
                if let entry, inLibrary {
                    trackingButton

                    if !entry.isLocal {
                        separator
                        downloadMenu(entry)
                    }
                }

                if !isManga {
                    if let entry, inLibrary { separator }
                    audioButton
                }
            }
            .frame(height: 46)
            .appGlassEffect(.regular, in: .capsule)
            .animation(AppMotion.glassMorph(reduceMotion: reduceMotion), value: inLibrary)
            .hapticFeedback(.success, trigger: inLibrary)
            .accessibilityElement(children: .contain)
        }
    }

    private var trackingButton: some View {
        Button(action: onTracking) {
            actionPillLabel(
                title: trackingTitle,
                systemImage: track == nil ? "chart.bar" : "chart.bar.fill",
                active: track != nil
            )
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Tracking")
        .accessibilityValue(trackingTitle)
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    private var audioButton: some View {
        Button(action: onAudio) {
            actionPillLabel(title: "Audio", systemImage: "headphones", active: false)
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Chapter audio downloads")
    }

    private func actionPillLabel(title: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? AnyShapeStyle(coverTint ?? .white) : AnyShapeStyle(.white.opacity(0.85)))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .padding(.horizontal, 12)
        .contentShape(.rect)
    }

    /// A hairline between segments; the capsule is the only glass.
    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 0.5, height: 18)
            .accessibilityHidden(true)
    }

    private var trackingTitle: String {
        guard let track else { return "Track" }
        return (TrackStatus(rawValue: track.status) ?? .planning).title
    }

    /// Mihon's download menu: the next few unread chapters, all unread, or all.
    private func downloadMenu(_ entry: Entry) -> some View {
        AppMenu {
            Button("Next chapter") { ChapterDownloadManager.shared.enqueueUnread(1, in: entry) }
            Button("Next 5 chapters") { ChapterDownloadManager.shared.enqueueUnread(5, in: entry) }
            Button("Next 10 chapters") { ChapterDownloadManager.shared.enqueueUnread(10, in: entry) }
            Button("Next 25 chapters") { ChapterDownloadManager.shared.enqueueUnread(25, in: entry) }
            Divider()
            Button("All unread chapters") { ChapterDownloadManager.shared.enqueueUnread(nil, in: entry) }
            Button("All chapters") { ChapterDownloadManager.shared.enqueue(entry.visibleChapters) }
            Divider()
            Button("Delete downloads", systemImage: "trash", role: .destructive) { confirmDeleteDownloads = true }
        } label: {
            actionPillLabel(title: "Download", systemImage: "arrow.down.circle", active: false)
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("Download chapters")
        .appConfirmationDialog(
            "Delete every downloaded chapter of this title?",
            isPresented: $confirmDeleteDownloads, titleVisibility: .visible
        ) {
            Button("Delete downloads", role: .destructive) { ChapterDownloadManager.shared.deleteDownloads(in: entry) }
        }
    }
}
