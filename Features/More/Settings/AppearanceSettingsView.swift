// AppearanceSettingsView.swift
// How much of a book's own colour the detail screens use.

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = false
    @AppStorage(AppearanceTint.strengthKey) private var strength = AppearanceTint.defaultStrength

    var body: some View {
        List {
            Section {
                Toggle("Tint details from the cover", isOn: $tintDetails)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Tint strength") {
                        Text("\(Int((strength * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    Slider(value: $strength, in: 0.1...1) {
                        Text("Tint strength")
                    }
                }
                .disabled(!tintDetails)
            } header: {
                Text("Detail screens")
            }
        }
        .settingsScreen("Appearance")
    }
}
