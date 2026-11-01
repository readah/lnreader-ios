// ScanlatorSettingsView.swift - Visibility and priority for scanlators.
//
// Two independent features, deliberately not nested:
//
// - Hiding: uncheck a scanlator and its chapters disappear from the list.
//   This works on its own.
// - Priority: merge chapters that share a number, keeping the scanlator highest
//   in the list. Only then does the order matter, so only then can rows be
//   dragged.
//
// The list used to be hidden entirely behind the priority toggle, which made
// "just hide this scanlator" impossible.

import SwiftUI

struct ScanlatorSettingsView: View {

    @Bindable var settings: ScanlatorSettings
    /// Scanlators present in this entry's chapter list.
    let scanlators: [String]

    @Environment(\.dismiss) private var dismiss

    /// The list's own copy of the order. A move updates it in the same
    /// transaction as the drop; reading the order back from `settings` lagged a
    /// frame behind, and the moved row kept the corners of the slot it left.
    @State private var rows: [String] = []
    /// Bumped after a move so the section's cells are rebuilt: UIKit does not
    /// re-mask a row dragged to or from either end, which left it square.
    @State private var layoutRevision = 0

    private var allVisible: Bool {
        !rows.contains { settings.value.disabled.contains($0) }
    }

    private var isPriorityOn: Bool { settings.isPriorityEnabled }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Priority scanlator", isOn: priorityBinding)
                } footer: {
                    Text(isPriorityOn
                        ? "Chapters with the same number are merged, keeping the scanlator highest in this list. Drag to reorder."
                        : "Merge duplicate chapters by scanlator, and choose which scanlator wins. Hiding works either way.")
                }

                Section {
                    if rows.isEmpty {
                        Text("No scanlators in this chapter list yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows, id: \.self) { name in
                            row(name)
                        }
                        .onMove { source, destination in
                            rows.move(fromOffsets: source, toOffset: destination)
                            settings.setPriority(rows)
                            remaskAfterDrop()
                        }
                    }
                } header: {
                    sectionHeader
                } footer: {
                    Text(isPriorityOn
                        ? "Top of the list wins. Uncheck one to hide it."
                        : "Uncheck one to hide its chapters.")
                }
                .id(layoutRevision)
            }
            // Dragging only means something when priority merging is on, so edit
            // mode follows that toggle — visibility does not.
            .environment(\.editMode, .constant(isPriorityOn ? .active : .inactive))
            .navigationTitle("Scanlators")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { rows = settings.orderedScanlators(from: scanlators) }
            .onChange(of: scanlators) { _, new in
                rows = settings.orderedScanlators(from: new)
            }
        }
    }

    /// Rebuild the section once the drop has settled, with no animation, so
    /// the cells get their corners back without a visible swap. Doing it in
    /// the move itself fought the drop animation and stuttered.
    private func remaskAfterDrop() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { layoutRevision += 1 }
        }
    }

    /// "Scanlators" with one button that shows every scanlator, or hides them
    /// all once they are all showing.
    private var sectionHeader: some View {
        HStack {
            Text("Scanlators")
            Spacer()
            if rows.count > 1 {
                Button(allVisible ? "Hide all" : "Show all") {
                    Haptics.shared.selection()
                    settings.setAllVisible(rows, !allVisible)
                }
                .font(Typography.caption)
                .textCase(nil)
            }
        }
    }

    /// Checkbox and name on the leading edge. In priority mode edit mode draws
    /// the drag handle on the trailing edge; the row draws none of its own.
    private func row(_ name: String) -> some View {
        let visible = !settings.value.disabled.contains(name)
        return Button {
            Haptics.shared.selection()
            settings.setVisible(name, !visible)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(visible ? AppTheme.controlFill : AppTheme.hairline)
                    .contentTransition(.symbolEffect(.replace))

                Text(displayName(name))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayName(name))
        .accessibilityValue(visible ? "Shown" : "Hidden")
        .accessibilityAddTraits(visible ? .isSelected : [])
    }

    /// Scanlator names arrive as the source spells them ("Official", "unofficial").
    private func displayName(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    private var priorityBinding: Binding<Bool> {
        Binding(
            get: { settings.isPriorityEnabled },
            set: { settings.setPriorityEnabled($0) }
        )
    }
}
