// SourceFilterSheet.swift
// Renders a source's `SourceFilter` definitions as a form and edits a `FilterState`.
//
// The sheet works on a draft and only writes it back on Apply, so a half-edited
// form never triggers a reload.

import SwiftUI

/// What the sheet needs to show a remote list's age and refetch it.
struct FilterRefresh {
    let fetchedAt: Date?
    let isRefreshing: Bool
    let failed: Bool
    let action: () -> Void
}

struct SourceFilterSheet: View {
    let filters: [SourceFilter]
    let refresh: FilterRefresh?
    let onApply: (FilterState) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: FilterState

    init(
        filters: [SourceFilter], applied: FilterState, refresh: FilterRefresh? = nil,
        onApply: @escaping (FilterState) -> Void
    ) {
        self.filters = filters
        self.refresh = refresh
        self.onApply = onApply
        _draft = State(initialValue: applied)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Self.sections(from: filters)) { section in
                    Section {
                        ForEach(section.filters) { filter in
                            SourceFilterRow(filter: filter, state: $draft)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
                if let refresh { refreshSection(refresh) }
            }
            .appNavigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { draft = FilterState() }
                        .disabled(!draft.isModified(for: filters))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func refreshSection(_ refresh: FilterRefresh) -> some View {
        Section {
            Button {
                refresh.action()
            } label: {
                HStack {
                    Text("Refresh filter lists")
                    Spacer()
                    if refresh.isRefreshing { ProgressView() }
                }
            }
            .disabled(refresh.isRefreshing)
        } footer: {
            if refresh.failed {
                Text("Couldn't refresh. Showing the last saved lists.")
            } else if let fetchedAt = refresh.fetchedAt {
                Text("Lists updated \(fetchedAt, format: .relative(presentation: .named)).")
            }
        }
    }

    // MARK: Sections

    private struct FilterSection: Identifiable {
        let id: String
        var title: String?
        var filters: [SourceFilter]
    }

    /// Headers and groups start a new section; everything else joins the current one.
    private static func sections(from filters: [SourceFilter]) -> [FilterSection] {
        var result: [FilterSection] = []
        var current = FilterSection(id: "root", title: nil, filters: [])

        func flush() {
            if !current.filters.isEmpty { result.append(current) }
        }

        func visit(_ filters: [SourceFilter]) {
            for filter in filters {
                switch filter {
                case .header(let id, let name):
                    flush()
                    current = FilterSection(id: id, title: name, filters: [])
                case .separator:
                    continue
                case .group(let id, let name, let children):
                    flush()
                    current = FilterSection(id: id, title: name, filters: [])
                    visit(children)
                    flush()
                    current = FilterSection(id: "\(id)-after", title: nil, filters: [])
                default:
                    current.filters.append(filter)
                }
            }
        }

        visit(filters)
        flush()
        return result
    }
}

// MARK: - Row

/// One editable filter. Reads through `FilterState.value(for:)` so an untouched
/// filter shows its default, and writes only when the user changes it.
private struct SourceFilterRow: View {
    let filter: SourceFilter
    @Binding var state: FilterState

    /// Selects with more options than this open a lazy list instead of a menu.
    private static let menuLimit = 12

    var body: some View {
        switch filter {
        case .select(_, let name, let options, _):
            if options.count > Self.menuLimit {
                // A Picker builds every option up front; a List only builds what is on screen.
                NavigationLink {
                    FilterChoiceList(title: name, options: options, selection: optionBinding)
                } label: {
                    LabeledContent(name, value: options.first { $0.id == optionBinding.wrappedValue }?.name ?? "")
                }
            } else {
                Picker(name, selection: optionBinding) {
                    ForEach(options) { Text($0.name).tag($0.id) }
                }
            }

        case .text(_, let name, let hint, _):
            LabeledContent(name) {
                TextField(hint ?? "", text: textBinding)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

        case .checkbox(_, let name, _):
            Toggle(name, isOn: checkboxBinding)

        case .triState(_, let name):
            TriStateRow(name: name, mode: triStateMode) { mode in
                state[filter.id] = .triState(included: mode == .include, excluded: mode == .exclude)
            }

        case .multiSelect(_, let name, let options, _):
            NavigationLink {
                FilterOptionList(title: name, options: options, state: optionsBinding)
            } label: {
                LabeledContent(name, value: summary(selectedCount))
            }

        case .excludable(_, let name, let options, _, _):
            NavigationLink {
                FilterExcludableList(title: name, options: options, state: excludeBinding)
            } label: {
                LabeledContent(name, value: summary(excludeCount))
            }

        case .sort(_, let name, let options, _, _):
            SortRow(name: name, options: options, selection: sortBinding)

        case .header, .separator, .group:
            EmptyView()
        }
    }

    // MARK: Bindings

    private var optionBinding: Binding<String> {
        Binding {
            if case .option(let value)? = state.value(for: filter) { return value }
            return ""
        } set: { state[filter.id] = .option($0) }
    }

    private var textBinding: Binding<String> {
        Binding {
            if case .text(let value)? = state.value(for: filter) { return value }
            return ""
        } set: { state[filter.id] = .text($0) }
    }

    private var checkboxBinding: Binding<Bool> {
        Binding {
            if case .checkbox(let value)? = state.value(for: filter) { return value }
            return false
        } set: { state[filter.id] = .checkbox($0) }
    }

    private var optionsBinding: Binding<Set<String>> {
        Binding {
            if case .options(let value)? = state.value(for: filter) { return value }
            return []
        } set: { state[filter.id] = .options($0) }
    }

    private var excludeBinding: Binding<(included: Set<String>, excluded: Set<String>)> {
        Binding {
            if case .exclude(let included, let excluded)? = state.value(for: filter) {
                return (included, excluded)
            }
            return ([], [])
        } set: { state[filter.id] = .exclude(included: $0.included, excluded: $0.excluded) }
    }

    private var sortBinding: Binding<(index: Int, ascending: Bool)> {
        Binding {
            if case .sort(let index, let ascending)? = state.value(for: filter) {
                return (index, ascending)
            }
            return (0, false)
        } set: { state[filter.id] = .sort(index: $0.index, ascending: $0.ascending) }
    }

    private var triStateMode: TriStateMode {
        guard case .triState(let included, let excluded)? = state.value(for: filter) else { return .off }
        return included ? .include : (excluded ? .exclude : .off)
    }

    // MARK: Summaries

    private var selectedCount: Int { optionsBinding.wrappedValue.count }

    private var excludeCount: Int {
        let value = excludeBinding.wrappedValue
        return value.included.count + value.excluded.count
    }

    private func summary(_ count: Int) -> String {
        count == 0 ? "Any" : "\(count) selected"
    }
}

// MARK: - Tri-state

private enum TriStateMode {
    case off, include, exclude

    var next: TriStateMode {
        switch self {
        case .off: .include
        case .include: .exclude
        case .exclude: .off
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle"
        case .include: "checkmark.circle.fill"
        case .exclude: "xmark.circle.fill"
        }
    }
}

private struct TriStateRow: View {
    let name: String
    let mode: TriStateMode
    let onChange: (TriStateMode) -> Void

    var body: some View {
        Button {
            onChange(mode.next)
        } label: {
            HStack {
                Text(name)
                Spacer()
                AppIcon(systemName: mode.symbol, size: 17)
                    .foregroundStyle(mode == .exclude ? AppTheme.warning : Color.accentColor)
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Sort

private struct SortRow: View {
    let name: String
    let options: [FilterOption]
    @Binding var selection: (index: Int, ascending: Bool)

    var body: some View {
        Picker(name, selection: Binding(
            get: { selection.index },
            set: { selection = ($0, selection.ascending) }
        )) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Text(option.name).tag(index)
            }
        }
        Picker("Direction", selection: Binding(
            get: { selection.ascending },
            set: { selection = (selection.index, $0) }
        )) {
            Text("Descending").tag(false)
            Text("Ascending").tag(true)
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Option lists

/// Single choice from a long list; tapping a row picks it and goes back.
private struct FilterChoiceList: View {
    let title: String
    let options: [FilterOption]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(visible) { option in
            Button {
                selection = option.id
                dismiss()
            } label: {
                HStack {
                    Text(option.name)
                    Spacer()
                    if selection == option.id {
                        AppIcon(systemName: "checkmark", size: 17, relativeTo: .body).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .appNavigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
    }

    private var visible: [FilterOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

private struct FilterOptionList: View {
    let title: String
    let options: [FilterOption]
    @Binding var state: Set<String>
    @State private var query = ""

    var body: some View {
        List(visible) { option in
            Button {
                if state.contains(option.id) { state.remove(option.id) } else { state.insert(option.id) }
            } label: {
                HStack {
                    Text(option.name)
                    Spacer()
                    if state.contains(option.id) {
                        AppIcon(systemName: "checkmark", size: 17, relativeTo: .body).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .appNavigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            if !state.isEmpty {
                ToolbarItem(placement: .primaryAction) { Button("Clear") { state = [] } }
            }
        }
    }

    private var visible: [FilterOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// Tap cycles a value through off, included and excluded.
private struct FilterExcludableList: View {
    let title: String
    let options: [FilterOption]
    @Binding var state: (included: Set<String>, excluded: Set<String>)
    @State private var query = ""

    var body: some View {
        List(visible) { option in
            Button {
                cycle(option.id)
            } label: {
                HStack {
                    Text(option.name)
                    Spacer()
                    if state.included.contains(option.id) {
                        AppIcon(systemName: "checkmark.circle.fill", size: 17, relativeTo: .body).foregroundStyle(Color.accentColor)
                    } else if state.excluded.contains(option.id) {
                        AppIcon(systemName: "xmark.circle.fill", size: 17, relativeTo: .body).foregroundStyle(AppTheme.warning)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .appNavigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            if !state.included.isEmpty || !state.excluded.isEmpty {
                ToolbarItem(placement: .primaryAction) { Button("Clear") { state = ([], []) } }
            }
        }
    }

    private func cycle(_ id: String) {
        var value = state
        if value.included.remove(id) != nil {
            value.excluded.insert(id)
        } else if value.excluded.remove(id) == nil {
            value.included.insert(id)
        }
        state = value
    }

    private var visible: [FilterOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}
