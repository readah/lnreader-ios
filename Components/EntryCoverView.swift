// EntryCoverView.swift
// Async image view for an entry's cover, with placeholder and loading states.

import SwiftUI

/// Displays an entry's cover image loaded asynchronously with a styled placeholder.
struct EntryCoverView: View {
    let url: String?
    var aspectRatio: CGFloat = LayoutConstants.coverAspectRatio
    var cornerRadius: CGFloat = LayoutConstants.cornerRadius

    var body: some View {
        // `Color.clear` + `aspectRatio` gives a flexible box with a fixed ratio
        // without a `GeometryReader` per cell. A GeometryReader in every grid
        // cell costs a layout pass each and is a known scroll-time drag.
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let urlString = url, let imageURL = URL(string: urlString) {
                    CustomAsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            placeholderView
                        case .empty:
                            shimmerPlaceholder
                        @unknown default:
                            placeholderView
                        }
                    }
                } else {
                    placeholderView
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholderView: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
            }
    }

    private var shimmerPlaceholder: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.6))
            .overlay {
                ProgressView()
            }
    }
}

#Preview {
    HStack {
        EntryCoverView(url: "https://picsum.photos/300/420")
            .frame(width: 120)
        EntryCoverView(url: nil)
            .frame(width: 120)
    }
    .padding()
}
