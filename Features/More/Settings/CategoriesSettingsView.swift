// CategoriesSettingsView.swift
// Create, rename, reorder and delete library categories, and set their update scope.

import SwiftData
import SwiftUI

struct CategoriesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.order) private var categories: [Category]

    /// Per-category overrides are keyed by name, not by ID. A rename has to
    /// carry them across and a delete has to drop them.
    @AppStorage("library.sorts") private var sortsJSON = "{}"
    @AppStorage("library.displays") private var displaysJSON = "{}"
    @AppStorage("library.filters") private var filtersJSON = "{}"

    @State private var editor: CategoryEditor?
    @State private var pendingDelete: Category?
    /// `Category.entries` is a relationship: counts are read off the main
    /// thread and cached, never walked in `body`.
    @State private var titleCounts: [PersistentIdentifier: Int] = [:]

    var body: some View {
        List {
            categoriesSection
        }
        .settingsScreen("Categories")
        .toolbar { toolbar }
        .sheet(item: $editor) { item in
            CategoryEditorSheet(
                category: item.category,
                initialName: item.name,
                initialExcluded: item.excluded,
                otherNames: categories.compactMap { $0 === item.category ? nil : $0.name },
                titleCount: item.category.flatMap { titleCounts[$0.persistentModelID] } ?? 0,
                onSave: { name, excluded in
                    self.commit(item, name: name, excluded: excluded)
                    self.editor = nil
                },
                onTitlesChanged: { Task { await self.loadTitleCounts() } }
            )
        }
        .confirmationDialog(
            "Delete category?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete category", role: .destructive) {
                if let category = pendingDelete { delete(category) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let category = pendingDelete {
                Text("\(titleCounts[category.persistentModelID] ?? 0) titles in \(category.name) stay in your library. This category's sort, display and filter overrides are removed.")
            }
        }
        .task(id: categoryIDs) { await loadTitleCounts() }
    }

    private var categoryIDs: [PersistentIdentifier] {
        categories.map(\.persistentModelID)
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { presented in if !presented { pendingDelete = nil } }
        )
    }

    // MARK: - List

    private var categoriesSection: some View {
        Section {
            if categories.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    title: "No categories",
                    subtitle: "Group novels and manga into categories to filter your library.",
                    actionTitle: "Add category",
                    action: { editor = CategoryEditor() }
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(categories) { category in
                    categoryRow(category)
                }
                .onMove(perform: move)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Categories are shared by novels and manga. Tap one to name it, choose its titles or change its update scope, drag in Edit to reorder, and swipe left to delete it. Deleting a category keeps its titles in the library.")
        }
    }

    private func categoryRow(_ category: Category) -> some View {
        Button {
            editor = CategoryEditor(category)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(.primary)
                    Text(titleSummary(for: category))
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if CategoryFlags.isExcluded(category.flags) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Excluded from updates")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDelete = category }
        }
    }

    private func titleSummary(for category: Category) -> String {
        let count = titleCounts[category.persistentModelID] ?? 0
        return count == 1 ? "1 title" : "\(count) titles"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if categories.count > 1 {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Add category", systemImage: "plus") {
                editor = CategoryEditor()
            }
            .accessibilityLabel("Add category")
        }
    }

    // MARK: - Counts

    /// `Category.entries` is only walked in a background context. Publishing
    /// the result is the one main-thread hop, so a large library cannot stall
    /// this screen while it renders.
    private func loadTitleCounts() async {
        let container = modelContext.container
        let snapshot = await Task.detached(priority: .utility) { () -> [PersistentIdentifier: Int] in
            let context = ModelContext(container)
            let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
            var result: [PersistentIdentifier: Int] = [:]
            for category in all {
                result[category.persistentModelID] = category.entries.count
            }
            return result
        }.value
        titleCounts = snapshot
    }

    // MARK: - Mutations

    private func commit(_ item: CategoryEditor, name: String, excluded: Bool) {
        guard let category = item.category else {
            create(name: name, excluded: excluded)
            return
        }
        rename(category, to: name, excluded: excluded)
    }

    private func create(name: String, excluded: Bool) {
        let category = Category(
            name: name,
            // The same rule MihonBackup.restore uses, so imports and the editor
            // never race for the same slot.
            order: (categories.map(\.order).max() ?? -1) + 1,
            flags: CategoryFlags.setting(0, excluded: excluded)
        )
        modelContext.insert(category)
        try? modelContext.save()
        Haptics.shared.notify(.success)
    }

    private func rename(_ category: Category, to name: String, excluded: Bool) {
        let oldName = category.name
        if oldName != name {
            migrateSettings(from: oldName, to: name)
        }
        // Mutate in place: `#Unique<Category>([\.name])` upserts on a name
        // collision, which would silently replace this object and drop the
        // inverse of `Entry.categories`. Names are validated before we get here.
        category.name = name
        category.flags = CategoryFlags.setting(category.flags, excluded: excluded)
        try? modelContext.save()
        Haptics.shared.notify(.success)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        renumber(reordered)
        try? modelContext.save()
        Haptics.shared.selection()
    }

    private func delete(_ category: Category) {
        forgetSettings(for: category.name)
        // No delete rule on the relationship: SwiftData unlinks the entries,
        // which are the whole point of keeping them in the library.
        modelContext.delete(category)
        renumber(categories.filter { $0 !== category })
        try? modelContext.save()
        pendingDelete = nil
        Haptics.shared.notify(.success)
    }

    /// `Category.order` goes into both backup formats, so keep it contiguous
    /// after a move or a delete rather than leaving gaps.
    private func renumber(_ ordered: [Category]) {
        for (index, category) in ordered.enumerated() {
            category.order = index
        }
    }

    // MARK: - Per-category overrides

    /// Sorts, display modes and filters live in three UserDefaults values keyed
    /// by category name. Rewriting all three here keeps a new per-category
    /// setting from being forgotten later.
    private func migrateSettings(from oldName: String, to newName: String) {
        var sorts = LibrarySortStore(json: sortsJSON)
        var displays = LibraryDisplayStore(json: displaysJSON)
        var filters = LibraryFilterStore(json: filtersJSON)
        sorts.rename(from: oldName, to: newName)
        displays.rename(from: oldName, to: newName)
        filters.rename(from: oldName, to: newName)
        sortsJSON = sorts.json
        displaysJSON = displays.json
        filtersJSON = filters.json
    }

    private func forgetSettings(for name: String) {
        var sorts = LibrarySortStore(json: sortsJSON)
        var displays = LibraryDisplayStore(json: displaysJSON)
        var filters = LibraryFilterStore(json: filtersJSON)
        sorts.remove(name)
        displays.remove(name)
        filters.remove(name)
        sortsJSON = sorts.json
        displaysJSON = displays.json
        filtersJSON = filters.json
    }
}

// MARK: - Editor state

/// Plain values for the sheet. The sheet never holds a `Category` model, so
/// cancelling cannot leave a half-edited object behind.
private struct CategoryEditor: Identifiable {
    let id = UUID()
    let category: Category?
    let name: String
    let excluded: Bool

    init(_ category: Category? = nil) {
        self.category = category
        self.name = category?.name ?? ""
        self.excluded = category.map { CategoryFlags.isExcluded($0.flags) } ?? false
    }
}

// MARK: - Editor sheet

private struct CategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let category: Category?
    let otherNames: [String]
    let titleCount: Int
    let onSave: (String, Bool) -> Void
    let onTitlesChanged: () -> Void

    @State private var name: String
    @State private var excluded: Bool

    init(
        category: Category?,
        initialName: String,
        initialExcluded: Bool,
        otherNames: [String],
        titleCount: Int,
        onSave: @escaping (String, Bool) -> Void,
        onTitlesChanged: @escaping () -> Void
    ) {
        self.category = category
        self.otherNames = otherNames
        self.titleCount = titleCount
        self.onSave = onSave
        self.onTitlesChanged = onTitlesChanged
        _name = State(initialValue: initialName)
        _excluded = State(initialValue: initialExcluded)
    }

    private var isNew: Bool { category == nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `#Unique<Category>([\.name])` only treats exact matches as duplicates;
    /// block case variants too so the library tabs cannot show two names that
    /// read the same.
    private var validationMessage: String? {
        if trimmedName.isEmpty { return "Give the category a name." }
        if otherNames.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedName.lowercased()
        }) {
            return "A category with this name already exists."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                    if let validationMessage, !trimmedName.isEmpty {
                        Text(validationMessage)
                            .font(Typography.caption)
                            .foregroundStyle(AppTheme.destructive)
                    }
                }

                Section {
                    Toggle("Exclude from library updates", isOn: $excluded)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Excluded categories are skipped by library-wide and automatic updates. You can still refresh one from the library screen.")
                }

                if let category {
                    Section {
                        NavigationLink {
                            CategoryTitlesPickerView(category: category, onDismiss: onTitlesChanged)
                        } label: {
                            LabeledContent("Titles", value: "\(titleCount)")
                        }
                    } footer: {
                        Text("Choose which novels and manga belong to this category. A title can be in several categories, and stays in your library if this one is deleted.")
                    }
                }
            }
            .navigationTitle(isNew ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmedName, excluded)
                        dismiss()
                    }
                    .disabled(validationMessage != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Titles picker

/// Which library entries belong to one category. Membership is written on the
/// `Category.entries` side, the direction `V2SchemaChecks` proves updates both
/// halves of the inverse (removing an entry must not delete either object).
private struct CategoryTitlesPickerView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Entry> { $0.inLibrary },
        sort: \Entry.title
    )
    private var entries: [Entry]

    let category: Category
    let onDismiss: () -> Void

    @State private var searchText = ""
    /// Membership is read off the main thread, so a row never walks the
    /// `categories` relationship while the list is rendering.
    @State private var memberIDs: Set<PersistentIdentifier> = []

    private var visibleEntries: [Entry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                if visibleEntries.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: searchText.isEmpty ? "No titles in your library" : "No matches",
                        subtitle: searchText.isEmpty
                            ? "Add a title to your library before organising it."
                            : "Try a different title."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(visibleEntries) { entry in
                        Button {
                            toggle(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Text(entry.displayTitle)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if memberIDs.contains(entry.persistentModelID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("In this category")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("\(memberIDs.count) of \(entries.count) titles in \(category.name). A title can belong to more than one category.")
            }
        }
        .navigationTitle("Titles")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search titles")
        .task(id: category.persistentModelID) { await loadMembers() }
        .onDisappear(perform: onDismiss)
    }

    private func loadMembers() async {
        let container = modelContext.container
        let id = category.persistentModelID
        let members = await Task.detached(priority: .utility) { () -> Set<PersistentIdentifier> in
            let context = ModelContext(container)
            guard let target = context.model(for: id) as? Category else { return [] }
            return Set(target.entries.map(\.persistentModelID))
        }.value
        memberIDs = members
    }

    private func toggle(_ entry: Entry) {
        let id = entry.persistentModelID
        if memberIDs.contains(id) {
            memberIDs.remove(id)
            category.entries.removeAll { $0.persistentModelID == id }
        } else {
            memberIDs.insert(id)
            category.entries.append(entry)
        }
        try? modelContext.save()
        Haptics.shared.selection()
    }
}
