// MangaReaderSettingsSheet.swift - Reader settings: this series, and how input behaves.

import SwiftUI

struct MangaReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-series layout and tap zones.
    let series: MangaSeriesSettings
    /// Volume keys, auto scroll, hold to scroll: these follow the user.
    @Binding var controls: MangaControlSettings
    /// Presentation detent controlling compact vs expanded sheet.
    @Binding var detent: PresentationDetent

    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptics.scrollEnabledKey) private var scrollHaptics = true
    @ObservedObject private var focusManager = FocusModeManager.shared

    static let compactDetent: PresentationDetent = .height(260)

    init(
        series: MangaSeriesSettings,
        controls: Binding<MangaControlSettings>,
        detent: Binding<PresentationDetent> = .constant(.large)
    ) {
        self.series = series
        self._controls = controls
        self._detent = detent
    }

    private var isExpanded: Bool {
        detent == .large
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reader Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isExpanded)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            VStack(spacing: 0) {
                // Sticky Reading Mode Visualizations at the top
                readingModeHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(Color(uiColor: .systemGroupedBackground))

                Form {
                    if series.resolved.readingMode == .pager {
                        directionSection
                    }
                    tapSection
                    if series.resolved.readingMode == .webtoon {
                        stripSection
                    }
                    volumeSection
                    if series.resolved.readingMode == .webtoon {
                        autoScrollSection
                        holdSection
                    }
                    hapticsSection
                    focusSection
                    scopeSection
                }
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 12) {
                readingModeHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Form {
                    Section {
                        useForAllToggle
                    } footer: {
                        Text("Apply this reading layout to every title in your library.")
                    }
                }
                .scrollDisabled(true)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .transition(.opacity)
        }
    }

    // MARK: - Top Mode Visualizations

    private var readingModeHeader: some View {
        HStack(spacing: 12) {
            ReadingModeCard(
                mode: .pager,
                isSelected: series.resolved.readingMode == .pager
            ) {
                withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                    series.setReadingMode(.pager)
                    if !series.hasOverrides {
                        series.makeDefault()
                    }
                }
            }

            ReadingModeCard(
                mode: .webtoon,
                isSelected: series.resolved.readingMode == .webtoon
            ) {
                withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                    series.setReadingMode(.webtoon)
                    if !series.hasOverrides {
                        series.makeDefault()
                    }
                }
            }
        }
    }

    // MARK: - Page Direction (Paged Mode)

    private var directionSection: some View {
        Section("Page Direction") {
            HStack(spacing: 12) {
                directionCard(
                    title: "Left to Right",
                    subtitle: "Standard order (1 → 2)",
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
                    subtitle: "Manga format (2 ← 1)",
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
        }
    }

    private func directionCard(
        title: String,
        subtitle: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.controlFill : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tap Zones

    private var tapSection: some View {
        Section("Navigation & Tap Zones") {
            TapZoneVisualizer(
                layout: series.resolved.tapZones,
                inverted: series.resolved.invertTapZones
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            Picker("Tap layout", selection: Binding(
                get: { series.resolved.tapZones },
                set: {
                    series.setTapZones($0)
                    if !series.hasOverrides { series.makeDefault() }
                }
            )) {
                ForEach(MangaTapZoneLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }

            Toggle("Invert tap zones", isOn: Binding(
                get: { series.resolved.invertTapZones },
                set: {
                    series.setInvertTapZones($0)
                    if !series.hasOverrides { series.makeDefault() }
                }
            ))
            .tint(AppTheme.controlFill)
        }
    }

    // MARK: - Webtoon Strip

    private var stripSection: some View {
        Section("Webtoon Strip") {
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
        }
    }

    // MARK: - Hardware Buttons

    private var volumeSection: some View {
        Section("Hardware Buttons") {
            Toggle("Volume buttons turn pages", isOn: $controls.volumeKeys)
                .tint(AppTheme.controlFill)

            if controls.volumeKeys {
                Toggle("Invert volume buttons", isOn: $controls.volumeKeysInverted)
                    .tint(AppTheme.controlFill)
            }
        }
    }

    // MARK: - Auto Scroll

    private var autoScrollSection: some View {
        Section("Auto Scroll") {
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
        }
    }

    // MARK: - Hold to Scroll

    private var holdSection: some View {
        Section("Hold to Scroll") {
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
        }
    }

    // MARK: - Scrolling & Haptics

    private var hapticsSection: some View {
        Section {
            Toggle("Scroll haptics", isOn: $scrollHaptics)
                .tint(AppTheme.controlFill)
                .disabled(!hapticsEnabled)
                .onChange(of: scrollHaptics) { _, on in
                    if on { Haptics.shared.scroll(ScrollFeel.detent(speed: 800)) }
                }
        } header: {
            Text("Scrolling")
        } footer: {
            Text(hapticsEnabled
                ? "A soft swell as you scroll: rising as you read on, falling as you scroll back, "
                    + "and stronger the faster you flick. The master switch and strength live in "
                    + "Settings › General › Haptics."
                : "All vibration is off in Settings › General › Haptics.")
        }
    }

    // MARK: - Focus Integration

    private var focusSection: some View {
        Section {
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
            Text("Focus Integration")
        } footer: {
            Text("Show the active Focus mode near the top of the page while the controls are hidden.")
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
        Section("Settings Scope") {
            useForAllToggle

            if series.hasOverrides {
                Button("Reset this series to default", role: .destructive) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.reset()
                    }
                }
            }
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
                Label(title, systemImage: symbol)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - ReadingModeCard Component

struct ReadingModeCard: View {
    let mode: MangaReadingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Visualization graphic
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(height: 64)

                    if mode == .pager {
                        // Mini dual pages
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                                .frame(width: 32, height: 42)
                                .overlay(
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 18, height: 2)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 2)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 14, height: 2)
                                    }
                                )
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                                .frame(width: 32, height: 42)
                                .overlay(
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 20, height: 2)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 16, height: 2)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 2)
                                    }
                                )
                        }
                    } else {
                        // Mini vertical scrolling strip
                        VStack(spacing: 3) {
                            Image(systemName: "chevron.compact.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.6))

                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                    .frame(width: 44, height: 10)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                    .frame(width: 44, height: 10)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                    .frame(width: 44, height: 10)
                            }

                            Image(systemName: "chevron.compact.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                VStack(spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(mode == .pager ? "Horizontal pages" : "Continuous strip")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.controlFill : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TapZoneVisualizer Component

struct TapZoneVisualizer: View {
    let layout: MangaTapZoneLayout
    let inverted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            switch layout {
            case .standard:
                HStack(spacing: 2) {
                    zoneBox(inverted ? "Next" : "Prev", icon: inverted ? "chevron.right" : "chevron.left")
                    zoneBox("Menu", icon: "slider.horizontal.3", isMenu: true)
                    zoneBox(inverted ? "Prev" : "Next", icon: inverted ? "chevron.left" : "chevron.right")
                }
            case .lShaped:
                VStack(spacing: 2) {
                    zoneBox(inverted ? "Next" : "Prev", icon: inverted ? "chevron.up" : "chevron.left", height: 20)
                    HStack(spacing: 2) {
                        zoneBox(inverted ? "Next" : "Prev", icon: inverted ? "chevron.right" : "chevron.left")
                        zoneBox("Menu", icon: "slider.horizontal.3", isMenu: true)
                        zoneBox(inverted ? "Prev" : "Next", icon: inverted ? "chevron.left" : "chevron.right")
                    }
                    zoneBox(inverted ? "Prev" : "Next", icon: inverted ? "chevron.down" : "chevron.right", height: 20)
                }
            case .kindlish:
                VStack(spacing: 2) {
                    zoneBox("Menu", icon: "slider.horizontal.3", isMenu: true, height: 18)
                    HStack(spacing: 2) {
                        zoneBox(inverted ? "Next" : "Prev", icon: inverted ? "chevron.right" : "chevron.left")
                        zoneBox(inverted ? "Prev" : "Next", icon: inverted ? "chevron.left" : "chevron.right")
                    }
                }
            case .edge:
                HStack(spacing: 2) {
                    zoneBox(inverted ? "Next" : "Prev", icon: inverted ? "chevron.right" : "chevron.left", flex: 1)
                    zoneBox("Menu", icon: "slider.horizontal.3", isMenu: true, flex: 2.5)
                    zoneBox(inverted ? "Prev" : "Next", icon: inverted ? "chevron.left" : "chevron.right", flex: 1)
                }
            case .disabled:
                zoneBox("Menu Only (Taps do not turn pages)", icon: "hand.tap", isMenu: true)
            }
        }
        .frame(height: 72)
        .padding(.vertical, 4)
    }

    private func zoneBox(
        _ title: String,
        icon: String,
        isMenu: Bool = false,
        flex: CGFloat = 1,
        height: CGFloat? = nil
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(isMenu ? Color.secondary : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: height ?? .infinity)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isMenu ? Color.secondary.opacity(0.12) : Color(.secondarySystemFill))
        )
    }
}
