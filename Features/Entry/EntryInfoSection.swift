// EntryInfoSection.swift
// Expandable description and genre tags.
//
// Author, status and source are in the hero, so they are not repeated here.

import SwiftUI

struct EntryInfoSection: View {
    let summary: String?
    let genres: [String]
    @Binding var showFullDescription: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .font(Typography.body)
                        .lineLimit(showFullDescription ? nil : 4)
                        .foregroundStyle(.secondary)

                    Button(showFullDescription ? "Show less" : "Show more") {
                        withAnimation { showFullDescription.toggle() }
                    }
                    .font(Typography.caption)
                    .buttonStyle(.borderless)
                }
            }

            if !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre)
                                .font(Typography.small)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(AppTheme.surface, in: .capsule)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
