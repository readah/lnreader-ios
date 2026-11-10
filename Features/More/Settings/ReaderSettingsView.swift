// ReaderSettingsView.swift
// Global reader settings for light novels and manga.

import SwiftUI

struct ReaderSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case novel
        case manga

        var id: String { rawValue }

        var title: String {
            switch self {
            case .novel: "Light Novel"
            case .manga: "Manga"
            }
        }
    }

    @AppStorage("settings.readerTab") private var selectedTab: Tab = .novel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Novel reader settings
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineHeight") private var lineHeight: Double = 1.6
    @AppStorage("reader.fontFamily") private var fontFamily = "Georgia"
    @AppStorage("reader.padding") private var horizontalPadding: Double = 16
    @AppStorage("reader.verticalPadding") private var verticalPadding: Double = 20
    @AppStorage("reader.bionicReading") private var bionicReading = false
    @AppStorage("reader.lineFocusEnabled") private var lineFocusEnabled = false
    @AppStorage("reader.lineFocusLines") private var lineFocusLines = 1
    @AppStorage("reader.lineFocusDulling") private var lineFocusDulling = "mid"
    @AppStorage("reader.backgroundColor") private var backgroundColorHex: String = ""
    @AppStorage("reader.textColor") private var textColorHex: String = ""
    @AppStorage("reader.characterSpacing") private var characterSpacing: Double = 0.0
    @AppStorage("reader.wordSpacing") private var wordSpacing: Double = 0.0
    @AppStorage("reader.grainIntensity") private var grainIntensity: Double = 10.0

    // Manga reader global settings
    @AppStorage(MangaReaderSettingsKey.readingMode) private var readingModeRaw = MangaReadingMode.pager.rawValue
    @AppStorage(MangaReaderSettingsKey.direction) private var directionRaw = MangaPagingDirection.leftToRight.rawValue
    @AppStorage(MangaReaderSettingsKey.tapZones) private var tapZonesRaw = MangaTapZoneLayout.standard.rawValue
    @AppStorage(MangaReaderSettingsKey.invertTapZones) private var invertTapZones = false
    @AppStorage(MangaControlSettings.storageKey) private var controls = MangaControlSettings()

    @State private var showResetMangaDialog = false

    var body: some View {
        VStack(spacing: 0) {
            tabSwitcher
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(uiColor: .systemGroupedBackground))

            Group {
                switch selectedTab {
                case .novel:
                    novelContent
                case .manga:
                    mangaContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: selectedTab)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .settingsScreen("Reader settings")
    }

    private var tabSwitcher: some View {
        Picker("Reader", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .hapticFeedback(.selection, trigger: selectedTab)
    }

    // MARK: - Light Novel

    private var novelContent: some View {
        ReaderSettings(
            fontSize: $fontSize,
            lineHeight: $lineHeight,
            fontFamily: $fontFamily,
            horizontalPadding: $horizontalPadding,
            verticalPadding: $verticalPadding,
            backgroundColorHex: $backgroundColorHex,
            textColorHex: $textColorHex,
            bionicReading: $bionicReading,
            lineFocusEnabled: $lineFocusEnabled,
            lineFocusLines: $lineFocusLines,
            lineFocusDulling: $lineFocusDulling,
            characterSpacing: $characterSpacing,
            wordSpacing: $wordSpacing,
            grainIntensity: $grainIntensity,
            isEmbedded: true
        )
    }

    // MARK: - Manga

    private var mangaContent: some View {
        MangaReaderSettingsContent(
            readingMode: Binding(
                get: { MangaReadingMode(rawValue: readingModeRaw) ?? .pager },
                set: { readingModeRaw = $0.rawValue }
            ),
            direction: Binding(
                get: { MangaPagingDirection(rawValue: directionRaw) ?? .leftToRight },
                set: { directionRaw = $0.rawValue }
            ),
            tapZones: Binding(
                get: { MangaTapZoneLayout(rawValue: tapZonesRaw) ?? .standard },
                set: { tapZonesRaw = $0.rawValue }
            ),
            invertTapZones: $invertTapZones,
            controls: $controls,
            unconditional: true,
            bottomContent: {
                Section {
                    Button("Reset manga defaults", role: .destructive) {
                        showResetMangaDialog = true
                    }
                    .confirmationDialog(
                        "Reset manga defaults?",
                        isPresented: $showResetMangaDialog,
                        titleVisibility: .visible
                    ) {
                        Button("Reset manga defaults", role: .destructive) {
                            resetMangaDefaults()
                        }
                    } message: {
                        Text("Reading mode, page direction, tap zones, and scroll controls will return to defaults.")
                    }
                }
            }
        )
    }

    private func resetMangaDefaults() {
        MangaReaderPreferences.resetDefaults()
        readingModeRaw = MangaReadingMode.pager.rawValue
        directionRaw = MangaPagingDirection.leftToRight.rawValue
        tapZonesRaw = MangaTapZoneLayout.standard.rawValue
        invertTapZones = false
        controls = MangaControlSettings()
        Haptics.shared.notify(.warning)
    }
}
