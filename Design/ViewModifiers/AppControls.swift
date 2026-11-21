import SwiftUI

/// Settings share the same cards in a full screen and in a classic sheet.
/// Data-heavy lists keep List's reuse and editing behavior instead.
struct AppForm<Content: View>: View {
    @AppStorage(ChromeAppearance.systemFormsKey) private var systemForms = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        if systemForms {
            // Beta: a plain UIKit-backed grouped Form. No custom button style,
            // row insets, cards, press scale or form-row environment — this is
            // genuinely the system's form, not our rows in a different colour.
            Form { content() }
                .buttonStyle(.automatic)
                .environment(\.appFormRow, false)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(sections: content()) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.header.isEmpty {
                                section.header
                                    .font(Typography.caption)
                                    .padding(.horizontal, 14)
                            }
                            VStack(spacing: 0) {
                                ForEach(subviews: section.content) { row in
                                    if row.id != section.content.first?.id {
                                        Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
                                            .padding(.leading, 16)
                                    }
                                    row
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                }
                            }
                            .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 22), dense: true) }
                            if !section.footer.isEmpty {
                                section.footer.font(Typography.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .buttonStyle(AppFormButtonStyle())
            .environment(\.appFormRow, true)
        }
    }
}

private struct AppFormRowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var appFormRow: Bool {
        get { self[AppFormRowKey.self] }
        set { self[AppFormRowKey.self] = newValue }
    }
}

/// Buttons own their press feedback through `ButtonStyle.isPressed`. A row with
/// a Toggle, Picker or Stepper is not a button, so there is no gesture here:
/// observing touches on the row would steal the ScrollView's pan.
private struct AppFormButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .foregroundStyle(configuration.role == .destructive ? AppTheme.destructive : AppTheme.accent)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .appPressFeedback(configuration.isPressed)
    }
}

/// A small anchored menu instead of a full sheet. Glass mode uses a native
/// `Menu`, so classic mode gets the same scale of presentation: a frosted card
/// with press feedback and a checkmark on the chosen row. The reveal modifier
/// gives it the app's spring/unblur arrival when that preference is on.
private struct AppCompactMenuPopover<Popup: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var popup: () -> Popup

    func body(content: Content) -> some View {
        // No fixed arrow edge: UIKit flips the popover below the anchor when
        // the control sits near the top of the screen (e.g. a detail header),
        // so it never opens off the top of the viewport.
        content.popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: nil) {
            popup()
                .classicReveal(scale: 0.93, offsetY: -6, blur: 6)
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }
}

extension View {
    func appCompactMenuPopover<Popup: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder popup: @escaping () -> Popup
    ) -> some View {
        modifier(AppCompactMenuPopover(isPresented: isPresented, popup: popup))
    }
}

private struct AppCompactRowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Compact popovers are already one frosted card; their rows must not add
    /// a second inset card the way sheet popups do.
    var appCompactRow: Bool {
        get { self[AppCompactRowKey.self] }
        set { self[AppCompactRowKey.self] = newValue }
    }
}

/// Shared menu-surface metrics. Kept non-generic so every caller can read them
/// without having to infer `AppPopupMenuSurface`'s `Content` parameter.
enum AppPopupMenuMetrics {
    /// The gutter between the surface edge and the rows, and the radius the
    /// rows must subtract from their own: `14 - 4 = 10`. A highlight concentric
    /// with the container is what makes it read as part of the card rather than
    /// a slightly-too-square box floating inside it.
    static let cornerRadius: CGFloat = 14
    static let rowInset: CGFloat = 4
    static let rowCornerRadius: CGFloat = cornerRadius - rowInset
}

struct AppPopupMenuSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2, content: content)
                .padding(AppPopupMenuMetrics.rowInset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 264)
        .frame(maxHeight: 400, alignment: .leading)
        // Clip the scrolling content to the corner radius before the surface
        // draws behind it, so the popover's shadow is not clipped away too.
        .clipShape(RoundedRectangle(cornerRadius: AppPopupMenuMetrics.cornerRadius, style: .continuous))
        .background {
            ClassicSurface(
                shape: RoundedRectangle(cornerRadius: AppPopupMenuMetrics.cornerRadius, style: .continuous),
                elevation: .popover
            )
        }
        .environment(\.appCompactRow, true)
    }
}

/// Hairline between an optional menu title and the rows below it.
struct AppPopupMenuDivider: View {
    var body: some View {
        Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

struct AppMenu<Label: View, Content: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    @Environment(\.appPopupDismiss) private var parentPopup
    @State private var presented = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        Group {
            if classic {
                if parentPopup != nil {
                    Button { presented = true } label: {
                        HStack { label(); Spacer(); AppIcon(systemName: "chevron.right", size: 13) }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .padding(.horizontal, 14)
                            .background(AppTheme.surface.opacity(0.4), in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(AppPlainButtonStyle())
                    .appSheet(isPresented: $presented) { ClassicPopup(content: content) }
                } else {
                    Button { presented = true } label: {
                        label().contentShape(.rect)
                    }
                    .appCompactMenuPopover(isPresented: $presented) {
                        AppPopupMenuSurface { content() }
                            .buttonStyle(ClassicPopupButtonStyle())
                            .environment(\.appPopupDismiss, { presented = false })
                    }
                }
            } else {
                Menu(content: content, label: label)
            }
        }
    }
}
extension AppMenu where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.label = { Text(title) }
    }
}

enum AppPickerStyle { case automatic, segmented, menu, wheel, inline, navigationLink }
private struct AppPickerStyleKey: EnvironmentKey { static let defaultValue = AppPickerStyle.automatic }
extension EnvironmentValues {
    var appPickerStyle: AppPickerStyle {
        get { self[AppPickerStyleKey.self] }
        set { self[AppPickerStyleKey.self] = newValue }
    }
}
extension View {
    func appPickerStyle(_ style: AppPickerStyle) -> some View { environment(\.appPickerStyle, style) }
}

struct AppPicker<Selection: Hashable, Content: View, Label: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    @Environment(\.appPickerStyle) private var style
    @Environment(\.appPopupDismiss) private var closePopup
    @Binding var selection: Selection
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    @State private var presented = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        Group {
            if classic {
                if style == .segmented {
                    choices(segmented: true)
                        .padding(4)
                        .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 20)) }
                } else if closePopup != nil || style == .inline || style == .wheel {
                    VStack(alignment: .leading, spacing: 6) {
                        label().font(Typography.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                        choices(segmented: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button { presented = true } label: {
                        HStack(spacing: 12) {
                            label()
                            Spacer(minLength: 8)
                            selectedLabel
                            AppIcon(systemName: "chevron.up.chevron.down", size: 12)
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(AppPlainButtonStyle())
                    .appCompactMenuPopover(isPresented: $presented) {
                        AppPopupMenuSurface {
                            label().font(Typography.navigationTitle).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
                            AppPopupMenuDivider()
                            choices(segmented: false)
                        }
                    }
                }
            } else {
                nativePicker
            }
        }
    }

    private var selectedLabel: some View {
        Group(subviews: content()) { subviews in
            ForEach(subviews) { subview in
                if subview.containerValues.tag(for: Selection.self) == selection {
                    subview.font(Typography.body.weight(.medium))
                }
            }
        }
    }

    private func choices(segmented: Bool) -> some View {
        Group(subviews: content()) { subviews in
            let layout = segmented ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            layout {
                ForEach(subviews) { subview in
                    if let value = subview.containerValues.tag(for: Selection.self) {
                        Button {
                            Haptics.shared.selection()
                            withAnimation(AppMotion.tabSwitch(reduceMotion: reduceMotion)) { selection = value }
                            if !segmented { presented = false; closePopup?() }
                        } label: {
                            HStack(spacing: 8) {
                                subview
                                if !segmented { Spacer(minLength: 8) }
                                if !segmented, selection == value {
                                    AppIcon(systemName: "checkmark", size: 14)
                                        .foregroundStyle(AppTheme.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .font(Typography.body.weight(selection == value ? .semibold : .regular))
                            .foregroundStyle(.primary.opacity(selection == value ? 1 : 0.55))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                            .background {
                                if !segmented && selection == value {
                                    // Concentric with the popover surface: the
                                    // container radius minus the row gutter.
                                    RoundedRectangle(
                                        cornerRadius: AppPopupMenuMetrics.rowCornerRadius,
                                        style: .continuous
                                    )
                                    .fill(.primary.opacity(0.10))
                                }
                                if segmented && selection == value {
                                    Capsule().fill(.primary.opacity(0.16))
                                        .overlay { Capsule().strokeBorder(AppTheme.hairline, lineWidth: 0.5) }
                                        .matchedGeometryEffect(id: "picker_selection", in: indicator)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(AppPlainButtonStyle())
                        .accessibilityAddTraits(selection == value ? .isSelected : [])
                    }
                }
            }
        }
    }

    @ViewBuilder private var nativePicker: some View {
        switch style {
        case .automatic: Picker(selection: $selection, content: content, label: label)
        case .segmented: Picker(selection: $selection, content: content, label: label).pickerStyle(.segmented)
        case .menu: Picker(selection: $selection, content: content, label: label).pickerStyle(.menu)
        case .inline: Picker(selection: $selection, content: content, label: label).pickerStyle(.inline)
        case .wheel: Picker(selection: $selection, content: content, label: label).pickerStyle(.wheel)
        case .navigationLink: Picker(selection: $selection, content: content, label: label).pickerStyle(.navigationLink)
        }
    }
}
extension AppPicker where Label == Text {
    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Content) {
        self._selection = selection
        self.content = content
        self.label = { Text(title) }
    }
}

/// The platform slider. An earlier hand-drawn track and thumb read as too
/// glossy, so this defers to `Slider` while keeping the same call API (the
/// `tint` chain, an optional `step`, an editing callback and a label).
struct AppSlider: View {
    var tintColor: Color?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void
    var label: Text

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
        self.label = Text(verbatim: "")
    }

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        label: () -> Text
    ) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = { _ in }
        self.label = label()
    }

    func tint(_ color: Color?) -> AppSlider {
        var copy = self
        copy.tintColor = color
        return copy
    }

    var body: some View {
        Group {
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged) {
                    label
                }
            } else {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged) {
                    label
                }
            }
        }
        .tint(tintColor)
    }
}

struct AppButtonToggleStyle: ToggleStyle {
    @Environment(\.noLiquidGlass) private var classic
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if classic {
            Button { configuration.isOn.toggle() } label: {
                configuration.label.opacity(configuration.isOn ? 1 : 0.55)
            }
                .buttonStyle(FrostedButtonStyle())
                .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        } else { Toggle(configuration).toggleStyle(.button) }
    }
}

struct ClassicToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @Environment(\.coverTint) private var coverTint

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Button {
                Haptics.shared.selection()
                withAnimation(ClassicMotion.micro(reduceMotion: reduceMotion)) {
                    configuration.isOn.toggle()
                }
            } label: {
                EmptyView()
            }
            .buttonStyle(
                ClassicSwitchButtonStyle(
                    isOn: configuration.isOn,
                    activeTint: coverTint ?? AppTheme.controlFill,
                    direction: direction,
                    reduceMotion: reduceMotion
                )
            )
            .accessibilityLabel(Text(configuration.isOn ? "On" : "Off"))
        }
        .opacity(enabled ? 1 : 0.4)
    }
}

/// The classic switch draws itself in a ButtonStyle so the knob can react to
/// `isPressed` without a competing gesture. The knob widens while held and the
/// value change slides it across the track on the same `classicMicro` spring.
/// Reduce Motion removes both animations.
private struct ClassicSwitchButtonStyle: ButtonStyle {
    let isOn: Bool
    let activeTint: Color
    let direction: LayoutDirection
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let trackWidth: CGFloat = 50
        let trackHeight: CGFloat = 30
        let knobHeight: CGFloat = 24
        let knobWidth: CGFloat = pressed && !reduceMotion ? 29 : 24
        let padding: CGFloat = 3
        let isDark = colorScheme == .dark

        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? activeTint : (isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)))
                .overlay {
                    Capsule()
                        .strokeBorder(
                            (isDark ? Color.white : Color.black).opacity(isOn ? 0.16 : 0.10),
                            lineWidth: 0.5
                        )
                }

            Capsule()
                .fill(Color.white)
                .frame(width: knobWidth, height: knobHeight)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                .padding(padding)
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Capsule())
        .animation(ClassicMotion.micro(reduceMotion: reduceMotion), value: isOn)
        .animation(ClassicMotion.micro(reduceMotion: reduceMotion), value: pressed)
    }
}

struct AppStepper<Value: Strideable, Label: View>: View where Value: Comparable, Value.Stride: SignedNumeric {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var value: Value
    let bounds: ClosedRange<Value>
    var step: Value.Stride = 1
    @ViewBuilder var label: () -> Label
    var body: some View {
        if classic {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Button { change(-step) } label: { AppIcon(systemName: "minus", size: 16).frame(width: 44, height: 44) }
                        .disabled(value <= bounds.lowerBound).accessibilityLabel("Decrease")
                    Rectangle().fill(AppTheme.hairline).frame(width: 0.5, height: 20)
                    Button { change(step) } label: { AppIcon(systemName: "plus", size: 16).frame(width: 44, height: 44) }
                        .disabled(value >= bounds.upperBound).accessibilityLabel("Increase")
                }
                .buttonStyle(AppPlainButtonStyle())
                .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 16)) }
            }
        } else { Stepper(value: $value, in: bounds, step: step, label: label) }
    }
    private func change(_ amount: Value.Stride) {
        Haptics.shared.selection()
        value = min(max(value.advanced(by: amount), bounds.lowerBound), bounds.upperBound)
    }
    init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1, @ViewBuilder label: @escaping () -> Label) {
        _value = value; self.bounds = bounds; self.step = step; self.label = label
    }
}
extension AppStepper where Label == Text {
    init(_ title: String, value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1) {
        _value = value; self.bounds = bounds; self.step = step; label = { Text(title) }
    }
}

private struct AppBorderedButtonModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    var prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.buttonStyle(FrostedButtonStyle(prominent: prominent)) }
        else if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}
extension View {
    func appBorderedButtonStyle(prominent: Bool = false) -> some View { modifier(AppBorderedButtonModifier(prominent: prominent)) }
    func appSearchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text = Text("Search")) -> some View {
        modifier(AppSearchModifier(text: text, placement: placement, prompt: prompt))
    }
    func appSearchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: String) -> some View {
        appSearchable(text: text, placement: placement, prompt: Text(prompt))
    }
}
private struct AppSearchModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var text: String
    let placement: SearchFieldPlacement
    let prompt: Text
    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content.safeAreaInset(edge: .top, spacing: 8) {
                HStack(spacing: 10) {
                    AppIcon(systemName: "magnifyingglass", size: 17)
                    TextField(text: $text, prompt: prompt) { prompt }
                        .textFieldStyle(.plain).submitLabel(.search)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !text.isEmpty {
                        Button {
                            Haptics.shared.selection()
                            text = ""
                        } label: {
                            AppIcon(systemName: "xmark.circle.fill", size: 17)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(AppPlainButtonStyle())
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16).frame(height: 46)
                .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 18)) }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
            }
        } else { content.searchable(text: $text, placement: placement, prompt: prompt) }
    }
}

/// An overlay, not a refresh-control inset: it cannot pin or resize the grid
/// while the independently owned update task publishes library changes.
/// Expandable bottom-bar search shared by Library, Browse and History.
/// Collapsed it is a trailing capsule; expanded it fills the inset and owns
/// its focus, with a 44pt clear and close target. Both states share one
/// geometry identity so the morph is smooth instead of a frame jump.
struct AppExpandableSearchBar: View {
    @Binding var text: String
    let prompt: String
    var onSearch: (() -> Void)? = nil
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    var body: some View {
        ZStack(alignment: .trailing) {
            if expanded {
                HStack(spacing: 0) {
                    AppIcon(systemName: "magnifyingglass", size: 17, relativeTo: .body)
                        .padding(.leading, 16)
                        .padding(.trailing, 10)
                        .accessibilityHidden(true)

                    TextField(prompt, text: $text)
                        .font(Typography.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .accessibilityLabel(prompt)
                        .onSubmit {
                            focused = false
                            onSearch?()
                        }

                    if !text.isEmpty {
                        Button {
                            Haptics.shared.selection()
                            text = ""
                            // Refocus after the window tap recognizer's turn.
                            DispatchQueue.main.async { focused = true }
                        } label: {
                            AppIcon(systemName: "xmark.circle.fill", size: 17, relativeTo: .body)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Clear search")
                    }

                    Button(action: collapse) {
                        AppIcon(systemName: "chevron.down", size: 17, relativeTo: .body)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Close search")
                    .accessibilityHint("Clears the search and shows the full list.")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 46)
                .appGlassEffect(.regular, in: .capsule)
                .matchedGeometryEffect(id: "expandableSearch", in: morph)
            } else {
                Button(action: expand) {
                    AppLabel(prompt, systemName: "magnifyingglass", size: 17, relativeTo: .body)
                        .font(Typography.body)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 46)
                }
                .accessibilityHint("Expands a search field to filter this screen.")
                .appGlassEffect(.regular, in: .capsule)
                .matchedGeometryEffect(id: "expandableSearch", in: morph)
            }
        }
        .buttonStyle(AppPlainButtonStyle())
        .foregroundStyle(.primary)
        .animation(AppMotion.glassMorph(reduceMotion: reduceMotion), value: expanded)
        .accessibilityAction(.escape, collapse)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The capsule and the field it becomes share one tap, and that tap also reaches the app's
    /// window-level keyboard-dismiss recognizer — it resigns whatever it finds focused. Taking
    /// focus on the next main-queue turn puts the request after that recognizer's turn, which is
    /// the same one the Clear button waits out, instead of racing it and losing the keyboard
    /// every so often.
    private func expand() {
        Haptics.shared.selection()
        withAnimation(AppMotion.glassMorph(reduceMotion: reduceMotion)) { expanded = true }
        DispatchQueue.main.async { focused = true }
    }

    private func collapse() {
        Haptics.shared.selection()
        withAnimation(AppMotion.glassMorph(reduceMotion: reduceMotion)) {
            text = ""
            focused = false
            expanded = false
        }
    }
}

private struct AppRefreshModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    let label: String
    let refresh: @MainActor () async -> Void
    @State private var pull = PullToRefreshState()
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, distance in
                pull.changed(distance: distance)
            }
            .onScrollPhaseChange { old, phase, context in
                let distance = max(0, -(context.geometry.contentOffset.y + context.geometry.contentInsets.top))
                if phase == .interacting {
                    pull.begin(enabled: enabled && !isRefreshing)
                    pull.changed(distance: distance)
                } else if old == .interacting, phase == .idle || phase == .decelerating {
                    if pull.end(distance: distance, enabled: enabled && !isRefreshing) { activate() }
                } else if phase == .idle || phase == .animating {
                    pull.cancel()
                }
            }
            .overlay(alignment: .top) { indicator }
            .onDisappear { refreshTask?.cancel() }
            .accessibilityAction(named: Text(label)) {
                activate()
            }
    }

    private var indicator: some View {
        ZStack {
            if pull.didRelease {
                ProgressView().controlSize(.small)
            } else {
                Circle().trim(from: 0, to: pull.progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 22)
                AppIcon(systemName: "arrow.down", size: 12)
                    .rotationEffect(.degrees(pull.progress >= 1 ? 180 : 0))
                    .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: pull.progress >= 1)
            }
        }
        .frame(width: 36, height: 36)
        .background { FrostedSurface(shape: Circle()) }
        .offset(y: min(pull.distance, 120) / 2 - 18)
        .opacity((pull.isPulling && enabled) || pull.didRelease ? min(1, max(0, (pull.distance - 4) / 24)) : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func activate() {
        guard enabled, !isRefreshing else { return }
        Haptics.shared.impact(.light)
        isRefreshing = true
        refreshTask = Task { @MainActor in
            defer { isRefreshing = false; refreshTask = nil }
            await refresh()
        }
    }
}

extension View {
    func appRefreshable(_ label: String = "Refresh", enabled: Bool = true, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(AppRefreshModifier(enabled: enabled, label: label, refresh: action))
    }
}
