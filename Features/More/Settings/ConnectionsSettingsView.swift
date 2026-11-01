// ConnectionsSettingsView.swift
// Every account the app can sign into, in one place: AniList tracking and the
// NovelFire-family comment sessions. Each row can connect and disconnect.
//
// Why one screen: these used to live apart (tracking under a "Tracking" row,
// comment sign-in only behind a reader sheet), so there was no single place to
// see what the app was signed in to, or to sign out of it.

import SwiftUI

extension CommentSite: Identifiable {
    var id: String { rawValue }
}

struct ConnectionsSettingsView: View {
    @Environment(TrackingManager.self) private var tracking
    /// Which comment sites currently hold a session. Read from the cookie jar on
    /// appear and after every sign-in or sign-out, never cached across launches.
    @State private var connectedSites: Set<CommentSite> = []
    @State private var signingIn: CommentSite?
    @State private var isSigningInToAniList = false
    @State private var error: String?

    var body: some View {
        @Bindable var tracking = tracking
        List {
            trackingSection
            commentsSection
            Section {
                Toggle("Update progress automatically", isOn: $tracking.autoUpdate)
            }
        }
        .settingsScreen("Connections")
        .onAppear(perform: refreshSessions)
        .sheet(item: $signingIn) { site in
            NovelFireLoginView(onLoginSuccess: { refreshSessions() }, site: site)
        }
        .alert("Couldn't connect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Tracking

    private var trackingSection: some View {
        Section {
            if tracking.isLoggedIn {
                LabeledContent("Signed in as", value: tracking.userName ?? "AniList user")
                Button("Disconnect", role: .destructive) { tracking.logout() }
                    .buttonStyle(.borderless)
            } else {
                Button(action: connectAniList) {
                    HStack {
                        Text("Connect AniList")
                        Spacer()
                        if isSigningInToAniList { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isSigningInToAniList)
            }
        } header: {
            Text("Tracking")
        }
    }

    private func connectAniList() {
        isSigningInToAniList = true
        Task {
            defer { isSigningInToAniList = false }
            do {
                try await tracking.login()
            } catch AniListError.cancelled {
                // The user closed the sign-in sheet; nothing to report.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Comments

    private var commentsSection: some View {
        Section {
            ForEach(CommentSite.allCases) { site in
                commentRow(site)
            }
        } header: {
            Text("Comments")
        } footer: {
            Text("Only needed to post and vote on comments.")
        }
    }

    private func commentRow(_ site: CommentSite) -> some View {
        let connected = connectedSites.contains(site)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.displayName)
                Text(connected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                Button("Disconnect", role: .destructive) { disconnect(site) }
                    .buttonStyle(.borderless)
            } else {
                Button("Connect") { signingIn = site }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func disconnect(_ site: CommentSite) {
        NovelFireCommentsService.shared.disconnect(from: site)
        refreshSessions()
    }

    private func refreshSessions() {
        connectedSites = Set(CommentSite.allCases.filter { NovelFireCommentsService.shared.hasSession(for: $0) })
    }
}
