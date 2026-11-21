// EntryHeaderView.swift
// Hero header: cover, title, byline, status line and the primary reading action.

import SwiftUI
import Glur

struct EntryHeaderView<Actions: View>: View {
    @Environment(\.coverTint) private var coverTint
    /// A hold ends with a lift the button also reads as a tap; without this the
    /// tap would open the reader right after the hold scrolled the list.
    @State private var suppressTap = false

    var transitionNamespace: Namespace.ID? = nil
    let name: String
    let author: String?
    var artist: String? = nil
    let cover: String?
    let status: EntryStatus
    /// Source name, shown on the status line.
    var source: String? = nil
    var hasStartedReading: Bool = true
    /// All chapters are read: the button is disabled and says "All caught up".
    var isFinished: Bool = false
    /// Name of the chapter the button opens, shown under the label.
    var continueChapterName: String? = nil
    /// False until there is a chapter to open. The button used to look enabled
    /// and do nothing when tapped.
    var canStartReading: Bool = true
    var inLibrary: Bool = false
    var isAddingToLibrary: Bool = false
    let onContinueReading: () -> Void
    let onToggleLibrary: () -> Void
    /// Held the primary button: bring the chapter it would open into view.
    var onScrollToCurrent: (() -> Void)? = nil
    /// Held the title. The hero owns the gesture only: the screen that knows what
    /// the title is for writes the clipboard and confirms it.
    var onCopyTitle: (() -> Void)? = nil
    /// Secondary entry actions, drawn under the primary button.
    @ViewBuilder var actions: Actions

    @Namespace private var namespace

    var body: some View {
        ZStack(alignment: .bottom) {
            heroBackground
            contentOverlay
        }
        .frame(height: 520)
    }

    // MARK: - Seamless Hero Background

    @ViewBuilder
    private var heroBackground: some View {
        Group {
            if let cover, let url = URL(string: cover) {
                CustomAsyncImage(url: url, maxPixelSize: CoverDecode.heroMaxPixelSize) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                        .backgroundExtensionEffect()
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.06))
                }
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        }
        // Progressive blur starts halfway down so the bottom blends naturally into the canvas.
        .glur(radius: 26.0, offset: 0.48, interpolation: 0.45, direction: .down)
        // Soft legibility gradient only behind the typography & controls.
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.22), location: 0.0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .black.opacity(0.35), location: 0.62),
                    .init(color: .black.opacity(0.72), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Alpha dissolve at the bottom edge — eliminates any hard seam into the description.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.62),
                    .init(color: .white.opacity(0.55), location: 0.86),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Content Overlay

    /// Author and artist, once each.
    private var byline: String? {
        var names: [String] = []
        for name in [author, artist].compactMap({ $0?.trimmingCharacters(in: .whitespaces) })
        where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private var statusLine: String {
        [status == .unknown ? nil : status.displayName, source]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The hero holds the title and the one primary action. Every other entry
    /// action lives in `EntryActionBar` or the toolbar menu.
    private var contentOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()

            Text(name)
                .font(Typography.largeTitle)
                .foregroundStyle(.white)
                .lineLimit(3)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                // Hold to copy, in place of a context menu: the title is the one
                // thing on this screen worth pasting somewhere else.
                .onLongPressGesture(minimumDuration: 0.5) { onCopyTitle?() }
                // Nothing on screen says the title can be held, so VoiceOver is
                // offered the same action by name.
                .accessibilityAction(named: Text("Copy title")) { onCopyTitle?() }

            if let byline {
                Text(byline)
                    .font(Typography.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
            }

            if !statusLine.isEmpty {
                Label {
                    Text(statusLine)
                } icon: {
                    AppIcon(systemName: status.iconName, size: 12, relativeTo: .footnote)
                }
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
            }

            // Unified Liquid Glass container: primary CTA + inline library heart + compact secondary dock.
            AppGlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        continueButton
                        libraryCircleButton
                    }
                    actions
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Primary action: a solid white glass capsule over the dark hero.
    private var continueButton: some View {
        Button {
            if suppressTap {
                suppressTap = false
                return
            }
            onContinueReading()
        } label: {
            VStack(spacing: 1) {
                AppLabel(
                    isFinished ? "All caught up" : (hasStartedReading ? "Continue" : "Start reading"),
                    systemName: isFinished ? "checkmark.circle.fill" : "book.fill",
                    size: 16,
                    relativeTo: .body
                )
                .font(Typography.body)
                .lineLimit(1)

                if !isFinished, let continueChapterName, !continueChapterName.isEmpty {
                    Text(continueChapterName)
                        .font(Typography.small)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(0.65)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(AppPlainButtonStyle())
        .foregroundStyle(.black)
        .appGlassEffect(.regular.tint(.white.opacity(0.92)).interactive(), in: .capsule)
        .disabled(!canStartReading)
        .opacity(canStartReading ? 1 : 0.45)
        // Hold to find the chapter in the list. Nothing on screen says the button
        // can be held, so VoiceOver is offered the same action by name.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard canStartReading, let onScrollToCurrent else { return }
                Haptics.shared.impact(.medium)
                suppressTap = true
                // The lift may not report a tap at all; don't eat the next real one.
                Task { try? await Task.sleep(for: .milliseconds(600)); suppressTap = false }
                onScrollToCurrent()
            }
        )
        .accessibilityAction(named: Text("Scroll to current chapter")) { onScrollToCurrent?() }
        .glassEffectID("continue", in: namespace)
        .bookTransitionSource("continue", in: transitionNamespace)
    }

    private var libraryCircleButton: some View {
        // When in library: tint the glass button itself with `coverTint` (or white),
        // and keep the heart high-contrast (white on color, black on white).
        let heartColor: Color = if inLibrary {
            coverTint == nil ? .black : .white
        } else {
            .white
        }

        return Button(action: onToggleLibrary) {
            Image(systemName: inLibrary ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(heartColor)
                .frame(width: 50, height: 50)
                .contentShape(.circle)
        }
        .buttonStyle(AppPlainButtonStyle())
        .appGlassEffect(
            inLibrary
                ? .regular.tint(coverTint ?? .white).interactive()
                : .regular.interactive(),
            in: .circle
        )
        .disabled(isAddingToLibrary)
        .accessibilityLabel(inLibrary ? "Remove from library" : "Add to library")
        .glassEffectID("library", in: namespace)
    }
}
