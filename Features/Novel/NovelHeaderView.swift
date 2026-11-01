// NovelHeaderView.swift
// Hero header: cover, title, byline, status line and the primary reading action.

import SwiftUI
import Glur

struct NovelHeaderView<Actions: View>: View {
    var transitionNamespace: Namespace.ID? = nil
    let name: String
    let author: String?
    var artist: String? = nil
    let cover: String?
    let status: EntryStatus
    /// Source name, shown on the status line.
    var source: String? = nil
    var hasStartedReading: Bool = true
    /// All chapters are read: the button is disabled and says "You're all caught up".
    var isFinished: Bool = false
    /// Name of the chapter the button opens, shown under the label.
    var continueChapterName: String? = nil
    /// False until there is a chapter to open. The button used to look enabled
    /// and do nothing when tapped.
    var canStartReading: Bool = true
    let onContinueReading: () -> Void
    /// Secondary entry actions, drawn under the primary button.
    @ViewBuilder var actions: Actions

    @Namespace private var namespace

    var body: some View {
        ZStack(alignment: .bottom) {
            // Hero background with extension effect
            heroBackground

            // Gradient for text legibility over backgroundExtensionEffect
            LinearGradient(
                colors: [.clear, .black.opacity(0.3), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content overlay
            contentOverlay
        }
        .frame(height: 560)
    }

    // MARK: - Hero Background

    @ViewBuilder
    private var heroBackground: some View {
        Group {
            if let cover, let url = URL(string: cover) {
                CustomAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            minWidth: 0, maxWidth: .infinity,
                            minHeight: 0, maxHeight: .infinity
                        )
                        .clipped()
                        .backgroundExtensionEffect()
                } placeholder: {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.12), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.12), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .glur(radius: 20.0, offset: 0.75, interpolation: 0.25, direction: .down)
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
        VStack(alignment: .leading, spacing: 8) {
            Spacer()

            Text(name)
                .font(Typography.largeTitle)
                .foregroundStyle(.white)
                .lineLimit(3)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)

            if let byline {
                Text(byline)
                    .font(Typography.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .shadow(radius: 2)
            }

            if !statusLine.isEmpty {
                Label {
                    Text(statusLine)
                } icon: {
                    Image(systemName: status.iconName)
                }
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .shadow(radius: 2)
            }

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    continueButton
                    actions
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .padding(.bottom, 8)
    }

    /// Primary action: a solid white glass capsule over the dark hero.
    private var continueButton: some View {
        Button(action: onContinueReading) {
            VStack(spacing: 2) {
                Label(
                    isFinished ? "You're all caught up" : (hasStartedReading ? "Continue reading" : "Start reading"),
                    systemImage: isFinished ? "checkmark.circle.fill" : "book.fill"
                )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !isFinished, let continueChapterName, !continueChapterName.isEmpty {
                    Text(continueChapterName)
                        .font(Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(0.65)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(!canStartReading)
        .glassEffectID("continue", in: namespace)
        .bookTransitionSource("continue", in: transitionNamespace)
    }
}
