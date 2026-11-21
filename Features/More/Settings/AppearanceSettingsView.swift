// AppearanceSettingsView.swift
// How much of a book's own colour the detail screens use.

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = false
    @AppStorage(AppearanceTint.strengthKey) private var strength = AppearanceTint.defaultStrength
    @AppStorage(IconPack.storageKey) private var iconPack = IconPack.swiftIcons.rawValue
    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false
    @AppStorage(ChromeAppearance.noLiquidGlassKey) private var noLiquidGlass = false
    @AppStorage(ChromeAppearance.systemFormsKey) private var systemForms = true
    @AppStorage(RevealMotion.enabledKey) private var springUnblurMotion = false

    var body: some View {
        AppForm {
            Section {
                Toggle(isOn: $noLiquidGlass) { betaLabel("No Liquid Glass") }
            } header: {
                Text("Interface")
            } footer: {
                Text("Use soft frosted materials, blurred navigation bars and a custom tab dock instead of Liquid Glass. Applies throughout the app; onboarding stays unchanged.")
            }

            Section {
                Toggle(isOn: $systemForms) { betaLabel("Use iOS default forms") }
            } header: {
                Text("Beta")
            } footer: {
                Text("Uses iOS's native grouped form layout for every settings screen and option sheet instead of the custom frosted cards. Titles, buttons and content stay ours.")
            }

            Section {
                Toggle("Spring & unblur motion", isOn: $springUnblurMotion)
                AppearanceMotionPreview()
            } header: {
                Text("Motion")
            } footer: {
                Text("Custom popups and controls settle into place and sharpen into focus. Includes onboarding and switching library modes. Standard iOS navigation, tabs and sheets keep their own transitions. Respects Reduce Motion.")
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
                Toggle("Cover backdrop & tint", isOn: $tintDetails)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Backdrop intensity") {
                        Text("\(Int((strength * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    AppSlider(value: $strength, in: 0.0...1.0, step: 0.05) {
                        Text("Backdrop intensity")
                    }
                    .tint(AppTheme.accent)
                }
                .padding(.vertical, 4)
                .disabled(!tintDetails)
            } header: {
                Text("Detail screens")
            }

            Section {
                Toggle("Minimal Mode", isOn: $minimalMode)
            } header: {
                Text("Library")
            } footer: {
                Text("The library becomes a full-screen shelf and the tab bar is hidden. Swipe the library's title to enter it, and the title inside to leave.")
            }
        }
        .settingsScreen("Appearance")
    }

    /// A toggle label with a small "Beta" badge, marking an experimental option.
    private func betaLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text("Beta")
                .font(Typography.small.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(AppTheme.accent.opacity(0.14), in: .capsule)
                .accessibilityHidden(true)
        }
    }
}
