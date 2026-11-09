// GeneralSettingsView.swift
// Library defaults, confirmations and the app-wide haptics switch.

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(SourceManager.self) private var sourceManager

    @AppStorage("general.defaultSortOrder") private var defaultSortOrderRaw = SortOrder.lastRead.rawValue
    @AppStorage("general.defaultSortDirection") private var defaultSortDirectionRaw = SortDirection.descending.rawValue
    @AppStorage("general.defaultDisplayMode") private var defaultDisplayModeRaw = DisplayMode.comfortable.rawValue

    @AppStorage("general.confirmRemove") private var confirmRemove = true
    @AppStorage("general.showUnreadBadges") private var showUnreadBadges = true
    @AppStorage("general.showDownloadBadges") private var showDownloadBadges = false
    @AppStorage("general.showLanguageBadges") private var showLanguageBadges = false
    @AppStorage("general.showNewBadges") private var showNewBadges = false

    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptics.strengthKey) private var hapticStrength = 1.0
    @AppStorage(Haptics.scrollEnabledKey) private var scrollHaptics = true

    var body: some View {
        Form {
            Section {
                Picker("Sort order", selection: defaultSortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }

                Picker("Sort direction", selection: defaultSortDirection) {
                    ForEach(SortDirection.allCases, id: \.self) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }

                Picker("Display mode", selection: defaultDisplayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Defaults for every category. A single category can override its sort, filters and layout from Library options.")
            }

            Section {
                Toggle("Unread count", isOn: $showUnreadBadges)
                Toggle("New chapters", isOn: $showNewBadges)
                Toggle("Downloaded count", isOn: $showDownloadBadges)
                Toggle("Source language", isOn: $showLanguageBadges)
            } header: {
                Text("Library badges")
            }

            Section("Library") {
                Toggle("Confirm before remove", isOn: $confirmRemove)
            }

            browseSection

            hapticsSection
        }
        .settingsScreen("General")
    }

    private var browseSection: some View {
        @Bindable var sourceManager = sourceManager

        return Section {
            Toggle("Hide 18+ sources", isOn: $sourceManager.hidesAdultSources)
        } header: {
            Text("Browse")
        }
    }

    private var hapticsSection: some View {
        Section {
            Toggle("Vibration", isOn: $hapticsEnabled)
                .onChange(of: hapticsEnabled) { _, on in
                    if on { Haptics.shared.chapterBreak() }
                }
            if hapticsEnabled {
                Toggle("While scrolling", isOn: $scrollHaptics)
                LabeledContent("Strength") {
                    Text("\(Int((hapticStrength * 100).rounded()))%")
                        .monospacedDigit()
                }
                Slider(value: $hapticStrength, in: Haptics.strengthRange) { editing in
                    // Let go to feel the new strength.
                    if !editing { Haptics.shared.scroll(ScrollFeel.detent(speed: 800)) }
                }
                .accessibilityLabel("Strength")
            }
        } header: {
            Text("Haptics")
        }
    }

    private var defaultSortOrder: Binding<SortOrder> {
        Binding(
            get: { SortOrder(rawValue: defaultSortOrderRaw) ?? .lastRead },
            set: { defaultSortOrderRaw = $0.rawValue }
        )
    }

    private var defaultSortDirection: Binding<SortDirection> {
        Binding(
            get: { SortDirection(rawValue: defaultSortDirectionRaw) ?? .descending },
            set: { defaultSortDirectionRaw = $0.rawValue }
        )
    }

    private var defaultDisplayMode: Binding<DisplayMode> {
        Binding(
            get: { DisplayMode(rawValue: defaultDisplayModeRaw) ?? .comfortable },
            set: { defaultDisplayModeRaw = $0.rawValue }
        )
    }
}
