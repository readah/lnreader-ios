// LibraryOptionsSheet.swift
// One sheet for everything that shapes the library: filter, sort and display.
//
// Each tab is only its controls. The per-category scope is carried by the
// bindings the host passes in, so the sheet does not restate it on every tab.

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
    var hasSortOverride = false
    var hasDisplayOverride = false
    var onResetSort: () -> Void = {}
    var onResetDisplay: () -> Void = {}
    @Environment(\.appDismiss) private var dismiss

    var body: some View {
        AppNavigationStack {
            VStack(spacing: 0) {
                AppSlidingPicker(
                    title: "Options",
                    selection: $tab,
                    options: Tab.allCases
                ) { tab in
                    tab.rawValue
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                switch tab {
                case .filter: filterList
                case .sort: sortList
                case .display: displayList
                }
            }
            .appNavigationTitle("Library options")
            .navigationBarTitleDisplayMode(.inline)
            .appToolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Reset", role: .destructive, action: resetCurrentTab)
                        .disabled(!canResetCurrentTab)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }

    private var canResetCurrentTab: Bool {
        switch tab {
        case .filter: filter.isActive
        case .sort: hasSortOverride
        case .display: hasDisplayOverride
        }
    }

    private var resetLabel: String {
        "Reset"
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
        AppForm {
            Section {
                filterRow("Downloaded", noun: "downloaded", systemImage: "arrow.down.circle", state: $filter.downloaded)
                filterRow("Unread", noun: "unread", systemImage: "eye.slash", state: $filter.unread)
                filterRow("Started", noun: "started", systemImage: "book", state: $filter.started)
                filterRow("Completed", noun: "completed", systemImage: "checkmark.seal", state: $filter.completed)
                filterRow("Tracked", noun: "tracked", systemImage: "chart.bar", state: $filter.tracked)
            } header: {
                HStack(spacing: 6) {
                    Text(filter.isActive
                         ? "\(filter.activeCount) \(filter.activeCount == 1 ? "filter" : "filters") active"
                         : "Showing everything")
                    InfoButton(text: "Only keeps books that match, Hide removes them.")
                }
            }
        }
    }

    /// A tri-state filter as a menu picker. The choices are full sentences so
    /// "Only" and "Hide" say what they refer to without guessing.
    private func filterRow(_ title: String, noun: String, systemImage: String, state: Binding<TriState>) -> some View {
        AppPicker(selection: state) {
            Text("Any").tag(TriState.off)
            Text("Only \(noun)").tag(TriState.include)
            Text("Hide \(noun)").tag(TriState.exclude)
        } label: {
            AppLabel(title, systemName: systemImage, size: 17, relativeTo: .body)
        }
        .appPickerStyle(.menu)
        .tint(AppTheme.accent)
    }

    // MARK: - Sort

    private var sortList: some View {
        AppForm {
            Section {
                ForEach(SortOrder.allCases) { order in
                    sortRow(order)
                }
            } header: {
                SettingsSectionHeader(
                    title: "Sort by",
                    info: "Kept per category. Categories without their own sort follow Settings › General."
                )
            }

            Section {
                AppPicker("Direction", selection: $sort.direction) {
                    Text(sort.order.directionLabels.ascending).tag(SortDirection.ascending)
                    Text(sort.order.directionLabels.descending).tag(SortDirection.descending)
                }
                .appPickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if sort.order.supportsEmptyLast {
                Section {
                    Toggle("Empty ones last", isOn: $sort.emptyLast)
                } header: {
                    SettingsSectionHeader(
                        title: "Empty values",
                        info: "Books with a zero or missing value go to the end whichever way it sorts."
                    )
                }
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
                AppLabel(order.displayName, systemName: order.iconName, size: 17, relativeTo: .body)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: sort.direction.isAscending ? "arrow.up" : "arrow.down")
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected
            ? (sort.direction.isAscending
                ? order.directionLabels.ascending : order.directionLabels.descending)
            : "")
    }

    // MARK: - Display

    private var displayList: some View {
        DisplayOptionsList(displayMode: $displayMode)
    }
}

/// Layout and items per row. Library and Browse both show this, so the two
/// cannot drift.
struct DisplayOptionsList: View {
    @Binding var displayMode: DisplayMode
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic

    var body: some View {
        AppForm {
            Section {
                DisplayModePicker(selection: $displayMode)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            } header: {
                SettingsSectionHeader(
                    title: "Layout",
                    info: "The default layout for the library and for every source in Browse."
                )
            }

            if displayMode != .list {
                Section {
                    AppPicker("Items per row", selection: $columnCount) {
                        Text("Auto").tag(LibraryGridColumns.automatic)
                        ForEach(LibraryGridColumns.range, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .appPickerStyle(.menu)
                    .tint(AppTheme.accent)
                } header: {
                    SettingsSectionHeader(
                        title: "Grid",
                        info: "Shared by every category and by Browse. Auto fits as many covers as the screen allows."
                    )
                }
            }
        }
    }
}

/// Four layouts as tiles. A bare inline picker of names ("Comfortable",
/// "Cover Only") never said what any of them actually looks like.
struct DisplayModePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noLiquidGlass) private var classic
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
                AppIcon(systemName: mode.iconName, size: 20, relativeTo: .title3)
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
            .foregroundStyle(.primary.opacity(!classic || selected ? 1 : 0.55))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(!classic && selected ? AppTheme.accent.opacity(0.10) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(!classic && selected ? AppTheme.accent : AppTheme.hairline,
                            lineWidth: !classic && selected ? 1.5 : 0.5)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityLabel("\(mode.displayName), \(mode.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
