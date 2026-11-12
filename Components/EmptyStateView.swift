// EmptyStateView.swift
// Placeholder view for screens with no content.

import SwiftUI

/// A centered empty state with an SF Symbol, title, and optional subtitle and action.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    /// Technical text under the subtitle (an error's url and status), monospaced and copyable.
    var detail: String? = nil
    var actionTitle: String? = nil
    /// A filled call to action, for an empty state the user is expected to act on (a failed
    /// load). The default glass button suits an invitation, like browsing from an empty library.
    var prominent = false
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let subtitle {
                Text(subtitle)
            }
            if let detail {
                ErrorDetailBox(text: detail)
                    .padding(.top, 4)
            }
        } actions: {
            if let actionTitle, let action {
                if prominent {
                    Button(actionTitle, action: action).primaryActionStyle()
                } else {
                    Button(actionTitle, action: action).buttonStyle(.glass)
                }
            }
        }
    }
}

#Preview {
    EmptyStateView(
        icon: "books.vertical",
        title: "Your Library is Empty",
        subtitle: "Browse sources to find novels.",
        actionTitle: "Browse",
        action: {}
    )
}
