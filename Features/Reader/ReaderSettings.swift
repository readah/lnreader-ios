// ReaderSettings.swift
// Settings sheet for reader typography and layout customization.

import SwiftUI

struct ReaderSettings: View {
    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var fontFamily: String
    @Binding var horizontalPadding: Double
    @Binding var verticalPadding: Double
    @Binding var backgroundColorHex: String
    @Binding var textColorHex: String
    @Binding var bionicReading: Bool
    @Binding var lineFocusEnabled: Bool
    @Binding var lineFocusLines: Int
    @Binding var lineFocusDulling: String
    @Binding var characterSpacing: Double
    @Binding var wordSpacing: Double
    @Binding var grainIntensity: Double
    let isEmbedded: Bool

    @State private var localFontSize: Double
    @State private var localLineHeight: Double
    @State private var localHorizontalPadding: Double
    @State private var localVerticalPadding: Double
    @State private var localCharacterSpacing: Double
    @State private var localWordSpacing: Double
    @State private var localMargins: Double
    @State private var localFontFamily: String
    @State private var localBackgroundColorHex: String
    @State private var localTextColorHex: String
    @State private var localBionicReading: Bool
    @State private var localLineFocusEnabled: Bool
    @State private var localLineFocusLines: Int
    @State private var localLineFocusDulling: String
    @State private var localGrainIntensity: Double
    @State private var localFocusOverride: String
    
    @AppStorage("reader.justifyText") private var justifyText = true
    @AppStorage("reader.keepScreenOn") private var keepScreenOn = true
    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptics.scrollEnabledKey) private var scrollHaptics = true
    @ObservedObject private var focusManager = FocusModeManager.shared

    static let compactDetent: PresentationDetent = .height(420)

    /// The full settings sheet, opened by Customize.
    @State private var showCustomize = false
    /// What things looked like when Customize opened, so its ✕ can put them
    /// back. Every other control commits as it is used.
    @State private var draft: Draft?

    init(
        fontSize: Binding<Double>,
        lineHeight: Binding<Double>,
        fontFamily: Binding<String>,
        horizontalPadding: Binding<Double>,
        verticalPadding: Binding<Double>,
        backgroundColorHex: Binding<String>,
        textColorHex: Binding<String>,
        bionicReading: Binding<Bool>,
        lineFocusEnabled: Binding<Bool>,
        lineFocusLines: Binding<Int>,
        lineFocusDulling: Binding<String>,
        characterSpacing: Binding<Double>,
        wordSpacing: Binding<Double>,
        grainIntensity: Binding<Double>,
        isEmbedded: Bool = false,
        detent: Binding<PresentationDetent> = .constant(.large)
    ) {
        self._fontSize = fontSize
        self._lineHeight = lineHeight
        self._fontFamily = fontFamily
        self._horizontalPadding = horizontalPadding
        self._verticalPadding = verticalPadding
        self._backgroundColorHex = backgroundColorHex
        self._textColorHex = textColorHex
        self._bionicReading = bionicReading
        self._lineFocusEnabled = lineFocusEnabled
        self._lineFocusLines = lineFocusLines
        self._lineFocusDulling = lineFocusDulling
        self._characterSpacing = characterSpacing
        self._wordSpacing = wordSpacing
        self._grainIntensity = grainIntensity
        self.isEmbedded = isEmbedded

        self._localFontSize = State(initialValue: fontSize.wrappedValue)
        self._localLineHeight = State(initialValue: lineHeight.wrappedValue)
        self._localHorizontalPadding = State(initialValue: horizontalPadding.wrappedValue)
        self._localVerticalPadding = State(initialValue: verticalPadding.wrappedValue)
        self._localCharacterSpacing = State(initialValue: characterSpacing.wrappedValue)
        self._localWordSpacing = State(initialValue: wordSpacing.wrappedValue)
        self._localFontFamily = State(initialValue: fontFamily.wrappedValue)
        self._localBackgroundColorHex = State(initialValue: backgroundColorHex.wrappedValue)
        self._localTextColorHex = State(initialValue: textColorHex.wrappedValue)
        self._localBionicReading = State(initialValue: bionicReading.wrappedValue)
        self._localLineFocusEnabled = State(initialValue: lineFocusEnabled.wrappedValue)
        self._localLineFocusLines = State(initialValue: lineFocusLines.wrappedValue)
        self._localLineFocusDulling = State(initialValue: lineFocusDulling.wrappedValue)
        self._localGrainIntensity = State(initialValue: grainIntensity.wrappedValue)
        self._localFocusOverride = State(initialValue: FocusModeManager.shared.overrideType)
        
        let paddingVal = horizontalPadding.wrappedValue
        self._localMargins = State(initialValue: (paddingVal / 48.0) * 100.0)
    }

    private let fontFamilies = [
        "Georgia", "Palatino", "Times New Roman",
        "System", "Helvetica Neue", "Avenir",
        "Charter", "Iowan Old Style", "Open-Dyslexic",
    ]

    struct PresetTheme: Identifiable {
        var id: String { name }
        let name: String
        let bg: String
        let text: String
        let isBold: Bool
        let isSerif: Bool
        let isPremium: Bool
    }

    private let presets: [PresetTheme] = [
        PresetTheme(name: "Original", bg: "", text: "", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Quiet", bg: "#0A0A0C", text: "#BDBBC5", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Paper", bg: "#1C1C1E", text: "#E5E5EA", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Bold", bg: "#000000", text: "#FFFFFF", isBold: true, isSerif: false, isPremium: false),
        PresetTheme(name: "Calm", bg: "#362E26", text: "#EADBCC", isBold: false, isSerif: true, isPremium: false),
        PresetTheme(name: "Focus", bg: "#1C1B16", text: "#E6DEC9", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Daylight", bg: "#FFFFFF", text: "#24282E", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Ivory", bg: "#F8F3E8", text: "#39352E", isBold: false, isSerif: true, isPremium: false),
        PresetTheme(name: "Sepia", bg: "#F5E6CE", text: "#514030", isBold: false, isSerif: true, isPremium: false),
        PresetTheme(name: "Sage", bg: "#E6EDE5", text: "#293C32", isBold: false, isSerif: true, isPremium: false),
        PresetTheme(name: "Dusk", bg: "#242135", text: "#E0DAEA", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Midnight", bg: "#101827", text: "#D6E0EE", isBold: false, isSerif: false, isPremium: false),
        PresetTheme(name: "Forest", bg: "#15241F", text: "#D6E6DD", isBold: false, isSerif: true, isPremium: false)
    ]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader.highlightColor") private var highlightColorHex = ""
    @AppStorage("reader.highlightOpacity") private var highlightOpacity = 0.26
    /// The brightness slider. ReaderView reads the same key for its veil.
    @AppStorage(ReaderDim.key) private var dimLevel = 0.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if isEmbedded {
            mainContent
                .onDisappear {
                    commitChanges()
                }
        } else {
            VStack(spacing: 0) {
                ReaderSheetHeader(title: "Themes & Settings") {
                    commitChanges()
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                compactControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settingsBackground)
            .onDisappear { commitChanges() }
            .sheet(isPresented: $showCustomize) { customizeSheet }
        }
    }

    private var mainContent: some View {
        expandedContent
            .onChange(of: localFontSize) { _, _ in commitIfEmbedded() }
            .onChange(of: localLineHeight) { _, _ in commitIfEmbedded() }
            .onChange(of: localFontFamily) { _, _ in commitIfEmbedded() }
            .onChange(of: localHorizontalPadding) { _, _ in commitIfEmbedded() }
            .onChange(of: localVerticalPadding) { _, _ in commitIfEmbedded() }
            .onChange(of: localBackgroundColorHex) { _, _ in commitIfEmbedded() }
            .onChange(of: localTextColorHex) { _, _ in commitIfEmbedded() }
            .onChange(of: localBionicReading) { _, _ in commitIfEmbedded() }
            .onChange(of: localLineFocusEnabled) { _, _ in commitIfEmbedded() }
            .onChange(of: localLineFocusLines) { _, _ in commitIfEmbedded() }
            .onChange(of: localLineFocusDulling) { _, _ in commitIfEmbedded() }
            .onChange(of: localCharacterSpacing) { _, _ in commitIfEmbedded() }
            .onChange(of: localWordSpacing) { _, _ in commitIfEmbedded() }
            .onChange(of: localGrainIntensity) { _, _ in commitIfEmbedded() }
    }

    // MARK: - Half Sheet

    /// The half sheet, laid out like the system reader's themes sheet: quick
    /// text controls, a brightness slider, the themes, then one button that
    /// opens everything else. The reader behind the sheet is the preview, so
    /// every change commits as it is made.
    private var compactControls: some View {
        VStack(spacing: 0) {
            fontSizeRow
                .padding(.horizontal, 16)
                .padding(.top, 14)

            brightnessRow
                .padding(.horizontal, 16)
                .padding(.top, 16)

            compactThemeGrid
                .padding(.horizontal, 16)
                .padding(.top, 18)

            SheetActionButton(title: "Customize", systemImage: "gearshape") {
                draft = makeDraft()
                showCustomize = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    /// `A` small and `A` large either side of a hairline, in one glass capsule:
    /// the same stepper the system reader puts above the themes.
    private var fontSizeRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                fontSizeStep(15, delta: -1)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 22)
                    .accessibilityHidden(true)
                fontSizeStep(21, delta: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: GlassMetrics.side)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)

            HStack(spacing: 0) {
                GlassToggleSegment(symbol: "text.justify", label: "Justify text", isOn: justifyText) {
                    justifyText.toggle()
                }
                GlassToggleSegment(symbol: "bold", label: "Bionic reading", isOn: localBionicReading) {
                    localBionicReading.toggle()
                    commitChanges()
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)
        }
    }

    private func fontSizeStep(_ size: CGFloat, delta: Double) -> some View {
        Button {
            localFontSize = min(max(localFontSize + delta, 12), 32)
            commitChanges()
        } label: {
            Text("A")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: GlassMetrics.side)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta > 0 ? "Larger text" : "Smaller text")
    }

    /// Dims the page behind the sheet, so the slider shows its effect while it
    /// is being dragged.
    private var brightnessRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: $dimLevel, in: 0...1)
                .tint(.primary)
                .accessibilityLabel("Brightness")

            Image(systemName: "sun.max")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// Six themes in two rows. The rest live behind Customize: thirteen cards
    /// will not fit on a half sheet, and these six are the ones people switch
    /// between while reading.
    private var compactThemeGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(presets.prefix(6)) { preset in
                ThemePickerCard(
                    preset: preset,
                    isSelected: isSelected(preset),
                    height: 80,
                    showsSelectedMark: true
                ) {
                    selectTheme(preset)
                }
            }
        }
    }

    // MARK: - Full Sheet

    /// The live preview above the settings, used by the embedded screen.
    private var expandedContent: some View {
        VStack(spacing: 0) {
            previewBlock
            settingsForm
        }
    }

    // MARK: - Customize

    /// Customize opens its own sheet rather than growing the half sheet: the
    /// preview on the theme's paper at the top, everything else underneath, and
    /// a check that keeps what you changed. The ✕ puts it all back.
    private var customizeSheet: some View {
        VStack(spacing: 0) {
            ReaderSheetHeader(
                title: "Customize Theme",
                foreground: resolvedLocalTextColor,
                onClose: { finishCustomize(keep: false) },
                onConfirm: { finishCustomize(keep: true) }
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(resolvedLocalBackgroundColor)

            previewBlock

            settingsForm
        }
        .background(settingsBackground)
        // Swiping the sheet away keeps what you changed, like the check does.
        // Only the ✕ puts it back.
        .onDisappear { commitChanges() }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
    }

    /// What the sheet looked like when Customize opened.
    private struct Draft {
        var fontSize: Double
        var lineHeight: Double
        var fontFamily: String
        var horizontalPadding: Double
        var verticalPadding: Double
        var background: String
        var text: String
        var bionic: Bool
        var lineFocus: Bool
        var lineFocusLines: Int
        var lineFocusDulling: String
        var characterSpacing: Double
        var wordSpacing: Double
        var grain: Double
        var focus: String
    }

    private func makeDraft() -> Draft {
        Draft(
            fontSize: localFontSize,
            lineHeight: localLineHeight,
            fontFamily: localFontFamily,
            horizontalPadding: localHorizontalPadding,
            verticalPadding: localVerticalPadding,
            background: localBackgroundColorHex,
            text: localTextColorHex,
            bionic: localBionicReading,
            lineFocus: localLineFocusEnabled,
            lineFocusLines: localLineFocusLines,
            lineFocusDulling: localLineFocusDulling,
            characterSpacing: localCharacterSpacing,
            wordSpacing: localWordSpacing,
            grain: localGrainIntensity,
            focus: localFocusOverride
        )
    }

    private func finishCustomize(keep: Bool) {
        if !keep, let draft {
            localFontSize = draft.fontSize
            localLineHeight = draft.lineHeight
            localFontFamily = draft.fontFamily
            localHorizontalPadding = draft.horizontalPadding
            localVerticalPadding = draft.verticalPadding
            localBackgroundColorHex = draft.background
            localTextColorHex = draft.text
            localBionicReading = draft.bionic
            localLineFocusEnabled = draft.lineFocus
            localLineFocusLines = draft.lineFocusLines
            localLineFocusDulling = draft.lineFocusDulling
            localCharacterSpacing = draft.characterSpacing
            localWordSpacing = draft.wordSpacing
            localGrainIntensity = draft.grain
            localFocusOverride = draft.focus
            localMargins = (draft.horizontalPadding / 48.0) * 100.0
        }
        commitChanges()
        self.draft = nil
        showCustomize = false
    }

    /// The settings the half sheet leaves out.
    private var settingsForm: some View {
        Form {
            Section("Theme & Colors") {
                themesGrid
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                Toggle("Paper texture", isOn: Binding(get: { localGrainIntensity > 0 }, set: { localGrainIntensity = $0 ? 10 : 0 }))
                    .tint(AppTheme.controlFill)
                if localGrainIntensity > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GRAIN INTENSITY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                                .frame(width: 24)

                            Slider(value: $localGrainIntensity, in: 0...100, step: 5)
                                .tint(.primary)

                            Text("\(Int(localGrainIntensity))%")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ColorPicker("Word highlight", selection: Binding(
                    get: { Color(hex: ReaderAppearance.highlightHex(background: localBackgroundColorHex, custom: highlightColorHex)) ?? .green },
                    set: { if let hex = $0.toHex() { highlightColorHex = hex } }
                ), supportsOpacity: false)
                if !highlightColorHex.isEmpty {
                    Button("Use theme highlight") { highlightColorHex = "" }
                }
                HStack {
                    Text("Highlight strength")
                    Slider(value: $highlightOpacity, in: 0.1...0.65, step: 0.05)
                }
            }

            Section("Spacing & Margins") {
                groupedLayoutSection
            }

            typographySection
            moreLayoutSection
            lineFocusSection
            focusSection
            scrollingSection
        }
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: localLineFocusEnabled)
    }

    private var themesGrid: some View {
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(presets) { preset in
                ThemePickerCard(
                    preset: preset,
                    isSelected: isSelected(preset)
                ) {
                    selectTheme(preset)
                }
                .frame(width: 108)
                .accessibilityAddTraits(isSelected(preset) ? .isSelected : [])
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 4)
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .padding(.vertical, 4)
    }

    private var groupedLayoutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // LINE SPACING
            VStack(alignment: .leading, spacing: 6) {
                Text("LINE SPACING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    
                    Slider(value: $localLineHeight, in: 1.0...2.5, step: 0.05)
                        .tint(.primary)
                    
                    Text(String(format: "%.2f", localLineHeight))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            
            Divider()
                .background(Color.secondary.opacity(0.2))
            
            // CHARACTER SPACING
            VStack(alignment: .leading, spacing: 6) {
                Text("CHARACTER SPACING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    
                    Slider(value: $localCharacterSpacing, in: -5...30, step: 1)
                        .tint(.primary)
                    
                    Text("\(Int(localCharacterSpacing))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            
            Divider()
                .background(Color.secondary.opacity(0.2))
            
            // WORD SPACING
            VStack(alignment: .leading, spacing: 6) {
                Text("WORD SPACING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    
                    Slider(value: $localWordSpacing, in: 0...50, step: 2)
                        .tint(.primary)
                    
                    Text("\(Int(localWordSpacing))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            
            Divider()
                .background(Color.secondary.opacity(0.2))
            
            // MARGINS
            VStack(alignment: .leading, spacing: 6) {
                Text("MARGINS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Image(systemName: "square")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    
                    Slider(value: $localMargins, in: 0...100, step: 5)
                        .tint(.primary)
                        .onChange(of: localMargins) { _, newValue in
                            localHorizontalPadding = (newValue / 100.0) * 48.0
                        }
                    
                    Text("\(Int(localMargins))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var typographySection: some View {
        Section("Typography") {
            Picker("Font", selection: $localFontFamily) {
                ForEach(fontFamilies, id: \.self) { font in
                    Text(font)
                        .font(.custom(font, size: 15))
                        .tag(font)
                }
            }

            VStack(alignment: .leading) {
                Text("Font Size: \(Int(localFontSize))px")
                    .font(Typography.caption)
                Slider(value: $localFontSize, in: 12...32, step: 1)
                    .tint(.primary)
            }
        }
    }

    private var moreLayoutSection: some View {
        Section("Custom Layout & Colors") {
            VStack(alignment: .leading) {
                Text("Vertical Padding: \(Int(localVerticalPadding))px")
                    .font(Typography.caption)
                Slider(value: $localVerticalPadding, in: 0...80, step: 4)
                    .tint(.primary)
            }
            
            Toggle("Bionic Reading", isOn: $localBionicReading).tint(AppTheme.controlFill)
            Toggle("Justify Text", isOn: $justifyText).tint(AppTheme.controlFill)
            Toggle("Keep Screen On", isOn: $keepScreenOn).tint(AppTheme.controlFill)
            
            ColorPicker("Custom Background", selection: customBgColorBinding)
            ColorPicker("Custom Text Color", selection: customTextColorBinding)
        }
    }

    private var focusSection: some View {
        Section {
            Picker("Active Focus display", selection: $localFocusOverride) {
                Text("Off").tag("none")
                Text("System auto").tag("auto")
                Text("Do Not Disturb").tag("dnd")
                Text("Work Focus").tag("work")
                Text("Sleep Focus").tag("sleep")
            }
            .pickerStyle(.menu)

            if localFocusOverride == "auto" {
                FocusStatusRow(focusManager: focusManager)
            }
        } header: {
            Text("Focus Integration")
        }
    }

    private var scrollingSection: some View {
        Section {
            Toggle("Scroll haptics", isOn: $scrollHaptics)
                .tint(AppTheme.controlFill)
                .disabled(!hapticsEnabled)
                .onChange(of: scrollHaptics) { _, on in
                    // Switching it on plays one tick, so the feel is right there.
                    if on { Haptics.shared.scroll(ScrollFeel.detent(speed: 800)) }
                }
        } header: {
            Text("Scrolling")
        } footer: {
            if !hapticsEnabled { Text("Vibration is off in Settings › General › Haptics.") }
        }
    }

    private var lineFocusSection: some View {
        Section("Line Focus") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Line Focus Mode", isOn: $localLineFocusEnabled.animation(AppMotion.gentle(reduceMotion: reduceMotion))).tint(AppTheme.controlFill)
                
                if localLineFocusEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Focused Lines")
                                .font(Typography.caption)
                                .foregroundColor(.secondary)
                            Picker("Focused Lines", selection: $localLineFocusLines) {
                                Text("1 Line").tag(1)
                                Text("2 Lines").tag(2)
                                Text("3 Lines").tag(3)
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Background Dulling")
                                .font(Typography.caption)
                                .foregroundColor(.secondary)
                            Picker("Background Dulling", selection: $localLineFocusDulling) {
                                Text("Low").tag("low")
                                Text("Medium").tag("mid")
                                Text("High").tag("high")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func resolvedLineFocusOpacity(dulling: String) -> Double {
        switch dulling {
        case "low": return 0.3
        case "high": return 0.75
        default: return 0.5
        }
    }

    private var previewAttributedText: AttributedString {
        let highlightColor = (Color(hex: ReaderAppearance.highlightHex(background: localBackgroundColorHex, custom: highlightColorHex)) ?? .green).opacity(highlightOpacity)
        let passage = "The quick brown fox jumps over the lazy dog. This preview shows how "
            + "your text will look: the shape of the letters, the space between the lines, "
            + "and the width of the margins. Change something and watch it move."
        // Twice, so the block is full at every size and the overflow is clipped
        // at the fold the way the system reader's preview is.
        let sample = passage + " " + passage
        let highlightedWord = "brown"
        
        var result = AttributedString()
        let words = sample.components(separatedBy: " ")
        
        for (index, word) in words.enumerated() {
            if index > 0 {
                result.append(AttributedString(" "))
            }
            
            let isHighlighted = (word.lowercased() == highlightedWord)
            
            if localBionicReading {
                let len = word.count
                let boldLen = len <= 3 ? (len == 3 ? 2 : 1) : Int(ceil(Double(len) * 0.5))
                let boldPart = String(word.prefix(boldLen))
                let normalPart = String(word.dropFirst(boldLen))
                
                var boldAttr = AttributedString(boldPart)
                boldAttr.inlinePresentationIntent = .stronglyEmphasized
                if isHighlighted {
                    boldAttr.backgroundColor = highlightColor
                }
                result.append(boldAttr)
                
                if !normalPart.isEmpty {
                    var normalAttr = AttributedString(normalPart)
                    if isHighlighted {
                        normalAttr.backgroundColor = highlightColor
                    }
                    result.append(normalAttr)
                }
            } else {
                var wordAttr = AttributedString(word)
                if isHighlighted {
                    wordAttr.backgroundColor = highlightColor
                }
                result.append(wordAttr)
            }
        }
        
        return result
    }

    /// The live preview, drawn the way the system reader draws it: a big sample
    /// letter, then real text in the chosen face, on the theme's own paper,
    /// running off the bottom edge instead of sitting in a card.
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aa")
                .font(sampleFont(46))
                .foregroundStyle(resolvedLocalTextColor.opacity(0.4))
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Text(previewAttributedText)
                .font(sampleFont(localFontSize))
                .lineSpacing((localLineHeight - 1.0) * localFontSize)
                .tracking(localCharacterSpacing * 0.1)
                .foregroundStyle(resolvedLocalTextColor)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay { lineFocusVeil }
                .padding(.horizontal, 20)
                .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 330, alignment: .top)
        .background(paper)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of your reading text")
    }

    private var paper: some View {
        resolvedLocalBackgroundColor
            .overlay {
                if localGrainIntensity > 0 {
                    NoiseView(intensity: localGrainIntensity)
                        .allowsHitTesting(false)
                }
            }
    }

    private func sampleFont(_ size: Double) -> Font {
        localFontFamily == "System" ? .system(size: size) : .custom(localFontFamily, size: size)
    }

    @ViewBuilder
    private var lineFocusVeil: some View {
        if localLineFocusEnabled {
            let focusHeight = (Double(localLineFocusLines) + 0.2) * localLineHeight * localFontSize
            let opacity = resolvedLineFocusOpacity(dulling: localLineFocusDulling)

            VStack(spacing: 0) {
                Color.black.opacity(opacity)

                Color.clear
                    .frame(height: focusHeight)
                    .overlay(
                        VStack {
                            Divider().background(Color.secondary.opacity(0.4))
                            Spacer()
                            Divider().background(Color.secondary.opacity(0.4))
                        }
                    )

                Color.black.opacity(opacity)
            }
            .allowsHitTesting(false)
        }
    }

    private var settingsBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private func isSelected(_ preset: PresetTheme) -> Bool {
        return localBackgroundColorHex == preset.bg && localTextColorHex == preset.text
    }

    /// Themes apply the moment they are tapped: the reader is visible behind
    /// the half sheet, so it doubles as the preview.
    private func selectTheme(_ preset: PresetTheme) {
        localBackgroundColorHex = preset.bg
        localTextColorHex = preset.text
        commitChanges()
    }

    private var resolvedLocalBackgroundColor: Color {
        if localBackgroundColorHex.isEmpty {
            return Color(light: Color(hue: 0.10, saturation: 0.08, brightness: 0.98),
                         dark: Color(hue: 0.10, saturation: 0.05, brightness: 0.12))
        }
        return Color(hex: localBackgroundColorHex) ?? .white
    }

    private var resolvedLocalTextColor: Color {
        if localTextColorHex.isEmpty {
            return Color(light: Color(hue: 0.0, saturation: 0.0, brightness: 0.12),
                         dark: Color(hue: 0.0, saturation: 0.0, brightness: 0.90))
        }
        return Color(hex: localTextColorHex) ?? .black
    }

    private var customBgColorBinding: Binding<Color> {
        Binding(
            get: {
                if let color = Color(hex: localBackgroundColorHex) {
                    return color
                }
                return .white
            },
            set: { newColor in
                if let hex = newColor.toHex() {
                    localBackgroundColorHex = hex
                    commitIfEmbedded()
                }
            }
        )
    }

    private var customTextColorBinding: Binding<Color> {
        Binding(
            get: {
                if let color = Color(hex: localTextColorHex) {
                    return color
                }
                return .black
            },
            set: { newColor in
                if let hex = newColor.toHex() {
                    localTextColorHex = hex
                    commitIfEmbedded()
                }
            }
        )
    }

    private func commitChanges() {
        fontSize = localFontSize
        lineHeight = localLineHeight
        fontFamily = localFontFamily
        horizontalPadding = localHorizontalPadding
        verticalPadding = localVerticalPadding
        backgroundColorHex = localBackgroundColorHex
        textColorHex = localTextColorHex
        bionicReading = localBionicReading
        lineFocusEnabled = localLineFocusEnabled
        lineFocusLines = localLineFocusLines
        lineFocusDulling = localLineFocusDulling
        characterSpacing = localCharacterSpacing
        wordSpacing = localWordSpacing
        grainIntensity = localGrainIntensity
        FocusModeManager.shared.overrideType = localFocusOverride
        FocusModeManager.shared.updateFocusStatus()
    }

    private func commitIfEmbedded() {
        if isEmbedded {
            commitChanges()
        }
    }
}

// MARK: - ThemePickerCard Component

struct ThemePickerCard: View {
    let preset: ReaderSettings.PresetTheme
    let isSelected: Bool
    var height: CGFloat = 80
    /// Shows the little asterisk on the chosen theme, the way the system
    /// reader marks the one you are on.
    var showsSelectedMark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 28, weight: preset.isBold ? .bold : .regular, design: preset.isSerif ? .serif : .default))
                    .foregroundColor(preset.text.isEmpty ? .primary : (Color(hex: preset.text) ?? .primary))

                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(preset.text.isEmpty ? .secondary : (Color(hex: preset.text) ?? .secondary))
                    .opacity(preset.text.isEmpty ? 1.0 : 0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(preset.bg.isEmpty ? Color(.secondarySystemBackground) : (Color(hex: preset.bg) ?? Color(.secondarySystemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.85), lineWidth: isSelected ? 2.5 : 0)
            )
            .overlay(
                Group {
                    if isSelected && showsSelectedMark {
                        Text("*")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(preset.text.isEmpty ? .secondary : (Color(hex: preset.text) ?? .secondary))
                            .opacity(0.6)
                            .padding([.top, .trailing], 8)
                    }
                },
                alignment: .topTrailing
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NoiseView for Preview Paper Texture

struct NoiseView: View {
    let intensity: Double

    var body: some View {
        if let tile = ReaderAppearance.paperTile {
            Image(decorative: tile, scale: 1)
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(min(1, max(0, intensity / 100)))
                .accessibilityHidden(true)
        }
    }
}
