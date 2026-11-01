// EntryActionBar.swift
// The detail screen's row of entry actions: library, tracking, downloads, audio.
//
// Glass buttons over the hero, under the primary action, in the same glass
// container so the two rows read as one control group.
//
// Only actions that carry state belong here, at most four of them. Refresh is
// a toolbar button; occasional actions (migrate, edit) go in a toolbar menu;
// see docs/DETAIL_SCREEN.md.

import SwiftUI

struct EntryActionBar: View {
    let entry: Entry?
    let isManga: Bool
    let isAddingToLibrary: Bool
    /// The bound AniList entry, when there is one.
    let track: Track?
    let onToggleLibrary: () -> Void
    let onTracking: () -> Void
    let onAudio: () -> Void

    @State private var confirmDeleteDownloads = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inLibrary: Bool { entry?.inLibrary ?? false }

    var body: some View {
        HStack(spacing: 10) {
            libraryTile
            // Tracking and downloads hang off a stored entry; a browse result
            // gets them once it is added. Local books have nothing to download.
            if let entry, inLibrary {
                Button(action: onTracking) {
                    EntryActionTile(
                        title: trackingTitle,
                        systemImage: track == nil ? "chart.bar" : "chart.bar.fill",
                        isActive: track != nil)
                }
                .entryActionStyle()
                .accessibilityLabel("Tracking")
                .accessibilityValue(trackingTitle)
                .transition(Self.libraryAction)

                if !entry.isLocal {
                    downloadTile(entry).transition(Self.libraryAction)
                }
            }
            // Audio is generated from chapter text, which manga don't have.
            if !isManga {
                Button(action: onAudio) {
                    EntryActionTile(title: "Audio", systemImage: "headphones", isActive: false)
                }
                .entryActionStyle()
                .accessibilityLabel("Chapter audio downloads")
            }
        }
        .animation(AppMotion.glassMorph(reduceMotion: reduceMotion), value: inLibrary)
        .hapticFeedback(.success, trigger: inLibrary)
    }

    /// Fades in; leaves at once. A glass button fading out inside the
    /// container leaves its glass behind until it is gone.
    private static let libraryAction: AnyTransition = .asymmetric(insertion: .opacity, removal: .identity)

    private var libraryTile: some View {
        Button(action: onToggleLibrary) {
            EntryActionTile(
                title: inLibrary ? "In library" : "Add to library",
                systemImage: inLibrary ? "heart.fill" : "heart",
                isActive: inLibrary)
        }
        .entryActionStyle()
        .disabled(isAddingToLibrary)
        .accessibilityLabel(inLibrary ? "Remove from library" : "Add to library")
    }

    private var trackingTitle: String {
        guard let track else { return "Tracking" }
        return (TrackStatus(rawValue: track.status) ?? .planning).title
    }

    /// Mihon's download menu: the next few unread chapters, all unread, or all.
    private func downloadTile(_ entry: Entry) -> some View {
        Menu {
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
            EntryActionTile(title: "Download", systemImage: "arrow.down.circle", isActive: false)
        }
        .entryActionStyle()
        .accessibilityLabel("Download chapters")
        .confirmationDialog(
            "Delete every downloaded chapter of this title?",
            isPresented: $confirmDeleteDownloads, titleVisibility: .visible
        ) {
            Button("Delete downloads", role: .destructive) { ChapterDownloadManager.shared.deleteDownloads(in: entry) }
        }
    }
}

/// One action: a symbol over a short label. State shows in the symbol
/// (filled when on), never in the button's shape, so every action is the same
/// glass and none competes with the primary button above.
struct EntryActionTile: View {
    let title: String
    let systemImage: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 22)
            Text(title)
                .font(Typography.small.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

private extension View {
    /// The hero's secondary glass, matching the primary capsule above it.
    func entryActionStyle() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .controlSize(.large)
            .foregroundStyle(.white)
    }
}
