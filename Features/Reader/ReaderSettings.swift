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
    @Binding var detent: PresentationDetent

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

    private var isExpanded: Bool {
        isEmbedded || detent != .medium
    }

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
        self._detent = detent

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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if isEmbedded {
            mainContent
                .onDisappear {
                    commitChanges()
                }
        } else {
            NavigationStack {
                mainContent
                    .navigationTitle("Reader Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                commitChanges()
                                dismiss()
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
            .onDisappear { commitChanges() }
        }
    }

    private var mainContent: some View {
        content
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isExpanded)
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

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            VStack(spacing: 0) {
                // Pinned Preview at the top
                pinnedPreview
                
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
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                themesGrid
                Spacer()
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settingsBackground)
            .transition(.opacity)
        }
    }

    private var themesGrid: some View {
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(presets) { preset in
                ThemePickerCard(
                    preset: preset,
                    isSelected: isSelected(preset)
                ) {
                    localBackgroundColorHex = preset.bg
                    localTextColorHex = preset.text
                    commitChanges()
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
        } footer: {
            Text("Show the active Focus mode (moon, work, sleep) near the top of the reader area.")
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
            Text(hapticsEnabled
                ? "A soft swell as the page moves: rising as you read on, falling as you scroll "
                    + "back, and stronger the faster you flick. The master switch and strength "
                    + "live in Settings › General › Haptics."
                : "All vibration is off in Settings › General › Haptics.")
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
        let sample = "The quick brown fox jumps over the lazy dog. This preview shows how text appears with your current settings."
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

    private var pinnedPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12)
            
            Text(previewAttributedText)
                .font(localFontFamily == "System" ? .system(size: localFontSize) : .custom(localFontFamily, size: localFontSize))
                .lineSpacing((localLineHeight - 1.0) * localFontSize)
                .tracking(localCharacterSpacing * 0.1)
                .padding(.horizontal, localHorizontalPadding)
                .padding(.vertical, localVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(resolvedLocalTextColor)
                .background(
                    resolvedLocalBackgroundColor
                        .overlay {
                            if localGrainIntensity > 0 {
                                NoiseView(intensity: localGrainIntensity)
                                    .allowsHitTesting(false)
                            }
                        }
                )
                .overlay {
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
                .frame(height: 165, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transaction { $0.animation = nil }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
        }
        .background(settingsBackground)
    }

    private var settingsBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    // MARK: - Helpers

    private func isSelected(_ preset: PresetTheme) -> Bool {
        return localBackgroundColorHex == preset.bg && localTextColorHex == preset.text
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
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(preset.bg.isEmpty ? Color(.secondarySystemBackground) : (Color(hex: preset.bg) ?? Color(.secondarySystemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: ReaderAppearance.highlightHex(background: preset.bg)) ?? .primary, lineWidth: isSelected ? 3 : 0)
            )
            .overlay(
                Group {
                    if preset.isPremium {
                        Text("*")
                            .font(.system(size: 20, weight: .bold))
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
