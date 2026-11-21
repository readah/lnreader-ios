// EntryActionBar.swift
// The detail screen's compact secondary dock: tracking, downloads, audio.
//
// Library moved into the hero beside Continue Reading, so these are slim glass
// capsules in the hero's glass container. Only actions that carry state belong
// here. Refresh is a toolbar button; occasional actions (migrate, edit) go in a
// toolbar menu; see docs/DETAIL_SCREEN.md.

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
    @Namespace private var actionGlass

    private var inLibrary: Bool { entry?.inLibrary ?? false }
    private var showsAnyAction: Bool { (entry != nil && inLibrary) || !isManga }

    var body: some View {
        if showsAnyAction {
            HStack(spacing: 8) {
                if let entry, inLibrary {
                    Button(action: onTracking) {
                        actionPillLabel(
                            title: trackingTitle,
                            systemImage: track == nil ? "chart.bar" : "chart.bar.fill",
                            active: track != nil
                        )
                    }
                    .entryGlassPill(active: track != nil, tint: coverTint)
                    .glassEffectID("tracking", in: actionGlass)
                    .accessibilityLabel("Tracking")
                    .accessibilityValue(trackingTitle)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))

                    if !entry.isLocal {
                        downloadPill(entry)
                            .glassEffectID("download", in: actionGlass)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }

                if !isManga {
                    Button(action: onAudio) {
                        actionPillLabel(title: "Audio", systemImage: "headphones", active: false)
                    }
                    .entryGlassPill(active: false, tint: coverTint)
                    .glassEffectID("audio", in: actionGlass)
                    .accessibilityLabel("Chapter audio downloads")
                }
            }
            .animation(AppMotion.glassMorph(reduceMotion: reduceMotion), value: inLibrary)
            .hapticFeedback(.success, trigger: inLibrary)
        }
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
        .foregroundStyle(active ? (coverTint ?? .white) : .white.opacity(0.92))
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .padding(.horizontal, 12)
        .contentShape(.capsule)
    }

    private var trackingTitle: String {
        guard let track else { return "Track" }
        return (TrackStatus(rawValue: track.status) ?? .planning).title
    }

    /// Mihon's download menu: the next few unread chapters, all unread, or all.
    private func downloadPill(_ entry: Entry) -> some View {
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
        .entryGlassPill(active: false, tint: coverTint)
        .accessibilityLabel("Download chapters")
        .appConfirmationDialog(
            "Delete every downloaded chapter of this title?",
            isPresented: $confirmDeleteDownloads, titleVisibility: .visible
        ) {
            Button("Delete downloads", role: .destructive) { ChapterDownloadManager.shared.deleteDownloads(in: entry) }
        }
    }
}

private extension View {
    func entryGlassPill(active: Bool, tint: Color?) -> some View {
        self
            .buttonStyle(AppPlainButtonStyle())
            .appGlassEffect(
                active
                    ? .regular.tint((tint ?? .white).opacity(0.28)).interactive()
                    : .regular.interactive(),
                in: .capsule
            )
    }
}
