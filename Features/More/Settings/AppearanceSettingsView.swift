// AppearanceSettingsView.swift
// How much of a book's own colour the detail screens use.

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = false
    @AppStorage(AppearanceTint.strengthKey) private var strength = AppearanceTint.defaultStrength
    @AppStorage(IconPack.storageKey) private var iconPack = IconPack.swiftIcons.rawValue
    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false
    @AppStorage(ChromeAppearance.noLiquidGlassKey) private var noLiquidGlass = false
    @AppStorage(RevealMotion.enabledKey) private var springUnblurMotion = false

    var body: some View {
        List {
            Section {
                Toggle("No Liquid Glass", isOn: $noLiquidGlass)
            } header: {
                Text("Interface")
            } footer: {
                Text("Use soft frosted materials, blurred navigation bars and a custom tab dock instead of Liquid Glass. Applies throughout the app; onboarding stays unchanged.")
            }

            Section {
                Toggle("Spring & unblur motion", isOn: $springUnblurMotion)
                AppearanceMotionPreview()
            } header: {
                Text("Motion")
            } footer: {
                Text("Screens, sheets and controls settle into place with a subtle spring and sharpen into focus. Includes onboarding. Respects Reduce Motion.")
            }

            Section {
                AppPicker("Icon Pack", selection: $iconPack) {
                    ForEach(IconPack.allCases) { pack in
                        Text(pack.displayName).tag(pack.rawValue)
                    }
                }
                .tint(AppTheme.accent)
            } header: {
                Text("Icons")
            }

            Section {
                Toggle("Tint details from the cover", isOn: $tintDetails)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Tint strength") {
                        Text("\(Int((strength * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    AppSlider(value: $strength, in: 0.1...1) {
                        Text("Tint strength")
                    }
                    .tint(AppTheme.accent)
                }
                .disabled(!tintDetails)
            } header: {
                Text("Detail screens")
            }

            Section {
                Toggle("Minimal Mode", isOn: $minimalMode)
            } header: {
                Text("Library")
            } footer: {
                Text("The library becomes a full-screen list and the tab bar is hidden. Turn it off from the ··· menu on that screen.")
            }
        }
        .settingsScreen("Appearance")
    }
}
