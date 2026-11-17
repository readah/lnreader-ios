// MoreView.swift
// Settings hub: profile and sync, then grouped navigation rows in a native inset list.

import PhotosUI
import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var showingEditProfile = false
    @State private var showingSignIn = false
    @State private var showingRestore = false
    @State private var showingSignOut = false
    @State private var showingRestartOnboarding = false

    private var userProfile: UserProfile {
        profiles.first ?? UserProfile(name: "Reader")
    }

    var body: some View {
        AppNavigationStack {
            List {
                profileSection
                syncSection
                libraryManagementSection
                settingsSection
                infoSection
            }
            .appNavigationTitle("More")
            .sheet(isPresented: $showingEditProfile) {
                ProfileEditSheet(profile: userProfile)
            }
            .navigationDestination(isPresented: $showingSignIn) {
                LiquidGlassOnboardingView(onComplete: {
                    showingSignIn = false
                }, entryPoint: .signIn)
                .navigationBarBackButtonHidden()
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
            }
            .confirmationDialog(
                "Show the onboarding intro again?",
                isPresented: $showingRestartOnboarding,
                titleVisibility: .visible
            ) {
                Button("Restart") { restartOnboarding() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                ensureProfileExists()
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
                    AppIcon(systemName: "pencil", size: 17, relativeTo: .body)
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
        return "Reading on this device"
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
                Button {
                    Haptics.shared.impact(.light)
                    showingSignIn = true
                } label: {
                    HStack(spacing: 12) {
                        AppIcon(systemName: "person.crop.circle.badge.plus", size: 22, relativeTo: .title2)
                            .font(Typography.title)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sign in or create account")
                                .font(Typography.headline)
                            Text("Set up optional cloud sync")
                                .font(Typography.body)
                        }
                        Spacer(minLength: 0)
                        AppIcon(systemName: "chevron.right", size: 17, relativeTo: .body)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Opens account setup. An account is not required to read.")
            } else {
                Button {
                    Task {
                        await syncManager.push(
                            profile: userProfile,
                            sources: sourceManager.allSources,
                            context: modelContext
                        )
                    }
                } label: {
                    HStack {
                        AppLabel("Sync up", systemName: "arrow.up.circle", size: 17, relativeTo: .body)
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
                    AppLabel("Sync download", systemName: "arrow.down.circle", size: 17, relativeTo: .body)
                }
                .disabled(syncManager.isWorking)
                .confirmationDialog(
                    "Restore your library from the cloud?",
                    isPresented: $showingRestore,
                    titleVisibility: .visible
                ) {
                    Button("Sync download", action: download)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The cloud copy wins wherever the two disagree. Reading progress made on this device since the last sync is replaced.")
                }

                Button(role: .destructive) {
                    showingSignOut = true
                } label: {
                    AppLabel("Sign out", systemName: "rectangle.portrait.and.arrow.right", size: 17, relativeTo: .body)
                }
                .disabled(syncManager.isWorking)
                .confirmationDialog(
                    "Sign out of cloud sync?",
                    isPresented: $showingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) {
                        Task { await syncManager.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your library stays on this device, and your cloud copy is not deleted. Sync first if you want your latest changes available on other devices.")
                }
            }
        } header: {
            SettingsSectionHeader(
                title: "Cloud sync",
                info: syncManager.currentUser != nil
                    ? "Sync is manual. Sync up replaces the cloud copy with this device’s library, imported books, bookmarks and reading positions. Sync download brings them back and replaces matching local reading state."
                    : "Your library and reading progress stay on this device. Sign in only if you want cloud sync; no account is needed to read."
            )
        }
    }

    private func download() {
        Task { await syncManager.restore(into: modelContext) }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let error = syncManager.lastError {
            AppLabel(error, systemName: "exclamationmark.triangle.fill", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(AppTheme.destructive)
        } else if let message = syncManager.lastMessage {
            AppLabel(message, systemName: "info.circle.fill", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if syncManager.currentUser == nil {
            AppLabel("On-device reading · Not signed in", systemName: "iphone", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !syncManager.hasSynced {
            AppLabel("Signed in, nothing synced yet", systemName: "cloud", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            AppLabel("Cloud sync connected", systemName: "icloud.fill", size: 13, relativeTo: .footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation rows

    private var libraryManagementSection: some View {
        Section {
            link("Bookmarks", symbol: "highlighter") { BookmarksView() }
            link("Downloads", symbol: "arrow.down.circle") { OfflineLibraryView() }
            link("Categories", symbol: "square.grid.2x2") { CategoriesSettingsView() }
            link("Library updates", symbol: "arrow.triangle.2.circlepath") { LibraryUpdateSettingsView() }
            link("Connections", symbol: "link") { ConnectionsSettingsView() }
            link("Backup & restore", symbol: "externaldrive") { LibraryBackupView() }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            link("General", symbol: "gearshape") { GeneralSettingsView() }
            link("Appearance", symbol: "paintpalette") { AppearanceSettingsView() }
            link("Reader", symbol: "textformat.size") { ReaderSettingsView() }
            link("TTS", symbol: "waveform") { TTSSettingsView() }
            link("Advanced", symbol: "slider.horizontal.3") { AdvancedSettingsView() }

            Button {
                showingRestartOnboarding = true
            } label: {
                AppLabel("Restart Onboarding", systemName: "arrow.counterclockwise", size: 17, relativeTo: .body)
            }
        }
    }

    private var infoSection: some View {
        Section {
            link("Statistics", symbol: "chart.bar.fill", haptic: .medium) { StatisticsView() }
            link("About", symbol: "info.circle", haptic: .medium) { AboutView() }
        }
    }

    private func restartOnboarding() {
        Haptics.shared.impact(.light)
        UserDefaults.standard.set(false, forKey: OnboardingStorage.completionKey)
    }

    private func link<Destination: View>(
        _ title: String,
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
            AppLabel(title, systemName: symbol, size: 17, relativeTo: .body)
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
        AppNavigationStack {
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
            .appNavigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                AppToolbarItem(placement: .confirmationAction) {
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
