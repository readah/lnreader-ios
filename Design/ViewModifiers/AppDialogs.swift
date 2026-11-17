import SwiftUI
import UIKit

extension View {
    func appConfirmationDialog<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder message: @escaping () -> Message) -> some View {
        modifier(AppDialogModifier(title: title, isPresented: isPresented, titleVisibility: titleVisibility, isAlert: false, actions: actions, message: message))
    }
    func appConfirmationDialog<Actions: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        appConfirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility, actions: actions) { EmptyView() }
    }
    func appAlert<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder message: @escaping () -> Message) -> some View {
        modifier(AppDialogModifier(title: title, isPresented: isPresented, titleVisibility: .visible, isAlert: true, actions: actions, message: message))
    }
    func appAlert<Actions: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        appAlert(title, isPresented: isPresented, actions: actions) { EmptyView() }
    }
    func appAlert<Data, Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, presenting data: Data?, @ViewBuilder actions: @escaping (Data) -> Actions, @ViewBuilder message: @escaping (Data) -> Message) -> some View {
        appAlert(title, isPresented: isPresented) {
            if let data { actions(data) }
        } message: {
            if let data { message(data) }
        }
    }
    func appContextMenu<Items: View>(@ViewBuilder menuItems: @escaping () -> Items) -> some View {
        modifier(AppContextMenuModifier(hasPreview: false, items: menuItems, preview: { EmptyView() }))
    }
    func appContextMenu<Items: View, Preview: View>(@ViewBuilder menuItems: @escaping () -> Items, @ViewBuilder preview: @escaping () -> Preview) -> some View {
        modifier(AppContextMenuModifier(hasPreview: true, items: menuItems, preview: preview))
    }
    func appInteractiveDismissDisabled(_ disabled: Bool = true) -> some View {
        modifier(AppDismissDisabledModifier(disabled: disabled))
    }
}

private struct AppDialogModifier<Actions: View, Message: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let title: String
    @Binding var isPresented: Bool
    let titleVisibility: Visibility
    let isAlert: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var message: () -> Message
    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: !classic && isAlert ? $isPresented : .constant(false), actions: actions, message: message)
            .confirmationDialog(title, isPresented: !classic && !isAlert ? $isPresented : .constant(false), titleVisibility: titleVisibility, actions: actions, message: message)
            .appSheet(isPresented: classic ? $isPresented : .constant(false)) {
                ClassicPopup(title: Text(title)) {
                    message().font(Typography.body).foregroundStyle(.secondary).padding(.bottom, 8)
                    actions()
                }
            }
    }
}
private struct AppContextMenuModifier<Items: View, Preview: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @State private var presented = false
    let hasPreview: Bool
    @ViewBuilder var items: () -> Items
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    Haptics.shared.impact(.medium)
                    presented = true
                })
                .accessibilityAction(named: Text("Quick actions")) { presented = true }
                .appSheet(isPresented: $presented) {
                    ClassicPopup {
                        preview().frame(maxHeight: 160).clipped()
                        items()
                    }
                }
        } else if hasPreview {
            content.contextMenu(menuItems: items, preview: preview)
        } else {
            content.contextMenu(menuItems: items)
        }
    }
}
struct AppDismissDisabledKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
private struct AppDismissDisabledModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let disabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.preference(key: AppDismissDisabledKey.self, value: disabled) }
        else { content.interactiveDismissDisabled(disabled) }
    }
}

/// App-owned colour and date editors, avoiding the system's glass popovers.
struct AppColorPicker: View {
    let title: String
    let supportsOpacity: Bool
    @Binding var selection: Color
    @Environment(\.noLiquidGlass) private var classic
    @State private var presented = false
    var body: some View {
        Group {
            if classic {
                Button { presented = true } label: {
                    HStack {
                        Text(title)
                        Spacer()
                        Circle().fill(selection).frame(width: 28, height: 28)
                            .overlay { Circle().strokeBorder(AppTheme.hairline, lineWidth: 1) }
                    }.foregroundStyle(.primary).frame(minHeight: 44)
                }.buttonStyle(AppPlainButtonStyle())
            } else { ColorPicker(title, selection: $selection, supportsOpacity: supportsOpacity) }
        }
        .appSheet(isPresented: $presented) { ClassicColorEditor(title: title, selection: $selection, supportsOpacity: supportsOpacity) }
    }
    init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.title = title; _selection = selection; self.supportsOpacity = supportsOpacity
    }
}
private struct ClassicColorEditor: View {
    let title: String
    @Binding var selection: Color
    let supportsOpacity: Bool
    @State private var red = 0.0
    @State private var green = 0.0
    @State private var blue = 0.0
    @State private var alpha = 1.0
    var body: some View {
        ClassicPopup(title: Text(title)) {
            RoundedRectangle(cornerRadius: 20).fill(selection).frame(height: 64)
            channel("Red", value: $red)
            channel("Green", value: $green)
            channel("Blue", value: $blue)
            if supportsOpacity { channel("Opacity", value: $alpha) }
        }
        .onAppear {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            UIColor(selection).getRed(&r, green: &g, blue: &b, alpha: &a)
            red = Double(r); green = Double(g); blue = Double(b); alpha = Double(a)
        }
        .onChange(of: red) { update() }
        .onChange(of: green) { update() }
        .onChange(of: blue) { update() }
        .onChange(of: alpha) { update() }
    }
    private func channel(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typography.caption)
            AppSlider(value: value).accessibilityLabel(title)
        }
    }
    private func update() { selection = Color(.sRGB, red: red, green: green, blue: blue, opacity: supportsOpacity ? alpha : 1) }
}

struct AppDatePicker: View {
    let title: String
    @Binding var selection: Date
    let displayedComponents: DatePickerComponents
    @Environment(\.noLiquidGlass) private var classic
    @State private var presented = false
    init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents) {
        self.title = title; _selection = selection; self.displayedComponents = displayedComponents
    }
    var body: some View {
        Group {
            if classic {
                Button { presented = true } label: {
                    HStack { Text(title); Spacer(); Text(selection, style: .date) }
                        .foregroundStyle(.primary).frame(minHeight: 44)
                }.buttonStyle(AppPlainButtonStyle())
            } else { DatePicker(title, selection: $selection, displayedComponents: displayedComponents) }
        }
        .appSheet(isPresented: $presented) {
            ClassicPopup(title: Text(title)) {
                datePart("Year", component: .year)
                datePart("Month", component: .month)
                datePart("Day", component: .day)
            }
        }
    }
    private func datePart(_ title: String, component: Calendar.Component) -> some View {
        HStack {
            Text(title); Spacer()
            Button { change(component, by: -1) } label: { AppIcon(systemName: "minus", size: 15) }
                .accessibilityLabel("Previous \(title.lowercased())")
            Text(Calendar.current.component(component, from: selection), format: .number.grouping(.never)).monospacedDigit().frame(minWidth: 44)
            Button { change(component, by: 1) } label: { AppIcon(systemName: "plus", size: 15) }
                .accessibilityLabel("Next \(title.lowercased())")
        }.buttonStyle(ClassicChromeButtonStyle())
    }

    private func change(_ component: Calendar.Component, by amount: Int) {
        if let date = Calendar.current.date(byAdding: component, value: amount, to: selection) { selection = date }
    }
}
