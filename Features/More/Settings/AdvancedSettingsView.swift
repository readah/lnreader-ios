// AdvancedSettingsView.swift
// Diagnostics, experimental flags, and maintenance actions.

import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetReaderDialog = false

    var body: some View {
        Form {
            Section("Maintenance") {
                Button("Reset reader settings", role: .destructive) {
                    showResetReaderDialog = true
                }
            }
        }
        .settingsScreen("Advanced")
        .confirmationDialog(
            "Reset reader settings?",
            isPresented: $showResetReaderDialog,
            titleVisibility: .visible
        ) {
            Button("Reset reader settings", role: .destructive) {
                resetReaderSettings()
            }
        } message: {
            Text("Font, line height, padding, and manga reader defaults will return to defaults.")
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
