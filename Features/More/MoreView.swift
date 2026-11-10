// MoreView.swift
// Settings hub: profile and sync, then grouped navigation rows in a native inset list.

import PhotosUI
import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Entry> { $0.inLibrary }) private var libraryNovels: [Entry]
    @Query private var profiles: [UserProfile]

    @State private var showingEditProfile = false
    @State private var showingAuth = false
    @State private var showingRestore = false

    private var userProfile: UserProfile {
        profiles.first ?? UserProfile(name: "Reader")
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                syncSection
                libraryManagementSection
                settingsSection
                infoSection
            }
            .navigationTitle("More")
            .sheet(isPresented: $showingEditProfile) {
                ProfileEditSheet(profile: userProfile)
            }
            .sheet(isPresented: $showingAuth) {
                AuthView()
            }
            .onAppear {
                ensureProfileExists()
            }
            // Signing in or out changes who owns the server copy, so the local
            // store has to catch up with it before the next push overwrites it.
            .onChange(of: syncManager.currentUser?.id) { _, id in
                guard id != nil else { return }
                Task { await syncManager.pull(into: modelContext, quiet: true) }
            }
        }
    }

    private func ensureProfileExists() {
        if profiles.isEmpty {
            let defaultProfile = UserProfile(name: "Reader")
            modelContext.insert(defaultProfile)
            try? modelContext.save()
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(userProfile.name)
                        .font(.headline)
                    Text(accountSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Haptics.shared.impact(.light)
                    showingEditProfile = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Edit profile")
            }
        }
    }

    private var accountSubtitle: String {
        if let currentUser = syncManager.currentUser {
            return currentUser.displayUsername ?? currentUser.username ?? "Signed in"
        }
        return "Local Profile"
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = userProfile.avatarData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.hairline, lineWidth: 1))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            syncStatus

            if syncManager.currentUser == nil {
                Button("Login") {
                    showingAuth = true
                }
                .primaryActionStyle()
            } else {
                Button {
                    Task {
                        await syncManager.push(
                            profile: userProfile,
                            entries: libraryNovels,
                            sources: sourceManager.novelSources,
                            context: modelContext
                        )
                    }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        if syncManager.isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(syncManager.isWorking)

                Button {
                    showingRestore = true
                } label: {
                    Label("Download from backend", systemImage: "arrow.down.circle")
                }
                .disabled(syncManager.isWorking)
                .confirmationDialog(
                    "Download your library from the backend?",
                    isPresented: $showingRestore,
                    titleVisibility: .visible
                ) {
                    Button("Download", action: download)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The backend's copy wins wherever the two disagree. Reading progress made here since the last sync is replaced.")
                }

                Button(role: .destructive) {
                    Task { await syncManager.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(syncManager.isWorking)
            }
        } header: {
            Text("Cloud sync")
        } footer: {
            if syncManager.currentUser != nil {
                Text("Download replaces matching titles with the backend's copy.")
            }
        }
    }

    private func download() {
        Task { await syncManager.restore(into: modelContext) }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let error = syncManager.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(AppTheme.destructive)
        } else if let message = syncManager.lastMessage {
            Label(message, systemImage: "info.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if syncManager.currentUser == nil {
            Label("Cloud sync offline", systemImage: "cloud.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !syncManager.hasSynced {
            Label("Signed in, nothing synced yet", systemImage: "cloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Label("Cloud synced", systemImage: "icloud.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation rows

    private var libraryManagementSection: some View {
        Section {
            link("Downloads", symbol: "arrow.down.circle") { OfflineLibraryView() }
            link("Categories", subtitle: "Groups & update scope", symbol: "square.grid.2x2") { CategoriesSettingsView() }
            link("Library updates", symbol: "arrow.triangle.2.circlepath") { LibraryUpdateSettingsView() }
            link("Connections", subtitle: "AniList, comments", symbol: "link") { ConnectionsSettingsView() }
            link("Backup & restore", symbol: "externaldrive") { LibraryBackupView() }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            link("General", subtitle: "Library & defaults", symbol: "gearshape") { GeneralSettingsView() }
            link("Appearance", subtitle: "Cover tint", symbol: "paintpalette") { AppearanceSettingsView() }
            link("Reader", subtitle: "Novel & manga", symbol: "textformat.size") { ReaderSettingsView() }
            link("TTS", subtitle: "Voices & servers", symbol: "waveform") { TTSSettingsView() }
            link("Advanced", subtitle: "Diagnostics & cache", symbol: "slider.horizontal.3") { AdvancedSettingsView() }
        }
    }

    private var infoSection: some View {
        Section {
            link("Statistics", subtitle: "Library and reading insights", symbol: "chart.bar.fill", haptic: .medium) { StatisticsView() }
            link("About", subtitle: "App version and source code", symbol: "info.circle", haptic: .medium) { AboutView() }
        }
    }

    private func link<Destination: View>(
        _ title: String,
        subtitle: String? = nil,
        symbol: String,
        haptic: Haptics.Weight = .light,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            // Fired on push: a tap gesture on the link itself swallows touches
            // on the label, leaving only the empty part of the row tappable.
            destination()
                .onAppear { Haptics.shared.impact(haptic) }
        } label: {
            Label {
                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}

// MARK: - Profile Edit Sheet

struct ProfileEditSheet: View {
    @Bindable var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var nameInput: String = ""
    @State private var currentAvatarData: Data? = nil
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Avatar") {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            if let data = currentAvatarData, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, height: 100)
                            }
                            
                            PhotosPicker(selection: $selectedItem, matching: .images) {
                                Text("Choose Photo")
                            }
                            .onChange(of: selectedItem) { _, newItem in
                                Task {
                                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                        currentAvatarData = data
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                
                Section("Name") {
                    TextField("Enter name", text: $nameInput)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Reader" : nameInput
                        profile.avatarData = currentAvatarData
                        dismiss()
                    }
                }
            }
            .onAppear {
                nameInput = profile.name
                currentAvatarData = profile.avatarData
            }
        }
    }
}
