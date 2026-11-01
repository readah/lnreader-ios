// MangaReaderSettingsSheet.swift - Reader settings: this series, and how input behaves.

import SwiftUI

struct MangaReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-series layout and tap zones.
    let series: MangaSeriesSettings
    /// Volume keys, auto scroll, hold to scroll: these follow the user.
    @Binding var controls: MangaControlSettings
    /// Presentation detent controlling half vs expanded sheet.
    @Binding var detent: PresentationDetent

    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptics.scrollEnabledKey) private var scrollHaptics = true
    @ObservedObject private var focusManager = FocusModeManager.shared

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
        detent != .medium
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reader settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .tint(AppTheme.controlFill)
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
            VStack(spacing: 16) {
                readingModeHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

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
        Section {
            HStack(spacing: 12) {
                directionCard(
                    title: "Left to Right",
                    subtitle: "Standard order (1 → 2)",
                    icon: "arrow.right.circle.fill",
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
                    icon: "arrow.left.circle.fill",
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
            Label("Page Direction", systemImage: "arrow.left.and.right")
        } footer: {
            Text("Right-to-left advances pages backward for Japanese tankōbon.")
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
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tap Zones

    private var tapSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("TAP REGIONS PREVIEW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                TapZoneVisualizer(
                    layout: series.resolved.tapZones,
                    inverted: series.resolved.invertTapZones
                )
            }
            .padding(.vertical, 4)

            Picker(selection: Binding(
                get: { series.resolved.tapZones },
                set: {
                    series.setTapZones($0)
                    if !series.hasOverrides { series.makeDefault() }
                }
            )) {
                ForEach(MangaTapZoneLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            } label: {
                HStack(spacing: 12) {
                    optionIcon("hand.tap.fill", color: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tap layout")
                        Text(series.resolved.tapZones.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { series.resolved.invertTapZones },
                set: {
                    series.setInvertTapZones($0)
                    if !series.hasOverrides { series.makeDefault() }
                }
            )) {
                HStack(spacing: 12) {
                    optionIcon("arrow.left.arrow.right.square.fill", color: .indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invert tap zones")
                        Text("Swaps advance and previous tap areas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Navigation & Tap Zones", systemImage: "hand.tap")
        } footer: {
            Text("In paged mode taps flip pages; in webtoon mode they scroll by screen height.")
        }
    }

    // MARK: - Webtoon Strip

    private var stripSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    optionIcon("rectangle.portrait.split.2x1.fill", color: .cyan)
                    Text("Strip width")
                    Spacer()
                    Text("\(Int((controls.stripWidth * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $controls.stripWidth, in: MangaControlSettings.stripWidthRange, step: 0.05)
            }
            .padding(.vertical, 2)

            Picker(selection: $controls.momentum) {
                ForEach(WebtoonMomentum.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                HStack(spacing: 12) {
                    optionIcon("wind", color: .cyan)
                    Text("Scroll momentum")
                }
            }
        } header: {
            Label("Webtoon Strip", systemImage: "rectangle.portrait.fill")
        } footer: {
            Text("A narrower strip leaves still margins on both sides for relaxed reading.")
        }
    }

    // MARK: - Volume Keys

    private var volumeSection: some View {
        Section {
            Toggle(isOn: $controls.volumeKeys) {
                HStack(spacing: 12) {
                    optionIcon("speaker.wave.2.circle.fill", color: .teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume buttons turn pages")
                        Text("Use hardware volume keys for hands-free navigation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if controls.volumeKeys {
                Toggle(isOn: $controls.volumeKeysInverted) {
                    HStack(spacing: 12) {
                        optionIcon("arrow.up.and.down.circle.fill", color: .teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Invert volume buttons")
                            Text("Volume up advances, volume down goes back")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Label("Hardware Buttons", systemImage: "button.vertical.right.press")
        } footer: {
            Text("While the reader is open, media volume is anchored and restored upon leaving.")
        }
    }

    // MARK: - Auto Scroll

    private var autoScrollSection: some View {
        Section {
            Picker(selection: $controls.autoScrollStyle) {
                ForEach(AutoScrollStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            } label: {
                HStack(spacing: 12) {
                    optionIcon("gauge.with.needle", color: .green)
                    Text("Scroll style")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    optionIcon("play.circle.fill", color: .green)
                    Text(controls.autoScrollStyle == .stepped ? "Pace" : "Speed")
                    Spacer()
                    Text("\(Int(controls.autoScrollSpeed)) pt/s")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Slider(
                        value: $controls.autoScrollSpeed,
                        in: MangaControlSettings.autoSpeedRange,
                        step: 5
                    )

                    Image(systemName: "hare.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Auto Scroll", systemImage: "play.circle")
        } footer: {
            Text("Webtoon mode. Touching the screen pauses scrolling."
                + (controls.autoScrollStyle == .stepped ? " The strip stays still while you read, then smoothly steps a screen." : ""))
        }
    }

    // MARK: - Hold to Scroll

    private var holdSection: some View {
        Section {
            Toggle(isOn: $controls.holdScrollEnabled) {
                HStack(spacing: 12) {
                    optionIcon("hand.draw.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to scroll")
                        Text("Press and hold the screen to scroll continuously")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if controls.holdScrollEnabled {
                speedSlider(
                    "Base speed",
                    icon: "speedometer",
                    value: $controls.hold.baseSpeed,
                    range: HoldScrollConfig.baseRange
                )

                speedSlider(
                    "Min speed",
                    icon: "tortoise",
                    value: $controls.hold.minSpeed,
                    range: 10...600
                )

                speedSlider(
                    "Max speed",
                    icon: "hare",
                    value: $controls.hold.maxSpeed,
                    range: 100...3000
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        optionIcon("arrow.up.and.down.and.sparkles", color: .orange)
                        Text("Drag sensitivity")
                        Spacer()
                        Text(String(format: "%.1f pt/s per pt", controls.hold.speedPerPoint))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $controls.hold.speedPerPoint, in: HoldScrollConfig.stepRange, step: 0.1)
                }
                .padding(.vertical, 2)

                Picker(selection: $controls.hold.upIncreases) {
                    Text("Swipe Up").tag(true)
                    Text("Swipe Down").tag(false)
                } label: {
                    HStack(spacing: 12) {
                        optionIcon("arrow.up.and.down", color: .orange)
                        Text("Faster when swiping")
                    }
                }
            }
        } header: {
            Label("Hold to Scroll", systemImage: "hand.draw")
        } footer: {
            Text("Hold a finger down to scroll; drag up or down while holding to dynamically alter scroll velocity.")
        }
    }

    private var hapticsSection: some View {
        Section {
            Toggle(isOn: $scrollHaptics) {
                HStack(spacing: 12) {
                    optionIcon("iphone.radiowaves.left.and.right", color: .purple)
                    Text("Scroll haptics")
                }
            }
            .disabled(!hapticsEnabled)
            .onChange(of: scrollHaptics) { _, on in
                if on { Haptics.shared.scroll(ScrollFeel.detent(speed: 800)) }
            }
        } header: {
            Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
        } footer: {
            Text(hapticsEnabled
                ? "A soft swell as you scroll: rising as you read on, falling as you scroll back, and stronger the faster you flick. The master switch and strength live in Settings › General › Haptics."
                : "All vibration is off in Settings › General › Haptics.")
        }
    }

    private var focusSection: some View {
        Section {
            Picker(selection: focusOverride) {
                Text("Off").tag("none")
                Text("System auto").tag("auto")
                Text("Do Not Disturb").tag("dnd")
                Text("Work Focus").tag("work")
                Text("Sleep Focus").tag("sleep")
            } label: {
                HStack(spacing: 12) {
                    optionIcon("moon.fill", color: .indigo)
                    Text("Active Focus display")
                }
            }
            .pickerStyle(.menu)

            if focusManager.overrideType == "auto" {
                FocusStatusRow(focusManager: focusManager)
            }
        } header: {
            Label("Focus Integration", systemImage: "moon.fill")
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
        Section {
            useForAllToggle

            if series.hasOverrides {
                Button(role: .destructive) {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        series.reset()
                    }
                } label: {
                    HStack(spacing: 12) {
                        optionIcon("arrow.uturn.backward.circle.fill", color: .red)
                        Text("Reset this series to default")
                    }
                }
            }
        } header: {
            Label("Settings Scope", systemImage: "gearshape.2")
        } footer: {
            Text(series.hasOverrides
                ? "This series has custom overrides active."
                : "This series is following app-wide defaults.")
        }
    }

    // MARK: - Reusable Components

    private var useForAllToggle: some View {
        Toggle(isOn: Binding(
            get: { !series.hasOverrides },
            set: { applyToAll in
                withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                    if applyToAll {
                        series.makeDefault()
                    } else {
                        // Lock in current preferences as this series' override
                        series.setReadingMode(series.resolved.readingMode)
                        series.setDirection(series.resolved.direction)
                        series.setTapZones(series.resolved.tapZones)
                        series.setInvertTapZones(series.resolved.invertTapZones)
                    }
                }
            }
        )) {
            HStack(spacing: 12) {
                optionIcon("square.stack.3d.up.fill", color: .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use for all series")
                        .font(.system(size: 15, weight: .medium))
                    Text("Apply this layout across all manga and webtoons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func speedSlider(
        _ title: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                optionIcon(icon, color: .orange)
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt/s")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 10)
        }
        .padding(.vertical, 2)
    }

    private func optionIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - ReadingModeCard Component

struct ReadingModeCard: View {
    let mode: MangaReadingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                // Visualization graphic
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                        .frame(height: 72)

                    if mode == .pager {
                        // Paged mode visualization: Two pages side-by-side with swipe arrows
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(.systemBackground)))
                                .frame(width: 32, height: 44)
                                .overlay(
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 18, height: 2.5)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 2.5)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 14, height: 2.5)
                                    }
                                    .padding(4)
                                )

                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(.systemBackground)))
                                .frame(width: 32, height: 44)
                                .overlay(
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 2.5)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 16, height: 2.5)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.3)).frame(width: 20, height: 2.5)
                                    }
                                    .padding(4)
                                )
                        }
                    } else {
                        // Webtoon mode visualization: Vertical continuous strip with scroll arrows
                        VStack(spacing: 3) {
                            Image(systemName: "chevron.compact.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                            VStack(spacing: 2.5) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemBackground)))
                                    .frame(width: 44, height: 12)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemBackground)))
                                    .frame(width: 44, height: 12)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.systemBackground)))
                                    .frame(width: 44, height: 12)
                            }

                            Image(systemName: "chevron.compact.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(mode.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(mode == .pager ? "Horizontal pages" : "Continuous strip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: isSelected ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
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
                .fill(isMenu ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.14))
        )
    }
}
