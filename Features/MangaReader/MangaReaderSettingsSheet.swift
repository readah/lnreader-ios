// MangaReaderSettingsSheet.swift - Reader settings: this series, and how input behaves.

import SwiftUI

struct MangaReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-series layout and tap zones.
    let series: MangaSeriesSettings
    /// Volume keys, auto scroll, hold to scroll: these follow the user.
    @Binding var controls: MangaControlSettings

    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptics.scrollEnabledKey) private var scrollHaptics = true
    @ObservedObject private var focusManager = FocusModeManager.shared

    static let compactDetent: PresentationDetent = .height(420)

    /// Everything the half sheet leaves out, on its own sheet.
    @State private var showAllSettings = false

    init(
        series: MangaSeriesSettings,
        controls: Binding<MangaControlSettings>
    ) {
        self.series = series
        self._controls = controls
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderSheetHeader(title: "Manga Settings") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.top, 10)

            compactContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showAllSettings) { allSettingsSheet }
    }

    /// The rest of the settings, on a sheet of their own rather than growing
    /// this one.
    private var allSettingsSheet: some View {
        VStack(spacing: 0) {
            ReaderSheetHeader(title: "Manga Settings") { showAllSettings = false }
                .padding(.horizontal, 16)
                .padding(.top, 10)

            expandedContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
    }

    // MARK: - Half Sheet

    /// Everything worth changing mid-chapter, and nothing else: how the pages
    /// flow, where taps land, and the two scrolling aids.
    private var compactContent: some View {
        VStack(spacing: 0) {
            readingModeCards
                .padding(.horizontal, 16)
                .padding(.top, 14)

            tapZoneCard
                .padding(.horizontal, 16)
                .padding(.top, 12)

            quickRows
                .padding(.horizontal, 16)
                .padding(.top, 12)

            SheetActionButton(title: "More settings", systemImage: "slider.horizontal.3") {
                showAllSettings = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    /// The layout as five words you can see at once, and the invert switch
    /// underneath. No menu: the choice is the point of the row. The picture of
    /// the zones lives in the full settings sheet, where there is room for it.
    private var tapZoneCard: some View {
        VStack(spacing: 12) {
            Picker("Tap zones", selection: tapZoneBinding) {
                ForEach(MangaTapZoneLayout.allCases) { layout in
                    Text(layout.shortName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(isOn: invertTapZones) {
                Text("Invert tap zones")
                    .font(.system(size: 15))
            }
            .tint(AppTheme.controlFill)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var tapZoneBinding: Binding<MangaTapZoneLayout> {
        Binding(
            get: { series.resolved.tapZones },
            set: { layout in
                withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                    series.setTapZones(layout)
                    if !series.hasOverrides { series.makeDefault() }
                }
            }
        )
    }

    private var readingModeCards: some View {
        HStack(spacing: 12) {
            ForEach(MangaReadingMode.allCases) { mode in
                ReadingModeCard(
                    mode: mode,
                    isSelected: series.resolved.readingMode == mode
                ) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.setReadingMode(mode)
                        if !series.hasOverrides { series.makeDefault() }
                    }
                }
            }
        }
    }

    /// Auto scroll style and hold to scroll in one card: the two things a
    /// reader reaches for while the strip is already moving.
    private var quickRows: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Scroll style", selection: $controls.autoScrollStyle) {
                    ForEach(AutoScrollStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 15))
                        .frame(width: 22)
                        .foregroundStyle(.secondary)

                    Text("Auto scroll")
                        .font(.system(size: 15))

                    Spacer(minLength: 8)

                    Text(controls.autoScrollStyle.displayName)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(height: 40)
                .contentShape(.rect)
            }

            Divider()
                .padding(.leading, 32)

            Toggle(isOn: $controls.holdScrollEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 15))
                        .frame(width: 22)
                        .foregroundStyle(.secondary)

                    Text("Hold to scroll")
                        .font(.system(size: 15))
                }
            }
            .tint(AppTheme.controlFill)
            .frame(height: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    // MARK: - Full Sheet

    private var expandedContent: some View {
        Form {
            if series.resolved.readingMode == .pager {
                directionSection
            }
            controlsSection
            if series.resolved.readingMode == .webtoon {
                stripSection
            }
            if series.resolved.readingMode == .webtoon {
                autoScrollSection
                holdSection
            }
            environmentSection
            scopeSection
        }
        .transition(.opacity)
    }

    // MARK: - Page Direction (Paged Mode)

    private var directionSection: some View {
        Section {
            HStack(spacing: 12) {
                directionCard(
                    title: "Left to Right",
                    icon: "arrow.right",
                    isSelected: series.resolved.direction == .leftToRight
                ) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.setDirection(.leftToRight)
                        if !series.hasOverrides { series.makeDefault() }
                    }
                }

                directionCard(
                    title: "Right to Left",
                    icon: "arrow.left",
                    isSelected: series.resolved.direction == .rightToLeft
                ) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.setDirection(.rightToLeft)
                        if !series.hasOverrides { series.makeDefault() }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            SettingsSectionHeader(
                title: "Page Direction",
                info: "Which way the pages run. Right to left is the manga format: "
                    + "page 2 sits to the left of page 1."
            )
        }
    }

    private func directionCard(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? (AppTheme.primaryFill) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Controls (tap zones and volume buttons)

    private var controlsSection: some View {
        Section {
            // On the section's own row, not a clear one: the picture belongs to
            // the picker under it, and a card of its own above the group read
            // as something that had landed there by accident.
            TapZoneDiagram(
                layout: series.resolved.tapZones,
                inverted: series.resolved.invertTapZones,
                rightToLeft: series.resolved.direction == .rightToLeft
            )
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
            // The row's separator would start at the picture's leading edge, a
            // third of the way in. The picture needs no rule under it.
            .listRowSeparator(.hidden)
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: series.resolved)

            // Segmented, so the picture above stays visible while the layout is
            // chosen. A menu would cover the very thing being chosen.
            Picker("Tap zones", selection: tapZoneBinding) {
                ForEach(MangaTapZoneLayout.allCases) { layout in
                    Text(layout.shortName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Invert tap zones", isOn: invertTapZones)
                .tint(AppTheme.controlFill)

            Toggle("Volume buttons turn pages", isOn: $controls.volumeKeys)
                .tint(AppTheme.controlFill)

            if controls.volumeKeys {
                Toggle("Invert volume buttons", isOn: $controls.volumeKeysInverted)
                    .tint(AppTheme.controlFill)
            }
        } header: {
            SettingsSectionHeader(
                title: "Controls",
                info: "Where a tap lands on the page. Red turns back, blue turns forward and "
                    + "the rest opens the menu; each layout arranges them differently. Invert "
                    + "swaps back and forward. Volume up goes back and volume down goes "
                    + "forward, unless inverted."
            )
        }
    }

    private var invertTapZones: Binding<Bool> {
        Binding(
            get: { series.resolved.invertTapZones },
            set: {
                series.setInvertTapZones($0)
                if !series.hasOverrides { series.makeDefault() }
            }
        )
    }

    // MARK: - Webtoon Strip

    private var stripSection: some View {
        Section {
            sliderRow(
                "Strip width",
                symbol: "rectangle.portrait.split.2x1",
                value: $controls.stripWidth,
                range: MangaControlSettings.stripWidthRange,
                step: 0.05,
                valueText: "\(Int((controls.stripWidth * 100).rounded()))%"
            )

            Picker("Scroll momentum", selection: $controls.momentum) {
                ForEach(WebtoonMomentum.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            SettingsSectionHeader(
                title: "Webtoon Strip",
                info: "Strip width frames the art in still margins, so less of the field of "
                    + "view moves. Momentum is how far the strip glides after a flick."
            )
        }
    }

    // MARK: - Auto Scroll

    private var autoScrollSection: some View {
        Section {
            Picker("Scroll style", selection: $controls.autoScrollStyle) {
                ForEach(AutoScrollStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }

            sliderRow(
                controls.autoScrollStyle == .stepped ? "Pace" : "Speed",
                symbol: "play.circle",
                value: $controls.autoScrollSpeed,
                range: MangaControlSettings.autoSpeedRange,
                step: 5,
                valueText: "\(Int(controls.autoScrollSpeed)) pt/s"
            )
        } header: {
            SettingsSectionHeader(
                title: "Auto Scroll",
                info: "Continuous crawls at the set pace. A screen at a time rests while you "
                    + "read, then moves a whole screenful at the same average pace."
            )
        }
    }

    // MARK: - Hold to Scroll

    private var holdSection: some View {
        Section {
            Toggle("Hold to scroll", isOn: $controls.holdScrollEnabled)
                .tint(AppTheme.controlFill)

            if controls.holdScrollEnabled {
                sliderRow(
                    "Base speed",
                    symbol: "speedometer",
                    value: $controls.hold.baseSpeed,
                    range: HoldScrollConfig.baseRange,
                    step: 10,
                    valueText: "\(Int(controls.hold.baseSpeed)) pt/s"
                )

                sliderRow(
                    "Min speed",
                    symbol: "tortoise",
                    value: $controls.hold.minSpeed,
                    range: 10...600,
                    step: 10,
                    valueText: "\(Int(controls.hold.minSpeed)) pt/s"
                )

                sliderRow(
                    "Max speed",
                    symbol: "hare",
                    value: $controls.hold.maxSpeed,
                    range: 100...3000,
                    step: 50,
                    valueText: "\(Int(controls.hold.maxSpeed)) pt/s"
                )

                sliderRow(
                    "Drag sensitivity",
                    symbol: "arrow.up.and.down",
                    value: $controls.hold.speedPerPoint,
                    range: HoldScrollConfig.stepRange,
                    step: 0.1,
                    valueText: String(format: "%.1f pt/s per pt", controls.hold.speedPerPoint)
                )

                Picker("Faster when swiping", selection: $controls.hold.upIncreases) {
                    Text("Swipe Up").tag(true)
                    Text("Swipe Down").tag(false)
                }
            }
        } header: {
            SettingsSectionHeader(
                title: "Hold to Scroll",
                info: "Hold a finger down to scroll at the base speed, then drag to speed up "
                    + "or slow down. Min and max are how far a drag can take it."
            )
        }
    }

    // MARK: - Haptics & Focus

    private var environmentSection: some View {
        Section {
            Toggle("Scroll haptics", isOn: $scrollHaptics)
                .tint(AppTheme.controlFill)
                .disabled(!hapticsEnabled)
                .onChange(of: scrollHaptics) { _, on in
                    if on { Haptics.shared.scroll(ScrollFeel.detent(speed: 800)) }
                }

            Picker("Active Focus display", selection: focusOverride) {
                Text("Off").tag("none")
                Text("System auto").tag("auto")
                Text("Do Not Disturb").tag("dnd")
                Text("Work Focus").tag("work")
                Text("Sleep Focus").tag("sleep")
            }
            .pickerStyle(.menu)

            if focusManager.overrideType == "auto" {
                FocusStatusRow(focusManager: focusManager)
            }
        } header: {
            SettingsSectionHeader(
                title: "Haptics & Focus",
                info: (hapticsEnabled
                    ? "Scroll haptics are a soft swell as you scroll, stronger the faster you "
                        + "flick. The master switch and strength live in Settings › General › "
                        + "Haptics. "
                    : "All vibration is off in Settings › General › Haptics. ")
                    + "The Focus display shows the active Focus mode near the top of the page "
                    + "while the controls are hidden."
            )
        }
    }

    private var focusOverride: Binding<String> {
        Binding(
            get: { focusManager.overrideType },
            set: { value in
                focusManager.overrideType = value
                focusManager.updateFocusStatus()
            }
        )
    }

    // MARK: - Scope & Defaults

    private var scopeSection: some View {
        Section {
            useForAllToggle

            if series.hasOverrides {
                Button("Reset this series to default", role: .destructive) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.reset()
                    }
                }
            }
        } header: {
            SettingsSectionHeader(
                title: "Settings Scope",
                info: "Use for all series makes this layout the default for every title in "
                    + "your library. Resetting drops this series' own changes."
            )
        }
    }

    // MARK: - Helpers

    private var useForAllToggle: some View {
        Toggle("Use for all series", isOn: Binding(
            get: { !series.hasOverrides },
            set: { applyToAll in
                withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                    if applyToAll {
                        series.makeDefault()
                    } else {
                        series.setReadingMode(series.resolved.readingMode)
                        series.setDirection(series.resolved.direction)
                        series.setTapZones(series.resolved.tapZones)
                        series.setInvertTapZones(series.resolved.invertTapZones)
                    }
                }
            }
        ))
        .tint(AppTheme.controlFill)
    }

    /// A labelled slider as one Form row: title and value on top, slider below.
    /// Identical to ReaderSettings sliderRow.
    private func sliderRow(
        _ title: LocalizedStringKey, symbol: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double = 1, valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(valueText).monospacedDigit()
            } label: {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: value, in: range, step: step)
                .tint(AppTheme.controlFill)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - Reading Mode Card

/// One of the two ways a chapter can flow: a single symbol and its name. The
/// little page mockups that used to be here read as clutter at this size.
struct ReadingModeCard: View {
    let mode: MangaReadingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(height: 26)

                Text(mode.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        Color(.secondarySystemGroupedBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? (AppTheme.primaryFill) : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Tap Zone Diagram

/// The reader screen as a picture: one translucent box per tap target, red for
/// back, blue for forward, the menu left almost bare.
///
/// Drawn from `MangaTapZoneLayout.zones(in:)` — the same rectangles
/// `action(at:)` tests a tap against — so the picture cannot promise something
/// the tap will not do. The colours belong to the action, not to the side, so
/// inverting swaps which side is red instead of lying about it.
struct TapZoneDiagram: View {
    let layout: MangaTapZoneLayout
    var inverted = false
    var rightToLeft = false

    /// A phone's proportions. This is the only picture of the zones in the app,
    /// so it is drawn large enough to read at a glance.
    var size = CGSize(width: 180, height: 230)

    /// Labels and corners grow with the screen, so a bigger picture is readable
    /// rather than just bigger.
    private var scale: CGFloat { size.width / 110 }

    private var zones: [MangaTapZone] {
        layout.zones(in: size, inverted: inverted, rightToLeft: rightToLeft)
    }

    /// One label per action, in the largest box that carries it: the L layout is
    /// drawn from five boxes but has three names.
    private var anchors: [MangaTapZone] {
        var largest: [MangaTapAction: MangaTapZone] = [:]
        for zone in zones {
            let area = zone.rect.width * zone.rect.height
            if let kept = largest[zone.action],
               kept.rect.width * kept.rect.height >= area { continue }
            largest[zone.action] = zone
        }
        return zones.filter { largest[$0.action] == $0 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.09)

            ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                Rectangle()
                    .fill(zone.action.zoneFill)
                    .frame(width: zone.rect.width, height: zone.rect.height)
                    .offset(x: zone.rect.minX, y: zone.rect.minY)
            }

            ForEach(Array(anchors.enumerated()), id: \.offset) { _, zone in
                label(for: zone)
                    .frame(width: zone.rect.width, height: zone.rect.height)
                    .offset(x: zone.rect.minX, y: zone.rect.minY)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func label(for zone: MangaTapZone) -> some View {
        let narrow = zone.rect.width < 34 * scale
        if zone.action == .menu {
            if !narrow { zoneText("Menu") }
        } else if narrow {
            // An edge strip is too thin for a word.
            Image(systemName: zone.action == .previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 10 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        } else {
            zoneText(zone.action == .previous ? "Back" : "Next")
        }
    }

    private func zoneText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * scale, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 2 * scale)
            .shadow(color: .black.opacity(0.35), radius: scale, y: 0.5 * scale)
    }

    private var accessibilitySummary: String {
        guard zones.contains(where: { $0.action != .menu }) else {
            return "\(layout.displayName): every tap opens the menu."
        }
        return "\(layout.displayName): red turns back, blue turns forward, the rest opens the menu."
    }
}

private extension MangaTapAction {
    /// Back is red and forward is blue, the two colours a reader tells apart at
    /// a glance. The menu stays almost bare, so the page-turn regions are what
    /// stands out.
    var zoneFill: Color {
        switch self {
        case .previous: Color.red.opacity(0.34)
        case .next: Color.blue.opacity(0.34)
        case .menu: Color.white.opacity(0.07)
        }
    }
}
