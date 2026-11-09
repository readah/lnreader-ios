// LibraryOptionsSheet.swift
// One sheet for everything that shapes the library: filter, sort and display.
//
// The confusing part was never the number of settings, it was that three of
// them have different scopes. Filters, sort and layout belong to the category
// on screen; "items per row" is shared with Browse; the default layout lives in
// Settings › General. Every control here now says which of those it is, and
// each tab has the same Reset affordance in the same place.

import SwiftUI

struct LibraryOptionsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case filter = "Filter", sort = "Sort", display = "Display"
        var id: String { rawValue }
    }

    @Binding var tab: Tab
    @Binding var filter: LibraryFilter
    @Binding var sort: LibrarySort
    @Binding var displayMode: DisplayMode
    let scopeName: String
    var hasSortOverride = false
    var hasDisplayOverride = false
    var onResetSort: () -> Void = {}
    var onResetDisplay: () -> Void = {}
    /// Dismisses the sheet and starts arranging; the host does it on dismiss.
    var onArrange: () -> Void = {}
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic
    @AppStorage("general.defaultDisplayMode") private var defaultDisplayMode: DisplayMode = .comfortable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Options", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                scopeCaption

                switch tab {
                case .filter: filterList
                case .sort: sortList
                case .display: displayList
                }
            }
            .navigationTitle("Library options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(resetLabel, action: resetCurrentTab)
                        .disabled(!canResetCurrentTab)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }

    /// "All" is a tab name, not a word that reads well in a sentence.
    private var scopeDescription: String {
        scopeName == "All" ? "the whole library" : scopeName
    }

    /// One line that answers "am I changing everything, or just this tab?".
    private var scopeCaption: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(tab == .display
                 ? "Layout for \(scopeDescription). Grid columns are shared."
                 : "Applies to \(scopeDescription).")
                .font(Typography.small)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var canResetCurrentTab: Bool {
        switch tab {
        case .filter: filter.isActive
        case .sort: hasSortOverride
        case .display: hasDisplayOverride
        }
    }

    /// "Reset" alone never said what it would reset once the sheet had tabs.
    private var resetLabel: String {
        switch tab {
        case .filter: "Reset filters"
        case .sort: "Reset sort"
        case .display: "Reset layout"
        }
    }

    private func resetCurrentTab() {
        switch tab {
        case .filter: filter = LibraryFilter()
        case .sort: onResetSort()
        case .display: onResetDisplay()
        }
    }

    // MARK: - Filter

    private var filterList: some View {
        List {
            Section {
                filterRow("Downloaded", noun: "downloaded", systemImage: "arrow.down.circle", state: $filter.downloaded)
                filterRow("Unread", noun: "unread", systemImage: "eye.slash", state: $filter.unread)
                filterRow("Started", noun: "started", systemImage: "book", state: $filter.started)
                filterRow("Completed", noun: "completed", systemImage: "checkmark.seal", state: $filter.completed)
                filterRow("Tracked", noun: "tracked", systemImage: "chart.bar", state: $filter.tracked)
            } header: {
                Text(filter.isActive
                     ? "\(filter.activeCount) \(filter.activeCount == 1 ? "filter" : "filters") active"
                     : "Showing everything")
            } footer: {
                Text("Only keeps books that match, Hide removes them. Filters apply to \(scopeDescription).")
            }
        }
    }

    /// A tri-state filter as a menu picker. The choices are full sentences so
    /// "Only" and "Hide" say what they refer to without guessing.
    private func filterRow(_ title: String, noun: String, systemImage: String, state: Binding<TriState>) -> some View {
        Picker(selection: state) {
            Text("Any").tag(TriState.off)
            Text("Only \(noun)").tag(TriState.include)
            Text("Hide \(noun)").tag(TriState.exclude)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .pickerStyle(.menu)
    }

    // MARK: - Sort

    private var sortList: some View {
        List {
            Section {
                ForEach(SortOrder.allCases) { order in
                    sortRow(order)
                }
            } header: {
                Text("Sort by")
            } footer: {
                Text("Kept for \(scopeDescription). Categories without their own sort follow Settings › General.")
            }

            if sort.order != .custom {
                Section {
                    Picker("Direction", selection: $sort.direction) {
                        Text(sort.order.directionLabels.ascending).tag(SortDirection.ascending)
                        Text(sort.order.directionLabels.descending).tag(SortDirection.descending)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Direction")
                }
            }

            if sort.order.supportsEmptyLast {
                Section {
                    Toggle("Empty ones last", isOn: $sort.emptyLast)
                } footer: {
                    Text("Books with a zero or missing value go to the end whichever way it sorts.")
                }
            }

            Section {
                Button("Arrange books", systemImage: "arrow.up.arrow.down", action: onArrange)
            } footer: {
                Text(sort.order == .custom
                     ? "Drag books into the order you want. Custom keeps that order."
                     : "Arranging gives \(scopeDescription) a manual order you can drag books into.")
            }
        }
    }

    /// Direction has its own control below. Tapping the selected criterion a
    /// second time used to flip it as well, which made the two compete.
    private func sortRow(_ order: SortOrder) -> some View {
        let selected = sort.order == order
        return Button {
            guard !selected else { return }
            sort.select(order)
        } label: {
            HStack {
                Label(order.displayName, systemImage: order.iconName)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    if order != .custom {
                        Image(systemName: sort.direction.isAscending ? "arrow.up" : "arrow.down")
                            .foregroundStyle(.tint)
                            .contentTransition(.symbolEffect(.replace))
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected && order != .custom
            ? (sort.direction.isAscending
                ? order.directionLabels.ascending : order.directionLabels.descending)
            : "")
    }

    // MARK: - Display

    private var displayList: some View {
        DisplayOptionsList(
            displayMode: $displayMode,
            columnCount: $columnCount,
            scopeName: scopeName,
            defaultDisplayMode: defaultDisplayMode,
            hasOverride: hasDisplayOverride
        )
    }
}

/// Layout and items per row. Library and Browse both show this, so the two
/// cannot drift. `scopeName == nil` means it edits the global default (Browse).
struct DisplayOptionsList: View {
    @Binding var displayMode: DisplayMode
    @Binding var columnCount: Int
    /// Non-nil when this list edits one category's override.
    var scopeName: String? = nil
    var defaultDisplayMode: DisplayMode = .comfortable
    var hasOverride = false

    var body: some View {
        List {
            Section {
                DisplayModePicker(selection: $displayMode)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Layout")
            } footer: {
                Text(scopeFooter)
            }

            if displayMode != .list {
                Section {
                    Picker("Items per row", selection: $columnCount) {
                        Text("Auto").tag(LibraryGridColumns.automatic)
                        ForEach(LibraryGridColumns.range, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Grid")
                } footer: {
                    Text("Shared by every category and by Browse. Auto fits as many covers as the screen allows.")
                }
            }

            if scopeName != nil {
                Section {
                    LabeledContent("Layout", value: hasOverride ? "Custom for this view" : "Using the default")
                } footer: {
                    Text("Picking a layout gives this view its own. Reset layout returns it to the default (\(defaultDisplayMode.displayName)) from Settings › General.")
                }
            }
        }
    }

    private var scopeFooter: String {
        if scopeName != nil {
            return "Layout is saved per category. Other categories follow the default (\(defaultDisplayMode.displayName)) from Settings › General."
        }
        return "The default layout for the library and for every source in Browse. A category can override it in Library options."
    }
}

/// Four layouts as tiles. A bare inline picker of names ("Comfortable",
/// "Cover Only") never said what any of them actually looks like.
struct DisplayModePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: DisplayMode

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile(.compact)
                tile(.comfortable)
            }
            HStack(spacing: 8) {
                tile(.coverOnly)
                tile(.list)
            }
        }
    }

    private func tile(_ mode: DisplayMode) -> some View {
        let selected = selection == mode
        return Button {
            withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) { selection = mode }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.iconName)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(Typography.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(mode.detail)
                        .font(Typography.small)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            // Everything tappable reads as primary; only the metadata is grey.
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? AppTheme.accent.opacity(0.10) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? AppTheme.accent : AppTheme.hairline,
                            lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.displayName), \(mode.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
