// AdvancedSettingsView.swift
// Diagnostics, experimental flags, and maintenance actions.

import SwiftData
import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetReaderDialog = false
    @State private var showCleanupDialog = false
    @State private var isCleaning = false
    @State private var cleanupMessage: String?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Form {
            Section {
                Button {
                    showCleanupDialog = true
                } label: {
                    HStack {
                        Text("Clean up unused data")
                        if isCleaning { ProgressView() }
                    }
                }
                .disabled(isCleaning)
                .confirmationDialog(
                    "Clean up books not in your library?",
                    isPresented: $showCleanupDialog,
                    titleVisibility: .visible
                ) {
                    Button("Clean up", role: .destructive) { runCleanup() }
                } message: {
                    Text("Downloads, reading progress and history for books you have not added to the library will be deleted. This can't be undone.")
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Removes downloads, progress, history and saved data for books that are not in your library.")
            }
            Section("Maintenance") {
                Button("Reset reader settings", role: .destructive) {
                    showResetReaderDialog = true
                }
                .confirmationDialog(
                    "Reset reader settings?",
                    isPresented: $showResetReaderDialog,
                    titleVisibility: .visible
                ) {
                    Button("Reset reader settings", role: .destructive) { resetReaderSettings() }
                } message: {
                    Text("Font, line height, padding, and manga reader defaults will return to defaults.")
                }
            }
        }
        .settingsScreen("Advanced")
        .alert("Cleanup finished", isPresented: Binding(
            get: { cleanupMessage != nil }, set: { if !$0 { cleanupMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanupMessage ?? "")
        }
    }

    private func runCleanup() {
        let container = modelContext.container
        isCleaning = true
        Task {
            let result = await LibraryMaintenance.cleanUpOrphans(container: container)
            LibraryChapterCounts.shared.invalidate()
            isCleaning = false
            var text = result.entries == 0
                ? "Nothing to clean up."
                : "Removed \(result.entries) books and \(result.chapters) chapters."
            if result.skipped > 0 { text += " \(result.skipped) with downloads in progress were kept." }
            cleanupMessage = text
        }
    }

    private func resetReaderSettings() {
        let defaults = UserDefaults.standard
        let keys = [
            "reader.fontSize",
            "reader.lineHeight",
            "reader.fontFamily",
            "reader.padding",
            "reader.justifyText",
            "reader.keepScreenOn",
            "reader.backgroundColor",
            "reader.textColor",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        MangaReaderPreferences.resetDefaults(defaults)
    }
}
