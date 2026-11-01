// LibraryOptionsSheet.swift
// One sheet for everything that shapes the library: filter, sort and display.
// It stays open while you adjust, so a multi-part sort (criterion, direction,
// empties) is one visit rather than three trips through a dropdown.

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
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Options", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch tab {
                case .filter: filterList
                case .sort: sortList
                case .display: displayList
                }
            }
            .navigationTitle(scopeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if tab == .filter {
                        Button("Reset") { filter = LibraryFilter() }
                            .disabled(!filter.isActive)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }

    // MARK: - Filter

    private var filterList: some View {
        List {
            Section {
                filterRow("Downloaded", systemImage: "arrow.down.circle", state: $filter.downloaded)
                filterRow("Unread", systemImage: "eye.slash", state: $filter.unread)
                filterRow("Started", systemImage: "book", state: $filter.started)
                filterRow("Completed", systemImage: "checkmark.seal", state: $filter.completed)
                filterRow("Tracked", systemImage: "chart.bar", state: $filter.tracked)
            } footer: {
                Text("Filters apply to \(scopeName) only. Only keeps books that match, Hide removes them.")
            }
        }
    }

    /// A tri-state filter as a menu picker: any, only these, or none of these.
    private func filterRow(_ title: String, systemImage: String, state: Binding<TriState>) -> some View {
        Picker(selection: state) {
            Text("Any").tag(TriState.off)
            Text("Only").tag(TriState.include)
            Text("Hide").tag(TriState.exclude)
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
                Text(sort.order == .custom
                     ? "Custom keeps the order you drag books into."
                     : "Tap the selected criterion again to flip its direction.")
            }

            if sort.order != .custom {
                Section("Direction") {
                    Picker("Direction", selection: $sort.direction) {
                        Text(sort.order.directionLabels.ascending).tag(SortDirection.ascending)
                        Text(sort.order.directionLabels.descending).tag(SortDirection.descending)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if sort.order.supportsEmptyLast {
                Section {
                    Toggle("Empty ones last", isOn: $sort.emptyLast)
                } footer: {
                    Text("Books with a zero or missing value go to the end whichever way it sorts.")
                }
            }

            if hasSortOverride {
                Section {
                    Button("Use default sort", systemImage: "arrow.uturn.backward", action: onResetSort)
                }
            }
        }
    }

    private func sortRow(_ order: SortOrder) -> some View {
        let selected = sort.order == order
        return Button {
            if selected {
                if order != .custom { sort.direction.toggle() }
            } else {
                sort.select(order)
            }
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
            footer: "Applies to every category. Auto fits as many covers as the screen allows.",
            hasOverride: hasDisplayOverride,
            onReset: onResetDisplay
        )
    }
}

/// Layout and items per row. Library and Browse both show this, so the two cannot drift.
struct DisplayOptionsList: View {
    @Binding var displayMode: DisplayMode
    @Binding var columnCount: Int
    var footer: String
    var hasOverride = false
    var onReset: () -> Void = {}

    var body: some View {
        List {
            Section {
                Picker("Layout", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if displayMode != .list {
                Section {
                    Picker("Items per row", selection: $columnCount) {
                        Text("Auto").tag(LibraryGridColumns.automatic)
                        ForEach(LibraryGridColumns.range, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(footer)
                }
            }
            if hasOverride {
                Section {
                    Button("Use default display", systemImage: "arrow.uturn.backward", action: onReset)
                }
            }
        }
    }
}
